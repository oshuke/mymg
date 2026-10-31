// 官方云端告警增强
//
// 官方 `getVehicleStatus` 响应里已有 `vehicle_alerts`，
// Rust 已映射到 VehicleSummary.alerts。这里负责：
// 1) 把服务端告警转成可读文案并推系统通知（与本地规则互补）
// 2) 去重（用独立 key，避免和本地规则 id 冲突）
// 3) 预留：未来若抓到「消息中心」列表接口，可在此并入轮询

import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mymg/src/rust/vehicle/model.dart';
import 'package:mymg/src/rust/vehicle/summary.dart';

const kOfficialAlertsEnabledKey = 'mymg.alert.official_enabled';
const kOfficialAlertsSeenKey = 'mymg.alert.official_seen';

class OfficialAlertService {
  OfficialAlertService._();

  static Future<bool> enabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(kOfficialAlertsEnabledKey) ?? true;
  }

  static Future<void> setEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kOfficialAlertsEnabledKey, v);
  }

  /// 每次拉到车况后调用：服务端告警有新增则通知
  static Future<int> syncFromSummary(VehicleSummary summary) async {
    if (!await enabled()) return 0;
    final alerts = summary.alerts;
    if (alerts == null || alerts.isEmpty) return 0;

    final p = await SharedPreferences.getInstance();
    final seenRaw = p.getString(kOfficialAlertsSeenKey);
    final seen = <String>{
      if (seenRaw != null && seenRaw.isNotEmpty)
        ...(jsonDecode(seenRaw) as List).cast<String>(),
    };

    final fresh = <VehicleAlert>[];
    final freshKeys = <String>[];
    for (final a in alerts) {
      final key = _keyOf(a);
      if (!seen.contains(key)) {
        fresh.add(a);
        freshKeys.add(key);
      }
    }

    // 写回「当前全部」以便下次差集；服务端消失的条目不再出现
    final currentKeys = alerts.map(_keyOf).toList();
    await p.setString(kOfficialAlertsSeenKey, jsonEncode(currentKeys));

    if (fresh.isEmpty) return 0;
    for (final a in fresh) {
      await _notifyOfficial(a);
    }
    developer.log('[MYMG.OFFICIAL] fresh=${fresh.length}', name: 'mymg_core');
    return fresh.length;
  }

  static String _keyOf(VehicleAlert a) {
    final id = a.alertId?.toString() ?? '';
    final type = a.alertType?.toString() ?? '';
    final data = a.alertData?.toString() ?? '';
    return 'off-$type-$id-$data';
  }

  static String describe(VehicleAlert a) {
    final id = a.alertId?.toString() ?? '?';
    final type = a.alertType?.toString();
    final data = a.alertData?.toString();
    final buf = StringBuffer('服务端告警 #$id');
    if (type != null && type.isNotEmpty) buf.write(' · 类型 $type');
    if (data != null && data.isNotEmpty) buf.write(' · $data');
    return buf.toString();
  }

  static Future<void> _notifyOfficial(VehicleAlert a) async {
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      const init = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      );
      await plugin.initialize(init);
      final id = _hash(_keyOf(a));
      const details = AndroidNotificationDetails(
        'mymg_alert_critical',
        '重要告警',
        channelDescription: '官方云端车辆告警',
        importance: Importance.max,
        priority: Priority.max,
        icon: '@mipmap/ic_launcher',
      );
      await plugin.show(
        id,
        '云端车辆告警',
        describe(a),
        const NotificationDetails(android: details),
      );
    } catch (e) {
      developer.log('[MYMG.OFFICIAL] notify failed: $e', name: 'mymg_core');
    }
  }

  static int _hash(String s) {
    int h = 0x811c9dc5 & 0x7FFFFFFF;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0x7FFFFFFF;
    }
    return h;
  }
}
