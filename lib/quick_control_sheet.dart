// 快捷控车弹窗：位置 + 实时车况 + 控车按钮 + 空调滑条 + 预约入口
// 磁贴 / 小组件 / 图标长按 共用此面板。

import 'app_config.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'theme_controller.dart';
import 'package:flutter/services.dart' show HapticFeedback, SystemNavigator;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:mymg/src/rust/api.dart';
import 'package:mymg/src/rust/vehicle/control.dart';

import 'ble_key_bridge.dart';
import 'control_config.dart';
import 'err_util.dart';
import 'notification_service.dart';
import 'pin_vault.dart';
import 'reservation_service.dart';
import 'summary_cache.dart';
import 'token_age.dart';
import 'ui_motion.dart';

/// 应用内 / 小组件 / 控制中心 共用同一弹窗组件，保证数据与连接状态唯一。
Future<void> showQuickControlSheet(BuildContext context) async {
  if (QuickControlHostPage.isShowing) return;
  await Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.transparent,
      barrierDismissible: true,
      pageBuilder: (_, __, ___) => const QuickControlHostPage(),
    ),
  );
}

/// 透明快捷控车宿主：滑入淡入+缩放；关闭可下滑/点空白/返回。
/// 无黑色遮罩，桌面/App 底保持可见。
class QuickControlHostPage extends StatefulWidget {
  const QuickControlHostPage({super.key, this.standalone = false});

  /// true=独立 Activity（小组件/磁贴），关闭时 pop 系统页面
  final bool standalone;

  static bool isShowing = false;

  @override
  State<QuickControlHostPage> createState() => _QuickControlHostPageState();
}

