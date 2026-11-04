// WorkManager 后台轮询回调（路线 A Day 6b）
//
// 注册一个周期任务，每 15 分钟在后台拉一次车况：
//   1. 写 SQLite（带指纹去重压缩）
//   2. 跑告警规则 → 状态变化时推本地通知
//
// 注意：这段代码会在**独立 Dart isolate** 里执行。
//   - 必须 `@pragma('vm:entry-point')` 让 AOT 保留入口
//   - workmanager 启动 background isolate 时会自动注册 plugin
//     （shared_preferences / sqflite / flutter_local_notifications / path_provider）
//   - FRB 需要 RustLib.init()，每个 isolate 的 `RustLib.instance` 独立，
//     所以重复 init 不会抛"should not initialize twice"

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'package:mymg/src/rust/api.dart';
import 'package:mymg/src/rust/frb_generated.dart';

import 'alert_rules.dart';
import 'legal_documents.dart';
import 'geofence_service.dart';
import 'official_alert_service.dart';
import 'reservation_service.dart';
import 'store.dart';
import 'vehicle_profile.dart';
import 'widget_sync.dart';

/// ★ WorkManager 的 registerXxxTask(uniqueName, taskName, ...) 是**两个不同的字符串**：
///   - uniqueName：任务在 WorkManager 里的唯一标识，用于去重 / 取消
///   - taskName  ：执行时传给 `callbackDispatcher` 回调的第一个参数 `task`
///
/// 早期版本把这两个参数传反了，导致回调里 `task == kFetchTaskName` 永远不成立，
/// 后台任务每次都"秒回 SUCCESS 但什么都没干"。改名前后的坑见 kLegacyUniqueName。
const String kFetchTaskName = 'mymg.fetch'; // ← 回调里收到的就是这个
const String kFetchUniqueName = 'mymg.bg.fetch'; // 周期任务唯一名
const String kFetchOnceUniqueName = 'mymg.bg.fetch.once'; // 立即触发的一次性任务

/// 历史遗留的唯一名（参数传反的那版用过）。启动时顺手取消，避免残留任务空跑。
const String kLegacyUniqueName = 'mymg.fetch';

/// 后台跑成功的最后时间戳（毫秒）—— 写到 SharedPreferences，
/// 前台设置页能读到，让"后台到底跑没跑"对用户可见。
const String kBgLastRunKey = 'mymg.bg.last_run_ms';

/// 后台错误信息（最后一次失败的简短描述）—— 同上目的。
const String kBgLastErrorKey = 'mymg.bg.last_error';

/// ★ Workmanager().initialize 必须传这个顶级函数
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (!await LegalConsent.isAccepted()) return true;
    developer.log('[MYMG.BG] executeTask task=$task inputData=$inputData',
        name: 'mymg_core');
    if (task == kFetchTaskName) {
      try {
        await _runFetchAndAlert();
        // 成功 → 清掉上一次的失败信息
        try {
          final p = await SharedPreferences.getInstance();
          await p.remove(kBgLastErrorKey);
        } catch (_) {}
        developer.log('[MYMG.BG] done OK', name: 'mymg_core');
        return true;
      } catch (e, st) {
        developer.log('[MYMG.BG] FAILED: $e\n$st',
            name: 'mymg_core', error: e, stackTrace: st);
        try {
          final p = await SharedPreferences.getInstance();
          await p.setString(kBgLastErrorKey, e.toString());
        } catch (_) {}
        // ★ 刻意返回 true（不回 RETRY）：
        //   周期任务本身 15 分钟就会再跑一次；返回 false 会让 WorkManager 用
        //   指数退避无限重试，而"token 失效""车况接口拒绝"这类错误重试也没用，
        //   只会白耗电。真正的失败原因已写进 kBgLastErrorKey，前台可见。
        return true;
      }
    }
    if (task == kResTaskName) {
      try {
        final c = await ReservationConfig.load();
        if (c.enabled && c.atMs > 0) {
          await runReservationOnce(c);
        }
        developer.log('[MYMG.BG] reservation task done', name: 'mymg_core');
      } catch (e, st) {
        developer.log('[MYMG.BG] reservation FAILED: $e\n$st',
            name: 'mymg_core', error: e, stackTrace: st);
      }
      return true;
    }
    return true;
  });
}

