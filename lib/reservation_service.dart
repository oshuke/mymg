// 预约控车：本机 WorkManager 到点自动执行一次（空调 / 主副驾加热）
//
// 存储键与 QuickControlSheet 共用 mymg.res.*
// 执行在独立 isolate：PIN 只走加密存储读取，后台不弹指纹。

import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'package:mymg/src/rust/api.dart';
import 'package:mymg/src/rust/frb_generated.dart';

import 'control_config.dart';
import 'legal_documents.dart';
import 'pin_vault.dart';

const String kResTaskName = 'mymg.res.run';
const String kResUniqueName = 'mymg.bg.res';

/// 原生 AlarmManager 精准闹钟（比 WorkManager 更准点）
const MethodChannel _alarmCh = MethodChannel('mymg/reservation_alarm');

/// 监听原生 AlarmManager 拉起的「立即执行预约」
void listenReservationAlarm() {
  _alarmCh.setMethodCallHandler((call) async {
    if (call.method == 'runReservation') {
      try {
        final c = await ReservationConfig.load();
        if (c.enabled && c.atMs > 0) {
          await ReservationConfig.tryRunDueInForeground();
        }
      } catch (e) {
        developer.log('[MYMG.RES] alarm runReservation failed: $e',
            name: 'mymg_core');
      }
    }
    return null;
  });
}

/// 供 UI / 调度共用的预约快照
class ReservationConfig {
  const ReservationConfig({
    required this.enabled,
    required this.type,
    required this.hour,
    required this.minute,
    required this.atMs,
  });

  final bool enabled;
  /// ac | seat_left | seat_right
  final String type;
  final int hour;
  final int minute;
  final int atMs;

  String get typeLabel => switch (type) {
        'seat_left' => '主驾加热',
        'seat_right' => '副驾加热',
        _ => '空调',
      };

  static Future<ReservationConfig> load() async {
    final p = await SharedPreferences.getInstance();
    return ReservationConfig(
      enabled: p.getBool('mymg.res.enabled') ?? false,
      type: p.getString('mymg.res.type') ?? 'ac',
      hour: (p.getInt('mymg.res.hour') ?? 8).clamp(0, 23),
      minute: (p.getInt('mymg.res.minute') ?? 0).clamp(0, 59),
      atMs: p.getInt('mymg.res.at_ms') ?? 0,
    );
  }

