import 'app_config.dart';
// 快捷控车弹窗：位置 + 实时车况 + 控车按钮 + 空调滑条 + 预约入口
// 磁贴 / 小组件 / 图标长按 共用此面板。

import 'dart:async';

import 'package:flutter/material.dart';

import 'theme_controller.dart';

import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, SystemNavigator;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:mymg/src/rust/api.dart';
import 'package:mymg/src/rust/vehicle/control.dart';
import 'package:mymg/src/rust/vehicle/summary.dart';

import 'ble_key_bridge.dart';
import 'ble_permission_controller.dart';
import 'climate_page.dart';
import 'control_config.dart';
import 'err_util.dart';
import 'notification_service.dart';
import 'pin_vault.dart';
import 'reservation_service.dart';
import 'summary_cache.dart';
import 'token_age.dart';
import 'ui/glass_surface.dart';
import 'ui/frosted_page.dart';
import 'ui/vehicle_hero.dart';

/// 应用内 / 小组件 / 控制中心 共用同一弹窗组件，保证数据与连接状态唯一。
Future<void> showQuickControlSheet(
  BuildContext context, {
  String? initialAction,
}) async {
  if (QuickControlHostPage.isShowing) return;
  await Navigator.of(context).push(_QuickControlRoute(initialAction));
}

// A control sheet is an overlay, not a detail page: dismissing it must preserve
// the originating tab. Its child owns the slide/fade animation.
class _QuickControlRoute extends PopupRoute<void> {
  _QuickControlRoute(this.initialAction);
  final String? initialAction;

  @override
  Color get barrierColor => Colors.transparent;
  @override
  bool get barrierDismissible => true;
  @override
  String get barrierLabel => '关闭控车';
  @override
  Duration get transitionDuration => Duration.zero;
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => QuickControlHostPage(initialAction: initialAction);
}

/// 透明快捷控车宿主：滑入淡入+缩放；关闭可下滑/点空白/返回。
/// 无黑色遮罩，桌面/App 底保持可见。
class QuickControlHostPage extends StatefulWidget {
  const QuickControlHostPage({
    super.key,
    this.standalone = false,
    this.initialAction,
  });