class _QuickControlHostPageState extends State<QuickControlHostPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    reverseDuration: const Duration(milliseconds: 240),
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.35),
    end: Offset.zero,
  ).animate(CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  ));
  late final Animation<double> _scale = Tween<double>(begin: 0.96, end: 1.0)
      .animate(CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  ));

  @override
  void initState() {
    super.initState();
    QuickControlHostPage.isShowing = true;
    _ctrl.forward();
  }

  @override
  void dispose() {
    QuickControlHostPage.isShowing = false;
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (_ctrl.isAnimating) return;
    QuickControlHostPage.isShowing = false;
    try {
      await _ctrl.reverse();
    } catch (_) {}
    if (!mounted) return;
    if (widget.standalone) {
      SystemNavigator.pop();
    } else {
      // PopScope(canPop:false) 下 maybePop 关不掉，必须 pop
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _close();
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _close,
              child: const ColoredBox(color: Colors.transparent),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: FadeTransition(
              opacity: _fade,
              child: SlideTransition(
                position: _slide,
                child: ScaleTransition(
                  scale: _scale,
                  alignment: Alignment.bottomCenter,
                  child: Material(
                    color: Theme.of(context).colorScheme.surface,
                    elevation: 8,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(20)),
                    clipBehavior: Clip.antiAlias,
                    child: SafeArea(
                      top: false,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(context).size.height * 0.94,
                        ),
                        child: QuickControlSheet(
                          standalone: widget.standalone,
                          onClose: _close,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class QuickControlSheet extends StatefulWidget {
  const QuickControlSheet({super.key, this.standalone = false, this.onClose});

  final bool standalone;

  /// 独立透明壳关闭回调（带动画）；为空时回退 SystemNavigator.pop
  final VoidCallback? onClose;

  @override
  State<QuickControlSheet> createState() => _QuickControlSheetState();
}

class _QuickControlSheetState extends State<QuickControlSheet> {
  final PinVault _vault = PinVault();
  ControlConfig? _cfg;
  bool _busy = false;
  bool _statusLoading = false;

  // 蓝牙数字钥匙
  StreamSubscription? _bleSub;
  late final BleKeyBridge _ble = BleKeyBridge.instance;
  bool _blePrefer = false;
  bool _bleConnected = false;
  bool _bleBusy = false;
  /// 数字钥匙会话状态：'' | 握手中 | 已鉴权（产品面要能看出「能不能着车」）
  String _bleSession = '';
  /// 蓝牙操作序号：只有最新一次操作的回调/看门狗能解锁按钮
  int _bleSeq = 0;
  /// 最近一次下发的 BLE 动作（超时事件里不带 action，用它兜底生成文案）
  String _bleLastAction = '';


  /// 控车结果条幅（显示在弹窗内，避免 SnackBar 被弹窗盖住）
  String? _uiMsg;
  bool _uiMsgIsError = false;
  Map<String, dynamic>? _lastBleEvent;
  /// 结果通知去重：**按时间窗**，不是永久去重 —— 每次解锁的结果文案是固定的，
  /// 永久去重会让第二次及以后的解锁/启动授权在口袋里完全没有通知反馈。
  final Map<String, DateTime> _bleNotifiedAt = {};


  // 座椅加热 / 空调（来自 summary 实时车况）
  bool? _acOn;
  int? _acTempC;
  bool? _seatHeatDriver;
  bool? _seatHeatPassenger;
  int? _seatHeatDriverLevel;
  int? _seatHeatPassengerLevel;

  // 座椅加热 / 空调（来自 summary 实时车况）
  // 预约（WorkManager 到点执行；独立页内联编辑，不再嵌套弹层）
  bool _resEnabled = false;
  String _resType = 'ac'; // ac | seat_left | seat_right
  TimeOfDay _resTime = const TimeOfDay(hour: 8, minute: 0);
  bool _resPanelOpen = false;
  String? _resLastError;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _bleSub?.cancel();
    super.dispose();
  }

  Future<void> _boot() async {
    await _ble.init();
    _blePrefer = _ble.preferBle;
    _bleSub = _ble.events.listen((ev) {
      if (!mounted) return;
      final raw = ev['raw'];
      _lastBleEvent = raw is Map ? Map<String, dynamic>.from(raw) : null;
      final stage = _lastBleEvent?['stage'] as String? ?? '';
      final msg = _lastBleEvent?['message'] as String? ?? _ble.message;
      final eventAction = _lastBleEvent?['action'] as String? ?? '';
      setState(() {
        _blePrefer = _ble.preferBle;
        // 「已连接」只认真的连上/已鉴权：忙但还没鉴权（正在建链）不能显示成已连接
        _bleConnected = _ble.state == BleBridgeState.connected ||
            (_ble.state == BleBridgeState.busy && _bleSession == '已鉴权');
        // ★ 任何终态事件都必须解锁按钮：控车页可能是独立 FlutterEngine
        //   （磁贴/小组件弹出的 QuickControlActivity），事件丢失过一次就会永久卡「蓝牙被占用」。
        _bleBusy = switch (stage) {
          'ready' || 'error' || 'timeout' || 'disconnected' => false,
          'busy' => true,
          _ => _ble.state == BleBridgeState.busy,
        };
        // 会话状态（产品面上要看得见「握手/已鉴权」，否则用户不知道能不能着车）
        if (stage == 'authed' || stage == 'ready') {
          _bleSession = '已鉴权';
        } else if (stage == 'connecting' ||
            stage == 'booking' ||
            stage == 'authing' ||
            stage == 'sent') {
          _bleSession = '握手中';
        } else if (stage == 'disconnected') {
          _bleSession = '';
        }
      });
      _announceBleResult(eventAction, stage, msg);
    });
    final c = await ControlConfig.load();
    if (!mounted) return;
    setState(() {
      _cfg = c;
    });
    await _loadReservation();
    // 到点补跑：WorkManager 可能被系统省电饿死，前台打开时兜底
    try {
      final ran = await ReservationConfig.tryRunDueInForeground();
      if (ran && mounted) {
        _toast('预约已到点，指令已下发');
        await _loadReservation();
      }
    } catch (_) {}
    // 优先蓝牙：立刻连钥匙，不等远程车况（车况含 requestVehicleStatus，很慢）
    if (_blePrefer) {
      unawaited(_autoConnectBle());
    }
    // 车况后台静默刷新，不挡打开（用户主动看实时以首页下拉为准）
    if (c.tokenOk && c.vinOk) {
      unawaited(_loadStatus());
    }
  }

  Future<void> _autoConnectBle() async {
    if (!mounted || !_ble.preferBle) return;
    if (_ble.state == BleBridgeState.connected) return;
    await _ble.connectOnceOnSheetOpen();
    if (mounted) setState(() {});
  }

  /// 车端回执 → 通知 + 弹窗条幅。文案面向使用者，不暴露 01/02/FD 这类内部码。
  void _announceBleResult(String eventAction, String stage, String msg) {
    if (stage != 'ready' && stage != 'error' && stage != 'timeout') return;
    final action = eventAction.isNotEmpty ? eventAction : _bleLastAction;
    // drive 的回执一律不提示：解锁文案已经隐含「可以启动」，多一条只会打扰
    if (action == 'drive' || msg.contains('启动授权')) return;
    final line = _userFacingBleLine(action, stage, msg);
    if (line == null || line.isEmpty) return;
    if (stage != 'timeout') {
      // 5 秒窗口内同文案不重复通知（同一次操作可能有两个终态事件），
      // 但 5 秒后同样文案要再通知 —— 每次解锁都该有回执。
      final lastAt = _bleNotifiedAt[line];
      final fresh = lastAt == null ||
          DateTime.now().difference(lastAt) > const Duration(seconds: 5);
      if (fresh) {
        _bleNotifiedAt[line] = DateTime.now();
        unawaited(_notifyLocal(
          stage == 'ready' ? '蓝牙车控' : '蓝牙车控失败',
          line,
        ));
      }
    }
    _toast(line);
  }

  /// 指令结果 → 用户看得懂的一句话；
  /// 非「指令结果」类事件（连接超时 / 材料未同步 / CCCD 失败…）原样透出，保证可排查。
  static String? _userFacingBleLine(String action, String stage, String msg) {
    if (!_isCommandResult(msg)) return msg;
    final (ok, fail, what) = switch (action) {
      'lock' => ('车辆已成功上锁', '上锁失败', '上锁'),
      'unlock' => ('车辆已成功解锁', '解锁失败', '解锁'),
      'trunk' => ('后备箱已打开', '后备箱打开失败', '开后备箱'),
      'liftgate_open' => ('电尾门已打开', '电尾门打开失败', '开电尾门'),
      'liftgate_close' => ('电尾门已关闭', '电尾门关闭失败', '关电尾门'),
      _ => ('指令已执行', '操作失败', '操作'),
    };
    return switch (stage) {
      'ready' => ok,
      // 只给一句人话，不带 01/02/FD 之类内部码（要查码请看「设置 → 蓝牙数字钥匙」诊断日志）
      'error' => fail,
      _ => '$what未响应，可重试',
    };
  }

  static bool _isCommandResult(String msg) =>
      msg.contains('已由车端确认') ||
      msg.contains('被车端拒绝') ||
      msg.contains('启动授权已下发');

  Future<void> _loadReservation() async {
    final c = await ReservationConfig.load();
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _resEnabled = c.enabled;
      _resType = c.type;
      _resTime = TimeOfDay(hour: c.hour, minute: c.minute);
      _resLastError = p.getString('mymg.res.last_err');
    });
  }

  Future<void> _saveReservation() async {
    // 到点时间：今天已过则记明天
    final now = DateTime.now();
    var when = DateTime(now.year, now.month, now.day, _resTime.hour, _resTime.minute);
    if (!when.isAfter(now)) {
      when = when.add(const Duration(days: 1));
    }
    await ReservationConfig.saveAndSchedule(
      enabled: _resEnabled,
      type: _resType,
      hour: _resTime.hour,
      minute: _resTime.minute,
      when: when,
    );
    if (!mounted) return;
    setState(() => _resLastError = null);
    _toast(_resEnabled
        ? '预约已保存：${_resTime.format(context)} 自动执行 ${_typeLabel(_resType)}'
        : '预约已关闭');
  }

  String _typeLabel(String t) => switch (t) {
        'seat_left' => '主驾加热',
        'seat_right' => '副驾加热',
        _ => '空调',
      };

  Future<void> _loadStatus({bool force = false}) async {
    final c = _cfg;
    if (c == null || !c.tokenOk || !c.vinOk) return;
    if (_statusLoading) return;
    _statusLoading = true;
    // 静默刷新，不转圈挡 UI
    try {
      final s = await SummaryCache.fetch(
        token: c.token!,
        vin: c.vin!,
        force: force,
      );
      if (!mounted) return;
      setState(() {
        _acOn = s.acOn;
        _acTempC = s.acTargetTemp?.toInt();
        _seatHeatDriver = s.seatHeatDriver;
        _seatHeatPassenger = s.seatHeatPassenger;
        _seatHeatDriverLevel = s.seatHeatDriverLevel?.toInt();
        _seatHeatPassengerLevel = s.seatHeatPassengerLevel?.toInt();
      });
    } catch (_) {
    } finally {
      _statusLoading = false;
    }
  }

  Future<String?> _ensurePin() async {
    // 内存缓存有效则直接用，避免每次控车都弹指纹/校验
    final pinCached = _vault.cachedPin;
    if (pinCached != null && pinCached.isNotEmpty) return pinCached;
    final c = _cfg;
    if (c == null || !c.readyForControl) {
      _toast('请先在「设置 → 远程控车」完成配置');
      return null;
    }
    final cached = _vault.cachedPin;
    if (cached != null) return cached;
    if (c.requireBiometric) {
      final bioOk = await _vault.isBiometricAvailable;
      if (bioOk) {
        final ok = await _vault.authenticate(reason: '解锁控车 PIN');
        if (ok) {
          final p = await _vault.loadIntoMemory();
          if (p != null) return p;
        }
        _toast('指纹未通过，请手动输入 PIN');
      }
    }
    final p = await _vault.loadIntoMemory();
    if (p != null) return p;
    final ctrl = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          backgroundColor: scheme.surface,
          titleTextStyle: TextStyle(
            color: scheme.onSurface,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
          contentTextStyle: TextStyle(color: scheme.onSurfaceVariant),
          title: const Text('输入控车密码'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            obscureText: true,
            style: TextStyle(color: scheme.onSurface),
            decoration: InputDecoration(
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              hintText: '4~8 位数字',
              hintStyle: TextStyle(color: scheme.onSurfaceVariant),
              filled: true,
              fillColor: scheme.surfaceContainerHighest.withOpacity(0.4),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text),
                child: const Text('确定')),
          ],
        );
      },
    );
    if (pin == null || pin.trim().length < 4) return null;
    await _vault.saveEncrypted(pin.trim());
    await _vault.loadIntoMemory();
    if (mounted) await _boot();
    return pin.trim();
  }

  Future<void> _act(
    String label,
    Future<ControlOutcome> Function(String pin, ControlConfig c) run, {
    String? bleAction,
  }) async {
    if (_busy || _bleBusy) {
      _toast('「$label」：上一次控车仍在进行，请稍候再点');
      return;
    }

    // ── 蓝牙模式：锁/解/后备箱只走 BLE（与设置页同一原生后台），绝不降级远程 ─────────
    if (bleAction != null && _blePrefer) {
      await _tryBleActionStrict(bleAction, label);
      return;
    }

    final c = _cfg;
    if (c == null || !c.readyForControl) {
      _toast('请先在「设置 → 远程控车」完成配置（userId/手机/PIN/VIN）');
      return;
    }
    _toast('「$label」请求中…');
    final pin = await _ensurePin();
    if (pin == null || pin.isEmpty) {
      _toast('未取得控车 PIN，已取消「$label」');
      return;
    }
    setState(() => _busy = true);
    try {
      var config = c;
      // 控车前：token 必须是 ACCESS_TOKEN；不是则先激活一次
      if (!AppConfig.looksLikeAccessToken(config.token ?? '')) {
        final upgraded = await _tryUpgradeToken(config);
        if (upgraded != null) config = upgraded;
      }
      var outcome = await run(pin, config);
      // 登录态失效：刷新 token 后只重试一次，绝不双发
      Future<ControlOutcome> retryWithRefresh() async {
        final upgraded = await _tryUpgradeToken(config);
        if (upgraded != null) config = upgraded;
        return run(pin, config);
      }

      final firstMsg = outcome.message ?? '';
      final rateLimited =
          firstMsg.contains('15006') || firstMsg.contains('频繁');
      if (!outcome.accepted &&
          !rateLimited &&
          (firstMsg.contains('14101') ||
              firstMsg.contains('登录态') ||
              firstMsg.contains('rav_code') ||
              firstMsg.contains('checkPINCode'))) {
        outcome = await retryWithRefresh();
      }
      if (!mounted) return;
      if (outcome.accepted) {
        // 只报「已下发」；结果后台轮询，不阻塞按钮
        _toast('「$label」已下发');
        final cid = outcome.commandId;
        final brand = c.brand;
        final token = c.token!;
        final vin = c.vin!;
        final userId = c.userId;
        final mobile = c.mobile;
        final devId = c.headerDeviceId;
        if (cid != null) {
          unawaited(_pollControlResult(
            label: label,
            brand: brand,
            token: token,
            vin: vin,
            userId: userId,
            mobile: mobile,
            headerDeviceId: devId,
            commandId: cid,
          ));
        }
        unawaited(_loadStatus(force: true));
      } else {
        final raw = outcome.message ?? '未知错误';
        _toast(_friendlyControlError(raw));
      }
    } catch (e) {
      if (!mounted) return;
      _toast(_friendlyControlError(formatFrbError(e)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 蓝牙模式严格路径：与设置页「蓝牙后台控车」完全同构——
  /// 直接把指令交给原生 startFlow（自行连接/复用 GATT/鉴权/下发），绝不降级远程。
  Future<void> _tryBleActionStrict(String action, String label) async {
    if (_bleBusy) {
      _toast('「$label」：蓝牙操作进行中，请稍候');
      return;
    }
    // 独立引擎（磁贴/小组件弹出的控车页）首次用蓝牙时要主动申请权限
    await _ble.requestBlePermissions();
    // 材料补齐交给 send()：它会依次尝试原生落盘 / 联网钥匙列表，并给出具体缺什么。
    setState(() {
      _bleBusy = true;
    });
    _bleLastAction = action;
    final seq = ++_bleSeq;
    final ok = await _ble.send(action);
    if (!ok) {
      if (mounted) setState(() => _bleBusy = false);
      // send() 失败时 message 已是人话（缺 mac / 缺 keyReference / 缺密钥），直接展示
      final why = _ble.message.trim();
      _toast(why.isEmpty ? '蓝牙指令发送失败' : why);
      return;
    }
    _toast('「$label」已下发蓝牙');
    // 结果确认见 _boot 的 events：stage=ready/error 会系统通知并释放 busy。
    // 看门狗：10s 后无条件解锁按钮（即使事件因跨引擎/车端静默而丢失），避免永久「蓝牙被占用」。
    Future<void>.delayed(const Duration(seconds: 10), () {
      if (!mounted || seq != _bleSeq) return;
      if (_bleBusy) setState(() => _bleBusy = false);
    });
  }

  /// 后台轮询远程指令结果，不再阻塞 _act（首包延迟只到「已下发」）。
  Future<void> _pollControlResult({
    required String label,
    required String brand,
    required String token,
    required String vin,
    required String userId,
    required String mobile,
    required String headerDeviceId,
    required PlatformInt64 commandId,
  }) async {
    // 单次查询；Dart 侧最多 4 轮（2s/3s/3s/3s），有终态立刻停
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration(seconds: i == 0 ? 2 : 3));
      try {
        final st = await vehicleGetControlStatus(
          brand: brand,
          token: token,
          vin: vin,
          userId: userId,
          mobile: mobile,
          headerDeviceId: headerDeviceId,
          commandId: commandId,
        );
        // Rust 已解析 done/success
        if (!st.done) continue;
        if (st.success) {
          _toast('「$label」执行成功');
          unawaited(_notifyLocal('远程车控', '$label指令执行成功'));
        } else {
          final why = st.failureMsg ?? st.commandStatus ?? '';
          if (why.isNotEmpty) {
            _toast('「$label」：$why');
            unawaited(_notifyLocal('远程车控', '$label：$why'));
          }
        }
        unawaited(_loadStatus(force: true));
        return;
      } catch (_) {
        // 网络抖动继续下一轮
      }
    }
  }
  /// 返回更新后的 ControlConfig；激活失败返回 null（继续用原 config）。
  Future<ControlConfig?> _tryUpgradeToken(ControlConfig c) async {
    try {
      final loginTok = c.token;
      if (loginTok == null || loginTok.isEmpty) return null;
      final activated = await authActivateToken(
        loginToken: loginTok,
        userId: c.userId,
        deviceId: c.headerDeviceId,
      );
      if (!AppConfig.looksLikeAccessToken(activated)) return null;
      if (activated == loginTok) return null;
      final p = await SharedPreferences.getInstance();
      await p.setString('mymg.token', activated);
      await TokenAge.capture(activated);
      _cfg = ControlConfig(
        brand: c.brand,
        userId: c.userId,
        mobile: c.mobile,
        headerDeviceId: c.headerDeviceId,
        requireBiometric: c.requireBiometric,
        pinSaved: c.pinSaved,
        token: activated,
        vin: c.vin,
      );
      return _cfg;
    } catch (_) {
      return null;
    }
  }

  Future<void> _lock() => _act('锁车', (pin, c) => vehicleLock(
        brand: c.brand, token: c.token!, vin: c.vin!,
        pin: pin, userId: c.userId, mobile: c.mobile, headerDeviceId: c.headerDeviceId,
      ), bleAction: 'lock');
  Future<void> _unlock() => _act('解锁', (pin, c) => vehicleUnlock(
        brand: c.brand, token: c.token!, vin: c.vin!,
        pin: pin, userId: c.userId, mobile: c.mobile, headerDeviceId: c.headerDeviceId,
      ), bleAction: 'unlock');
  Future<void> _trunk() => _act('开后备箱', (pin, c) => vehicleUnlockBoot(
        brand: c.brand, token: c.token!, vin: c.vin!,
        pin: pin, userId: c.userId, mobile: c.mobile, headerDeviceId: c.headerDeviceId,
      ), bleAction: 'trunk');

  /// 免钥匙启动不再是独立按钮：解锁成功由原生自动补一次 driveCycle（120 秒打火），
  /// 见 MymgBleKeyClient 的 autoDriveAfterUnlock。

  /// 找车：官方 requestFindVehicle（horn_volume=low / time_length=30）
  Future<void> _find() => _act('找车', (pin, c) => vehicleFindVehicle(
        brand: c.brand,
        token: c.token!,
        vin: c.vin!,
        pin: pin,
        userId: c.userId,
        mobile: c.mobile,
        headerDeviceId: c.headerDeviceId,
        isFlashing: true,
        hornVolume: 0,
        timeLengthS: 30,
      ));
  // 找车按钮已按官方参数加回（2026-09-22）

  Future<void> _acToggle(bool on) async {
    if (_acOn != true && !on) return;
    if (_busy) return;
    setState(() => _acOn = on);
    if (on) {
      await _act('开空调', (pin, c) => vehicleAcOn(
            brand: c.brand, token: c.token!, vin: c.vin!,
            pin: pin, userId: c.userId, mobile: c.mobile, headerDeviceId: c.headerDeviceId,
            targetTempC: _acTempC ?? 24,
          ));
    } else {
      await _act('关空调', (pin, c) => vehicleAcOff(
            brand: c.brand, token: c.token!, vin: c.vin!,
            pin: pin, userId: c.userId, mobile: c.mobile, headerDeviceId: c.headerDeviceId,
          ));
    }
  }

  Future<void> _acTempConfirm() async {
    if (_acOn != true || _busy) return;
    await _act('设置温度', (pin, c) => vehicleAcOn(
          brand: c.brand, token: c.token!, vin: c.vin!,
          pin: pin, userId: c.userId, mobile: c.mobile, headerDeviceId: c.headerDeviceId,
          targetTempC: _acTempC ?? 24,
        ));
  }

  Future<void> _seatHeat(String seat, bool on, String label) =>
      _act(label, (pin, c) => vehicleSeatHeat(
            brand: c.brand,
            token: c.token!,
            vin: c.vin!,
            pin: pin,
            userId: c.userId,
            mobile: c.mobile,
            headerDeviceId: c.headerDeviceId,
            seat: seat,
            on_: on,
          ));

  Future<void> _openReservation() async {
    // 独立透明页里嵌套 showModalBottomSheet / showTimePicker 常吞点击，
    // 改为主面板内联展开：开关 / 项目 / 时间 / 保存全部同层可点。
    setState(() => _resPanelOpen = !_resPanelOpen);
  }

  Widget _reservationPanel(bool enabled) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.45),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.schedule, size: 18, color: Colors.indigo),
                SizedBox(width: 6),
                Expanded(
                  child: Text('预约执行',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                ),
                Switch(
                  value: _resEnabled,
                  onChanged: enabled
                      ? (v) async {
                          setState(() => _resEnabled = v);
                          await _saveReservation();
                        }
                      : null,
                ),
              ],
            ),
            if (_resLastError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '上次失败：$_resLastError',
                  style: TextStyle(fontSize: 11, color: Colors.redAccent),
                ),
              ),
            if (_resEnabled) ...[
              Text('预约项目', style: TextStyle(fontSize: 12, color: AppPalette.muted)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('空调'),
                    selected: _resType == 'ac',
                    onSelected: enabled
                        ? (_) {
                            setState(() => _resType = 'ac');
                            _saveReservation();
                          }
                        : null,
                  ),
                  const SizedBox(width: 6),
                  ChoiceChip(
                    label: const Text('主驾热'),
                    selected: _resType == 'seat_left',
                    onSelected: enabled
                        ? (_) {
                            setState(() => _resType = 'seat_left');
                            _saveReservation();
                          }
                        : null,
                  ),
                  const SizedBox(width: 6),
                  ChoiceChip(
                    label: const Text('副驾热'),
                    selected: _resType == 'seat_right',
                    onSelected: enabled
                        ? (_) {
                            setState(() => _resType = 'seat_right');
                            _saveReservation();
                          }
                        : null,
                  ),
                ],
              ),
              SizedBox(height: 8),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: enabled
                    ? () async {
                        final t = await showTimePicker(
                          context: context,
                          initialTime: _resTime,
                        );
                        if (t != null) {
                          setState(() => _resTime = t);
                          await _saveReservation();
                        }
                      }
                    : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Icon(Icons.access_time, size: 16, color: AppPalette.muted),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '执行时间  ${_resTime.format(context)}',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                      Icon(Icons.edit_calendar, size: 16, color: AppPalette.muted),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 4),
              Text(
                'App 前台或后台任务到点自动执行一次；需已保存控车 PIN',
                style: TextStyle(fontSize: 11, color: AppPalette.subtle),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _toast(String msg) {
    final text = _friendlyControlError(msg);
    final isError = text.contains('失败') ||
        text.contains('拒绝') ||
        text.contains('失效') ||
        text.contains('请') ||
        text.contains('缺') ||
        text.contains('异常') ||
        text.contains('繁忙') ||
        text.contains('频繁');
    setState(() {
      _uiMsg = text;
      _uiMsgIsError = isError;
    });
  }

  Future<void> _notifyLocal(String title, String body) async {
    try {
      await NotificationService.instance
          .notifyPlain(title: title, body: body);
    } catch (_) {}
  }

  static String _friendlyControlError(String raw) {
    final m = raw;
    if (m.contains('15006') || m.contains('频繁操作') || m.contains('频繁')) {
      return '操作过于频繁：服务端限频（含 PIN 鉴权次数）。请等 1~2 分钟再试；'
          '找车/锁车不要连点。今日若测过多次控车，属正常风控。';
    }
    if (m.contains('14752') || m.contains('后台出错')) {
      return '服务端暂时异常，稍后再试';
    }
    if (m.contains('14101') || m.contains('登录态')) {
      return '登录态失效，请重新登录后再控车';
    }
    if (m.contains('checkPINCode') || m.contains('PIN')) {
      return 'PIN 或身份信息校验失败，请到「设置 → 远程控车」核对';
    }
    if (m.contains('14700')) {
      return '服务端拒绝：控车信息不完整，请核对设置里的 userId/手机/PIN';
    }
    if (m.contains('已下发') || m.contains('执行成功') || m.contains('请求中')) {
      return m.split('\n').first;
    }
    // 其它只保留首行，避免诊断长文刷屏
    return m.split('\n').first;
  }

  @override
  Widget build(BuildContext context) {
    // 顶栏固定，仅内容区滚动；关闭走小白条下拉 / 点空白
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // 按住小白条下拉即可关闭（独立弹窗 / App 内同一手势）
              onVerticalDragEnd: (d) {
                final v = d.primaryVelocity ?? 0;
                if (v > 240) {
                  final close = widget.onClose;
                  if (close != null) {
                    close();
                  } else if (widget.standalone) {
                    SystemNavigator.pop();
                  } else {
                    Navigator.of(context, rootNavigator: true).pop();
                  }
                }
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 6),
                child: Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(
                    color: AppPalette.track,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // 控车结果条幅（始终在弹窗内可见）
          if (_uiMsg != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: _uiMsgIsError
                    ? AppPalette.dangerBg
                    : AppPalette.okBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _uiMsgIsError
                      ? AppPalette.danger.withValues(alpha: 0.35)
                      : AppPalette.ok.withValues(alpha: 0.35),
                ),
              ),
              child: Text(
                _uiMsg!,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  fontWeight: FontWeight.w500,
                  color: _uiMsgIsError ? AppPalette.danger : AppPalette.ok,
                ),
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withOpacity(0.35),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.settings_remote,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('智能控车',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: AppPalette.strong)),
                ),
                _bleModeChip(),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 车辆位置不在控车弹窗展示
                  // 实时车况已隐藏：打开控车页即用，不转圈等接口
                  _actionsSection(),
                  // 空调 / 预约与锁车键同帧显示，不等车况
                  const SizedBox(height: 10),
                  _acCard(!_busy && !_bleBusy),
                  const SizedBox(height: 8),
                  _seatHeatSection(!_busy && !_bleBusy),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: (!_busy && !_bleBusy) ? _openReservation : null,
                      icon: Icon(
                        _resPanelOpen ? Icons.expand_less : Icons.schedule,
                        size: 16,
                      ),
                      label: Text(
                        _resEnabled
                            ? '预约中：${_resTime.format(context)} · ${_typeLabel(_resType)}'
                            : '预约加热 / 空调',
                      ),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(40),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  if (_resPanelOpen) ...[
                    const SizedBox(height: 10),
                    _reservationPanel(!_busy && !_bleBusy),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  /// 标题行内「蓝牙模式」开关 + 连接状态（不再单独占一张卡）
  Widget _bleModeChip() {
    final stateText = _blePrefer
        ? _bleConnected
            ? (_bleSession.isEmpty ? '已连接' : '已连接 · $_bleSession')
            : _ble.state == BleBridgeState.connecting ||
                    _ble.state == BleBridgeState.busy
                ? '连接中…'
                : _ble.state == BleBridgeState.error
                    ? '连接失败'
                    : '待连接'
        : '';
    final color = !_blePrefer
        ? Colors.grey
        : _bleConnected
            ? Colors.green
            : _ble.state == BleBridgeState.error
                ? Colors.redAccent
                : Colors.blueGrey;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.bluetooth, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          stateText.isEmpty ? '蓝牙模式' : stateText,
          style: TextStyle(
            fontSize: 11,
            color: _blePrefer ? Colors.blue.shade700 : AppPalette.subtle,
            fontWeight: _blePrefer ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        Transform.scale(
          scale: 0.8,
          child: Switch(
            value: _blePrefer,
            onChanged: (v) async {
              await _ble.setPrefer(v);
              if (mounted) {
                setState(() {
                  _blePrefer = v;
                  if (!v) _bleBusy = false; // 关闭蓝牙模式立即释放按钮
                });
              }
              if (v) unawaited(_autoConnectBle());
            },
          ),
        ),
      ],
    );
  }

  Widget _actionsSection() {
    final enabled = !_busy && !(_blePrefer && _bleBusy);
    // 控车网格：解锁 / 锁车 / 找车 / 后备箱（找车用官方 low/30s 参数）
    final items = <_CtrlItem>[
      _CtrlItem(Icons.lock_open, '解锁', _unlock, AppPalette.warn),
      _CtrlItem(Icons.lock, '锁车', _lock, AppPalette.ok),
      _CtrlItem(Icons.notifications_active, '找车', _find, AppPalette.info),
      _CtrlItem(Icons.lock_open_outlined, '后备箱', _trunk,
          const Color(0xFFB8860B)),
    ];

    return Column(
      children: [
        Row(
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(child: _bigActionBtn(items[i], enabled)),
            ],
          ],
        ),
        // 产品逻辑：解锁即自动下发 driveCycle「120 秒打火」，控车页不再放独立的启动按钮
        if (_blePrefer) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.key, size: 13, color: AppPalette.subtle),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '解锁后 120 秒内可直接按一键启动',
                  style: TextStyle(
                      fontSize: 10.5, color: AppPalette.subtle, height: 1.35),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _bigActionBtn(_CtrlItem it, bool enabled) {
    return ScalePress(
      enabled: enabled,
      onPressed: enabled
          ? () {
              // 点按控车键：短震动反馈
              HapticFeedback.mediumImpact();
              it.onTap();
            }
          : null,
      child: Material(
        color: it.color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(it.icon, size: 18, color: it.color),
              const SizedBox(height: 3),
              Text(
                it.label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: AppPalette.strong,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _acCard(bool enabled) {
    final temp = (_acTempC ?? 24).clamp(16, 30).toDouble();
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.45),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: (_acOn == true
                            ? const Color(0xFF26A69A)
                            : AppPalette.muted)
                        .withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.ac_unit,
                      size: 16,
                      color: _acOn == true
                          ? const Color(0xFF26A69A)
                          : AppPalette.muted),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _acOn == true
                        ? '空调运行中${_acTempC != null ? ' · ${_acTempC}℃' : ''}'
                        : '空调',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: AppPalette.strong),
                  ),
                ),
                Switch(
                  value: _acOn == true,
                  onChanged: enabled ? (v) => _acToggle(v) : null,
                ),
              ],
            ),
            if (_acOn == true)
              Row(
                children: [
                  Text('16℃', style: TextStyle(fontSize: 11, color: AppPalette.muted)),
                  Expanded(
                    child: Slider(
                      value: temp,
                      min: 16,
                      max: 30,
                      divisions: 14,
                      label: '${temp.round()}℃',
                      onChanged: enabled
                          ? (v) => setState(() => _acTempC = v.round())
                          : null,
                      onChangeEnd: (_) => _acTempConfirm(),
                    ),
                  ),
                  Text('${temp.round()}℃',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppPalette.strong)),
                  const SizedBox(width: 4),
                ],
              ),
            if (_acOn != true)
              Padding(
                padding: EdgeInsets.only(top: 4, bottom: 2),
                child: Text('开启后可滑动调节温度',
                    style: TextStyle(fontSize: 11, color: AppPalette.muted)),
              ),
          ],
        ),
      ),
    );
  }

  /// 主/副驾加热：独立于空调卡，放在空调板块下方
  /// （读状态可用；开关控制需要协议侧补齐对应接口后启用）
  Widget _seatHeatSection(bool enabled) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: enabled
                ? () => _seatHeat(
                    '1',
                    !(_seatHeatDriver == true),
                    _seatHeatDriver == true ? '关主驾加热' : '开主驾加热')
                : null,
            icon: const Icon(Icons.chair_alt, size: 16),
            label: Text(
              _seatHeatDriver == true
                  ? '主驾热${_seatHeatDriverLevel != null && _seatHeatDriverLevel! > 0 ? '·${_seatHeatDriverLevel}档' : ''}'
                  : '主驾加热',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: enabled
                ? () => _seatHeat(
                    '2',
                    !(_seatHeatPassenger == true),
                    _seatHeatPassenger == true ? '关副驾加热' : '开副驾加热')
                : null,
            icon: const Icon(Icons.chair_alt, size: 16),
            label: Text(
              _seatHeatPassenger == true
                  ? '副驾热${_seatHeatPassengerLevel != null && _seatHeatPassengerLevel! > 0 ? '·${_seatHeatPassengerLevel}档' : ''}'
                  : '副驾加热',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }
}

/// 大网格控车按钮的数据项
class _CtrlItem {
  const _CtrlItem(this.icon, this.label, this.onTap, this.color);
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;
}