  /// 保存并按 [when] 重新排一次 WorkManager 一次性任务。
  static Future<void> saveAndSchedule({
    required bool enabled,
    required String type,
    required int hour,
    required int minute,
    required DateTime when,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('mymg.res.enabled', enabled);
    await p.setString('mymg.res.type', type);
    await p.setInt('mymg.res.hour', hour);
    await p.setInt('mymg.res.minute', minute);
    if (!enabled) {
      await p.remove('mymg.res.at_ms');
      await p.remove('mymg.res.last_ok_ms');
      await p.remove('mymg.res.last_err');
      try {
        await Workmanager().cancelByUniqueName(kResUniqueName);
      } catch (_) {}
      try {
        await _alarmCh.invokeMethod('cancel');
      } catch (_) {}
      return;
    }
    final at = when.millisecondsSinceEpoch;
    await p.setInt('mymg.res.at_ms', at);
    await scheduleReservation(when);
  }

  /// 注册/替换一次性任务。delay 若已过期则立刻执行（由回调自己判断）。
  ///
  /// 双保险：
  /// 1. AlarmManager.setExactAndAllowWhileIdle —— 精准到点拉起 App
  /// 2. WorkManager 一次性任务 —— 闹钟被系统拒时的兜底
  static Future<void> scheduleReservation(DateTime when) async {
    final now = DateTime.now();
    var delay = when.difference(now);
    if (delay.isNegative) delay = Duration.zero;

    // ① AlarmManager 精准闹钟（主路径）
    try {
      await _alarmCh.invokeMethod('scheduleAt', {
        'atMs': when.millisecondsSinceEpoch,
      });
      developer.log('[MYMG.RES] AlarmManager scheduled for $when',
          name: 'mymg_core');
    } catch (e) {
      developer.log('[MYMG.RES] AlarmManager failed: $e', name: 'mymg_core');
    }

    // ② WorkManager 兜底（最小 delay 约 9 分钟）
    var wmDelay = delay;
    if (wmDelay < const Duration(minutes: 9)) {
      wmDelay = const Duration(minutes: 9);
    }
    try {
      await Workmanager().cancelByUniqueName(kResUniqueName);
      await Workmanager().registerOneOffTask(
        kResUniqueName,
        kResTaskName,
        initialDelay: wmDelay,
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingWorkPolicy.replace,
      );
      developer.log('[MYMG.RES] WorkManager scheduled in ${wmDelay.inMinutes}m',
          name: 'mymg_core');
    } catch (e) {
      developer.log('[MYMG.RES] WorkManager schedule failed: $e',
          name: 'mymg_core');
    }
  }

  /// 前台打开快捷控车时顺手执行已到期的预约（WorkManager 可能被系统饿死）。
  /// 返回 true 表示本次真正下发了控车。
  static Future<bool> tryRunDueInForeground() async {
    if (!await LegalConsent.isAccepted()) return false;
    final c = await load();
    if (!c.enabled || c.atMs <= 0) return false;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // 容差：到期后 15 分钟内仍可补跑；超时视为过期，改到明天同时刻
    if (nowMs + 2 * 60 * 1000 < c.atMs) return false;
    if (nowMs - c.atMs > 15 * 60 * 1000) {
      final next = DateTime.now().add(const Duration(days: 1));
      await saveAndSchedule(
        enabled: true,
        type: c.type,
        hour: c.hour,
        minute: c.minute,
        when: DateTime(next.year, next.month, next.day, c.hour, c.minute),
      );
      return false;
    }
    final ok = await runReservationOnce(c);
    if (ok) {
      final p = await SharedPreferences.getInstance();
      await p.setInt('mymg.res.last_ok_ms', nowMs);
      await p.remove('mymg.res.at_ms');
      await p.setBool('mymg.res.enabled', false);
      try {
        await Workmanager().cancelByUniqueName(kResUniqueName);
      } catch (_) {}
      try {
        await _alarmCh.invokeMethod('cancel');
      } catch (_) {}
    }
    return ok;
  }
}

/// 真正下发一次预约动作（冷启动 WorkManager / 前台补跑共用）。
Future<bool> runReservationOnce(ReservationConfig c) async {
  if (!await LegalConsent.isAccepted()) return false;
  try {
    await RustLib.init();
  } catch (_) {}

  final cfg = await ControlConfig.load();
  if (!cfg.readyForControl) {
    await _notify('预约未执行', '控车身份 / PIN 未配置完成');
    await _saveError('身份或 PIN 未配置');
    return false;
  }

  // 后台不能弹指纹：直接读加密存储里的 PIN
  String? pin;
  try {
    pin = await PinVault().readEncrypted();
  } catch (e) {
    // flutter_secure_storage 在 WorkManager isolate 可能未注册插件
    developer.log('[MYMG.RES] PIN vault unavailable in bg: $e', name: 'mymg_core');
    await _notify('预约未执行', '后台读不到 PIN，请打开 App 保持前台到点，或在设置重存 PIN');
    await _saveError('后台无法读取 PIN（需前台）');
    return false;
  }
  if (pin == null || pin.isEmpty) {
    await _notify('预约未执行', '请先在设置里保存控车 PIN');
    await _saveError('PIN 未保存');
    return false;
  }

  try {
    final outcome = await switch (c.type) {
      'seat_left' => vehicleSeatHeat(
          brand: cfg.brand,
          token: cfg.token!,
          vin: cfg.vin!,
          pin: pin,
          userId: cfg.userId,
          mobile: cfg.mobile,
          headerDeviceId: cfg.headerDeviceId,
          seat: '1',
          on_: true,
        ),
      'seat_right' => vehicleSeatHeat(
          brand: cfg.brand,
          token: cfg.token!,
          vin: cfg.vin!,
          pin: pin,
          userId: cfg.userId,
          mobile: cfg.mobile,
          headerDeviceId: cfg.headerDeviceId,
          seat: '2',
          on_: true,
        ),
      _ => vehicleAcOn(
          brand: cfg.brand,
          token: cfg.token!,
          vin: cfg.vin!,
          pin: pin,
          userId: cfg.userId,
          mobile: cfg.mobile,
          headerDeviceId: cfg.headerDeviceId,
          targetTempC: 24,
        ),
    };
    if (outcome.accepted) {
      final p = await SharedPreferences.getInstance();
      await p.setInt('mymg.res.last_ok_ms', DateTime.now().millisecondsSinceEpoch);
      await p.remove('mymg.res.last_err');
      await _notify('预约已执行', '${c.typeLabel} 指令已下发');
      developer.log('[MYMG.RES] OK type=${c.type}', name: 'mymg_core');
      return true;
    }
    await _saveError(outcome.message ?? '服务端拒绝');
    await _notify('预约失败', outcome.message ?? '服务端拒绝');
    developer.log('[MYMG.RES] reject: ${outcome.message}', name: 'mymg_core');
    return false;
  } catch (e) {
    await _saveError(e.toString());
    await _notify('预约失败', '控车出错，请打开 App 重试');
    developer.log('[MYMG.RES] threw: $e', name: 'mymg_core');
    return false;
  }
}

Future<void> _saveError(String msg) async {
  try {
    final p = await SharedPreferences.getInstance();
    await p.setString('mymg.res.last_err', msg);
  } catch (_) {}
}

Future<void> _notify(String title, String body) async {
  try {
    final plugin = FlutterLocalNotificationsPlugin();
    const details = AndroidNotificationDetails(
      'mymg_alerts_v2',
      '车况告警',
      channelDescription: '车门/车窗/锁/油量异常推送',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    );
    await plugin.show(
      0x726573, // 'res'
      title,
      body,
      const NotificationDetails(android: details),
    );
  } catch (_) {}
}

/// 仅诊断用：把预约状态序列化成一行日志
String debugReservationLine(ReservationConfig c) {
  return jsonEncode({
    'en': c.enabled,
    't': c.type,
    'hm': '${c.hour}:${c.minute}',
    'at': c.atMs,
  });
}
