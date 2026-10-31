// 控车路径里的蓝牙数字钥匙桥：优先 BLE，远程兜底；非 BLE 能力在优先模式下隐藏。
//
// 与设置页 DigitalKeySection 共用同一条 MethodChannel('mymg/ble')：
// handler 挂在 BleKeyBridge 单例上，避免两处抢 handler。

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mymg/src/rust/api.dart';
import 'package:mymg/src/rust/vehicle/control.dart';

import 'control_config.dart';

const String kBlePreferKey = 'mymg.ble.prefer';
const String kBleLastMacKey = 'mymg.ble.last_mac';
const String kBleLastRefKey = 'mymg.ble.last_key_ref';
const String kBleAutoDriveKey = 'mymg.ble.auto_drive_after_unlock';

/// BLE 能直接做的指令（与 VehicleBleCommand 对齐）
const Set<String> kBleCapabilities = {
  'lock',
  'unlock',
  'trunk', // BASE_BOOT_UNLOCK
  'drive', // BASE_DRIVE_CYCLE 120秒打火
};

enum BleBridgeState {
  idle,
  connecting,
  connected,
  busy,
  error,
}

class BleKeyBridge {
  BleKeyBridge._();

  static String _friendlyBleError(Object e) {
    final s = e.toString();
    if (s.contains('MissingPluginException') || s.contains('not registered')) {
      return '原生蓝牙模块未就绪：请安装最新 APK，并授予附近设备/蓝牙权限后重试';
    }
    if (s.contains('Permission') || s.contains('permission')) {
      return '蓝牙权限不足：请到系统设置允许「附近设备 / 定位」后重试';
    }
    if (s.contains('TBOX') || s.contains('密钥')) {
      return s;
    }
    return '连接失败：$s';
  }

  static final BleKeyBridge instance = BleKeyBridge._();

  static const MethodChannel _ch = MethodChannel('mymg/ble');

  final _events = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _events.stream;

  BleBridgeState state = BleBridgeState.idle;
  String message = '';
  String? mac;
  String? connectMac;
  int keyRef = 0;
  /// SAIC 账号 userId：官方解锁指令载荷是 `"1"+userId`，车端据此认定“哪位用户的数字钥匙在场”
  /// （实测：不带 userId 时能开门、但解锁后无法免钥匙启动）
  String userId = '';
  String? _aesKey;
  String? _secretKey;
  bool preferBle = false;
  DateTime? _lastOkAt;

  /// 解锁成功后自动下发 driveCycle（120 秒打火）。
  /// **产品默认开启**：实测只解锁不能着车，必须补一次打火授权；
  /// 控车页已不再放独立的「启动」按钮，所以这里默认必须是 true。
  bool autoDriveAfterUnlock = true;

  /// 把开关同步给原生（原生是单例，跨引擎/跨页面只有它一份状态）
  Future<void> loadAutoDrive() async {
    try {
      final p = await SharedPreferences.getInstance();
      autoDriveAfterUnlock = p.getBool(kBleAutoDriveKey) ?? true;
    } catch (_) {}
    try {
      await _ch.invokeMethod('setAutoDriveAfterUnlock', {
        'enabled': autoDriveAfterUnlock,
      });
    } catch (_) {}
  }

