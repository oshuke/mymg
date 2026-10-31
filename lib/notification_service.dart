// 本地通知服务（路线 A Day 5）
//
// 封装 flutter_local_notifications：
//   - init()：在 main() 调一次
//   - notifyAlert(rule) / notifyAlerts(ids)：告警
//   - notifyPlain：控车结果等普通通知
//
// Android 13+ 需要 POST_NOTIFICATIONS 权限，会在 init 里自动请求。

import 'dart:developer' as developer;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'alert_rules.dart';

class NotificationService {
  static final NotificationService instance = NotificationService._();
  NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _inited = false;
  bool _granted = false;

  static const _channelId = 'mymg_alerts_v2';
  static const _channelName = '车况告警';
  static const _channelCriticalId = 'mymg_alert_critical';
  static const _channelCriticalName = '重要告警';
  static const _channelWarningId = 'mymg_alert_warning';
  static const _channelWarningName = '一般告警';

  Future<void> init() async {
    if (_inited) return;
    _inited = true;

    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _plugin.initialize(initSettings);

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    _granted = await android?.requestNotificationsPermission() ?? false;
  }

  Future<void> notifyAlert(AlertRule rule) async {
    if (!_inited) {
      developer.log('[MYMG.NOTIF] not inited, skip', name: 'mymg_core');
      return;
    }
    if (!AlertRules.shouldNotify(rule)) return;
    if (!_granted) {
      _granted = await _areEnabled();
      if (!_granted) return;
    }
    final critical = rule.severity == AlertSeverity.critical;
    final id = _idForRule(rule.id);
    final androidDetails = AndroidNotificationDetails(
      critical ? _channelCriticalId : _channelWarningId,
      critical ? _channelCriticalName : _channelWarningName,
      channelDescription: critical ? '严重车况告警（悬浮提醒）' : '一般车况提醒',
      importance: _importanceOf(rule.severity),
      priority: _priorityOf(rule.severity),
      icon: '@mipmap/ic_launcher',
      ticker: rule.title,
    );
    await _plugin.show(
      id,
      rule.title,
      rule.bodyBuilder(),
      NotificationDetails(android: androidDetails),
    );
  }

  /// 给一组新出现的告警批量推
  Future<void> notifyAlerts(Set<String> freshIds) async {
    for (final id in freshIds) {
      final rule = AlertRules.byId(id);
      if (rule != null) await notifyAlert(rule);
    }
  }

  /// 控车结果等普通通知
  Future<void> notifyPlain({
    required String title,
    required String body,
    bool critical = false,
  }) async {
    if (!_inited) return;
    if (!_granted) {
      _granted = await _areEnabled();
      if (!_granted) return;
    }
    final details = AndroidNotificationDetails(
      critical ? _channelCriticalId : _channelWarningId,
      critical ? _channelCriticalName : _channelWarningName,
      channelDescription: critical ? '重要车控/安全通知' : '车控与车况提醒',
      importance: critical ? Importance.max : Importance.defaultImportance,
      priority: critical ? Priority.high : Priority.defaultPriority,
      icon: '@mipmap/ic_launcher',
    );
    final id = DateTime.now().millisecondsSinceEpoch.remainder(100000);
    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(android: details),
    );
  }

  Future<bool> areNotificationsEnabled() => _areEnabled();

  Future<bool> _areEnabled() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return true;
      return await android.areNotificationsEnabled() ?? true;
    } catch (e) {
      developer.log('[MYMG.NOTIF] areNotificationsEnabled err: $e',
          name: 'mymg_core');
      return true;
    }
  }

  static int _idForRule(String s) {
    int h = 0x811c9dc5 & 0x7FFFFFFF;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0x7FFFFFFF;
    }
    return h;
  }

  static Importance _importanceOf(AlertSeverity s) => switch (s) {
        AlertSeverity.info => Importance.defaultImportance,
        AlertSeverity.warning => Importance.high,
        AlertSeverity.critical => Importance.max,
      };

  static Priority _priorityOf(AlertSeverity s) => switch (s) {
        AlertSeverity.info => Priority.defaultPriority,
        AlertSeverity.warning => Priority.high,
        AlertSeverity.critical => Priority.max,
      };
}
