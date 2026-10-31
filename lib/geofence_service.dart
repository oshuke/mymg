// 地理围栏 / 异常移动
//
// 数据来自每次车况快照的 GPS（WGS-84）。后台 WorkManager 拉数后调用
// evaluateGeofence：对比围栏内外状态变化，并检测短时间大位移。

import 'dart:math' as math;
import 'dart:developer' as developer;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mymg/src/rust/vehicle/summary.dart';

const kFenceEnabledKey = 'mymg.fence.enabled';
const kFenceLatKey = 'mymg.fence.lat';
const kFenceLngKey = 'mymg.fence.lng';
const kFenceRadiusKey = 'mymg.fence.radius_m';
const kFenceLastInsideKey = 'mymg.fence.last_inside';
const kFenceAlertMoveKey = 'mymg.fence.alert_move';
const kFenceAlertEnterExitKey = 'mymg.fence.alert_enter_exit';

/// 异常移动阈值（米）：两次快照之间位移超过此值提醒
const kFenceMoveThresholdM = 400.0;

class GeofenceService {
  GeofenceService._();

  static Future<({
    bool enabled,
    double? lat,
    double? lng,
    double radiusM,
    bool alertMove,
    bool alertEnterExit,
  })> load() async {
    final p = await SharedPreferences.getInstance();
    return (
      enabled: p.getBool(kFenceEnabledKey) ?? false,
      lat: p.getDouble(kFenceLatKey),
      lng: p.getDouble(kFenceLngKey),
      radiusM: p.getDouble(kFenceRadiusKey) ?? 200,
      alertMove: p.getBool(kFenceAlertMoveKey) ?? true,
      alertEnterExit: p.getBool(kFenceAlertEnterExitKey) ?? true,
    );
  }

  static Future<void> save({
    required bool enabled,
    double? lat,
    double? lng,
    required double radiusM,
    required bool alertMove,
    required bool alertEnterExit,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kFenceEnabledKey, enabled);
    if (lat != null) await p.setDouble(kFenceLatKey, lat);
    if (lng != null) await p.setDouble(kFenceLngKey, lng);
    await p.setDouble(kFenceRadiusKey, radiusM);
    await p.setBool(kFenceAlertMoveKey, alertMove);
    await p.setBool(kFenceAlertEnterExitKey, alertEnterExit);
  }

  /// 米
  static double distanceM(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final p1 = lat1 * math.pi / 180;
    final p2 = lat2 * math.pi / 180;
    final dp = (lat2 - lat1) * math.pi / 180;
    final dl = (lon2 - lon1) * math.pi / 180;
    final a = math.sin(dp / 2) * math.sin(dp / 2) +
        math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }
}

/// 后台每轮拉数后调用
Future<void> evaluateGeofence(VehicleSummary summary) async {
  final cfg = await GeofenceService.load();
  if (!cfg.enabled) return;

  final lat = double.tryParse(summary.latitude ?? '');
  final lng = double.tryParse(summary.longitude ?? '');
  if (lat == null || lng == null) return;
  if (lat == 0 && lng == 0) return;

  final p = await SharedPreferences.getInstance();

  // ── 异常移动：与上次有效坐标比距离 ──
  if (cfg.alertMove) {
    final lastLat = p.getDouble('mymg.geo.last_lat');
    final lastLng = p.getDouble('mymg.geo.last_lng');
    final lastTs = p.getInt('mymg.geo.last_ts') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (lastLat != null && lastLng != null && lastTs > 0) {
      final d = GeofenceService.distanceM(lastLat, lastLng, lat, lng);
      final dtMin = (now - lastTs) / 60000.0;
      // 10 分钟内移动超过阈值 → 提醒
      if (d >= kFenceMoveThresholdM && dtMin <= 30) {
        await _notify(
          id: 9001,
          title: '检测到车辆移动',
          body: '约 ${d.round()} 米（${dtMin.toStringAsFixed(0)} 分钟内）。若非本人操作请留意。',
          critical: true,
        );
      }
    }
  }
  await p.setDouble('mymg.geo.last_lat', lat);
  await p.setDouble('mymg.geo.last_lng', lng);
  await p.setInt('mymg.geo.last_ts', DateTime.now().millisecondsSinceEpoch);

  // ── 围栏进出 ──
  if (cfg.alertEnterExit && cfg.lat != null && cfg.lng != null) {
    final d = GeofenceService.distanceM(cfg.lat!, cfg.lng!, lat, lng);
    final inside = d <= cfg.radiusM;
    final lastInside = p.getBool(kFenceLastInsideKey);
    if (lastInside != null && lastInside != inside) {
      await _notify(
        id: 9002,
        title: inside ? '车辆已进入围栏' : '车辆已离开围栏',
        body: inside
            ? '距围栏中心约 ${d.round()} 米（半径 ${cfg.radiusM.round()} 米）'
            : '距围栏中心约 ${d.round()} 米，已超出半径 ${cfg.radiusM.round()} 米',
        critical: true,
      );
    }
    await p.setBool(kFenceLastInsideKey, inside);
  }
}

Future<void> _notify({
  required int id,
  required String title,
  required String body,
  bool critical = false,
}) async {
  try {
    final plugin = FlutterLocalNotificationsPlugin();
    const init = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await plugin.initialize(init);
    final details = AndroidNotificationDetails(
      critical ? 'mymg_alert_critical' : 'mymg_alert_warning',
      critical ? '重要告警' : '一般告警',
      channelDescription: '车辆安全 / 围栏 / 状态提醒',
      importance:
          critical ? Importance.max : Importance.defaultImportance,
      priority: critical ? Priority.high : Priority.defaultPriority,
      icon: '@mipmap/ic_launcher',
      styleInformation: BigTextStyleInformation(body),
    );
    await plugin.show(id, title, body, NotificationDetails(android: details));
    developer.log('[MYMG.GEOFENCE] $title', name: 'mymg_core');
  } catch (e) {
    developer.log('[MYMG.GEOFENCE] notify failed: $e', name: 'mymg_core');
  }
}