/// 注册周期任务：每 15 分钟一次（Android WorkManager 最小间隔）
Future<void> schedulePeriodicFetch() async {
  // 先清掉历史遗留名字下的任务（参数传反的那版注册过），
  // 否则升级后旧任务会一直"空跑"占着配额
  try {
    await Workmanager().cancelByUniqueName(kLegacyUniqueName);
  } catch (_) {}
  try {
    await Workmanager().registerPeriodicTask(
      kFetchUniqueName,
      kFetchTaskName,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      backoffPolicy: BackoffPolicy.exponential,
    );
  } catch (e) {
    developer.log('[MYMG.BG] registerPeriodicTask failed: $e',
        name: 'mymg_core');
  }
}

/// 注册一次性任务（立即执行），用于设置页"立即触发一次"按钮。
///
/// 故意用**独立的 uniqueName**（kFetchOnceUniqueName）：若和周期任务共用
/// 同一个 uniqueName，`replace` 策略会把正在等待的周期任务一起顶掉，
/// 导致"点一次立即触发，后台轮询就永久停了"。
Future<bool> runOnceNow() async {
  try {
    await Workmanager().registerOneOffTask(
      kFetchOnceUniqueName,
      kFetchTaskName,
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
    return true;
  } catch (e) {
    developer.log('[MYMG.BG] registerOneOffTask failed: $e', name: 'mymg_core');
    return false;
  }
}

Future<void> cancelPeriodicFetch() async {
  // 清掉历史遗留名字的任务，避免升级后残留一个"空跑"的周期任务
  try {
    await Workmanager().cancelByUniqueName(kLegacyUniqueName);
  } catch (_) {}
  await Workmanager().cancelByUniqueName(kFetchUniqueName);
  await Workmanager().cancelByUniqueName(kFetchOnceUniqueName);
}

/// 前台由 HomePage Timer 负责拉数时，暂停 WorkManager 周期任务，避免双拉费电费流量。
Future<void> pausePeriodicFetch() async {
  try {
    await Workmanager().cancelByUniqueName(kFetchUniqueName);
  } catch (e) {
    developer.log('[MYMG.BG] pausePeriodicFetch: $e', name: 'mymg_core');
  }
}

/// App 退到后台：若用户开启了后台轮询，恢复 WorkManager（15 分钟档）。
Future<void> resumePeriodicFetch() async {
  try {
    final p = await SharedPreferences.getInstance();
    if (!(p.getBool(kBackgroundEnabledKey) ?? false)) return;
    await schedulePeriodicFetch();
  } catch (e) {
    developer.log('[MYMG.BG] resumePeriodicFetch: $e', name: 'mymg_core');
  }
}

/// 后台 isolate 内：拉车况 → 写库 → 跑告警
Future<void> _runFetchAndAlert() async {
  developer.log('[MYMG.BG] step1 read prefs', name: 'mymg_core');
  final p = await SharedPreferences.getInstance();
  final token = p.getString('mymg.token') ?? '';
  final vin = p.getString('mymg.vin') ?? '';
  final enabled = p.getBool(kAlertsEnabledKey) ?? true;
  developer.log('[MYMG.BG] token.len=${token.length} vin=$vin enabled=$enabled',
      name: 'mymg_core');
  if (token.isEmpty || vin.length != 17) return;

  try {
    developer.log('[MYMG.BG] step2 RustLib.init', name: 'mymg_core');
    await RustLib.init();
    developer.log('[MYMG.BG] step3 fetchSummary', name: 'mymg_core');
    final summary = await fetchSummary(token: token, vin: vin);
    developer.log('[MYMG.BG] step4 insertFromSummary fuel=${summary.fuelPercent}',
        name: 'mymg_core');
    await SnapshotStore.instance.insertFromSummary(summary, vin: vin);

    // ★ Day 7：后台刷新的车况也写进桌面小组件的数据槽。
    //   注意：这里的 isolate 没有自定义 MethodChannel，"敲门"那步会
    //   MissingPluginException（WidgetSync 已吞掉）；数据已落盘，
    //   小组件下次 onUpdate 就能读到。
    try {
      final plate = p.getString(kPlateKey) ?? '';
      await WidgetSync.push(summary, vin: vin, plate: plate);
    } catch (e) {
      developer.log('[MYMG.BG] widget push failed: $e', name: 'mymg_core');
    }
    // 后台静默刷新结束后清掉小组件「刷新中」标记（原生广播侧也会清一次）
    try {
      await p.setBool('mymg.widget.refreshing', false);
    } catch (_) {}

    developer.log('[MYMG.BG] step5 alert detect', name: 'mymg_core');
    await AlertRules.reload();
    AlertRules.rememberFuel(summary.fuelPercent);
    final active = AlertRules.activeIds(summary);
    final fresh = await AlertDiffEngine.diffAndSave(active);
    developer.log('[MYMG.BG] active=$active fresh=$fresh enabled=$enabled',
        name: 'mymg_core');
    if (enabled && fresh.isNotEmpty) {
      await _showAlertsDirect(fresh);
    }

    // 地理围栏 / 异常移动
    try {
      await evaluateGeofence(summary);
    } catch (e) {
      developer.log('[MYMG.BG] geofence failed: $e', name: 'mymg_core');
    }
    // 官方云端 vehicle_alerts 差集通知
    try {
      await OfficialAlertService.syncFromSummary(summary);
    } catch (e) {
      developer.log('[MYMG.BG] official alerts failed: $e', name: 'mymg_core');
    }
  } finally {
    // 记录"最后执行时间"（不管成败）—— 让用户能判断后台任务是否还活着。
    // 成败明细看 kBgLastErrorKey（失败时才有值）。
    try {
      final pp = await SharedPreferences.getInstance();
      await pp.setInt(kBgLastRunKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }
}

/// 在 background isolate 里发通知 —— 直接拿 FlutterLocalNotificationsPlugin，
/// 不复用 NotificationService 是因为后者会在 init 时再请求权限
/// （在 background 会抛 / 卡住）。
Future<void> _showAlertsDirect(Set<String> ids) async {
  final plugin = FlutterLocalNotificationsPlugin();
  for (final id in ids) {
    final rule = AlertRules.byId(id);
    if (rule == null) continue;
    if (!AlertRules.shouldNotify(rule)) continue;
    final critical = rule.severity == AlertSeverity.critical;
    final androidDetails = AndroidNotificationDetails(
      critical ? 'mymg_alert_critical' : 'mymg_alert_warning',
      critical ? '重要告警' : '一般告警',
      channelDescription:
          critical ? '严重车况告警（悬浮提醒）' : '一般车况提醒',
      importance:
          critical ? Importance.max : Importance.high,
      priority: critical ? Priority.max : Priority.high,
      icon: '@mipmap/ic_launcher',
    );
    await plugin.show(
      _hash(id),
      rule.title,
      rule.bodyBuilder(),
      NotificationDetails(android: androidDetails),
    );
  }
}

/// 与 `NotificationService._idForRule` **逐字符等价**的 FNV-1a，
/// 保证前后台推同一规则拿到同一个通知 id（覆盖而不是重复）。
///
/// ★ 必须收敛到有符号 32 位（0x7FFFFFFF）：Android 要求通知 id 在
///   [-2^31, 2^31-1] 内，否则 `plugin.show` 抛
///   "must fit within the size of a 32-bit integer"。
int _hash(String s) {
  int h = 0x811c9dc5 & 0x7FFFFFFF;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0x7FFFFFFF;
  }
  return h;
}