  Future<void> setAutoDrive(bool v) async {
    autoDriveAfterUnlock = v;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(kBleAutoDriveKey, v);
    } catch (_) {}
    try {
      await _ch.invokeMethod('setAutoDriveAfterUnlock', {'enabled': v});
    } catch (_) {}
    _emit();
  }

  /// 近期是否成功建链/下发：用于「已连接」观感保持，不再闪「连接中」
  bool get recentlyOk =>
      _lastOkAt != null &&
      DateTime.now().difference(_lastOkAt!) < const Duration(minutes: 3);

  /// 申请蓝牙权限（幂等，失败静默）。
  /// 控车页可能是独立引擎首次发起 BLE 操作，不主动申请只会看到「缺少蓝牙连接权限」。
  Future<void> requestBlePermissions() async {
    try {
      await _ch.invokeMethod('requestPermissions');
    } catch (_) {}
  }

  /// 解锁载荷需要 userId：内存 → 原生缓存 → ControlConfig（登录态里已有）
  Future<void> ensureUserId() async {
    if (userId.isNotEmpty) return;
    try {
      final cached = await _ch.invokeMethod<Map>('cachedMaterial');
      final uid = (cached?['userId'] as String?) ?? '';
      if (uid.isNotEmpty) {
        userId = uid;
        return;
      }
    } catch (_) {}
    try {
      final c = await ControlConfig.load();
      if (c.userId.isNotEmpty) userId = c.userId;
    } catch (_) {}
  }

  /// 是否处于「优先蓝牙」且已连上 / 正在连 —— 控制区按此隐藏非 BLE 功能
  bool get bleModeActive =>
      preferBle &&
      (state == BleBridgeState.connected || state == BleBridgeState.busy);

  /// 是否是本车 TBOX：tbox_mac / 广播地址（首尾对调）/ connectMac 三者任一
  bool matchesVehicle(String address) {
    final m = mac;
    if (m == null || m.isEmpty) return false;
    final a = address.replaceAll(':', '').replaceAll('-', '').toUpperCase();
    if (a.length < 6) return false;
    final t = m.replaceAll(':', '').replaceAll('-', '').toUpperCase();
    if (t.length != 12) return false;
    if (a == t) return true;
    final swapped = t.substring(8) + t.substring(4, 8) + t.substring(0, 4);
    if (a == swapped) return true;
    final cm = (connectMac ?? '')
        .replaceAll(':', '')
        .replaceAll('-', '')
        .toUpperCase();
    return cm.length == 12 && a == cm;
  }

  bool get canBleLock => mac != null && _secretKey != null && _secretKey!.isNotEmpty;
  bool get canBleUnlock =>
      mac != null &&
      ((_secretKey != null && _secretKey!.isNotEmpty) ||
          (_aesKey != null && _aesKey!.isNotEmpty));
  bool get canBleTrunk =>
      mac != null && _secretKey != null && _secretKey!.isNotEmpty;
  bool get canBleLiftgate => canBleTrunk;
  bool get canBleDrive => canBleLock;

  Future<void> init() async {
    // 统一持有 MethodChannel 回调：设置页/控车页都经 onNativeEvent 更新状态
    _ch.setMethodCallHandler((call) async {
      final a = Map<String, dynamic>.from(
        (call.arguments as Map?)?.map((k, v) => MapEntry(k.toString(), v)) ??
            const {},
      );
      onNativeEvent(call.method, a);
      return null;
    });
    final p = await SharedPreferences.getInstance();
    preferBle = p.getBool(kBlePreferKey) ?? false;
    mac = p.getString(kBleLastMacKey);
    keyRef = p.getInt(kBleLastRefKey) ?? 0;
    await loadAutoDrive();
    // 冷启动后 prefs 里只有 mac/keyRef，密钥在原生落盘里（Dart 不持久化密钥）。
    // 不水合的话 lock/trunk/drive 会被「缺密钥」挡在前端，看起来就是"控车失败"。
    await hydrateFromNative();
    _emit();
  }

  /// 从原生落盘材料回填 Dart 侧状态（离线 / 独立引擎 / token 过期时唯一可用来源）。
  /// 原生 cachedMaterial 会先把 SharedPreferences 里的材料灌进内存再返回。
  Future<bool> hydrateFromNative() async {
    try {
      final cached = await _ch.invokeMethod<Map>('cachedMaterial');
      if (cached == null) return false;
      final tbox = (cached['tboxMac'] as String?) ?? '';
      if (tbox.isNotEmpty) mac = tbox;
      final aes = (cached['aesKey'] as String?) ?? '';
      if (aes.isNotEmpty) _aesKey = aes;
      final sec = (cached['secretKey'] as String?) ?? '';
      if (sec.isNotEmpty) _secretKey = sec;
      final address = (cached['connectMac'] as String?) ?? '';
      if (address.isNotEmpty) connectMac = address;
      final uid = (cached['userId'] as String?) ?? '';
      if (uid.isNotEmpty) userId = uid;
      final ref = cached['keyReference'];
      final r = ref is int ? ref : (ref is num ? ref.toInt() : 0);
      if (r != 0) keyRef = r;
      if (mac != null && keyRef != 0) {
        final p = await SharedPreferences.getInstance();
        await p.setString(kBleLastMacKey, mac!);
        await p.setInt(kBleLastRefKey, keyRef);
      }
      _emit();
      return mac != null && mac!.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// 由持有 MethodChannel 的 UI（设置页）转发原生事件进来
  void onNativeEvent(String method, Map<String, dynamic> a) {
    if (method == 'status') {
      message = (a['message'] as String?) ?? '';
      final stage = (a['stage'] as String?) ?? '';
      switch (stage) {
        case 'connecting':
          // 短时成功过：静默保活重连，不闪「连接中」
          state = recentlyOk ? BleBridgeState.connected : BleBridgeState.connecting;
          break;
        case 'connected':
        case 'discovered':
        case 'booking':
        case 'authing':
        case 'sent':
        case 'ready':
          _lastOkAt = DateTime.now();
          state = BleBridgeState.connected;
          break;
        case 'busy':
          state = BleBridgeState.busy;
          break;
        case 'error':
          state = BleBridgeState.error;
          break;
        case 'timeout':
          // 指令超时 ≠ 连接断开：保持已连接观感，避免状态闪烁
          state = BleBridgeState.connected;
          break;
        case 'disconnected':
          // 意外断开且近期连过：保持 connected 观感，等静默重连
          state = recentlyOk ? BleBridgeState.connected : BleBridgeState.idle;
          break;
        default:
          break;
      }
    }
    _emit();
    if (!_events.isClosed) {
      _events.add({'method': method, 'raw': a, ..._payload()});
    }
  }

  Map<String, dynamic> _payload() => {
        'stage': state.name,
        'message': message,
        'prefer': preferBle,
        'mac': mac,
      };

  Future<void> setPrefer(bool v) async {
    preferBle = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(kBlePreferKey, v);
    _emit();
  }

  /// 拉钥匙列表并缓存当前车的 mac / 密钥 / keyRef
  Future<bool> loadKeyMaterial({String? preferVin, bool force = false}) async {
    // 已有密钥则直接复用，加速连接。⚠️ keyRef 必须一起判定：
    // keyRef=0 时 BookingId 会变成 00000000 → 车端会立即断开链路（实测 status=19）。
    if (!force &&
        mac != null &&
        (_secretKey != null || _aesKey != null) &&
        keyRef != 0) {
      return true;
    }
    final c = await ControlConfig.load();
    if (!c.tokenOk) return false;
    var userId = c.userId;
    if (userId.isEmpty) {
      try {
        final fetched =
            await authFetchUserId(token: c.token!, deviceId: c.headerDeviceId);
        if (fetched != null && fetched.isNotEmpty) {
          userId = fetched;
          await ControlConfig.saveIdentity(
            brand: c.brand,
            userId: userId,
            mobile: c.mobile,
            headerDeviceId: c.headerDeviceId,
          );
        }
      } catch (_) {}
    }
    if (userId.isNotEmpty) this.userId = userId;
    try {
      final r = await vehicleFetchBluetoothKeys(
        brand: c.brand,
        token: c.token!,
        vin: c.vin ?? preferVin ?? '',
        userId: userId,
        mobile: c.mobile,
        headerDeviceId: c.headerDeviceId,
      );
      final all = <BluetoothKeyInfo>[
        ...(r.digitalKeyList ?? const []),
        ...(r.bluetoothKeyList ?? const []),
      ];
      // 优先匹配当前 VIN，否则取第一把
      final vin = c.vin;
      BluetoothKeyInfo? pick;
      for (final k in all) {
        if (vin != null && k.vin == vin) {
          pick = k;
          break;
        }
      }
      pick ??= all.isNotEmpty ? all.first : null;
      if (pick == null) return false;
      final raw =
          pick.raw is Map ? Map<String, dynamic>.from(pick.raw as Map) : null;
      final m = (raw?['tbox_mac'] as String?) ?? pick.mac ?? '';
      if (m.isEmpty) return false;
      mac = m;
      // BLE 广播地址：tbox_mac 首尾 2 字节组对调（见 docs/ble-digital-key-reverse.md）
      final mm = m.replaceAll(':', '').replaceAll('-', '').toUpperCase();
      if (mm.length == 12) {
        final swapped = mm.substring(8) + mm.substring(4, 8) + mm.substring(0, 4);
        final parts = <String>[];
        for (var i = 0; i < 12; i += 2) {
          parts.add(swapped.substring(i, i + 2));
        }
        connectMac = parts.join(':');
      } else {
        connectMac = m;
      }
      _aesKey = (raw?['aes_key'] as String?) ?? pick.aesKey;
      _secretKey = (raw?['secret_key'] as String?) ?? pick.secretKey;
      final ref = raw?['key_reference'];
      keyRef = ref is int ? ref : (ref is num ? ref.toInt() : 0);
      final p = await SharedPreferences.getInstance();
      await p.setString(kBleLastMacKey, mac!);
      await p.setInt(kBleLastRefKey, keyRef);
      _emit();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 开 App / 进控车页各最多试一次，避免反复重连
  bool _appConnectTried = false;
  bool _sheetConnectTried = false;

  Future<void> connect({String from = 'manual'}) async {
    // 已连接则直接复用，不再 probe
    if (state == BleBridgeState.connected) {
      _emit();
      return;
    }
    if (state == BleBridgeState.connecting || state == BleBridgeState.busy) return;
    if (preferBle) {
      await setPrefer(true);
    }
    try {
      await _ch.invokeMethod('requestPermissions');
    } catch (_) {}
    // 独立引擎需要先恢复钥匙材料，连接状态不能替代材料同步。
    try {
      final cached = await _ch.invokeMethod<Map>('cachedMaterial');
      final tbox = cached?['tboxMac'] as String? ?? '';
      if (tbox.isNotEmpty) {
        mac = tbox;
        _aesKey = cached?['aesKey'] as String?;
        _secretKey = cached?['secretKey'] as String?;
        final address = cached?['connectMac'] as String? ?? '';
        if (address.isNotEmpty) connectMac = address;
        final uid = cached?['userId'] as String? ?? '';
        if (uid.isNotEmpty) userId = uid;
        final ref = cached?['keyReference'];
        if (ref is num) keyRef = ref.toInt();
      }
    } catch (_) {}
    try {
      final nativeConnected = await _ch.invokeMethod<bool>('isConnected') ?? false;
      if (nativeConnected) {
        _lastOkAt = DateTime.now();
        state = BleBridgeState.connected;
        message = '已连接';
        _emit();
        return;
      }
    } catch (_) {}
    // 近期连过且只差重连：静默重建，不闪「连接中」
    if (recentlyOk) {
      message = '已连接';
    }
    // 密钥：内存 → 原生缓存 → 网络（keyRef=0 会导致 BookingId 全 0 被车端踢）
    if (mac == null || _secretKey == null || keyRef == 0) {
      try {
        final cached = await _ch.invokeMethod<Map>('cachedMaterial');
        final tbox = cached?['tboxMac'] as String? ?? '';
        if (tbox.isNotEmpty) {
          mac = tbox;
          _aesKey = cached?['aesKey'] as String?;
          _secretKey = cached?['secretKey'] as String?;
          final cm = cached?['connectMac'] as String? ?? '';
          if (cm.isNotEmpty) connectMac = cm;
          final ref = cached?['keyReference'];
          if (ref is int && ref != 0) {
            keyRef = ref;
          } else if (ref is num) {
            keyRef = ref.toInt();
          } else if (ref is String && ref.isNotEmpty) {
            keyRef = int.tryParse(ref) ?? keyRef;
          }
          if (keyRef != 0) {
            final p = await SharedPreferences.getInstance();
            await p.setInt(kBleLastRefKey, keyRef);
          }
        }
      } catch (_) {}
    }
    if (mac == null || keyRef == 0 || _secretKey == null || _secretKey!.isEmpty) {
      await loadKeyMaterial();
    }
    if (mac == null) {
      state = BleBridgeState.error;
      message = '无 TBOX 密钥，无法连接蓝牙钥匙';
      _emit();
      return;
    }
    state = BleBridgeState.connecting;
    message = '正在连接 TBOX…';
    _emit();
    // userId 先灌给原生：手表/磁贴等冷启动路径只调 performCachedAction，
    // 拿不到 Dart 参数，靠这里预热解锁载荷。
    await ensureUserId();
    try {
      final probeArgs = <String, dynamic>{
        'tboxMac': mac,
        'connectMac': connectMac,
        'userId': userId,
      };
      // 带上 keyReference（原生也有落盘兜底）：否则冷启动的磁贴/小组件
      // 会因为 probe 没有 ref 而只有「材料未同步」的提示。
      if (keyRef != 0) probeArgs['keyReference'] = keyRef;
      await _ch.invokeMethod('probe', probeArgs);
    } catch (e) {
      state = BleBridgeState.error;
      message = _friendlyBleError(e);
      _emit();
    }
  }

  /// App 启动：只试一次
  Future<void> connectOnceOnAppStart() async {
    if (_appConnectTried) return;
    _appConnectTried = true;
    await init();
    if (!preferBle) return;
    if (state == BleBridgeState.connected) return;
    await connect(from: 'app_start');
  }

  /// 控车弹窗打开：若未连接，再试一次
  Future<void> connectOnceOnSheetOpen() async {
    if (state == BleBridgeState.connected) return;
    if (_sheetConnectTried && state != BleBridgeState.idle) return;
    _sheetConnectTried = true;
    await init();
    if (!preferBle) return;
    await connect(from: 'sheet_open');
  }

  Future<void> disconnect() async {
    try {
      await _ch.invokeMethod('disconnect');
    } catch (_) {}
    state = BleBridgeState.idle;
    message = '已断开';
    _emit();
  }

  /// 发起 BLE 控车。返回 true 表示已交给 BLE（结果看 events）。
  Future<bool> send(String action) async {
    // 材料补齐顺序：原生落盘（离线/磁贴/小组件冷启动）→ 联网钥匙列表 → 再读一次原生。
    // 旧逻辑只看 mac/keyRef，密钥为空时 lock/trunk/drive 会直接 return false，
    // 界面上只剩一句没信息量的"发送失败"（用户 2026-10-26 报的三入口控车失败即此）。
    await hydrateFromNative();
    final needSecret = action != 'unlock';
    bool missing() =>
        mac == null ||
        keyRef == 0 ||
        (needSecret && (_secretKey == null || _secretKey!.isEmpty)) ||
        (action == 'unlock' &&
            (_secretKey == null || _secretKey!.isEmpty) &&
            (_aesKey == null || _aesKey!.isEmpty));
    if (missing()) {
      await loadKeyMaterial();
      if (missing()) await hydrateFromNative();
    }
    if (mac == null || mac!.isEmpty) {
      state = BleBridgeState.error;
      message = '未找到 TBOX 密钥：请联网后在「设置 → 蓝牙数字钥匙」刷新钥匙列表';
      _emit();
      return false;
    }
    if (keyRef == 0) {
      state = BleBridgeState.error;
      message = '数字钥匙材料未同步：缺少 keyReference，请联网后重试';
      _emit();
      return false;
    }
    if (missing()) {
      state = BleBridgeState.error;
      message = '缺少车辆密钥：请联网后在「设置 → 蓝牙数字钥匙」刷新钥匙列表后重试';
      _emit();
      return false;
    }
    await ensureUserId();
    _lastOkAt = DateTime.now();
    // 与设置页 DigitalKeySection 相同：直接 invokeMethod 原生后台执行，
    // 连接/复用 GATT/鉴权全在 MymgBleKeyClient.startFlow 内完成。
    try {
      final args = <String, dynamic>{
        'tboxMac': mac,
        'aesKey': _aesKey ?? '',
        'secretKey': _secretKey ?? '',
        'keyReference': keyRef,
        'connectMac': connectMac,
        'userId': userId,
      };
      switch (action) {
        case 'unlock':
          await _ch.invokeMethod('unlock', args);
          return true;
        case 'lock':
          await _ch.invokeMethod('lock', args);
          return true;
        case 'trunk':
          await _ch.invokeMethod('trunk', args);
          return true;
        case 'liftgate_open':
        case 'liftgateOpen':
          await _ch.invokeMethod('liftgateOpen', args);
          return true;
        case 'liftgate_close':
        case 'liftgateClose':
          await _ch.invokeMethod('liftgateClose', args);
          return true;
        case 'drive':
          await _ch.invokeMethod('drive', args);
          return true;
        default:
          return false;
      }
    } catch (_) {
      return false;
    }
  }

  void _emit() {
    if (_events.isClosed) return;
    _events.add({
      // method 必须显式：digital_key_section 只记 status/challenge/notify/services，
      // 缺省会被当成空 status 写成 "[]" 刷屏
      'method': 'bridge',
      'state': state.name,
      'message': message,
      'mac': mac,
      'prefer': preferBle,
      'bleMode': bleModeActive,
      'canLock': canBleLock,
      'canUnlock': canBleUnlock,
      'canTrunk': canBleTrunk,
      'canDrive': canBleDrive,
    });
  }
}
