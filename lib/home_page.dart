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
import 'coord.dart';
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
import 'vehicle_profile.dart';
import 'widget_sync.dart';

/// 被用户手动忽略的告警 key（type-id-data），存在 SharedPreferences
const _kIgnoredAlertsKey = 'mymg.ignored_alerts';

/// 告警去重/忽略用的稳定 key
String alertKeyOf(VehicleAlert a) =>
    '${a.alertType ?? ""}-${a.alertId ?? ""}-${a.alertData ?? ""}';

/// 主页：调用 Rust 拉取车况摘要，按卡分组展示
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.token, required this.vin});
  final String token;
  final String vin;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  VehicleSummary? _summary;
  String? _error;
  bool _loading = false;
  DateTime? _updatedAt;
  int? _snapshotCount;   // 本机 SQLite 已存的快照数（首屏读一次）
  Set<String> _ignoredAlerts = <String>{};  // 用户手动忽略的告警

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
      FadeSlidePageRoute(page: HistoryPage(token: widget.token, vin: widget.vin)),
    );
  }

  void _openMap() {
    Navigator.of(context).push(
      FadeSlidePageRoute(page: MapPage(token: widget.token, vin: widget.vin)),
    );
  }

  /// 快捷控车弹窗（与控制中心磁贴一致）
  void _openQuickControlSheet() {
    unawaited(showQuickControlSheet(context));
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已恢复全部告警显示')),
      );
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
      final changed = prev == null ||
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

  /// 打开官方 App 的「爱车 / 控车」页面（首页「控车」按钮）。
  ///
  /// **跳转策略（2026-09-10 通过在小米15上实测修正）**：
  /// 真正的控车主页面（车牌 / 24℃ / 后备箱 / 上锁 / 解锁 / 寻车 / 空调...）是
  /// `com.zone.tsp.saic.ui.VehicleMixedActivity`，**但它在 manifest 中
  /// `exported=false` 且没有 intent-filter**，外部 app 没办法直接 setComponent 拉起。
  /// 同理 MainActivity、VehicleHomeActivity 也都是 `exported=false`。
  /// 唯一可行的路径：**走 launcher intent**，让官方 App 自己 splash → main → home
  /// → mixed 跳到控车主页，大约 5~7 秒后到达。
  ///
  /// 返回值（由原生 `openControl` 桥方法给出）：
  ///   * `"launcher"` — 已拉起官方 App，约 5~7 秒后到达控车主页。提示一次。
  ///   * `false`      — 未安装官方 App。提示一次。
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
      return await SnapshotStore.instance
          .listByRange(vin: widget.vin, fromMs: from, limit: 2000);
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('所选时段内没有历史快照')),
          );
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('AI 总结失败：$label')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _aiRunning = false;
        if (auto) _aiAutoNote = 'AI 总结失败，请检查网络或 AI 设置';
      });
      if (!auto) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('AI 总结失败：$e')),
        );
      }
    }
  }

  /// 保养提醒：里程每跨过间隔推一条本地通知（默认可关）
  Future<void> _maybeMaintenanceAlert(double? odometerKm) async {
    if (odometerKm == null) return;
    final p = await SharedPreferences.getInstance();
    final on = p.getBool('mymg.maint.enabled') ?? true;
    if (!on) return;
    final interval = (p.getInt('mymg.maint.interval_km') ?? 5000).clamp(1000, 50000);
    final last = p.getInt('mymg.maint.last_notified_km') ?? 0;
    final cur = odometerKm.floor();
    if (cur < last + interval) return;
    final msg =
        '总里程已达 ${cur}km，距上次提醒约 ${cur - last}km，建议检查机油/滤芯等常规保养项目。';
    await p.setInt('mymg.maint.last_notified_km', cur);
    await p.setString('mymg.maint.last_msg', msg);
    await p.setInt('mymg.maint.last_msg_at', DateTime.now().millisecondsSinceEpoch);
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
    await Navigator.of(context).push(
      FadeSlidePageRoute(page: const LoginPage()),
    );
  }

  /// AI 解读服务端私有告警码（Day 7）
  Future<void> _openAiExplainAlerts() async {
    final s = _summary;
    if (s == null || (s.alerts ?? const []).isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前没有告警可解读')),
      );
      return;
    }
    await showAiReport(
      context,
      title: 'AI 告警解读',
      run: (onDelta) =>
          AiService.instance.explainAlerts(s, vin: widget.vin, onDelta: onDelta),
      onOpenSettings: _openSettings,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _summary;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _plate.isNotEmpty
              ? _plate
              : VehicleProfile.primaryLabel(plate: _plate, vin: widget.vin),
          style: const TextStyle(letterSpacing: 0.3, fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            tooltip: '消息中心',
            icon: const Icon(Icons.notifications_none_outlined),
            onPressed: () {
              Navigator.of(context).push(
                FadeSlidePageRoute(
                  page: MessageCenterPage(
                    token: widget.token,
                    vin: widget.vin,
                  ),
                ),
              );
            },
          ),
          IconButton(
            tooltip: '设置',
            icon: Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
        ],
        titleSpacing: 8,
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        color: Theme.of(context).colorScheme.primary,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            if (_loading && s == null)
              Padding(
                padding: const EdgeInsets.all(40),
                child: Center(
                  child: BrandPulse(
                    child: CircularProgressIndicator(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              )
            else if (_error != null && s == null)
              StaggeredAppear(
                index: 0,
                child: _ErrorCard(
                  error: _error!,
                  onRetry: _refresh,
                  onRelogin: _openRelogin,
                ),
              )
            else if (s != null) ...[
              // ① 能耗 Hero：油量 / 续航 / 里程 / 油耗 + 数据新鲜度
              RepaintBoundary(
                child: StaggeredAppear(
                  index: 0,
                  animate: !_entrancePlayed,
                  child: _FuelCard(
                    fuelPercent: s.fuelPercent,
                    rangeKm: s.rangeKm,
                    odometerKm: s.odometerKm,
                    fuelConsumption: s.fuelConsumption,
                    serverTimeMs: s.updateTime?.toInt(),
                    localFetchedAt: _updatedAt,
                    acOn: s.acOn,
                    acTemp: s.acTargetTemp?.toInt(),
                    interior: s.interiorTemp,
                    exterior: s.exteriorTemp,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // ② 安全状态 + 告警：开门/开窗/未锁优先扫一眼
              StaggeredAppear(
                index: 1,
                animate: !_entrancePlayed,
                child: _SafetyStatusCard(
                  summary: s,
                  alerts: s.alerts,
                  ignoredKeys: _ignoredAlerts,
                  onIgnore: _ignoreAlert,
                  onRestore: _restoreAlerts,
                  onAiExplain: _openAiExplainAlerts,
                  onOpenMessages: () {
                    Navigator.of(context).push(
                      FadeSlidePageRoute(
                        page: MessageCenterPage(
                          token: widget.token,
                          vin: widget.vin,
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              // ③ 胎压
              StaggeredAppear(
                index: 2,
                animate: !_entrancePlayed,
                child: _TyreCard(summary: s),
              ),
              const SizedBox(height: 12),
              // ④ 位置
              StaggeredAppear(
                index: 4,
                animate: !_entrancePlayed,
                child: _LocationCard(
                  lat: s.latitude,
                  lng: s.longitude,
                  updateTime: s.updateTime,
                  journey: s.journeyKm,
                  lastRefresh: _updatedAt,
                  token: widget.token,
                  vin: widget.vin,
                  address: _geoLabel,
                  geoLoading: _geoLoading,
                ),
              ),
              const SizedBox(height: 12),
              // ⑤ AI 车况解读（折叠预览）
              StaggeredAppear(
                index: 3,
                animate: !_entrancePlayed,
                child: _AiSummaryCard(
                  aiHistory: _aiHistory,
                  autoNote: _aiAutoNote,
                  aiRunning: _aiRunning,
                  onOpenHistory: _openHistory,
                  onOpenSettings: _openSettings,
                ),
              ),
              const SizedBox(height: 12),
              // ⑥ 保养
              StaggeredAppear(
                index: 5,
                animate: !_entrancePlayed,
                child: _MaintCard(
                  odometerKm: s.odometerKm,
                  lastKm: _maintLastKm,
                  lastMsg: _maintLastMsg,
                ),
              ),
            ],
            if (_error != null && s != null) ...[
              const SizedBox(height: 8),
              _ErrorCard(
                error: _error!,
                onRetry: _refresh,
                onRelogin: _openRelogin,
              ),
            ],
          ],
        ),
      ),
      floatingActionButton: AnimatedSlide(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        offset: _loading ? const Offset(0, 1.2) : Offset.zero,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: _loading ? 0 : 1,
          child: IgnorePointer(
            ignoring: _loading,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // 刷新与下拉重复，只保留控车入口
                FloatingActionButton.extended(
                  heroTag: 'control_car',
                  tooltip: '智能控车',
                  onPressed: _openQuickControlSheet,
                  icon: const Icon(Icons.settings_remote, size: 20),
                  label: const Text('控车'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── 卡片们 ───────────────────────────────────────────────────────────

class _FuelCard extends StatelessWidget {
  const _FuelCard({
    this.fuelPercent,
    this.rangeKm,
    this.odometerKm,
    this.fuelConsumption,
    this.serverTimeMs,
    this.localFetchedAt,
    this.acOn,
    this.acTemp,
    this.interior,
    this.exterior,
  });
  final int? fuelPercent;
  final int? rangeKm;
  final double? odometerKm;
  final double? fuelConsumption;
  final int? serverTimeMs;
  final DateTime? localFetchedAt;
  final bool? acOn;
  final int? acTemp;
  final double? interior;
  final double? exterior;

  /// 右上角：车辆/TBOX 上传时间（server_time）；与本地拉取时间区分
  String? get _serverTimeLabel {
    final raw = serverTimeMs;
    if (raw == null || raw <= 0) return null;
    final ms = raw > 1000000000000 ? raw : raw * 1000;
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    if (dt.year < 2020 || dt.year > 2100) return null;
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }

  /// 本地拉取时间（App 拉到车况的时刻）
  /// 指标行用的短里程：超过 1 万 km 用「万」避免截断
  String get _fuelConsText {
    final c = fuelConsumption;
    if (c != null && c > 0) return '${c.toStringAsFixed(1)}L/100km';
    // API no consumption: estimate from fuel% / range with 45L tank
    final fuel = fuelPercent;
    final range = rangeKm;
    if (fuel != null && range != null && fuel > 0 && range > 30) {
      final est = (fuel / 100.0 * 45.0) / range * 100.0;
      return '${est.toStringAsFixed(1)}L/100km~';
    }
    return '—';
  }

  String get _odoShort {
    final o = odometerKm;
    if (o == null) return '—';
    if (o >= 10000) {
      return '${(o / 10000).toStringAsFixed(2)}万km';
    }
    return '${o.toStringAsFixed(0)}km';
  }

  @override
  Widget build(BuildContext context) {
    final p = fuelPercent ?? 0;
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: dark
                ? const [Color(0xFF1A1F2E), Color(0xFF121214), Color(0xFF1E1A28)]
                : [
                    const Color(0xFFF7F5FF),
                    scheme.surfaceContainerHighest.withOpacity(0.9),
                  ],
          ),
        ),
        child: Stack(
          children: [
            // 背景：车侧影线稿（居中、低透明度）
            //   ① 放在 Stack 最底层、数据控件在上层 → 不遮挡数据
            //   ② IgnorePointer → 不吃点击；ColorFiltered 按主题着色，浅色主题用深色线
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: Opacity(
                    opacity: dark ? 0.32 : 0.10,
                    child: ColorFiltered(
                      colorFilter: ColorFilter.mode(
                        dark ? Colors.white : Colors.black,
                        BlendMode.srcIn,
                      ),
                      child: Image.asset(
                        'assets/car/home_status_bg.png',
                        width: double.infinity,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppPalette.okBg,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.bolt, size: 12, color: AppPalette.ok),
                        const SizedBox(width: 4),
                        Text(
                          '实时车况',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppPalette.ok,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  // 右上角：车辆/TBOX 上报到服务端的时间
                  if (_serverTimeLabel != null)
                    Text(
                      '车辆上传 $_serverTimeLabel',
                      style: TextStyle(fontSize: 11, color: AppPalette.subtle),
                    ),
                ],
              ),
              // 环境 / 空调条：Hero 卡内一眼可见
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _miniChip(
                    Icons.thermostat,
                    interior == null
                        ? '车内 —'
                        : '车内 ${interior!.toStringAsFixed(0)}°C',
                  ),
                  _miniChip(
                    Icons.wb_sunny_outlined,
                    exterior == null
                        ? '车外 —'
                        : '车外 ${exterior!.toStringAsFixed(0)}°C',
                  ),
                  _miniChip(
                    Icons.ac_unit,
                    acOn == true
                        ? '空调${acTemp != null ? ' $acTemp°C' : ' 开'}'
                        : '空调 关',
                    on: acOn == true,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '油量',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppPalette.muted,
                          letterSpacing: 0.4,
                        ),
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          ValueFade(
                            value: '$p',
                            builder: (_, v) => Text(
                              v,
                              style: TextStyle(
                                fontSize: 64,
                                height: 0.95,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -2,
                                color: AppPalette.strong,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8, left: 2),
                            child: Text(
                              '%',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: AppPalette.muted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '剩余续航',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppPalette.muted,
                          letterSpacing: 0.4,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          ValueFade(
                            value: rangeKm == null ? '—' : '$rangeKm',
                            builder: (_, v) => Text(
                              v,
                              style: TextStyle(
                                fontSize: 40,
                                height: 0.95,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -1,
                                color: AppPalette.strong,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 5, left: 3),
                            child: Text(
                              'km',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: AppPalette.muted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: (p.clamp(0, 100)) / 100.0,
                  minHeight: 8,
                  backgroundColor: AppPalette.track,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _heroMetric('总里程', _odoShort),
                  ),
                  Container(width: 1, height: 22, color: AppPalette.track),
                  Expanded(child: _heroMetric('油耗', _fuelConsText)),
                ],
              ),
              // 车辆上传偏旧时的说明：App 只能拉服务端已缓存的数据
            ],
          ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _heroMetric(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppPalette.muted,
              )),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: AppPalette.strong,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniChip(IconData icon, String text, {bool on = false}) {
    final color = on ? AppPalette.ok : AppPalette.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: (on ? AppPalette.ok : AppPalette.info).withOpacity(0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: (on ? AppPalette.ok : AppPalette.info).withOpacity(0.30),
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: on ? FontWeight.w700 : FontWeight.w500,
              color: on ? AppPalette.ok : AppPalette.strong,
            ),
          ),
        ],
      ),
    );
  }
}

class _LocationCard extends StatelessWidget {
  const _LocationCard({
    this.lat, this.lng, this.updateTime, this.journey, this.lastRefresh,
    required this.token, required this.vin,
    this.address, this.geoLoading = false,
  });
  final String? lat;
  final String? lng;
  final int? updateTime;
  final double? journey;
  final DateTime? lastRefresh;
  final String token;
  final String vin;
  final String? address;
  final bool geoLoading;

  @override
  Widget build(BuildContext context) {
    String ts = '—';
    final dt = _parseServerTs(updateTime);
    if (dt != null) ts = dt.toLocal().toString().split('.').first;
    final wgsLat = double.tryParse(lat ?? '');
    final wgsLng = double.tryParse(lng ?? '');
    final hasCoord = wgsLat != null && wgsLng != null;
    // ★ 车联是 WGS-84；这里统一转成 GCJ-02 显示，与内嵌高德地图 / 手机高德一致
    final gcj = hasCoord ? wgs84ToGcj02(wgsLat, wgsLng) : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const _Title('位置'),
                const Spacer(),
                if (hasCoord)
                  TextButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(
                        FadeSlidePageRoute(
                          page: MapPage(token: token, vin: vin),
                        ),
                      );
                    },
                    icon: const Icon(Icons.map_outlined, size: 18),
                    label: const Text('查看完整地图'),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            // 位置预览条：可点击 → 进入 MapPage（Hero 飞入地图上的车标）
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: hasCoord
                  ? () {
                      Navigator.of(context).push(
                        FadeSlidePageRoute(
                          page: MapPage(token: token, vin: vin),
                        ),
                      );
                    }
                  : null,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppPalette.ok.withValues(alpha: 0.45)),
                ),
                child: Row(
                  children: [
                    Hero(
                      tag: 'map-car',
                      child: Icon(Icons.place, color: AppPalette.ok, size: 22),
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  hasCoord ? '车辆当前位置' : '暂无位置数据',
                                  style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: AppPalette.strong),
                                ),
                              ),
                              if (journey != null && journey! > 0)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: AppPalette.info.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    '行程 ${journey!.toStringAsFixed(1)}km',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w600,
                                      color: AppPalette.info,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          if (hasCoord)
                            Text(
                              address ??
                                  (geoLoading
                                      ? '地址解析中…'
                                      : '${gcj!.lat.toStringAsFixed(4)}, ${gcj.lng.toStringAsFixed(4)}'),
                              style: TextStyle(
                                fontSize: 12, color: AppPalette.muted,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            )
                          else
                            Text('GPS 未定位或服务端暂未返回',
                                style: TextStyle(fontSize: 12, color: AppPalette.muted)),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: AppPalette.subtle),
                  ],
                ),
              ),
            ),
            SizedBox(height: 12),
            _kv('本次行程',
                journey == null ? '—' : '${journey!.toStringAsFixed(1)} km'),
            _kv('服务端数据时间', ts),
            if (lastRefresh != null)
              _kv('本地刷新',
                  lastRefresh!.toLocal().toString().split('.').first),
          ],
        ),
      ),
    );
  }

  // 跳系统地图的功能已由 MapPage 内部统一提供（MapPage 底部有"系统地图打开"），
  // 主页这里不再重复实现，避免两处逻辑分叉。

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Text(k, style: TextStyle(color: AppPalette.muted)),
            const Spacer(),
            Text(v, style: const TextStyle(fontSize: 14)),
          ],
        ),
      );
}

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

  Widget _gate(String label, IconData icon, bool? closed,
      {required String onText, required String offText}) {
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
            Text(label,
                style: TextStyle(fontSize: 11, color: AppPalette.muted)),
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
    final visible =
        all.where((a) => !ignoredKeys.contains(alertKeyOf(a))).toList();
    final hiddenCount = all.length - visible.length;
    final hasIssue = s.allLocked == false ||
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
                _gate('中控锁', Icons.lock_outline, s.allLocked,
                    onText: '已锁', offText: '未锁'),
                _gate('车门', Icons.door_front_door_outlined, s.allDoorsClosed,
                    onText: '关', offText: '开'),
                _gate('车窗', Icons.blinds_closed_outlined, s.allWindowsClosed,
                    onText: '关', offText: '开'),
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
                        Icon(Icons.warning_amber, size: 16, color: AppPalette.warn),
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
                          child: Text('忽略',
                              style: TextStyle(
                                  fontSize: 11, color: AppPalette.subtle)),
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
                        style: TextStyle(fontSize: 11, color: AppPalette.subtle),
                      ),
                    TextButton.icon(
                      onPressed: onAiExplain,
                      icon: const Icon(Icons.auto_awesome, size: 14),
                      label: const Text('AI 解读告警', style: TextStyle(fontSize: 12)),
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
                child: Text('已忽略 $hiddenCount 条 · 点击恢复',
                    style: TextStyle(fontSize: 12, color: AppPalette.info)),
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
                Text(_rangeText, style: TextStyle(fontSize: 12, color: AppPalette.muted)),
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
                  const Icon(Icons.auto_awesome, size: 18, color: Color(0xFF7B4DFF)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('AI 车况解读',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                  ),
                  Text(status,
                      style: TextStyle(fontSize: 11, color: AppPalette.subtle)),
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
  const _MaintCard({
    this.odometerKm,
    this.lastKm,
    this.lastMsg,
  });
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
                  child: Text('保养提醒',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
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
                style: TextStyle(fontSize: 13, color: AppPalette.warn, height: 1.4),
              )
            else if (lastMsg != null)
              Text(lastMsg!, style: TextStyle(fontSize: 13, height: 1.4))
            else
              Text(
                cur <= 0
                    ? '暂无里程数据'
                    : '每 5000km 一次 · 下次约 ${next}km',
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
  const _ErrorCard({required this.error, required this.onRetry, this.onRelogin});
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
                Text('获取失败',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: AppPalette.danger)),
              ],
            ),
            const SizedBox(height: 6),
            Text(error, style: TextStyle(fontSize: 12, color: AppPalette.strong)),
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
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600));
}

/// AI 车况卡里横向滚动的一项：标签（小字）+ 数值（粗大字）
/// 解析服务端时间戳。
///
/// 上汽这个接口的 `update_time` 实测是**毫秒**级（如 1788871240000）。
/// 这里做单位自适应：大于 1e12 视为毫秒，否则视为秒，
/// 避免以后接口改单位或某个字段用秒时又显示成 5 万年。
DateTime? _parseServerTs(int? v) {
  if (v == null || v <= 0) return null;
  final ms = v > 1000000000000 ? v : v * 1000;
  return DateTime.fromMillisecondsSinceEpoch(ms);
}
