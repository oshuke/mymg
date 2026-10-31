// 历史快照收敛 + AI 自动总结时机 策略测试
//
// 钉死两条产品规则：
//   1) 车况未变化时，**连续**同指纹快照只保留首尾两条（便于分析时间段，
//      又不把相同历史堆成几十条）。A→B→A 两段各自收敛，不能全局误合并。
//   2) AI 车况解读在「最合适的时候」自动生成：车况关键字段变化才跑，
//      温度波动不触发；明显变化立刻跑，轻微变化限流。

import 'package:flutter_test/flutter_test.dart';

import 'package:mymg/ai_report_store.dart';
import 'package:mymg/store.dart';

({int id, String vin, int capturedAt, String? fingerprint}) _row(
  int id,
  String vin,
  int t,
  String? fp,
) =>
    (id: id, vin: vin, capturedAt: t, fingerprint: fp);

SnapshotDigest _digest({
  int? fuel,
  int? range,
  int? odo,
  int? interior,
  int? exterior,
  int? speed,
}) {
  // SnapshotDigest.fromLatest 要 SnapshotRow；用 map 路径太绕，
  // 直接构造两份同结构数据：喂 fromLatest 的最小 SnapshotRow。
  final row = SnapshotRow(
    id: 1,
    capturedAt: 1000,
    vin: 'VIN',
    fuelPercent: fuel,
    rangeKm: range,
    odometerKm: odo?.toDouble(),
    interiorTemp: interior?.toDouble(),
    exteriorTemp: exterior?.toDouble(),
    speed: speed?.toDouble(),
  );
  return SnapshotDigest.fromLatest([row]);
}

