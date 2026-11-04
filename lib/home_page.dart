import 'dart:async';

import 'package:flutter/material.dart';

import 'theme_controller.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:mymg/src/rust/vehicle/summary.dart';
import 'package:mymg/src/rust/vehicle/model.dart';

import 'ai_report_store.dart';
import 'ai_service.dart';
import 'ai_widgets.dart';
import 'alert_rules.dart';
import 'background.dart';
import 'backup_service.dart';
import 'car_image_settings_page.dart';
import 'climate_page.dart';
import 'err_util.dart';
import 'geocode_service.dart';
import 'history_page.dart';
import 'login_page.dart';
import 'map_page.dart';
import 'notification_service.dart';
import 'message_center_page.dart';
import 'official_alert_service.dart';
import 'quick_control_sheet.dart';
import 'settings_page.dart';
import 'shortcut_router.dart';
import 'store.dart';
import 'summary_cache.dart';
import 'ui_motion.dart';
import 'ui/home_dashboard.dart';
import 'ui/glass_surface.dart';
import 'vehicle_status_page.dart';
import 'vehicle_profile.dart';
import 'widget_sync.dart';

/// 被用户手动忽略的告警 key（type-id-data），存在 SharedPreferences
const _kIgnoredAlertsKey = 'mymg.ignored_alerts';

/// 告警去重/忽略用的稳定 key
String alertKeyOf(VehicleAlert a) =>
    '${a.alertType ?? ""}-${a.alertId ?? ""}-${a.alertData ?? ""}';