  /// true=独立 Activity（小组件/磁贴），关闭时 pop 系统页面
  final bool standalone;
  final String? initialAction;

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
  late final Animation<Offset> _slide =
      Tween<Offset>(begin: const Offset(0, 0.35), end: Offset.zero).animate(
        CurvedAnimation(
          parent: _ctrl,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        ),
      );
  late final Animation<double> _scale = Tween<double>(begin: 0.96, end: 1.0)
      .animate(
        CurvedAnimation(
          parent: _ctrl,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        ),
      );

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
      Navigator.of(context).pop();
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
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(20),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: SafeArea(
                      top: false,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(context).size.height * 0.94,
                        ),
                        child: FrostedBackground(
                          child: QuickControlSheet(
                            standalone: widget.standalone,
                            initialAction: widget.initialAction,
                            onClose: _close,
                          ),
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
  const QuickControlSheet({
    super.key,
    this.standalone = false,
    this.initialAction,
    this.onClose,
    this.embedded = false,
    this.climateOnly = false,
    this.token,
    this.vin,
  });

  final bool standalone;
  final String? initialAction;

  /// A shortcut may highlight intent, but must never execute on page open.
  final bool embedded;
  final bool climateOnly;
  final String? token;
  final String? vin;

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
  int _targetTemp = 24;
  bool _temperatureEdited = false;
  VehicleSummary? _summary;
  bool? _seatHeatDriver;
  bool? _seatHeatPassenger;
  int? _seatHeatDriverLevel;
  int? _seatHeatPassengerLevel;

  // 座椅加热 / 空调（来自 summary 实时车况）
  // 预约（WorkManager 到点执行；独立页内联编辑，不再嵌套弹层）
  bool _resEnabled = false;
  String _resType = 'ac';
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
    if (!mounted) return;
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
        _bleConnected =
            _ble.state == BleBridgeState.connected ||
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
    final saved = await ControlConfig.load();
    final c = ControlConfig(
      brand: saved.brand,
      userId: saved.userId,
      mobile: saved.mobile,
      headerDeviceId: saved.headerDeviceId,
      requireBiometric: saved.requireBiometric,
      pinSaved: saved.pinSaved,
      token: widget.token ?? saved.token,
      vin: widget.vin ?? saved.vin,
    );
    if (!mounted) return;
    setState(() {
      _cfg = c;
    });
    await _loadReservation();
    // Opening a surface only loads state. Commands (including overdue
    // reservations) must never be triggered by navigation or initialAction.
    // 车况后台静默刷新，不挡打开（用户主动看实时以首页下拉为准）
    if (c.tokenOk && c.vinOk) {
      unawaited(_loadStatus());
    }
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
      final fresh =
          lastAt == null ||
          DateTime.now().difference(lastAt) > const Duration(seconds: 5);
      if (fresh) {
        _bleNotifiedAt[line] = DateTime.now();
        unawaited(_notifyLocal(stage == 'ready' ? '蓝牙车控' : '蓝牙车控失败', line));
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
    // Retire previously saved, unsupported heating reservations as well as
    // removing their UI; otherwise they could still fire in the background.
    if (c.enabled && c.type != 'ac') {
      await ReservationConfig.saveAndSchedule(
        enabled: false,
        type: 'ac',
        hour: c.hour,
        minute: c.minute,
        when: DateTime.now(),
      );
    }
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _resEnabled = c.enabled && c.type == 'ac';
      _resType = 'ac';
      _resTime = TimeOfDay(hour: c.hour, minute: c.minute);
      _resLastError = p.getString('mymg.res.last_err');
    });
  }

  Future<void> _saveReservation() async {
    // 到点时间：今天已过则记明天
    final now = DateTime.now();
    var when = DateTime(
      now.year,
      now.month,
      now.day,
      _resTime.hour,
      _resTime.minute,
    );
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
    _toast(
      _resEnabled
          ? '预约已保存：${_resTime.format(context)} 自动执行 ${_typeLabel(_resType)}'
          : '预约已关闭',
    );
  }

  String _typeLabel(String t) => '空调';

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
        _summary = s;
        _acOn = s.acOn;
        _acTempC = s.acTargetTemp?.toInt();
        if (!_temperatureEdited && _acTempC != null) {
          _targetTemp = _acTempC!.clamp(16, 30);
        }
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
        // Authentication cancellation is silent; explicit PIN entry remains
        // available on the next attempt if biometrics are unavailable.
        return null;
      }
    }
    final p = await _vault.loadIntoMemory();
    if (p != null) return p;
    if (!mounted) return null;
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
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: 8,
            obscureText: true,
            style: TextStyle(color: scheme.onSurface),
            decoration: InputDecoration(
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              hintText: '4~8 位数字',
              hintStyle: TextStyle(color: scheme.onSurfaceVariant),
              filled: true,
              fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
    if (pin == null || !RegExp(r'^\d{4,8}$').hasMatch(pin.trim())) {
      return null;
    }
    await _vault.saveEncrypted(pin.trim());
    await _vault.loadIntoMemory();
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

    // Guard synchronously, before permission requests, biometrics or PIN UI.
    setState(() => _busy = true);
    try {
      if (bleAction != null && _blePrefer) {
        await _tryBleActionStrict(bleAction, label);
        return;
      }
      final c = _cfg;
      if (c == null || !c.readyForControl) {
        _toast('请先在「设置 → 远程控车」完成配置');
        return;
      }
      final pin = await _ensurePin();
      if (!mounted || pin == null || pin.isEmpty) return;
      _toast('「$label」请求中…');
      var config = c;
      // 控车前：token 必须是 ACCESS_TOKEN；不是则先激活一次
      if (!AppConfig.looksLikeAccessToken(config.token ?? '')) {
        final upgraded = await _tryUpgradeToken(config);
        if (upgraded != null) config = upgraded;
      }
      if (!mounted) return;
      var outcome = await run(pin, config);
      // 登录态失效：刷新 token 后只重试一次，绝不双发
      Future<ControlOutcome> retryWithRefresh() async {
        final upgraded = await _tryUpgradeToken(config);
        if (upgraded != null) config = upgraded;
        return run(pin, config);
      }

      final firstMsg = outcome.message ?? '';
      final rateLimited = firstMsg.contains('15006') || firstMsg.contains('频繁');
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
        // Accepted means dispatched, never confirmed vehicle state.
        _toast('「$label」已下发');
        final cid = outcome.commandId;
        final brand = config.brand;
        final token = config.token!;
        final vin = config.vin!;
        final userId = config.userId;
        final mobile = config.mobile;
        final devId = config.headerDeviceId;
        if (cid != null) {
          await _pollControlResult(
            label: label,
            brand: brand,
            token: token,
            vin: vin,
            userId: userId,
            mobile: mobile,
            headerDeviceId: devId,
            commandId: cid,
          );
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
    // send() waits for permission in both engines; hold busy before that await.
    // 材料补齐交给 send()：它会依次尝试原生落盘 / 联网钥匙列表，并给出具体缺什么。
    setState(() {
      _bleBusy = true;
    });
    _bleLastAction = action;
    final seq = ++_bleSeq;
    final ok = await _ble.send(action);
    if (!mounted) return;
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

  /// Keep the duplicate guard held until the remote result is known or times out.
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
      if (!mounted) return;
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
        if (!mounted) return;
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

  Future<void> _lock() => _act(
    '锁车',
    (pin, c) => vehicleLock(
      brand: c.brand,
      token: c.token!,
      vin: c.vin!,
      pin: pin,
      userId: c.userId,
      mobile: c.mobile,
      headerDeviceId: c.headerDeviceId,
    ),
    bleAction: 'lock',
  );
  Future<void> _unlock() => _act(
    '解锁',
    (pin, c) => vehicleUnlock(
      brand: c.brand,
      token: c.token!,
      vin: c.vin!,
      pin: pin,
      userId: c.userId,
      mobile: c.mobile,
      headerDeviceId: c.headerDeviceId,
    ),
    bleAction: 'unlock',
  );
  Future<void> _trunk() => _act(
    '开后备箱',
    (pin, c) => vehicleUnlockBoot(
      brand: c.brand,
      token: c.token!,
      vin: c.vin!,
      pin: pin,
      userId: c.userId,
      mobile: c.mobile,
      headerDeviceId: c.headerDeviceId,
    ),
    bleAction: 'trunk',
  );

  /// 免钥匙启动不再是独立按钮：解锁成功由原生自动补一次 driveCycle（120 秒打火），
  /// 见 MymgBleKeyClient 的 autoDriveAfterUnlock。

  /// 找车：官方 requestFindVehicle（horn_volume=low / time_length=30）
  Future<void> _find() => _act(
    '找车',
    (pin, c) => vehicleFindVehicle(
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
    ),
  );
  // 找车按钮已按官方参数加回（2026-09-22）

  Future<void> _acToggle(bool on) async {
    if (_busy) return;
    if (on) {
      await _act(
        '开空调',
        (pin, c) => vehicleAcOn(
          brand: c.brand,
          token: c.token!,
          vin: c.vin!,
          pin: pin,
          userId: c.userId,
          mobile: c.mobile,
          headerDeviceId: c.headerDeviceId,
          targetTempC: _targetTemp,
        ),
      );
    } else {
      await _act(
        '关空调',
        (pin, c) => vehicleAcOff(
          brand: c.brand,
          token: c.token!,
          vin: c.vin!,
          pin: pin,
          userId: c.userId,
          mobile: c.mobile,
          headerDeviceId: c.headerDeviceId,
        ),
      );
    }
  }

  Future<void> _acTempConfirm() async {
    if (_busy) return;
    await _act(
      '设置温度',
      (pin, c) => vehicleAcOn(
        brand: c.brand,
        token: c.token!,
        vin: c.vin!,
        pin: pin,
        userId: c.userId,
        mobile: c.mobile,
        headerDeviceId: c.headerDeviceId,
        targetTempC: _targetTemp,
      ),
    );
  }

  Future<void> _openReservation() async {
    // 独立透明页里嵌套 showModalBottomSheet / showTimePicker 常吞点击，
    // 改为主面板内联展开：开关 / 项目 / 时间 / 保存全部同层可点。
    setState(() => _resPanelOpen = !_resPanelOpen);
  }

  void _toast(String msg) {
    if (!mounted) return;
    final text = _friendlyControlError(msg);
    final isError =
        text.contains('失败') ||
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
      await NotificationService.instance.notifyPlain(title: title, body: body);
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
    final enabled = !_busy && !_bleBusy && _cfg != null;
    return Column(
      mainAxisSize: widget.embedded ? MainAxisSize.max : MainAxisSize.min,
      children: [
        if (!widget.embedded)
          Row(
            children: [
              const SizedBox(width: 16),
              const Expanded(
                child: Text(
                  '车辆控制',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '关闭控车',
                onPressed:
                    widget.onClose ??
                    () {
                      if (widget.standalone) {
                        SystemNavigator.pop();
                      } else {
                        Navigator.of(context).pop();
                      }
                    },
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_uiMsg != null) ...[
                      Semantics(
                        liveRegion: true,
                        child: GlassSurface(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: [
                              Icon(
                                _uiMsgIsError
                                    ? Icons.info_outline
                                    : Icons.check_circle_outline,
                                color: _uiMsgIsError
                                    ? context.danger
                                    : context.info,
                                size: 20,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _uiMsg!,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (BlePermissionController.instance.denied)
                        TextButton.icon(
                          onPressed: () async {
                            final opened = await BlePermissionController
                                .instance
                                .openAppSettings();
                            if (!opened && mounted)
                              _toast('无法打开应用设置，请手动进入系统设置授权');
                          },
                          icon: const Icon(Icons.settings_outlined),
                          label: const Text('打开应用设置'),
                        ),
                      const SizedBox(height: 14),
                    ],
                    if (widget.climateOnly) ...[
                      _climateHero(enabled),
                      const SizedBox(height: 16),
                    ] else ...[
                      _vehicleStage(enabled),
                      const SizedBox(height: 12),
                    ],
                    _temperatureCard(enabled),
                    const SizedBox(height: 14),
                    if (widget.climateOnly) ...[
                      GlassSurface(
                        child: Row(
                          children: [
                            Icon(Icons.air_rounded, color: context.muted),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                '模式与风量请在车内调节',
                                style: TextStyle(
                                  color: context.muted,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    _seatReadOnly(),
                    const SizedBox(height: 14),
                    _reservationPanel(enabled),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _vehicleStage(bool enabled) {
    return Column(
      children: [
        Row(
          children: [
            Text(
              'MG5',
              style: TextStyle(
                fontSize: 13,
                color: context.muted,
                letterSpacing: 2,
              ),
            ),
            const Spacer(),
            _bleModeChip(),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 326,
          child: Row(
            children: [
              SizedBox(
                width: 70,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _stageAction(
                      Icons.lock_outline_rounded,
                      '车锁',
                      enabled ? _showLockOptions : null,
                      id: 'lock',
                    ),
                    _stageAction(
                      Icons.window_rounded,
                      '车窗',
                      enabled ? _showWindowOptions : null,
                      id: 'window',
                    ),
                    _stageAction(
                      Icons.directions_car_outlined,
                      '后备箱',
                      enabled ? _trunk : null,
                      id: 'trunk',
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Semantics(
                    image: true,
                    label:
                        'MG5 车辆俯视状态示意，车锁${_summary?.allLocked == true
                            ? '已锁'
                            : _summary?.allLocked == false
                            ? '未锁'
                            : '状态未知'}',
                    child: CustomPaint(
                      painter: _VehiclePlanPainter(
                        accent: context.info,
                        windowsClosed: _summary?.allWindowsClosed,
                        locked: _summary?.allLocked,
                      ),
                      size: const Size(170, 320),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 70,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _stageAction(
                      Icons.lock_open_rounded,
                      '解锁',
                      enabled ? _unlock : null,
                      id: 'unlock',
                    ),
                    _stageAction(
                      Icons.volume_up_outlined,
                      '寻车',
                      enabled ? _find : null,
                      id: 'find',
                    ),
                    _stageAction(
                      Icons.ac_unit_rounded,
                      '空调',
                      enabled ? _openClimate : null,
                      id: 'climate',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Text(
          _blePrefer ? '蓝牙解锁后，120 秒内可按一键启动' : '远程控车 · 车辆状态以最新回报为准',
          textAlign: TextAlign.center,
          style: TextStyle(color: context.muted, fontSize: 12),
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _stageAction(
    IconData icon,
    String label,
    VoidCallback? action, {
    required String id,
  }) {
    final highlighted = widget.initialAction == id;
    return Semantics(
      key: ValueKey('vehicle-action-$id'),
      selected: highlighted,
      child: SizedBox(
        width: 70,
        child: Opacity(
          opacity: action == null ? 0.45 : 1,
          child: GlassSurface(
            onTap: action,
            tint: highlighted
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            borderRadius: 20,
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
            child: Column(
              children: [
                Icon(
                  icon,
                  size: 24,
                  color: highlighted ? context.info : context.strong,
                ),
                const SizedBox(height: 8),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: highlighted ? FontWeight.w700 : FontWeight.w500,
                    color: highlighted ? context.info : context.strong,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showLockOptions() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('锁车'),
              onTap: () => Navigator.pop(context, 'lock'),
            ),
            ListTile(
              leading: const Icon(Icons.lock_open),
              title: const Text('解锁'),
              onTap: () => Navigator.pop(context, 'unlock'),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'lock') await _lock();
    if (action == 'unlock') await _unlock();
  }

  Future<void> _showWindowOptions() async {
    final open = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('车窗'), subtitle: Text('车窗操作使用远程控车')),
            ListTile(
              leading: const Icon(Icons.open_in_full),
              title: const Text('打开车窗'),
              onTap: () => Navigator.pop(context, true),
            ),
            ListTile(
              leading: const Icon(Icons.close_fullscreen),
              title: const Text('关闭车窗'),
              onTap: () => Navigator.pop(context, false),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
    if (!mounted || open == null) return;
    await _act(
      open ? '打开车窗' : '关闭车窗',
      (pin, c) => open
          ? vehicleWindowOpen(
              brand: c.brand,
              token: c.token!,
              vin: c.vin!,
              pin: pin,
              userId: c.userId,
              mobile: c.mobile,
              headerDeviceId: c.headerDeviceId,
              target: 'all',
              position: 100,
            )
          : vehicleWindowClose(
              brand: c.brand,
              token: c.token!,
              vin: c.vin!,
              pin: pin,
              userId: c.userId,
              mobile: c.mobile,
              headerDeviceId: c.headerDeviceId,
              target: 'all',
              position: 0,
            ),
    );
  }

  void _openClimate() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ClimatePage(token: _cfg?.token ?? '', vin: _cfg?.vin ?? ''),
      ),
    );
  }

  Widget _climateHero(bool enabled) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _acOn == true
                    ? '空调运行中'
                    : _acOn == false
                    ? '空调已关闭'
                    : '空调状态未知',
                style: TextStyle(color: context.muted, fontSize: 13),
              ),
            ),
            IconButton.filledTonal(
              key: const ValueKey('climate-power'),
              tooltip: _acOn == true ? '关闭空调' : '开启空调',
              onPressed: enabled ? () => _acToggle(_acOn != true) : null,
              icon: Icon(
                Icons.power_settings_new_rounded,
                color: _acOn == true ? context.info : context.muted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text('设定温度', style: TextStyle(color: context.muted, fontSize: 12)),
        const SizedBox(height: 4),
        Text(
          '$_targetTemp.0°C',
          key: const ValueKey('climate-target'),
          style: const TextStyle(
            fontSize: 60,
            fontWeight: FontWeight.w400,
            letterSpacing: -2,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '车内 ${_summary?.interiorTemp?.toStringAsFixed(1) ?? '—'}°C  |  车外 ${_summary?.exteriorTemp?.toStringAsFixed(1) ?? '—'}°C',
          style: TextStyle(color: context.muted, fontSize: 12),
        ),
        const SizedBox(height: 18),
        ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: SizedBox(
            height: 192,
            width: double.infinity,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const VehicleImage(),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        context.info.withValues(alpha: 0.02),
                        context.info.withValues(alpha: 0.15),
                      ],
                    ),
                  ),
                ),
                if (_acOn == true)
                  IgnorePointer(
                    child: CustomPaint(painter: _AirflowPainter(context.info)),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _setTarget(int value) {
    setState(() {
      _temperatureEdited = true;
      _targetTemp = value.clamp(16, 30);
    });
  }

  Widget _temperatureAdjustment(bool enabled) {
    const valueStyle = TextStyle(
      fontSize: 32,
      fontWeight: FontWeight.w500,
      letterSpacing: -1,
    );
    final temperature = '$_targetTemp.0°C';
    return LayoutBuilder(
      builder: (context, constraints) {
        final measurement = TextPainter(
          text: TextSpan(text: temperature, style: valueStyle),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final stacked = measurement.width + 120 > constraints.maxWidth;
        measurement.dispose();
        final value = Text(temperature, style: valueStyle);
        final decrease = IconButton.filledTonal(
          tooltip: '降低温度',
          icon: const Icon(Icons.remove_rounded),
          onPressed: enabled && _targetTemp > 16
              ? () => _setTarget(_targetTemp - 1)
              : null,
        );
        final increase = IconButton.filledTonal(
          tooltip: '升高温度',
          icon: const Icon(Icons.add_rounded),
          onPressed: enabled && _targetTemp < 30
              ? () => _setTarget(_targetTemp + 1)
              : null,
        );
        if (stacked) {
          return Column(
            children: [
              Center(
                child: FittedBox(fit: BoxFit.scaleDown, child: value),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [decrease, increase],
              ),
            ],
          );
        }
        return Row(
          children: [
            decrease,
            Expanded(child: Center(child: value)),
            increase,
          ],
        );
      },
    );
  }

  Widget _temperatureCard(bool enabled) {
    return GlassSurface(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.climateOnly ? '温度调节' : '车内温度',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_busy) ...[
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: context.info,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '处理中',
                  style: TextStyle(fontSize: 12, color: context.muted),
                ),
              ] else if (!widget.climateOnly)
                Text(
                  _acOn == true
                      ? '运行中'
                      : _acOn == false
                      ? '已关闭'
                      : '状态未知',
                  style: TextStyle(fontSize: 12, color: context.muted),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _temperatureAdjustment(enabled),
          Slider(
            value: _targetTemp.toDouble(),
            min: 16,
            max: 30,
            divisions: 14,
            label: '$_targetTemp°C',
            activeColor: context.info,
            onChanged: enabled ? (v) => _setTarget(v.round()) : null,
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '16°C',
                style: TextStyle(fontSize: 11, color: context.muted),
              ),
              Text(
                '30°C',
                style: TextStyle(fontSize: 11, color: context.muted),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('climate-apply'),
                  onPressed: enabled ? _acTempConfirm : null,
                  icon: const Icon(Icons.ac_unit_rounded, size: 18),
                  label: Text(_acOn == true ? '应用温度' : '开启空调'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                key: const ValueKey('climate-off'),
                onPressed: enabled ? () => _acToggle(false) : null,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(76, 48),
                ),
                child: const Text('关闭'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '温度调整后点击${_acOn == true ? '「应用温度」' : '「开启空调」'}发送',
            style: TextStyle(fontSize: 11, color: context.muted),
          ),
        ],
      ),
    );
  }

  String _heatText(bool? on, int? level) {
    if (on == null) return '未知';
    if (!on) return '关闭';
    return level != null && level > 0 ? '$level 档' : '开启';
  }

  Widget _seatReadOnly() {
    return GlassSurface(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.airline_seat_recline_normal_rounded,
                size: 22,
                color: context.strong,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  '座椅加热',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              Text('仅查看', style: TextStyle(color: context.muted, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  '主驾  ${_heatText(_seatHeatDriver, _seatHeatDriverLevel)}',
                  style: TextStyle(color: context.muted, fontSize: 13),
                ),
              ),
              Expanded(
                child: Text(
                  '副驾  ${_heatText(_seatHeatPassenger, _seatHeatPassengerLevel)}',
                  style: TextStyle(color: context.muted, fontSize: 13),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _reservationPanel(bool enabled) {
    return GlassSurface(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.schedule_rounded, color: context.info),
            title: const Text('预约空调', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              _resEnabled ? '${_resTime.format(context)} · 24°C' : '提前准备舒适车厢',
              style: TextStyle(color: context.muted, fontSize: 12),
            ),
            trailing: Icon(
              _resPanelOpen ? Icons.expand_less : Icons.chevron_right,
              color: context.muted,
            ),
            onTap: enabled ? _openReservation : null,
          ),
          if (_resPanelOpen) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用预约', style: TextStyle(fontSize: 14)),
              value: _resEnabled,
              onChanged: enabled
                  ? (v) async {
                      setState(() => _resEnabled = v);
                      await _saveReservation();
                    }
                  : null,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('执行时间', style: TextStyle(fontSize: 14)),
              trailing: Text(_resTime.format(context)),
              onTap: enabled
                  ? () async {
                      final time = await showTimePicker(
                        context: context,
                        initialTime: _resTime,
                      );
                      if (!mounted || time == null) return;
                      setState(() => _resTime = time);
                      if (_resEnabled) await _saveReservation();
                    }
                  : null,
            ),
            if (_resLastError != null)
              Text(
                '上次预约未完成：$_resLastError',
                style: TextStyle(color: context.danger, fontSize: 12),
              ),
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Text(
                '需已保存控车密码；到点执行一次，后台执行时间受系统限制。',
                style: TextStyle(
                  color: context.muted,
                  fontSize: 11,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _bleModeChip() {
    final stateText = _blePrefer
        ? _bleConnected
              ? (_bleSession.isEmpty ? '已连接' : '已连接 · $_bleSession')
              : _ble.state == BleBridgeState.connecting ||
                    _ble.state == BleBridgeState.busy
              ? '连接中…'
              : '待连接'
        : '远程';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          _blePrefer ? Icons.bluetooth_rounded : Icons.cloud_outlined,
          size: 15,
          color: context.info,
        ),
        const SizedBox(width: 5),
        Text(stateText, style: TextStyle(fontSize: 11, color: context.muted)),
        const SizedBox(width: 4),
        Switch(
          value: _blePrefer,
          onChanged: _busy || _bleBusy
              ? null
              : (v) async {
                  await _ble.setPrefer(v);
                  if (!mounted) return;
                  setState(() => _blePrefer = v);
                  // Switching transport selects it; connection begins on explicit action.
                },
        ),
      ],
    );
  }
}

/// A neutral MG5-sized sedan diagram, not a simulated live vehicle rendering.
/// Metallic bodywork and dark glazing keep the status diagram legible in both
/// themes without borrowing another manufacturer's vehicle.
class _VehiclePlanPainter extends CustomPainter {
  const _VehiclePlanPainter({
    required this.accent,
    this.windowsClosed,
    this.locked,
  });
  final Color accent;
  final bool? windowsClosed;
  final bool? locked;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = (size.width / 164).clamp(0.0, size.height / 320);
    canvas.save();
    canvas.translate(
      (size.width - 164 * scale) / 2,
      (size.height - 320 * scale) / 2,
    );
    canvas.scale(scale);
    final body = Path()
      ..moveTo(82, 7)
      ..cubicTo(50, 7, 29, 14, 26, 45)
      ..cubicTo(21, 100, 24, 212, 28, 266)
      ..cubicTo(30, 296, 44, 311, 82, 312)
      ..cubicTo(120, 311, 134, 296, 136, 266)
      ..cubicTo(140, 212, 143, 100, 138, 45)
      ..cubicTo(135, 14, 114, 7, 82, 7)
      ..close();
    canvas.drawShadow(
      body.shift(const Offset(0, 7)),
      const Color(0xFF203653),
      13,
      true,
    );
    final tyre = Paint()..color = const Color(0xFF17202D);
    for (final x in [20.0, 134.0]) {
      for (final y in [65.0, 236.0]) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, 10, 37),
            const Radius.circular(4),
          ),
          tyre,
        );
      }
    }
    canvas.drawPath(
      body,
      Paint()
        ..shader = const LinearGradient(
          colors: [
            Color(0xFF667487),
            Color(0xFFE8EDF4),
            Color(0xFF9DAAB9),
            Color(0xFFD9E0E9),
            Color(0xFF586779),
          ],
          stops: [0, .13, .5, .85, 1],
        ).createShader(const Rect.fromLTWH(24, 0, 116, 320)),
    );
    canvas.drawPath(
      body,
      Paint()
        ..color = const Color(0xFF8897A9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1,
    );

    // Sculpted hood and trunk seams.
    final seam = Paint()
      ..color = const Color(0xFF75879B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .8;
    canvas.drawPath(
      Path()
        ..moveTo(40, 61)
        ..quadraticBezierTo(82, 51, 124, 61),
      seam,
    );
    canvas.drawPath(
      Path()
        ..moveTo(37, 277)
        ..quadraticBezierTo(82, 291, 127, 277),
      seam,
    );
    for (final x in [39.0, 125.0]) {
      canvas.drawPath(
        Path()
          ..moveTo(x, 29)
          ..quadraticBezierTo(x - (x < 82 ? 4 : -4), 47, x, 65),
        seam,
      );
    }

    final glass = Path()
      ..moveTo(43, 89)
      ..quadraticBezierTo(82, 67, 121, 89)
      ..lineTo(129, 142)
      ..lineTo(123, 239)
      ..quadraticBezierTo(82, 259, 41, 239)
      ..lineTo(35, 142)
      ..close();
    canvas.drawPath(
      glass,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF65778D), Color(0xFF15212E), Color(0xFF283A4B)],
        ).createShader(const Rect.fromLTWH(35, 77, 94, 180)),
    );
    // Windshield, body-coloured roof, rear windscreen.
    final roof = RRect.fromRectAndRadius(
      const Rect.fromLTWH(47, 127, 70, 89),
      const Radius.circular(14),
    );
    canvas.drawRRect(
      roof,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFFA5B2C0), Color(0xFFD6DFE8), Color(0xFF7B8CA1)],
        ).createShader(roof.outerRect),
    );
    final reflection = Paint()
      ..color = const Color(0xFFDAEBFF).withValues(alpha: .22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    canvas.drawPath(
      Path()
        ..moveTo(47, 95)
        ..quadraticBezierTo(82, 79, 117, 95),
      reflection,
    );
    canvas.drawPath(
      Path()
        ..moveTo(49, 226)
        ..quadraticBezierTo(82, 239, 115, 226),
      reflection,
    );
    final windowLine = Paint()
      ..color = windowsClosed == false ? accent : const Color(0xFF6C8299)
      ..style = PaintingStyle.stroke
      ..strokeWidth = windowsClosed == false ? 2.4 : .8;
    for (final x in [39.0, 125.0]) {
      canvas.drawLine(Offset(x, 148), Offset(x, 223), windowLine);
    }
    canvas.drawLine(const Offset(36, 175), const Offset(46, 175), seam);
    canvas.drawLine(const Offset(118, 175), const Offset(128, 175), seam);
    // Side mirrors.
    for (final rect in [
      const Rect.fromLTWH(14, 105, 15, 10),
      const Rect.fromLTWH(135, 105, 15, 10),
    ]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        Paint()..color = const Color(0xFF98A8BA),
      );
    }
    final light = Paint()
      ..color = const Color(0xFFF1F8FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(
      Path()
        ..moveTo(33, 35)
        ..quadraticBezierTo(41, 24, 53, 23),
      light,
    );
    canvas.drawPath(
      Path()
        ..moveTo(111, 23)
        ..quadraticBezierTo(123, 24, 131, 35),
      light,
    );
    final tail = Paint()
      ..color = const Color(0xFFC24F59)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(
      Path()
        ..moveTo(34, 283)
        ..quadraticBezierTo(43, 295, 57, 297),
      tail,
    );
    canvas.drawPath(
      Path()
        ..moveTo(107, 297)
        ..quadraticBezierTo(121, 295, 130, 283),
      tail,
    );
    // Lock indicator is shown only from observed telemetry.
    if (locked != null) {
      final indicator = Paint()
        ..color = accent.withValues(alpha: locked! ? .9 : .25);
      canvas.drawCircle(const Offset(82, 171), 4, indicator);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_VehiclePlanPainter oldDelegate) =>
      oldDelegate.accent != accent ||
      oldDelegate.windowsClosed != windowsClosed ||
      oldDelegate.locked != locked;
}

class _AirflowPainter extends CustomPainter {
  const _AirflowPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: .02),
          const Color(0xFFB9E5FF).withValues(alpha: .5),
          color.withValues(alpha: .02),
        ],
      ).createShader(Offset.zero & size)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 5; i++) {
      final x = size.width * (.40 + i * .09);
      canvas.drawPath(
        Path()
          ..moveTo(x, size.height * .51)
          ..cubicTo(
            x - 12,
            size.height * .66,
            x - 30,
            size.height * .8,
            x - 55,
            size.height,
          ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_AirflowPainter oldDelegate) => oldDelegate.color != color;
}