void main() {
  group('consecutiveCollapseIds 连续同指纹只留首尾', () {
    test('★ 3 条连续同指纹 → 删中间 1 条', () {
      final doomed = SnapshotStore.consecutiveCollapseIds([
        _row(1, 'V', 10, 'A'),
        _row(2, 'V', 20, 'A'),
        _row(3, 'V', 30, 'A'),
      ]);
      expect(doomed, [2]);
    });

    test('2 条同指纹不删（首尾语义）', () {
      expect(
        SnapshotStore.consecutiveCollapseIds([
          _row(1, 'V', 10, 'A'),
          _row(2, 'V', 20, 'A'),
        ]),
        isEmpty,
      );
    });

    test('5 条连续同指纹 → 只留首尾，删中间 3 条', () {
      final doomed = SnapshotStore.consecutiveCollapseIds([
        _row(1, 'V', 10, 'A'),
        _row(2, 'V', 20, 'A'),
        _row(3, 'V', 30, 'A'),
        _row(4, 'V', 40, 'A'),
        _row(5, 'V', 50, 'A'),
      ]);
      expect(doomed, [2, 3, 4]);
    });

    test('★ A→B→A 两段各自收敛，不能全局合并', () {
      // 段1: A A A（删 2）；段2: B；段3: A A A（删 6）
      // 旧 SQL 按全局 fingerprint 分组会把 6 条 A 当成一段，错删中间 4 条。
      final doomed = SnapshotStore.consecutiveCollapseIds([
        _row(1, 'V', 10, 'A'),
        _row(2, 'V', 20, 'A'),
        _row(3, 'V', 30, 'A'),
        _row(4, 'V', 40, 'B'),
        _row(5, 'V', 50, 'A'),
        _row(6, 'V', 60, 'A'),
        _row(7, 'V', 70, 'A'),
      ]);
      expect(doomed, [2, 6], reason: '只删两段 A 各自的中间行');
    });

    test('不同 vin 的同指纹不互相合并', () {
      final doomed = SnapshotStore.consecutiveCollapseIds([
        _row(1, 'V1', 10, 'A'),
        _row(2, 'V2', 20, 'A'),
        _row(3, 'V1', 30, 'A'),
      ]);
      // V1: A,A 两条 → 不删；V2: 一条 → 不删
      expect(doomed, isEmpty);
    });

    test('交替指纹一行都不删', () {
      expect(
        SnapshotStore.consecutiveCollapseIds([
          _row(1, 'V', 10, 'A'),
          _row(2, 'V', 20, 'B'),
          _row(3, 'V', 30, 'A'),
          _row(4, 'V', 40, 'B'),
        ]),
        isEmpty,
      );
    });
  });

  group('SnapshotDigest 车况关键字段', () {
    test('温度变化 → 车况视为未变', () {
      final a = _digest(fuel: 50, range: 200, odo: 1000, interior: 24, exterior: 20);
      final b = _digest(fuel: 50, range: 200, odo: 1000, interior: 31, exterior: 28);
      expect(a.isVehicleUnchangedFrom(b), isTrue);
      expect(a.isSameAs(b), isFalse, reason: '完整 hash 仍不同');
    });

    test('油量变了 → 车况有变', () {
      final a = _digest(fuel: 50, range: 200, odo: 1000);
      final b = _digest(fuel: 42, range: 200, odo: 1000);
      expect(a.isVehicleUnchangedFrom(b), isFalse);
      expect(a.isSignificantChangeFrom(b), isTrue, reason: '油量差 8% ≥5');
    });

    test('里程 +3km 不算明显变化，+6km 算', () {
      final base = _digest(fuel: 50, range: 200, odo: 1000);
      expect(
        base.isSignificantChangeFrom(_digest(fuel: 50, range: 200, odo: 1003)),
        isFalse,
      );
      expect(
        base.isSignificantChangeFrom(_digest(fuel: 50, range: 200, odo: 1006)),
        isTrue,
      );
    });
  });

  group('AiAutoPolicy.decide 生成时机', () {
    final now = DateTime(2026, 3, 20, 12);

    AiReport report({required SnapshotDigest digest, Duration age = Duration.zero}) {
      return AiReport(
        text: '上次结论',
        atMs: now.subtract(age).millisecondsSinceEpoch,
        digest: digest,
      );
    }

    test('尚无总结 → 立刻生成首份', () {
      final d = AiAutoPolicy.decide(
        lastReport: null,
        current: _digest(fuel: 50),
        now: now,
      );
      expect(d.shouldRun, isTrue);
      expect(d.significant, isTrue);
    });

    test('★ 车况没变（仅温度波动）→ 不跑', () {
      final last = report(
        digest: _digest(fuel: 50, range: 200, odo: 1000, interior: 24),
        age: const Duration(hours: 1),
      );
      final d = AiAutoPolicy.decide(
        lastReport: last,
        current: _digest(fuel: 50, range: 200, odo: 1000, interior: 30),
        now: now,
      );
      expect(d.shouldRun, isFalse);
      expect(d.note, contains('无变化'));
    });

    test('★ 明显变化（油量掉 8%）→ 立刻跑，不受 2h 限流', () {
      final last = report(
        digest: _digest(fuel: 50, range: 200, odo: 1000),
        age: const Duration(minutes: 10),
      );
      final d = AiAutoPolicy.decide(
        lastReport: last,
        current: _digest(fuel: 42, range: 180, odo: 1050),
        now: now,
      );
      expect(d.shouldRun, isTrue);
      expect(d.significant, isTrue);
    });

    test('轻微变化 + 30 分钟内 → 再等等', () {
      final last = report(
        digest: _digest(fuel: 50, range: 200, odo: 1000),
        age: const Duration(minutes: 10),
      );
      final d = AiAutoPolicy.decide(
        lastReport: last,
        current: _digest(fuel: 49, range: 200, odo: 1001),
        now: now,
      );
      expect(d.shouldRun, isFalse);
    });

    test('轻微变化 + 超过 2 小时 → 跑', () {
      final last = report(
        digest: _digest(fuel: 50, range: 200, odo: 1000),
        age: const Duration(hours: 3),
      );
      final d = AiAutoPolicy.decide(
        lastReport: last,
        current: _digest(fuel: 49, range: 200, odo: 1001),
        now: now,
      );
      expect(d.shouldRun, isTrue);
      expect(d.significant, isFalse);
    });

    test('旧报告没有 digest → 当作需要生成', () {
      final last = AiReport(text: '旧', atMs: now.millisecondsSinceEpoch);
      final d = AiAutoPolicy.decide(
        lastReport: last,
        current: _digest(fuel: 50),
        now: now,
      );
      // lastDigest == null → vehicleChanged，且 significant
      expect(d.shouldRun, isTrue);
    });
  });
}
