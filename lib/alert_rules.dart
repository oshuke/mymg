// 告警规则引擎（路线 A Day 5）
//
// 把"车况数据 → 一组当前活跃告警"做成纯函数：
//   AlertRules.activeIds(summary) -> Set<String>
// 状态变化时发通知，状态持续时不再重复打扰。

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mymg/src/rust/vehicle/summary.dart';

/// 告警严重度 → 通知 channel 优先级
enum AlertSeverity { info, warning, critical }

/// 一条规则的定义。`id` 既是通知 key 也是去重 key，必须稳定。
class AlertRule {
  const AlertRule({
    required this.id,
    required this.title,
    required this.bodyBuilder,
    required this.severity,
    required this.check,
  });

  final String id;
  final String title;
  final String Function() bodyBuilder;
  final AlertSeverity severity;
  final bool Function(VehicleSummary) check;
}

/// 设置页用的 key（其它文件 import 用）
const kLowFuelThresholdKey = 'mymg.alert.low_fuel_threshold';
const kAlertDoorsKey = 'mymg.alert.doors';
const kAlertWindowsKey = 'mymg.alert.windows';
const kAlertUnlockedKey = 'mymg.alert.unlocked';
const kAlertLowFuelKey = 'mymg.alert.low_fuel';
const kAlertsEnabledKey = 'mymg.alerts_enabled';
const kLastAlertsKey = 'mymg.last_alerts_ids';
const kBackgroundEnabledKey = 'mymg.bg.enabled';

/// 推送级别：0=全部(info+) 1=警告及以上 2=仅严重
const kAlertMinLevelKey = 'mymg.alert.min_level';

class AlertLevelKeys {
  static const minLevel = kAlertMinLevelKey;
}

extension AlertSeverityX on AlertSeverity {
  int get levelIndex => switch (this) {
        AlertSeverity.info => 0,
        AlertSeverity.warning => 1,
        AlertSeverity.critical => 2,
      };

  String get label => switch (this) {
        AlertSeverity.info => '提示',
        AlertSeverity.warning => '警告',
        AlertSeverity.critical => '严重',
      };
}

/// 跨进程告警去重引擎：上次活跃告警的 id 集合存在 SharedPreferences，
///  前后台 / 后台多次回调共享同一份"真相"。
class AlertDiffEngine {
  /// 检测本次"新出现"的告警集合。
  ///
  /// 返回当前活跃告警与上次的差集（即"上次没这次有"），调用方对这部分发通知；
  /// 然后把当前集合写回 SharedPreferences 用于下一次去重。
  static Future<Set<String>> diffAndSave(Set<String> current) async {
    final p = await SharedPreferences.getInstance();
    final lastRaw = p.getString(kLastAlertsKey);
    final last = <String>{
      if (lastRaw != null && lastRaw.isNotEmpty)
        ...(jsonDecode(lastRaw) as List).cast<String>(),
    };

    final fresh = current.difference(last);
    await p.setString(kLastAlertsKey, jsonEncode(current.toList()));
    return fresh;
  }
}

/// 规则定义 + 用户开关 / 阈值缓存。
///
/// 把 SharedPreferences 里的开关 / 阈值缓存到静态字段，避免每条规则都 await。
class AlertRules {
  static int _lowFuelThreshold = 20;
  static int? _lastFuelPercent;
  static bool _doors = true;
  static bool _windows = true;
  static bool _unlocked = true;
  static bool _lowFuel = true;

  /// 通知最低级别（0/1/2）
  static int _minLevel = 1;

  static int? get lastFuelPercent => _lastFuelPercent;
  static int get minLevel => _minLevel;

  static Future<void> reload() async {
    final p = await SharedPreferences.getInstance();
    _lowFuelThreshold = p.getInt(kLowFuelThresholdKey) ?? 20;
    _doors = p.getBool(kAlertDoorsKey) ?? true;
    _windows = p.getBool(kAlertWindowsKey) ?? true;
    _unlocked = p.getBool(kAlertUnlockedKey) ?? true;
    _lowFuel = p.getBool(kAlertLowFuelKey) ?? true;
    _minLevel = p.getInt(kAlertMinLevelKey) ?? 1;
  }

  static Future<void> setMinLevel(int level) async {
    _minLevel = level.clamp(0, 2);
    final p = await SharedPreferences.getInstance();
    await p.setInt(kAlertMinLevelKey, _minLevel);
  }

  /// 是否达到推送级别
  static bool shouldNotify(AlertRule rule) =>
      rule.severity.levelIndex >= _minLevel;

  /// 让 bodyBuilder 渲染具体数值时调用
  static void rememberFuel(int? p) {
    _lastFuelPercent = p;
  }

  static bool _isEnabled(String id) {
    switch (id) {
      case 'door_open':
        return _doors;
      case 'window_open':
        return _windows;
      case 'unlocked':
        return _unlocked;
      case 'low_fuel':
        return _lowFuel;
      default:
        return true;
    }
  }

  /// 内置规则
  static final List<AlertRule> all = [
    AlertRule(
      id: 'door_open',
      title: '车门未关',
      bodyBuilder: () => '请检查车门是否完全关闭',
      severity: AlertSeverity.warning,
      check: (s) => s.allDoorsClosed == false,
    ),
    AlertRule(
      id: 'window_open',
      title: '车窗未关',
      bodyBuilder: () => '请检查车窗是否完全关闭',
      severity: AlertSeverity.warning,
      check: (s) => s.allWindowsClosed == false,
    ),
    AlertRule(
      id: 'unlocked',
      title: '车门未锁',
      bodyBuilder: () => '车辆当前未设防，建议尽快落锁',
      severity: AlertSeverity.critical,
      check: (s) => s.allLocked == false,
    ),
    AlertRule(
      id: 'low_fuel',
      title: '油量过低',
      bodyBuilder: () {
        final p = _lastFuelPercent;
        return p == null ? '油量过低，请尽快加油' : '当前油量 $p%，请尽快加油';
      },
      severity: AlertSeverity.warning,
      check: (s) {
        final p = s.fuelPercent;
        if (p == null) return false;
        return p < _lowFuelThreshold;
      },
    ),
    AlertRule(
      id: 'temp_high',
      title: '车内温度过高',
      bodyBuilder: () => '车内温度偏高，注意物品与电池安全',
      severity: AlertSeverity.warning,
      check: (s) {
        final t = s.interiorTemp;
        return t != null && t >= 45;
      },
    ),
  ];

  /// 计算当前活跃告警 id 集合（应用用户开关过滤）
  static Set<String> activeIds(VehicleSummary s) {
    return {
      for (final r in all)
        if (_isEnabled(r.id) && r.check(s)) r.id,
    };
  }

  /// 按 id 取规则
  static AlertRule? byId(String id) {
    for (final r in all) {
      if (r.id == id) return r;
    }
    return null;
  }
}