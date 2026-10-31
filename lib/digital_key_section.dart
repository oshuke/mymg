// 设置 → 蓝牙数字钥匙
//
// 1) 拉取官方 bluetoothAndDigitalKeys 列表
// 2) 多钥匙选择 + 密钥状态（aes/secret 是否就绪）
// 3) BLE 扫描 RSSI + GATT 探测 / 解锁 / 锁车（协议实现见原生 MymgBleKeyClient 扩展点）

import 'app_config.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'theme_controller.dart';
import 'package:flutter/services.dart';

import 'package:mymg/src/rust/api.dart';
import 'package:mymg/src/rust/vehicle/control.dart';

import 'ble_key_bridge.dart';
import 'control_config.dart';
import 'err_util.dart';

/// 设置页入口：蓝牙数字钥匙
/// （与「AI 智能分析 / 坚果云备份」同样的入口式折叠：设置页只留一行，点开才是细节）
class DigitalKeyEntryTile extends StatelessWidget {
  const DigitalKeyEntryTile({super.key});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.bluetooth),
      title: const Text('蓝牙数字钥匙'),
      subtitle: const Text('钥匙 / 密钥 · 车旁操作 · 诊断',
          style: TextStyle(fontSize: 12)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const DigitalKeyPage()),
      ),
    );
  }
}

/// 蓝牙数字钥匙详情页：钥匙列表 + 车旁操作 + GATT 诊断
class DigitalKeyPage extends StatelessWidget {
  const DigitalKeyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('蓝牙数字钥匙')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: const [
          DigitalKeySection(),
        ],
      ),
    );
  }
}

class DigitalKeySection extends StatefulWidget {
  const DigitalKeySection({super.key});

  @override
  State<DigitalKeySection> createState() => _DigitalKeySectionState();
}

class _DigitalKeySectionState extends State<DigitalKeySection> {
  bool _loading = false;
  String? _error;
  BluetoothKeysResponse? _keys;
  bool _bleScanning = false;
  final List<Map<String, dynamic>> _nearby = [];
  final MethodChannel _bleCh = const MethodChannel('mymg/ble');
  StreamSubscription<Map<String, dynamic>>? _bleSub;
  String _userId = '';
  final _userIdCtrl = TextEditingController();

  /// 当前选中的钥匙（多车场景）
  BluetoothKeyInfo? _selected;
  String? _vehicleMac;
  int _keyRef = 0;

  String _gattStage = '';
  String? _gattMsg;
  String? _challengeHex;
  bool _gattBusy = false;
  final List<String> _gattLog = [];
  /// 设置页蓝牙后台控车入口：与智能控车共用同一条原生 GATT 链路
  static const _showGattLab = true;

  @override
  void initState() {
    super.initState();
    _bindBleChannel();
    _boot();
  }

  @override
  void dispose() {
    _bleSub?.cancel();
    _userIdCtrl.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    final c = await ControlConfig.load();
    _userId = c.userId;
    _userIdCtrl.text = c.userId;
    await _loadKeys();
  }

  bool _isVehicleMac(String addr) {
    final m = _vehicleMac;
    if (m == null || m.isEmpty) return false;
    final a = addr.replaceAll(':', '').toUpperCase();
    final t = m.replaceAll(':', '').replaceAll('-', '').toUpperCase();
    if (t.length != 12) return false;
    if (a == t) return true;
    // 广播地址 = tbox_mac 首尾 2 字节组对调（与 BleKeyBridge.matchesVehicle 一致）
    final swapped = t.substring(8) + t.substring(4, 8) + t.substring(0, 4);
    return a == swapped;
  }

