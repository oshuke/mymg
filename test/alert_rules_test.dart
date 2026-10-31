// 告警规则引擎单测（路线 A Day 5）
//
// 覆盖两件最容易写错、又不能靠真机碰运气验证的事：
//   1. `AlertRules.activeIds()` —— 车况 → 活跃告警集合的映射是否精确
//      （尤其 null 字段不能被当成"异常"误报）
//   2. `AlertDiffEngine.diffAndSave()` —— 跨进程去重：只有"新出现"的告警才算 fresh，
//      状态持续时不能反复打扰用户
//
// 跑法：cd app && flutter test test/alert_rules_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mymg/alert_rules.dart';
import 'package:mymg/src/rust/vehicle/summary.dart';

/// 造一个"一切正常"的车况，再按需覆盖单个字段。
///
/// 注意 `PlatformInt64` 在非 web 平台就是 `int` 的 typedef，测试里可直接传 int。
VehicleSummary _car({
  int? fuelPercent,
  bool? allLocked,
  bool? allDoorsClosed,
  bool? allWindowsClosed,
}) =>
    VehicleSummary(
      fuelPercent: fuelPercent,
      allLocked: allLocked,
      allDoorsClosed: allDoorsClosed,
      allWindowsClosed: allWindowsClosed,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // 每个用例都从"干净的默认配置"开始，避免用例间互相污染
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AlertRules.reload();
  });

  group('AlertRules.activeIds 规则映射', () {
    test('车况全正常 → 无任何活跃告警', () {
      final s = _car(
        fuelPercent: 82,
        allLocked: true,
        allDoorsClosed: true,
        allWindowsClosed: true,
      );
      expect(AlertRules.activeIds(s), isEmpty);
    });

    test('车门未关 → 只命中 door_open', () {
      final s = _car(
        fuelPercent: 82,
        allLocked: true,
        allDoorsClosed: false,
        allWindowsClosed: true,
      );
      expect(AlertRules.activeIds(s), {'door_open'});
    });

    test('车窗未关 → 只命中 window_open', () {
      final s = _car(
        fuelPercent: 82,
        allLocked: true,
        allDoorsClosed: true,
        allWindowsClosed: false,
      );
      expect(AlertRules.activeIds(s), {'window_open'});
    });

    test('未设防 → 只命中 unlocked', () {
      final s = _car(
        fuelPercent: 82,
        allLocked: false,
        allDoorsClosed: true,
        allWindowsClosed: true,
      );
      expect(AlertRules.activeIds(s), {'unlocked'});
    });

    test('多个异常同时存在 → 全部命中', () {
      final s = _car(
        fuelPercent: 8,
        allLocked: false,
        allDoorsClosed: false,
        allWindowsClosed: false,
      );
      expect(
        AlertRules.activeIds(s),
        {'door_open', 'window_open', 'unlocked', 'low_fuel'},
      );
    });

    test('★ null 字段不能当成异常（燃油车 battery 类字段恒为 null）', () {
      // 三态字段全为 null = 服务端没给数据，绝不能等同于 false
      final s = _car(fuelPercent: null);
      expect(AlertRules.activeIds(s), isEmpty);
    });
  });

  group('low_fuel 阈值', () {
    test('默认阈值 20：15% 命中，25% 不命中，20% 恰好不命中（严格小于）', () {
      expect(AlertRules.activeIds(_car(fuelPercent: 15)), contains('low_fuel'));
      expect(AlertRules.activeIds(_car(fuelPercent: 25)),
          isNot(contains('low_fuel')));
      expect(AlertRules.activeIds(_car(fuelPercent: 20)),
          isNot(contains('low_fuel')));
    });

    test('阈值改到 30 后，25% 也命中', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{kLowFuelThresholdKey: 30});
      await AlertRules.reload();
      expect(AlertRules.activeIds(_car(fuelPercent: 25)), contains('low_fuel'));
    });
  });

  group('用户开关', () {
    test('关掉 door 规则 → 车门未关也不再报', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{kAlertDoorsKey: false});
      await AlertRules.reload();
      expect(AlertRules.activeIds(_car(allDoorsClosed: false)),
          isNot(contains('door_open')));
      // 其它规则不受影响
      expect(AlertRules.activeIds(_car(allLocked: false)), contains('unlocked'));
    });

    test('关掉 low_fuel 规则 → 即使油量极低也不报', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{kAlertLowFuelKey: false});
      await AlertRules.reload();
      expect(AlertRules.activeIds(_car(fuelPercent: 3)), isEmpty);
    });
  });

  group('AlertDiffEngine 跨进程去重', () {
    test('首次出现 → 全部算 fresh', () async {
      final fresh = await AlertDiffEngine.diffAndSave({'unlocked'});
      expect(fresh, {'unlocked'});
    });

    test('★ 状态持续 → fresh 为空（不重复打扰）', () async {
      await AlertDiffEngine.diffAndSave({'unlocked'});
      final fresh = await AlertDiffEngine.diffAndSave({'unlocked'});
      expect(fresh, isEmpty);
    });

    test('新增一条 → 只有新增的那条算 fresh', () async {
      await AlertDiffEngine.diffAndSave({'unlocked'});
      final fresh = await AlertDiffEngine.diffAndSave({'unlocked', 'low_fuel'});
      expect(fresh, {'low_fuel'});
    });

    test('告警消失后再出现 → 重新算 fresh', () async {
      await AlertDiffEngine.diffAndSave({'unlocked'});
      await AlertDiffEngine.diffAndSave(<String>{});
      final fresh = await AlertDiffEngine.diffAndSave({'unlocked'});
      expect(fresh, {'unlocked'});
    });
  });

  group('规则表自检', () {
    test('byId 能取到全部内置规则，id 不重复', () {
      final ids = AlertRules.all.map((r) => r.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'id 必须唯一，否则通知会互相覆盖');
      for (final id in ids) {
        expect(AlertRules.byId(id), isNotNull);
      }
    });
  });
}