/// 主页：调用 Rust 拉取车况摘要，按卡分组展示
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.token,
    required this.vin,
    this.onNavigate,
    this.active = true,
  });
  final String token;
  final String vin;
  final ValueChanged<int>? onNavigate;
  final bool active;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  VehicleSummary? _summary;
  String? _error;
  bool _loading = false;
  DateTime? _updatedAt;
  int? _snapshotCount; // 本机 SQLite 已存的快照数（首屏读一次）
  Set<String> _ignoredAlerts = <String>{}; // 用户手动忽略的告警

  // ── AI 智能总结（最新在前，本机最多 10 条） ──
  /// 首条 = 最新一条 = 首页 AI 卡的主展示内容；其余 = "最近总结"列表。
  List<AiReport> _aiHistory = const [];
  bool _aiRunning = false;

  /// 自动跑的去抖定时器（数据就绪后稍等 UI 稳定再调大模型）
  Timer? _aiAutoDebounce;

  /// 冷启动自动 AI 的结果提示（无变化时告诉用户为何没新总结）
  String? _aiAutoNote;

  /// 车牌号（本机手填，设置页维护；接口不返回）
  String _plate = '';

  /// 入场动画只播一次，避免每次刷新/生命周期触发卡片重放
  bool _entrancePlayed = false;

  /// 逆地理文字地址（异步）
  String? _geoLabel;
  bool _geoLoading = false;
  String? _geoForKey;
  String? _maintLastMsg;
  int? _maintLastKm;

  // ── 自动刷新（Day 3b）──
  Timer? _autoTimer;
  bool _autoRefresh = true;
  int _intervalMin = 5;

  /// 长按图标快捷方式的订阅（Day 7）
  StreamSubscription<String>? _shortcutSub;

  @override
  void initState() {
    super.initState();
    // 打开 App：先拉一次数据；成功后再触发 AI 自动分析（仅一次）
    unawaited(_bootstrap());
    _loadSnapshotCount();
    _loadIgnoredAlerts();
    _loadAutoRefresh();
    _loadPlate();
    _loadAiHistory();
    _loadMaintState();
    WidgetsBinding.instance.addObserver(this);
    _bindShortcuts();
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active && widget.active) {
      unawaited(_loadAutoRefresh());
      unawaited(_loadSnapshotCount());
      unawaited(_loadPlate());
      unawaited(_loadMaintState());
    }
  }

  Future<void> _loadMaintState() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _maintLastMsg = p.getString('mymg.maint.last_msg');
        _maintLastKm = p.getInt('mymg.maint.last_notified_km');
      });
    } catch (_) {}
  }

  /// 冷启动：非静默拉一次最新车况，成功后由 _refresh 内触发一次 AI
  Future<void> _bootstrap() async {
    await _refresh();
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _aiAutoDebounce?.cancel();
    _shortcutSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 订阅 + 消费长按图标的快捷方式请求
  void _bindShortcuts() {
    _shortcutSub = ShortcutRouter.stream.listen(_handleShortcut);
    // 冷启动：等第一帧结束再跳，确保 Navigator 已挂载
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pending = ShortcutRouter.consumePending();
      if (pending != null && mounted) _handleShortcut(pending);
    });
  }

  void _handleShortcut(String action) {
    if (!mounted) return;
    switch (action) {
      case ShortcutAction.history:
        _openHistory();
        break;
      case ShortcutAction.map:
        _openMap();
        break;
      case ShortcutAction.control:
        _openQuickControlSheet();
        break;
      case ShortcutAction.quickControl:
        _openQuickControlSheet();
        break;
    }
  }

  void _openHistory() {
    Navigator.of(context).push(
      FadeSlidePageRoute(
        page: HistoryPage(token: widget.token, vin: widget.vin),
      ),
    );
  }

  void _openMap() {
    Navigator.of(context).push(
      FadeSlidePageRoute(
        page: MapPage(token: widget.token, vin: widget.vin),
      ),
    );
  }

  /// 快捷控车弹窗（与控制中心磁贴一致）
  void _openQuickControlSheet({String? initialAction}) {
    unawaited(showQuickControlSheet(context, initialAction: initialAction));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 后台：停前台 Timer，按设置恢复 WorkManager，避免双开拉网
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _autoTimer?.cancel();
      _autoTimer = null;
      unawaited(resumePeriodicFetch());
      return;
    }
    if (state == AppLifecycleState.resumed) {
      // 前台：暂停 WM 周期任务，交给本页 Timer
      unawaited(pausePeriodicFetch());
      _loadAutoRefresh();
      _refresh(silent: _summary != null);
      unawaited(BackupService.instance.maybeAutoBackup());
    }
  }

  /// 读取自动刷新配置（设置页可能改过），并重建定时器
  Future<void> _loadAutoRefresh() async {
    final p = await SharedPreferences.getInstance();
    final auto = p.getBool(kAutoRefreshKey) ?? true;
    final intv = p.getInt(kIntervalMinKey) ?? 5;
    if (!mounted) return;
    setState(() {
      _autoRefresh = auto;
      _intervalMin = intv;
    });
    _restartAutoTimer();
  }

  void _restartAutoTimer() {
    _autoTimer?.cancel();
    _autoTimer = null;
    if (!_autoRefresh) return;
    // 最低 1 分钟，避免用户误设 0 造成空转
    final minutes = _intervalMin < 1 ? 5 : _intervalMin;
    _autoTimer = Timer.periodic(
      Duration(minutes: minutes),
      (_) => _refresh(silent: true),
    );
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      FadeSlidePageRoute(
        page: SettingsPage(token: widget.token, vin: widget.vin),
      ),
    );
    // 回来可能改了间隔/清了数据/填了车牌
    await _loadAutoRefresh();
    await _loadSnapshotCount();
    await _loadPlate();
  }

  /// 读车牌号（设置页可能刚改过）
  Future<void> _loadPlate() async {
    final p = await VehicleProfile.plate(force: true);
    if (mounted) setState(() => _plate = p);
  }

  Future<void> _loadIgnoredAlerts() async {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(_kIgnoredAlertsKey) ?? const <String>[];
    if (mounted) setState(() => _ignoredAlerts = list.toSet());
  }

  Future<void> _ignoreAlert(String key) async {
    final p = await SharedPreferences.getInstance();
    final next = {..._ignoredAlerts, key};
    await p.setStringList(_kIgnoredAlertsKey, next.toList());
    if (mounted) setState(() => _ignoredAlerts = next);
  }

  Future<void> _restoreAlerts() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kIgnoredAlertsKey);
    if (mounted) {
      setState(() => _ignoredAlerts = <String>{});
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已恢复全部告警显示')));
    }
  }

  Future<void> _resolveGeo(VehicleSummary s) async {
    final lat = double.tryParse(s.latitude ?? '');
    final lng = double.tryParse(s.longitude ?? '');
    if (lat == null || lng == null) {
      if (mounted) {
        setState(() {
          _geoLabel = null;
          _geoForKey = null;
        });
      }
      return;
    }
    final key = '${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';
    if (_geoLoading && _geoForKey == key) return;
    if (_geoForKey == key && _geoLabel != null) return;
    _geoLoading = true;
    _geoForKey = key;
    try {
      final label = await GeocodeService.instance.labelFor(lat, lng);
      if (!mounted) return;
      setState(() => _geoLabel = label);
    } catch (_) {
      if (!mounted) return;
      setState(() => _geoLabel = null);
    } finally {
      _geoLoading = false;
    }
  }

  /// 拉取车况。
  ///
  /// [silent] = true 时不显示 loading 转圈（自动刷新用），避免页面来回闪，
  /// 也避免 Flutter 的 RefreshIndicator / FAB 频繁显隐。
  Future<void> _refresh({bool silent = false}) async {
    if (_loading) return;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      // 主动下拉 / 非静默：必须唤醒车辆拿实时；静默刷新 30s 内可复用缓存
      final s = await SummaryCache.fetch(
        token: widget.token,
        vin: widget.vin,
        force: !silent,
      );
      if (!mounted) return;
      final prev = _summary;
      final changed =
          prev == null ||
          prev.fuelPercent != s.fuelPercent ||
          prev.rangeKm != s.rangeKm ||
          prev.odometerKm != s.odometerKm ||
          prev.allLocked != s.allLocked ||
          prev.allDoorsClosed != s.allDoorsClosed ||
          prev.allWindowsClosed != s.allWindowsClosed ||
          prev.fuelConsumption != s.fuelConsumption ||
          (s.alerts?.length ?? 0) != (prev.alerts?.length ?? 0);
      setState(() {
        _summary = s;
        _updatedAt = DateTime.now();
        _error = null;
      });
      // 首屏入场动画播完后标记，后续刷新不再重放
      if (prev == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_entrancePlayed) {
            setState(() => _entrancePlayed = true);
          }
        });
      }
      // 数据没变时跳过逆地理，减少网络与 setState
      if (changed || !silent) {
        unawaited(_resolveGeo(s));
      }
      // 副作用并行：写库 / 小组件 / 告警 / 备份 / 保养 互不阻塞 UI
      unawaited(() async {
        try {
          await SnapshotStore.instance.insertFromSummary(s, vin: widget.vin);
          try {
            await OfficialAlertService.syncFromSummary(s);
          } catch (_) {}
          await _loadSnapshotCount();
        } catch (e) {
          debugPrint('[MYMG] snapshot save failed: $e');
        }
      }());

      // ★ Day 7：把最新车况推给桌面小组件（写 SharedPreferences + 敲门）
      unawaited(() async {
        try {
          await WidgetSync.push(s, vin: widget.vin, plate: _plate);
        } catch (e) {
          debugPrint('[MYMG] widget sync failed: $e');
        }
      }());

      // ★ 路线 A Day 5：跑告警规则 → 状态变化时推通知
      unawaited(() async {
        try {
          AlertRules.rememberFuel(s.fuelPercent);
          await AlertRules.reload();
          final p = await SharedPreferences.getInstance();
          final masterOn = p.getBool(kAlertsEnabledKey) ?? true;
          if (masterOn) {
            final active = AlertRules.activeIds(s);
            final fresh = await AlertDiffEngine.diffAndSave(active);
            if (fresh.isNotEmpty) {
              await NotificationService.instance.notifyAlerts(fresh);
            }
          }
        } catch (e) {
          debugPrint('[MYMG] alert detection failed: $e');
        }
      }());

      // 坚果云自动备份：拉到车况后检查周期（静默，失败只记 last_error）
      unawaited(() async {
        try {
          await BackupService.instance.maybeAutoBackup();
        } catch (e) {
          debugPrint('[MYMG] auto webdav backup failed: $e');
        }
      }());

      // 保养提醒：总里程每 +5000km 提示一次（本机静默通知）
      unawaited(() async {
        try {
          await _maybeMaintenanceAlert(s.odometerKm);
        } catch (_) {}
      }());

      // 自动 AI：按「最合适时机」策略决定（车况明显变化 / 总结过期才跑），
      // 静默刷新若赶上行程结束等明显变化也会触发；温度抖动不会烧 token。
      unawaited(_maybeAutoRunAi(fromSilent: silent));
    } catch (e) {
      if (!mounted) return;
      // 静默刷新失败且已有数据时不打扰用户（下次定时轮询还会重试）
      if (!silent || _summary == null) {
        setState(() => _error = formatFrbError(e));
      }
      // 冷启动网络失败：仍尝试用本地近 24h 快照跑一次 AI（有缓存就不空手）
      if (!silent) {
        unawaited(_maybeAutoRunAi(fromSilent: silent));
      }
    } finally {
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  /// 异步读取 SQLite 已存快照数
  Future<void> _loadSnapshotCount() async {
    try {
      final n = await SnapshotStore.instance.count(widget.vin);
      if (!mounted) return;
      setState(() => _snapshotCount = n);
      // AI 自动跑改到 _refresh 首次成功后触发，这里不再触发
    } catch (_) {
      // DB 第一次可能还没初始化
    }
  }

  /// 读最近 10 条 AI 智能总结（最新在前），从本机缓存恢复。
  Future<void> _loadAiHistory() async {
    try {
      final list = await AiReportStore.loadSummaryList(widget.vin);
      if (!mounted) return;
      setState(() => _aiHistory = list);
    } catch (_) {
      // 缓存坏了当没有，不影响使用
    }
  }

  /// 给「AI 智能总结」捞历史快照。
  /// 默认只取最近 24 小时（省 token、加载快）。
  Future<List<SnapshotRow>> _loadSnapshotsForAi({
    Duration since = const Duration(hours: 24),
  }) async {
    try {
      final from = DateTime.now().subtract(since).millisecondsSinceEpoch;
      return await SnapshotStore.instance.listByRange(
        vin: widget.vin,
        fromMs: from,
        limit: 2000,
      );
    } catch (_) {
      return const <SnapshotRow>[];
    }
  }

  /// 「最合适的时候」自动跑 AI：数据落库后由 [AiAutoPolicy] 判定。
  ///
  /// 触发时机（而不是"一打开就跑"）：
  ///   - 首次（还没有总结）
  ///   - 车况关键字段明显变化（跑了一段 / 油量升降 ≥5%）
  ///   - 普通变化且距上次总结 ≥2h
  /// 温度/天气波动不触发。[fromSilent] 时只响应「明显变化」，避免轮询打扰。
  ///
  /// 去抖 2s：让首屏卡片先稳住，再调大模型。
  Future<void> _maybeAutoRunAi({bool fromSilent = false}) async {
    if (_aiRunning) return;
    if (_aiAutoDebounce?.isActive ?? false) return;
    if (!mounted) return;

    final cfg = await AiService.instance.load();
    if (!cfg.isConfigured) return;
    if (!mounted) return;

    if ((_snapshotCount ?? 0) <= 0) {
      await _loadSnapshotCount();
      if ((_snapshotCount ?? 0) <= 0) return;
    }

    final rows = await _loadSnapshotsForAi();
    if (rows.isEmpty) return;
    final current = SnapshotDigest.fromLatest(rows);
    final latest = await AiReportStore.loadLatestSummary(widget.vin);
    final decision = AiAutoPolicy.decide(
      lastReport: latest,
      current: current,
      now: DateTime.now(),
    );
    if (!decision.shouldRun) {
      if (!fromSilent && mounted) {
        setState(() => _aiAutoNote = decision.note);
      }
      return;
    }
    // 静默轮询只在「明显变化」时打扰（行程结束 / 油量大变）
    if (fromSilent && !decision.significant) return;

    _aiAutoDebounce = Timer(const Duration(seconds: 2), () {
      if (!mounted || _aiRunning) return;
      unawaited(_runAiAnalysis(auto: true));
    });
  }

  /// 跑一次 AI 智能总结（手动按钮和"打开软件时自动"都走这个）。
  ///
  /// [auto] 为 true 时是会话内首次自动跑；为 false 时是用户主动点的。
  /// 不论哪种，错误都通过 UI 反馈；自动跑失败时**不弹 snackbar**（避免打扰），
  /// 手动跑失败时给一个轻提示。
  ///
  /// **第 9 轮去重**：用快照指纹 (SnapshotDigest) 判断"数据没变 / 变化不大"，
  /// 直接跳过保存；手动跑也只在跳过时给个轻提示，不算"成功"。
  Future<void> _runAiAnalysis({
    bool auto = false,
    Duration since = const Duration(hours: 24),
  }) async {
    if (_aiRunning) return;
    setState(() => _aiRunning = true);
    try {
      // 自动路径：若计数为 0，先再等一下冷启动插入完成
      if ((_snapshotCount ?? 0) <= 0) {
        await _loadSnapshotCount();
      }
      final rows = await _loadSnapshotsForAi(since: since);
      if (rows.isEmpty) {
        if (!mounted) return;
        setState(() => _aiRunning = false);
        if (!auto) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('所选时段内没有历史快照')));
        }
        return;
      }
      // ★ 第 9 轮：先算数据指纹。如果跟最近一次总结的指纹相同 / 相似，
      //   就不调大模型了——省 token + 省时间 + 历史记录不被"无意义总结"污染。
      final digest = SnapshotDigest.fromLatest(rows);

      // ★ "数据完全没变" → 不调大模型，直接复用上次结果
      final latest = await AiReportStore.loadLatestSummary(widget.vin);
      if (latest != null &&
          latest.digest != null &&
          digest.isSameAs(latest.digest!)) {
        if (!mounted) return;
        setState(() {
          _aiRunning = false;
          if (auto) _aiAutoNote = '车况无变化，沿用上次总结';
        });
        if (!auto) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('数据无变化，跳过本次 AI 总结'),
              duration: Duration(seconds: 3),
            ),
          );
        }
        return;
      }

      final text = await AiService.instance.analyzeHistory(
        rows,
        vin: widget.vin,
        onDelta: (_) {
          // 流式进度不展示到首页卡（卡上只用最新一份），
          // 想要"边生成边看"的历史页场景已经在第 5 轮移除了。
        },
      );
      if (!mounted) return;
      final report = AiReport(
        text: text,
        atMs: DateTime.now().millisecondsSinceEpoch,
      );
      // 把 digest 一起传进去，saveSummary 内部做三档去重。
      // 自动路径不再 force 绕过「相似跳过」—— 时机已由 AiAutoPolicy 把关，
      // 避免把几乎一样的解读塞进历史。
      final outcome = await AiReportStore.saveSummary(
        widget.vin,
        report,
        digest: digest,
      );
      // 重新读一遍（saveSummary 内部会做去重 / 封顶），拿到最新顺序
      _aiHistory = await AiReportStore.loadSummaryList(widget.vin);
      if (!mounted) return;
      setState(() {
        _aiRunning = false;
        if (auto) {
          _aiAutoNote = outcome.saved
              ? '已自动总结'
              : outcome.skippedReasonLabel.isEmpty
              ? null
              : outcome.skippedReasonLabel;
        }
      });
      if (!auto && mounted) {
        final msg = outcome.saved
            ? 'AI 智能总结已更新（近 ${since.inHours < 24 ? '${since.inHours} 小时' : '${since.inDays} 天'}）'
            : outcome.skippedReasonLabel.isEmpty
            ? 'AI 总结未保存'
            : outcome.skippedReasonLabel;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    } on AiException catch (e) {
      if (!mounted) return;
      // 状态栏只放第一行（如「请求失败（400）」），全文在 SnackBar / 历史页
      final first = e.message.split('\n').first.trim();
      final label = e.statusCode == 500 || e.statusCode == 502
          ? 'AI 服务端错误（${e.statusCode}），稍后重试或检查 AI 设置'
          : (first.isEmpty ? e.message : first);
      setState(() {
        _aiRunning = false;
        if (auto) _aiAutoNote = label;
      });
      if (!auto) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('AI 总结失败：$label')));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _aiRunning = false;
        if (auto) _aiAutoNote = 'AI 总结失败，请检查网络或 AI 设置';
      });
      if (!auto) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('AI 总结失败：$e')));
      }
    }
  }

  /// 保养提醒：里程每跨过间隔推一条本地通知（默认可关）
  Future<void> _maybeMaintenanceAlert(double? odometerKm) async {
    if (odometerKm == null) return;
    final p = await SharedPreferences.getInstance();
    final on = p.getBool('mymg.maint.enabled') ?? true;
    if (!on) return;
    final interval = (p.getInt('mymg.maint.interval_km') ?? 5000).clamp(
      1000,
      50000,
    );
    final last = p.getInt('mymg.maint.last_notified_km') ?? 0;
    final cur = odometerKm.floor();
    if (cur < last + interval) return;
    final msg = '总里程已达 ${cur}km，距上次提醒约 ${cur - last}km，建议检查机油/滤芯等常规保养项目。';
    await p.setInt('mymg.maint.last_notified_km', cur);
    await p.setString('mymg.maint.last_msg', msg);
    await p.setInt(
      'mymg.maint.last_msg_at',
      DateTime.now().millisecondsSinceEpoch,
    );
    setState(() {
      _maintLastMsg = msg;
      _maintLastKm = cur;
    });
    try {
      await NotificationService.instance.notifyAlert(
        AlertRule(
          id: 'maint_$cur',
          severity: AlertSeverity.info,
          title: '保养提醒',
          bodyBuilder: () => msg,
          check: (_) => false,
        ),
      );
    } catch (_) {}
  }

  Future<void> _openRelogin() async {
    await Navigator.of(
      context,
      rootNavigator: true,
    ).pushReplacement(FadeSlidePageRoute(page: const LoginPage()));
  }

  /// AI 解读服务端私有告警码（Day 7）
  Future<void> _openAiExplainAlerts() async {
    final s = _summary;
    if (s == null || (s.alerts ?? const []).isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('当前没有告警可解读')));
      return;
    }
    await showAiReport(
      context,
      title: 'AI 告警解读',
      run: (onDelta) => AiService.instance.explainAlerts(
        s,
        vin: widget.vin,
        onDelta: onDelta,
      ),
      onOpenSettings: _openSettings,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _summary;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: HomeDashboard(
        summary: s,
        plate: _plate,
        address: _geoLabel,
        lastSynced: _updatedAt,
        loading: _loading,
        onRefresh: _refresh,
        onMessages: () => Navigator.of(context).push(
          FadeSlidePageRoute(
            page: MessageCenterPage(token: widget.token, vin: widget.vin),
          ),
        ),
        onSettings: _openSettings,
        onImage: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const CarImageSettingsPage())),
        onLock: () => _openQuickControlSheet(initialAction: 'lock'),
        onClimate: _openClimate,
        onTrunk: () => _openQuickControlSheet(initialAction: 'trunk'),
        onFind: () => _openQuickControlSheet(initialAction: 'find'),
        onStatus: () {
          if (widget.onNavigate != null) {
            widget.onNavigate!(2);
          } else {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    VehicleStatusPage(token: widget.token, vin: widget.vin),
              ),
            );
          }
        },
        onLocation: () {
          if (widget.onNavigate != null) {
            widget.onNavigate!(3);
          } else {
            _openMap();
          }
        },
        onHistory: _openHistory,
        error: _error == null
            ? null
            : _ErrorCard(
                error: _error!,
                onRetry: _refresh,
                onRelogin: _openRelogin,
              ),
        details: s == null
            ? null
            : GlassSurface(
                padding: EdgeInsets.zero,
                child: ExpansionTile(
                  title: const Text(
                    '更多车况与提醒',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  subtitle: const Text(
                    '详细告警、AI 解读与保养',
                    style: TextStyle(fontSize: 12),
                  ),
                  childrenPadding: const EdgeInsets.all(12),
                  children: [
                    _SafetyStatusCard(
                      summary: s,
                      alerts: s.alerts,
                      ignoredKeys: _ignoredAlerts,
                      onIgnore: _ignoreAlert,
                      onRestore: _restoreAlerts,
                      onAiExplain: _openAiExplainAlerts,
                      onOpenMessages: () => Navigator.of(context).push(
                        FadeSlidePageRoute(
                          page: MessageCenterPage(
                            token: widget.token,
                            vin: widget.vin,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _TyreCard(summary: s),
                    const SizedBox(height: 12),
                    _AiSummaryCard(
                      aiHistory: _aiHistory,
                      autoNote: _aiAutoNote,
                      aiRunning: _aiRunning,
                      onOpenHistory: _openHistory,
                      onOpenSettings: _openSettings,
                    ),
                    const SizedBox(height: 12),
                    _MaintCard(
                      odometerKm: s.odometerKm,
                      lastKm: _maintLastKm,
                      lastMsg: _maintLastMsg,
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  void _openClimate() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ClimatePage(token: widget.token, vin: widget.vin),
      ),
    );
  }
}

// ── 卡片们 ───────────────────────────────────────────────────────────

/// 安全状态 + 告警：锁/门/窗 优先扫一眼，异常高亮
class _SafetyStatusCard extends StatelessWidget {
  const _SafetyStatusCard({
    required this.summary,
    this.alerts,
    required this.ignoredKeys,
    required this.onIgnore,
    required this.onRestore,
    required this.onAiExplain,
    this.onOpenMessages,
  });

  final VehicleSummary summary;
  final List<VehicleAlert>? alerts;
  final Set<String> ignoredKeys;
  final ValueChanged<String> onIgnore;
  final VoidCallback onRestore;
  final VoidCallback onAiExplain;
  final VoidCallback? onOpenMessages;

  Widget _gate(
    String label,
    IconData icon,
    bool? closed, {
    required String onText,
    required String offText,
  }) {
    final ok = closed == true;
    final color = closed == null
        ? AppPalette.muted
        : ok
        ? AppPalette.ok
        : AppPalette.warn;
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.28), width: 0.8),
        ),
        child: Column(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: AppPalette.muted),
            ),
            const SizedBox(height: 2),
            Text(
              closed == null ? '—' : (ok ? onText : offText),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final all = alerts ?? const <VehicleAlert>[];
    final visible = all
        .where((a) => !ignoredKeys.contains(alertKeyOf(a)))
        .toList();
    final hiddenCount = all.length - visible.length;
    final hasIssue =
        s.allLocked == false ||
        s.allDoorsClosed == false ||
        s.allWindowsClosed == false;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  hasIssue ? Icons.warning_amber : Icons.verified_user_outlined,
                  size: 18,
                  color: hasIssue ? AppPalette.warn : AppPalette.ok,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    hasIssue ? '有未关好项' : '车辆安全',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ),
                if (onOpenMessages != null)
                  TextButton.icon(
                    onPressed: onOpenMessages,
                    icon: const Icon(Icons.notifications_none, size: 14),
                    label: Text(
                      visible.isEmpty ? '消息' : '消息 ${visible.length}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _gate(
                  '中控锁',
                  Icons.lock_outline,
                  s.allLocked,
                  onText: '已锁',
                  offText: '未锁',
                ),
                _gate(
                  '车门',
                  Icons.door_front_door_outlined,
                  s.allDoorsClosed,
                  onText: '关',
                  offText: '开',
                ),
                _gate(
                  '车窗',
                  Icons.blinds_closed_outlined,
                  s.allWindowsClosed,
                  onText: '关',
                  offText: '开',
                ),
              ],
            ),
            if (visible.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppPalette.warnBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppPalette.warn.withOpacity(0.35),
                    width: 0.8,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.warning_amber,
                          size: 16,
                          color: AppPalette.warn,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '告警 ${visible.length} 条',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: AppPalette.warn,
                          ),
                        ),
                        const Spacer(),
                        InkWell(
                          onTap: () => onIgnore(alertKeyOf(visible.first)),
                          child: Text(
                            '忽略',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppPalette.subtle,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    for (final a in visible.take(2))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '· ${a.alertData ?? "告警 #${a.alertId ?? "?"}"}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: AppPalette.strong,
                          ),
                        ),
                      ),
                    if (visible.length > 2 || hiddenCount > 0)
                      Text(
                        [
                          if (visible.length > 2) '另有 ${visible.length - 2} 条',
                          if (hiddenCount > 0) '已忽略 $hiddenCount',
                        ].join(' · '),
                        style: TextStyle(
                          fontSize: 11,
                          color: AppPalette.subtle,
                        ),
                      ),
                    TextButton.icon(
                      onPressed: onAiExplain,
                      icon: const Icon(Icons.auto_awesome, size: 14),
                      label: const Text(
                        'AI 解读告警',
                        style: TextStyle(fontSize: 12),
                      ),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ],
                ),
              ),
            ] else if (hiddenCount > 0)
              InkWell(
                onTap: onRestore,
                child: Text(
                  '已忽略 $hiddenCount 条 · 点击恢复',
                  style: TextStyle(fontSize: 12, color: AppPalette.info),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 胎压独立卡：四轮示意 + 异常高亮
class _TyreCard extends StatelessWidget {
  const _TyreCard({required this.summary});
  final VehicleSummary summary;

  String get _rangeText {
    final t = summary.tyreKpa;
    if (t == null || t.length < 4) return '—';
    final vals = t.whereType<int>().toList();
    if (vals.isEmpty) return '—';
    final lo = vals.reduce((a, b) => a < b ? a : b);
    final hi = vals.reduce((a, b) => a > b ? a : b);
    return lo == hi ? '$lo kPa' : '$lo–$hi kPa';
  }

  Widget _cell(String label, int? kpa) {
    final bad = kpa != null && (kpa < 200 || kpa > 280);
    final color = kpa == null
        ? AppPalette.muted
        : bad
        ? AppPalette.warn
        : AppPalette.ok;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: (bad ? AppPalette.warn : AppPalette.info).withOpacity(0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: (bad ? AppPalette.warn : AppPalette.info).withOpacity(0.25),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(fontSize: 10, color: AppPalette.muted)),
          const SizedBox(height: 1),
          Text(
            kpa == null ? '—' : '$kpa',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          Text('kPa', style: TextStyle(fontSize: 9, color: AppPalette.muted)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = summary.tyreKpa;
    int? at(int i) => (t != null && t.length > i) ? t[i] : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(child: _Title('胎压')),
                Text(
                  _rangeText,
                  style: TextStyle(fontSize: 12, color: AppPalette.muted),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _cell('左前', at(0))),
                const SizedBox(width: 10),
                Expanded(child: _cell('右前', at(1))),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _cell('左后', at(2))),
                const SizedBox(width: 10),
                Expanded(child: _cell('右后', at(3))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// AI 车况解读入口卡：两行预览，点开历史
class _AiSummaryCard extends StatelessWidget {
  const _AiSummaryCard({
    required this.aiHistory,
    this.autoNote,
    required this.aiRunning,
    required this.onOpenHistory,
    this.onOpenSettings,
  });

  final List<AiReport> aiHistory;
  final String? autoNote;
  final bool aiRunning;
  final VoidCallback onOpenHistory;
  final VoidCallback? onOpenSettings;

  String _peek(AiReport? latest) {
    if (latest == null) {
      return '点击查看「历史数据 + AI 车况解读」\n首次启动会自动总结一次；未配置 AI 需在设置里填接口。';
    }
    final lines = latest.text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .take(2)
        .toList();
    return lines.isEmpty ? '点击查看历史 + AI 解读' : lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final latest = aiHistory.isEmpty ? null : aiHistory.first;
    final status = aiRunning
        ? '自动总结中…'
        : (autoNote ??
              (latest == null
                  ? 'AI 车况'
                  : '上次总结 · ${latest.at.month.toString().padLeft(2, '0')}-${latest.at.day.toString().padLeft(2, '0')} ${latest.at.hour.toString().padLeft(2, '0')}:${latest.at.minute.toString().padLeft(2, '0')}'));

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onOpenHistory,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.auto_awesome,
                    size: 18,
                    color: Color(0xFF7B4DFF),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'AI 车况解读',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  Text(
                    status,
                    style: TextStyle(fontSize: 11, color: AppPalette.subtle),
                  ),
                  const Icon(Icons.chevron_right, size: 18),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _peek(latest),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.5,
                  color: latest == null ? AppPalette.muted : AppPalette.strong,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MaintCard extends StatelessWidget {
  const _MaintCard({this.odometerKm, this.lastKm, this.lastMsg});
  final double? odometerKm;
  final int? lastKm;
  final String? lastMsg;

  @override
  Widget build(BuildContext context) {
    final cur = odometerKm?.floor() ?? 0;
    final next = ((lastKm ?? 0) + 5000);
    final remain = next - cur;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.build_outlined, size: 18, color: Colors.brown),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '保养提醒',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                ),
                if (remain > 0 && cur > 0)
                  Text(
                    '还剩约 ${remain.clamp(0, 999999)} km',
                    style: TextStyle(fontSize: 12, color: AppPalette.muted),
                  ),
              ],
            ),
            SizedBox(height: 8),
            if (remain <= 0 && cur > 0)
              Text(
                '已到保养里程（${cur}km），建议检查机油 / 机滤 / 空滤',
                style: TextStyle(
                  fontSize: 13,
                  color: AppPalette.warn,
                  height: 1.4,
                ),
              )
            else if (lastMsg != null)
              Text(lastMsg!, style: TextStyle(fontSize: 13, height: 1.4))
            else
              Text(
                cur <= 0 ? '暂无里程数据' : '每 5000km 一次 · 下次约 ${next}km',
                style: TextStyle(fontSize: 13, color: AppPalette.strong),
              ),
            SizedBox(height: 4),
            Text(
              '设置 → 保养提醒 可调整间隔',
              style: TextStyle(fontSize: 11, color: AppPalette.subtle),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    required this.error,
    required this.onRetry,
    this.onRelogin,
  });
  final String error;
  final VoidCallback onRetry;
  final VoidCallback? onRelogin;

  @override
  Widget build(BuildContext context) {
    final tokenDead = error.contains('14101') || error.contains('登录态');
    return Card(
      color: AppPalette.dangerBg,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline, color: AppPalette.danger),
                SizedBox(width: 8),
                Text(
                  '获取失败',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppPalette.danger,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              error,
              style: TextStyle(fontSize: 12, color: AppPalette.strong),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(onPressed: onRetry, child: const Text('重试')),
                if (tokenDead && onRelogin != null)
                  FilledButton.tonal(
                    onPressed: onRelogin,
                    child: const Text('重新登录 / 更新 Token'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
  );
}