  /// 扫描到的车辆 BLE 地址（优先），否则由 tbox_mac 推导。
  String? _resolveConnectMac() {
    for (final n in _nearby) {
      final addr = (n['address'] as String?) ?? '';
      final name = ((n['name'] as String?) ?? '').toUpperCase();
      if (_isVehicleMac(addr) || name.contains('FMC')) return addr;
    }
    final t = _vehicleMac;
    if (t == null || t.length != 12) return null;
    final m = t.replaceAll(':', '').replaceAll('-', '').toUpperCase();
    final swapped = m.substring(8) + m.substring(4, 8) + m.substring(0, 4);
    final buf = StringBuffer();
    for (var i = 0; i < 12; i += 2) {
      if (i > 0) buf.write(':');
      buf.write(swapped.substring(i, i + 2));
    }
    return buf.toString();
  }

  int? _vehicleRssi() {
    for (final n in _nearby) {
      final addr = (n['address'] as String?) ?? '';
      if (_isVehicleMac(addr)) return n['rssi'] as int?;
    }
    return null;
  }

  void _bindBleChannel() {
    // 不再抢占 mymg/ble handler：统一由 BleKeyBridge 接收，这里只订阅事件刷 UI
    BleKeyBridge.instance.init();
    _bleSub = BleKeyBridge.instance.events.listen((e) {
      if (!mounted) return;
      final method = (e['method'] as String?) ?? '';
      // bridge 心跳/快照不写日志：它们没有 stage，写出来就是 "[]"
      if (method == 'bridge') return;
      final a = (e['raw'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      switch (method) {
        case 'nearby':
          final addr = (a['address'] as String?) ?? '';
          final rssi = (a['rssi'] as int?) ?? -999;
          setState(() {
            _nearby.removeWhere((el) => el['address'] == addr);
            _nearby.add({'address': addr, 'rssi': rssi, 'name': a['name']});
            _nearby.sort((x, y) => ((y['rssi'] as int?) ?? -999)
                .compareTo((x['rssi'] as int?) ?? -999));
            if (_nearby.length > 20) _nearby.removeRange(20, _nearby.length);
          });
          break;
        case 'status':
          setState(() {
            _gattStage = (a['stage'] as String?) ?? '';
            _gattMsg = a['message'] as String?;
            final line = '[$_gattStage] ${_gattMsg ?? ''}';
            // 空 stage+空 message 的事件直接丢弃，避免 [] 刷屏
            if (_gattStage.isNotEmpty || (_gattMsg != null && _gattMsg!.trim().isNotEmpty)) {
              _pushLog(line);
            }
            _gattBusy = _gattStage == 'connecting' ||
                _gattStage == 'busy' ||
                _gattStage == 'authing' ||
                _gattStage == 'authed' ||
                _gattStage == 'sent' ||
                _gattStage == 'booking';
          });
          break;
        case 'challenge':
          setState(() {
            _challengeHex = a['hex'] as String?;
            _pushLog('挑战 ${_challengeHex ?? ''} (${a['length'] ?? 0}B)');
          });
          break;
        case 'notify':
          final uuid = a['uuid'] as String? ?? '';
          final hex = a['hex'] as String? ?? '';
          final short = uuid.length >= 8 ? uuid.substring(0, 8) : uuid;
          // 空 hex 的通知只记一次短行，不占日志位
          if (hex.isEmpty) {
            _pushLog('通知 $short(空)');
          } else {
            _pushLog('通知 $short $hex');
          }
          break;
        case 'services':
          _pushLog('服务列表 ${(a['services'] as List?)?.join(', ') ?? ''}');
          break;
      }
    });
  }

  void _pushLog(String s) {
    final t = s.trim();
    // 过滤空事件：status 无 stage/message 会打成 "[]"，notify 无 hex 也是空壳
    if (t.isEmpty || t == '[]' || t == '通知' || t == '服务列表') return;
    if (t.startsWith('通知 ') && t.length <= 10) return;
    if (t.startsWith('[') && t.endsWith(']') && t.length <= 2) return;
    final ts = DateTime.now();
    final hh = ts.hour.toString().padLeft(2, '0');
    final mm = ts.minute.toString().padLeft(2, '0');
    final ss = ts.second.toString().padLeft(2, '0');
    _gattLog.insert(0, '[$hh:$mm:$ss] $t');
    // 日志式：默认不主动清除，超过 1000 条才丢最旧
    if (_gattLog.length > 1000) _gattLog.removeLast();
  }

  Future<void> _loadKeys() async {
    final c = await ControlConfig.load();
    if (!c.tokenOk) {
      setState(() {
        _loading = false;
        _error = '请先登录（需要 token）。';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _keys = null;
    });
    try {
      var userId = _userId.trim().isNotEmpty ? _userId.trim() : c.userId;
      if (userId.isEmpty) {
        try {
          final fetched = await authFetchUserId(
            token: c.token!,
            deviceId: c.headerDeviceId,
          );
          if (fetched != null && fetched.isNotEmpty) {
            userId = fetched;
            _userIdCtrl.text = userId;
            _userId = userId;
            await ControlConfig.saveIdentity(
              brand: c.brand,
              userId: userId,
              mobile: c.mobile,
              headerDeviceId: c.headerDeviceId,
            );
          }
        } catch (_) {}
      }

      final r = await vehicleFetchBluetoothKeys(
        brand: c.brand,
        token: c.token!,
        vin: c.vin ?? '',
        userId: userId,
        mobile: c.mobile,
        headerDeviceId: c.headerDeviceId,
      );
      if (!mounted) return;
      final all = <BluetoothKeyInfo>[
        ...(r.digitalKeyList ?? const []),
        ...(r.bluetoothKeyList ?? const []),
      ];
      // 默认选启用中的第一把
      BluetoothKeyInfo? pick = _selected;
      final prev = pick;
      if (prev == null ||
          !all.any((k) => k.licenseNo == prev.licenseNo && k.vin == prev.vin)) {
        pick = all.isNotEmpty ? all.first : null;
      }
      setState(() {
        _keys = r;
        _selected = pick;
        _userId = userId.isNotEmpty ? userId : _userId;
        _applySelected(pick);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = formatFrbError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _applySelected(BluetoothKeyInfo? k) {
    if (k == null) {
      _vehicleMac = null;
      _keyRef = 0;
      return;
    }
    final raw = k.raw is Map ? Map<String, dynamic>.from(k.raw as Map) : null;
    final mac = (raw?['tbox_mac'] as String?) ?? k.mac ?? '';
    _vehicleMac = mac.isNotEmpty ? mac : null;
    final ref = raw?['key_reference'];
    _keyRef = ref is int ? ref : (ref is num ? ref.toInt() : 0);
    // 与桥缓存同步：这样「智能控车」页/自动锁车也拿到同一个 keyRef
    if (_keyRef != 0) BleKeyBridge.instance.keyRef = _keyRef;
  }

  /// 本页 keyReference 为 0（接口偶尔不回该字段 / 切换钥匙）时，回落到桥里的缓存值：
  /// 0 会让 BookingId 变成 00000000，车端会立即断开链路（实测 status=19）。
  int get _effectiveKeyRef => _keyRef != 0 ? _keyRef : BleKeyBridge.instance.keyRef;

  Future<void> _toggleScan() async {
    try {
      if (_bleScanning) {
        await _bleCh.invokeMethod('stopScan');
        setState(() => _bleScanning = false);
        return;
      }
      final has = await _bleCh.invokeMethod<bool>('hasScanPermission') ?? false;
      if (!has) {
        await _bleCh.invokeMethod('requestPermissions');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('请在系统设置中允许蓝牙/定位权限后，再打开扫描')),
          );
        }
        return;
      }
      _nearby.clear();
      await _bleCh.invokeMethod('startScan');
      setState(() => _bleScanning = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('蓝牙扫描：${formatFrbError(e)}')),
        );
      }
    }
  }

  Future<void> _requestBleConnectPerm() async {
    await _bleCh.invokeMethod('requestPermissions');
  }

  Future<void> _probeGatt() async {
    final mac = _vehicleMac;
    if (mac == null) {
      _snack('请先刷新钥匙列表并选中含 TBOX MAC 的钥匙');
      return;
    }
    await _requestBleConnectPerm();
    setState(() {
      _gattBusy = true;
      _gattStage = 'probe';
      _pushLog('— $_gattStage 操作 —');
      _challengeHex = null;
    });
    try {
      await _bleCh.invokeMethod('probe', {
        'tboxMac': mac,
        'connectMac': _resolveConnectMac(),
        'keyReference': _effectiveKeyRef,
      });
    } catch (e) {
      setState(() {
        _gattBusy = false;
        _gattMsg = e.toString().contains('notImplemented') || e.toString().contains('MissingPlugin')
            ? '原生 GATT 通道未注册：请安装最新 APK，并确认已授予蓝牙/附近设备权限'
            : formatFrbError(e);
      });
    }
  }

  String _bleStatusHint() {
    final m = _gattMsg ?? '';
    if (m.contains('147')) {
      return '已断开 status=147：多为车端/系统主动断开。请靠近 TBOX（FMC BTLE）、'
          '保持车辆唤醒、关闭电池优化后再「连接」。';
    }
    return '探测时请保持车辆唤醒；附近列表应能看到车辆 TBOX（FMC BTLE）。';
  }

  Future<void> _bleUnlock() async {
    final mac = _vehicleMac;
    final aes = _aesOf(_selected);
    final secret = _secretOf(_selected);
    if (mac == null) {
      _snack('缺少 TBOX MAC');
      return;
    }
    if ((secret == null || secret.isEmpty) && (aes == null || aes.isEmpty)) {
      _snack('当前钥匙无 secret/aes 密钥，无法蓝牙解锁');
      return;
    }
    await _requestBleConnectPerm();
    setState(() {
      _gattBusy = true;
      _gattStage = 'unlock';
      _pushLog('— $_gattStage 操作 —');
    });
    try {
      await _bleCh.invokeMethod('unlock', {
        'tboxMac': mac,
        'aesKey': aes ?? '',
        'secretKey': _secretOf(_selected) ?? '',
        'keyReference': _effectiveKeyRef,
        'connectMac': _resolveConnectMac(),
        // 官方 unlock 载荷 = "1"+userId，车端据此认定数字钥匙用户在场（免钥匙启动前提）
        'userId': _userId,
      });
    } catch (e) {
      setState(() {
        _gattBusy = false;
        _gattMsg = formatFrbError(e);
      });
    }
  }

  Future<void> _bleLock() async {
    final mac = _vehicleMac;
    final secret = _secretOf(_selected);
    if (mac == null) {
      _snack('缺少 TBOX MAC');
      return;
    }
    if (secret == null || secret.isEmpty) {
      _snack('当前钥匙无 secret_key，无法蓝牙锁车');
      return;
    }
    await _requestBleConnectPerm();
    setState(() {
      _gattBusy = true;
      _gattStage = 'lock';
      _pushLog('— $_gattStage 操作 —');
    });
    try {
      await _bleCh.invokeMethod('lock', {
        'tboxMac': mac,
        'aesKey': _aesOf(_selected) ?? '',
        'secretKey': secret,
        'keyReference': _effectiveKeyRef,
        'connectMac': _resolveConnectMac(),
        'userId': _userId,
      });
    } catch (e) {
      setState(() {
        _gattBusy = false;
        _gattMsg = formatFrbError(e);
      });
    }
  }

  Future<void> _bleTrunk() async {
    final mac = _vehicleMac;
    final secret = _secretOf(_selected);
    if (mac == null) {
      _snack('缺少 TBOX MAC');
      return;
    }
    if (secret == null || secret.isEmpty) {
      _snack('当前钥匙无 secret_key，无法开后备箱');
      return;
    }
    await _requestBleConnectPerm();
    setState(() {
      _gattBusy = true;
      _gattStage = 'trunk';
      _pushLog('— $_gattStage 操作 —');
    });
    try {
      await _bleCh.invokeMethod('trunk', {
        'tboxMac': mac,
        'aesKey': _aesOf(_selected) ?? '',
        'secretKey': secret,
        'keyReference': _effectiveKeyRef,
        'connectMac': _resolveConnectMac(),
        'userId': _userId,
      });
    } catch (e) {
      setState(() {
        _gattBusy = false;
        _gattMsg = formatFrbError(e);
      });
    }
  }


  /// 免钥匙启动：BASE_DRIVE_CYCLE「120 秒打火」→ AUTHENTICATED 后写 Drive 特征。
  /// 车端进入启动授权窗口，之后 120 秒内按一键启动即可着车。
  Future<void> _bleDrive() async {
    final mac = _vehicleMac;
    final secret = _secretOf(_selected);
    if (mac == null) {
      _snack('缺少 TBOX MAC');
      return;
    }
    if (secret == null || secret.isEmpty) {
      _snack('当前钥匙无 secret_key，无法蓝牙启动');
      return;
    }
    await _requestBleConnectPerm();
    setState(() {
      _gattBusy = true;
      _gattStage = 'drive';
      _pushLog('— $_gattStage 操作 —');
    });
    try {
      await _bleCh.invokeMethod('drive', {
        'tboxMac': mac,
        'aesKey': _aesOf(_selected) ?? '',
        'secretKey': secret,
        'keyReference': _effectiveKeyRef,
        'connectMac': _resolveConnectMac(),
        'userId': _userId,
      });
    } catch (e) {
      setState(() {
        _gattBusy = false;
        _gattMsg = formatFrbError(e);
      });
    }
  }


  Future<void> _disconnectBle() async {
    try {
      await _bleCh.invokeMethod('disconnect');
    } catch (_) {}
    setState(() => _gattBusy = false);
  }

  String? _aesOf(BluetoothKeyInfo? k) {
    if (k == null) return null;
    final raw = k.raw is Map ? Map<String, dynamic>.from(k.raw as Map) : null;
    return (raw?['aes_key'] as String?) ?? k.aesKey;
  }

  String? _secretOf(BluetoothKeyInfo? k) {
    if (k == null) return null;
    final raw = k.raw is Map ? Map<String, dynamic>.from(k.raw as Map) : null;
    return (raw?['secret_key'] as String?) ?? k.secretKey;
  }

  int? _keyRefOf(BluetoothKeyInfo? k) {
    if (k == null) return null;
    final raw = k.raw is Map ? Map<String, dynamic>.from(k.raw as Map) : null;
    final ref = raw?['key_reference'];
    return ref is int ? ref : (ref is num ? ref.toInt() : null);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _maskKey(String? k) {
    if (k == null || k.isEmpty) return '无';
    if (k.length <= 4) return '****';
    return '${k.substring(0, 2)}…${k.substring(k.length - 2)} (${k.length})';
  }

  @override
  Widget build(BuildContext context) {
    final digital = _keys?.digitalKeyList ?? const <BluetoothKeyInfo>[];
    final bluetooth = _keys?.bluetoothKeyList ?? const <BluetoothKeyInfo>[];
    final all = <BluetoothKeyInfo>[...digital, ...bluetooth];
    final sel = _selected;
    final mac = _vehicleMac;
    final serviceUuid = mac != null && mac.isNotEmpty
        ? _serviceUuidPreview(mac)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: Icon(Icons.bluetooth_searching),
          title: Text('蓝牙数字钥匙'),
          subtitle: Text(
            _loading
                ? '正在拉取钥匙列表…'
                : _error != null
                    ? _error!
                    : '数字钥匙 ${digital.length} · 蓝牙钥匙 ${bluetooth.length}',
            style: TextStyle(fontSize: 12),
          ),
          trailing: IconButton(
            tooltip: '刷新钥匙',
            icon: Icon(Icons.refresh, size: 20),
            onPressed: _loading ? null : _loadKeys,
          ),
        ),
        if (_error == null && all.isEmpty && !_loading)
          Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '账号下暂无已绑定钥匙。\n请在官方 App → 数字钥匙 完成绑定后再刷新。',
              style: TextStyle(fontSize: 12, color: AppPalette.muted, height: 1.4),
            ),
          ),

        // 多钥匙选择
        if (all.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: DropdownButtonFormField<BluetoothKeyInfo>(
              isExpanded: true,
              // ignore: deprecated_member_use
              value: sel,
              decoration: const InputDecoration(
                labelText: '当前钥匙',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: all
                  .map(
                    (k) => DropdownMenuItem(
                      value: k,
                      child: Text(
                        '${k.licenseNo ?? k.name ?? "钥匙"}'
                        '${k.vin != null ? " · …${k.vin!.substring(k.vin!.length >= 6 ? k.vin!.length - 6 : 0)}" : ""}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (k) {
                setState(() {
                  _selected = k;
                  _applySelected(k);
                });
              },
            ),
          ),

        if (_showGattLab) ...[
        // ── 蓝牙 GATT 实验（常驻，不藏在钥匙列表里）────────────────
        if (_keys != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Card(
              elevation: 0,
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.bluetooth_connected,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '蓝牙后台控车',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      mac == null
                          ? '当前钥匙没有 TBOX MAC。请先「刷新钥匙」，或点选列表里带 TBOX 的那一把。'
                          : '车旁操作：解锁 / 锁车 / 开后备箱 / 启动（120秒打火）与智能控车共用同一后台通道。车旁直接点即可，无需连接云端。异常时可「GATT 探测」排查。',
                      style: TextStyle(fontSize: 12, height: 1.45),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: (mac == null || _gattBusy) ? null : _probeGatt,
                          icon: Icon(Icons.radar, size: 16),
                          label: Text('GATT 探测'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: (mac == null ||
                                  _gattBusy ||
                                  _aesOf(sel) == null)
                              ? null
                              : _bleUnlock,
                          icon: Icon(Icons.lock_open, size: 16),
                          label: const Text('蓝牙解锁'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: (mac == null ||
                                  _gattBusy ||
                                  _secretOf(sel) == null)
                              ? null
                              : _bleLock,
                          icon: Icon(Icons.lock, size: 16),
                          label: const Text('蓝牙锁车'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: (mac == null ||
                                  _gattBusy ||
                                  _secretOf(sel) == null)
                              ? null
                              : _bleTrunk,
                          icon: Icon(Icons.door_front_door_outlined, size: 16),
                          label: const Text('开后备箱'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: (mac == null ||
                                  _gattBusy ||
                                  _secretOf(sel) == null)
                              ? null
                              : _bleDrive,
                          icon: Icon(Icons.key, size: 16),
                          label: const Text('启动（120秒打火）'),
                        ),
                        if (_gattBusy)
                          OutlinedButton.icon(
                            onPressed: _disconnectBle,
                            icon: const Icon(Icons.link_off, size: 16),
                            label: const Text('断开'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // 解锁即授权启动（产品默认开）：控车页没有独立启动按钮，
                    // 解锁确认后由原生自动跟一次 driveCycle，上车直接按一键启动。
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: BleKeyBridge.instance.autoDriveAfterUnlock,
                      onChanged: (v) async {
                        await BleKeyBridge.instance.setAutoDrive(v);
                        if (mounted) setState(() {});
                      },
                      title: const Text('解锁后自动下发启动授权（120 秒打火）',
                          style: TextStyle(fontSize: 13)),
                      subtitle: Text(
                        '产品默认开启：解锁成功即自动授权启动，120 秒内上车按一键启动即可。'
                        '关掉后只能手动点「启动（120秒打火）」。',
                        style: TextStyle(fontSize: 11, color: AppPalette.subtle, height: 1.35),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '后台保活：只要用过蓝牙控车，通知栏会出现「MYMG 蓝牙数字钥匙」常驻通知，'
                      '用于防止进程被冻结导致断链；点通知里的「断开」即退出保活。',
                      style: TextStyle(fontSize: 11, color: AppPalette.subtle, height: 1.35),
                    ),
                    if (mac == null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '若装的是旧包可能看不到本卡片，请安装 mymg-ble-gatt-2026-09-16-arm64.apk',
                          style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),

        for (final k in digital) _keyTile(Icons.vpn_key, '数字钥匙', k),
        for (final k in bluetooth) _keyTile(Icons.bluetooth, '蓝牙钥匙', k),

        // 密钥 / MAC 状态卡
        if (sel != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Card(
              elevation: 0,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '密钥材料',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'TBOX  ${mac ?? "—"}\n'
                      'keyRef  ${_keyRefOf(sel) ?? "—"}\n'
                      'aes_key  ${_maskKey(_aesOf(sel))}\n'
                      'secret  ${_maskKey(_secretOf(sel))}\n'
                      '服务UUID  ${serviceUuid ?? "—"}',
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

        if (_gattStage.isNotEmpty && _gattMsg != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 6, 0, 0),
            child: Text(
              _bleStatusHint(),
              style: TextStyle(
                fontSize: 12,
                color: _gattStage == 'error' || _gattStage == 'timeout'
                    ? Colors.orange.shade800
                    : AppPalette.muted,
                height: 1.35,
              ),
            ),
          ),
        if (_challengeHex != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: SelectableText(
              '挑战 $_challengeHex',
              style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: ExpansionTile(
            dense: true,
            title: Text('GATT 日志（${_gattLog.length}）',
                style: const TextStyle(fontSize: 12)),
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: _gattLog.isEmpty
                        ? null
                        : () async {
                            final text = _gattLog.reversed.join('\n');
                            await Clipboard.setData(
                                ClipboardData(text: text));
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('日志已复制到剪贴板')),
                              );
                            }
                          },
                    icon: const Icon(Icons.copy, size: 14),
                    label: const Text('复制', style: TextStyle(fontSize: 12)),
                  ),
                  TextButton.icon(
                    onPressed: _gattLog.isEmpty
                        ? null
                        : () {
                            setState(() => _gattLog.clear());
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('日志已清空')),
                            );
                          },
                    icon: const Icon(Icons.delete_outline, size: 14),
                    label: const Text('清空', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              // 限高滚动；整段可选中复制
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _gattLog.reversed.join('\n'),
                    style: const TextStyle(
                        fontSize: 10, fontFamily: 'monospace'),
                  ),
                ),
              ),
            ],
          ),
        ),

        if (_keys != null && _keys!.raw.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: ExpansionTile(
              dense: true,
              title: const Text('原始响应（排障）', style: TextStyle(fontSize: 12)),
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _keys!.raw.length > 2000
                          ? '${_keys!.raw.substring(0, 2000)}…'
                          : _keys!.raw,
                      style: const TextStyle(
                          fontSize: 10, fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ],
            ),
          ),

        SwitchListTile(
          value: _bleScanning,
          onChanged: (_) => _toggleScan(),
          title: const Text('附近蓝牙扫描'),
          subtitle: Text(
            _vehicleMac == null
                ? '显示附近 BLE 设备 RSSI。'
                : '车辆 TBOX $_vehicleMac · 匹配设备会高亮。',
            style: const TextStyle(fontSize: 12, height: 1.4),
          ),
          isThreeLine: true,
        ),
        if (_bleScanning && _vehicleRssi() != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Card(
              color: Colors.green.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(Icons.near_me, color: Colors.green, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '检测到车辆附近：RSSI ${_vehicleRssi()} dBm',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.green,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_bleScanning && _nearby.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Container(
              constraints: const BoxConstraints(maxHeight: 180),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _nearby.length,
                itemBuilder: (_, i) {
                  final n = _nearby[i];
                  final addr = (n['address'] as String?) ?? '';
                  final isCar = _isVehicleMac(addr);
                  final rssi = (n['rssi'] as int?) ?? -999;
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      isCar ? Icons.directions_car : Icons.bluetooth,
                      size: 16,
                      color: isCar ? Colors.green : null,
                    ),
                    title: Text(
                      isCar
                          ? '★ 车辆 TBOX'
                          : ((n['name'] as String?)?.isNotEmpty == true
                              ? n['name'] as String
                              : '未知设备'),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: isCar ? FontWeight.w700 : FontWeight.w400,
                        color: isCar ? Colors.green.shade800 : null,
                      ),
                    ),
                    subtitle: Text(addr, style: TextStyle(fontSize: 11)),
                    trailing: Text(
                      '$rssi dBm',
                      style: TextStyle(
                        fontSize: 12,
                        color: rssi > -70 ? Colors.green : AppPalette.muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 数字钥匙 GATT 服务 UUID（构建时通过 --dart-define=MYMG_BLE_SERVICE_UUID 注入）
  static const kFixedServiceUuid = AppConfig.bleServiceUuid;

  /// UI 预览：优先显示官方固定服务 UUID
  String? _serviceUuidPreview(String tboxMac) {
    return kFixedServiceUuid;
  }

  Widget _keyTile(IconData icon, String type, BluetoothKeyInfo k) {
    final rawMap = k.raw is Map ? Map<String, dynamic>.from(k.raw as Map) : null;
    final tboxMac = (rawMap?['tbox_mac'] as String?) ?? k.mac;
    final enable = rawMap?['enable'] == true || rawMap?['is_enable'] == true;
    final endTime = rawMap?['key_end_time'];
    String? endStr;
    if (endTime is int && endTime > 1000000000000) {
      endStr = DateTime.fromMillisecondsSinceEpoch(endTime)
          .toLocal()
          .toString()
          .split(' ')
          .first;
    }
    final isSel = _selected != null &&
        _selected!.licenseNo == k.licenseNo &&
        _selected!.vin == k.vin;
    final hasAes = (rawMap?['aes_key'] as String?)?.isNotEmpty == true ||
        k.aesKey?.isNotEmpty == true;
    final hasSec = (rawMap?['secret_key'] as String?)?.isNotEmpty == true ||
        k.secretKey?.isNotEmpty == true;
    return ListTile(
      dense: true,
      selected: isSel,
      onTap: () {
        setState(() {
          _selected = k;
          _applySelected(k);
        });
      },
      leading: Icon(
        icon,
        size: 18,
        color: enable ? Colors.green : Colors.grey,
      ),
      title: Text(
        '${k.licenseNo ?? type}${isSel ? ' · 当前' : ''}',
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          if (k.vin != null && k.vin!.isNotEmpty)
            'VIN …${k.vin!.length >= 6 ? k.vin!.substring(k.vin!.length - 6) : k.vin}',
          if (tboxMac != null && tboxMac.isNotEmpty) 'TBOX $tboxMac',
          if (enable) '启用中' else '未启用',
          if (endStr != null) '至 $endStr',
          if (hasAes && hasSec) '密钥齐全'
          else if (hasAes)
            '仅 aes'
          else if (hasSec)
            '仅 secret',
        ].join(' · '),
        style: TextStyle(fontSize: 11),
      ),
      trailing: Text(
        k.status ?? '',
        style: TextStyle(fontSize: 12, color: AppPalette.subtle),
      ),
    );
  }
}
