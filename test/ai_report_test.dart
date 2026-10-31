// 「最近 AI 智能总结」本机缓存的回归测试（Day 7+ 第 6 轮）
//
// 第 6 轮：单条缓存升级成 list（最多 10），首页底部要展示最近 3 条。
// 本文件钉死：
//   1) AiReport / AiReportStore —— 序列化、坏数据容错、按 VIN 隔离、
//      封顶 10 条、5 分钟内同 text 视为重复覆盖
//   2) 旧单条 JSON 格式 → 新 list 格式 的兼容读
//   3) buildPreviousSection     —— 「新旧结论怎么合并」的核心
//   4) buildAiMarkdownSpans     —— 轻量 Markdown 渲染
//   5) 第 9 轮 SnapshotDigest + saveSummary 三档去重
//      —— 用户要求"变化不大就把类似的清掉"

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mymg/ai_report_store.dart';
import 'package:mymg/ai_service.dart';
import 'package:mymg/ai_widgets.dart';
import 'package:mymg/store.dart';

/// 把 span 树里的可见文本按顺序拼起来（便于断言）
String _flat(List<InlineSpan> spans) {
  final sb = StringBuffer();
  void walk(InlineSpan s) {
    if (s is! TextSpan) return;
    if (s.text != null) sb.write(s.text);
    s.children?.forEach(walk);
  }

  spans.forEach(walk);
  return sb.toString();
}

/// 收集被渲染成粗体的文本片段
List<String> _boldTexts(List<InlineSpan> spans) {
  final out = <String>[];
  void walk(InlineSpan s) {
    if (s is! TextSpan) return;
    if (s.style?.fontWeight == FontWeight.w700 &&
        s.text != null &&
        s.text!.trim().isNotEmpty) {
      out.add(s.text!);
    }
    s.children?.forEach(walk);
  }

  spans.forEach(walk);
  return out;
}

void main() {
  group('AiReport 序列化', () {
    test('encode → decode 往返保留全部字段', () {
      const r = AiReport(text: '### 总体状态\n- 一切正常', atMs: 1789000000000, dataTs: 1788999000);
      final back = AiReport.decode(r.encode());
      expect(back, isNotNull);
      expect(back!.text, r.text);
      expect(back.atMs, r.atMs);
      expect(back.dataTs, r.dataTs);
    });

    test('dataTs 为空时不写入，解码回来仍是 null', () {
      const r = AiReport(text: '内容', atMs: 123);
      final back = AiReport.decode(r.encode());
      expect(back!.dataTs, isNull);
    });

    test('坏数据一律返回 null，绝不能让首页崩溃', () {
      expect(AiReport.decode(null), isNull);
      expect(AiReport.decode(''), isNull);
      expect(AiReport.decode('   '), isNull);
      expect(AiReport.decode('这不是 JSON'), isNull);
      expect(AiReport.decode('[1,2,3]'), isNull); // 不是 Map
      expect(AiReport.decode('{"at":1}'), isNull); // 缺 text
      expect(AiReport.decode('{"text":"  "}'), isNull); // text 只有空白
    });

    test('at 字段缺失时时间戳退化为 0（不抛异常）', () {
      final back = AiReport.decode('{"text":"内容"}');
      expect(back!.atMs, 0);
    });
  });

  group('AiReportStore list 缓存 + 封顶 + 兼容旧版', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('save → loadSummaryList 能读回（最新在前）', () async {
      const r1 = AiReport(text: '第一份', atMs: 1000);
      const r2 = AiReport(text: '第二份', atMs: 2000);
      await AiReportStore.saveSummary('VIN-A', r1);
      await AiReportStore.saveSummary('VIN-A', r2);
      final list = await AiReportStore.loadSummaryList('VIN-A');
      expect(list.length, 2);
      expect(list[0].text, '第二份'); // 最新在前
      expect(list[1].text, '第一份');
    });

    test('loadLatestSummary 取首条（没有就 null）', () async {
      expect(await AiReportStore.loadLatestSummary('VIN-A'), isNull);
      await AiReportStore.saveSummary(
          'VIN-A', const AiReport(text: '最新', atMs: 9));
      final latest = await AiReportStore.loadLatestSummary('VIN-A');
      expect(latest!.text, '最新');
      expect(latest.atMs, 9);
    });

    test('未写过的 VIN 读到空列表 / null', () async {
      expect(await AiReportStore.loadSummaryList('VIN-NEVER'), isEmpty);
      expect(await AiReportStore.loadLatestSummary('VIN-NEVER'), isNull);
    });

    test('空 VIN 直接短路，不落盘也不报错', () async {
      await AiReportStore.saveSummary('', const AiReport(text: 'x', atMs: 1));
      expect(await AiReportStore.loadSummaryList(''), isEmpty);
      expect(await AiReportStore.loadLatestSummary(''), isNull);
    });

    test('两辆车的缓存互不干扰', () async {
      await AiReportStore.saveSummary('VIN-A', const AiReport(text: 'A 的', atMs: 1));
      await AiReportStore.saveSummary('VIN-B', const AiReport(text: 'B 的', atMs: 2));
      expect((await AiReportStore.loadLatestSummary('VIN-A'))!.text, 'A 的');
      expect((await AiReportStore.loadLatestSummary('VIN-B'))!.text, 'B 的');
    });

    test('clear 之后读不到', () async {
      await AiReportStore.saveSummary('VIN-A', const AiReport(text: 'x', atMs: 1));
      await AiReportStore.clearSummary('VIN-A');
      expect(await AiReportStore.loadSummaryList('VIN-A'), isEmpty);
    });

    test('★ 超过 10 条会自动封顶（保留最新 10 条）', () async {
      for (var i = 0; i < 15; i++) {
        await AiReportStore.saveSummary(
            'VIN-A', AiReport(text: '第$i 份', atMs: 1000 + i));
      }
      final list = await AiReportStore.loadSummaryList('VIN-A');
      expect(list.length, 10);
      // 最新的是 i=14
      expect(list.first.text, '第14 份');
      expect(list.last.text, '第5 份'); // 0~4 被挤掉
    });

    test('5 分钟内同 text 视为重复，覆盖最新那条而非新增', () async {
      await AiReportStore.saveSummary(
          'VIN-A', const AiReport(text: '油量 62%', atMs: 1000));
      await AiReportStore.saveSummary(
          'VIN-A', const AiReport(text: '油量 62%', atMs: 1000 + 60 * 1000)); // +1min
      // 应该还是 1 条，时间戳被覆盖成最新的
      final list = await AiReportStore.loadSummaryList('VIN-A');
      expect(list.length, 1);
      expect(list.first.atMs, 1000 + 60 * 1000);
    });

    test('5 分钟外的同 text 视为新条目', () async {
      await AiReportStore.saveSummary(
          'VIN-A', const AiReport(text: '油量 62%', atMs: 1000));
      await AiReportStore.saveSummary(
          'VIN-A',
          const AiReport(
              text: '油量 62%', atMs: 1000 + 6 * 60 * 1000)); // +6min
      final list = await AiReportStore.loadSummaryList('VIN-A');
      expect(list.length, 2);
    });

    test('★ 旧版单条 JSON（无 items 字段）能自动包成 [单条] 读出来', () async {
      // 模拟第 5 轮写入的旧格式：{"text":"...","at":...}
      SharedPreferences.setMockInitialValues({
        'flutter.mymg.ai.last.summary.VIN-OLD':
            '{"text":"旧版结论","at":12345}',
      });
      final list = await AiReportStore.loadSummaryList('VIN-OLD');
      expect(list.length, 1);
      expect(list.first.text, '旧版结论');
      expect(list.first.atMs, 12345);
    });
  });

  group('buildPreviousSection（再次分析时合并上次结论）', () {
    test('null / 空 / 过短 → 不拼任何东西（避免拿一句废话去"对比"）', () {
      expect(buildPreviousSection(null), '');
      expect(buildPreviousSection(''), '');
      expect(buildPreviousSection('   '), '');
      expect(buildPreviousSection('太短了'), '');
    });

    test('正常长度 → 带标题且包含原文', () {
      const prev = '### 总体状态\n四星。油量充足，胎压正常，四门已锁。建议周末检查雨刮。';
      final s = buildPreviousSection(prev);
      expect(s, contains('上一次的结论'));
      expect(s, contains('四星。油量充足'));
    });

    test('超长 → 截断到 1800 字并加省略号', () {
      final prev = 'x' * 5000;
      final s = buildPreviousSection(prev);
      expect(s, contains('…'));
      // 截断后正文部分不应超过 1801（1800 + 省略号）
      final body = s.split('\n')[1];
      expect(body.length, lessThanOrEqualTo(1801));
      expect(body.length, greaterThan(1700));
    });
  });

  group('buildAiMarkdownSpans 轻量渲染', () {
    test('### 标题渲染为粗体大字', () {
      final spans = buildAiMarkdownSpans('### 总体状态');
      expect(_flat(spans), contains('总体状态'));
      expect(_boldTexts(spans), contains('总体状态'));
      // ### 是 3 级标题 → 15.2；## 及以上才是 16.5
      final h = spans.whereType<TextSpan>().firstWhere(
            (s) => s.children != null && s.style?.fontSize == 15.2,
          );
      expect(h.style?.fontWeight, FontWeight.w700);
    });

    test('## 一级/二级标题字号更大', () {
      final spans = buildAiMarkdownSpans('## 总览');
      final h = spans.whereType<TextSpan>().firstWhere(
            (s) => s.children != null && s.style?.fontSize == 16.5,
          );
      expect(h.style?.fontWeight, FontWeight.w700);
    });

    test('无序列表加圆点前缀', () {
      expect(_flat(buildAiMarkdownSpans('- 油量 62%')), contains('•'));
      expect(_flat(buildAiMarkdownSpans('* 胎压 235 kPa')), contains('235 kPa'));
    });

    test('有序列表保留序号', () {
      expect(_flat(buildAiMarkdownSpans('1. 先加油')), contains('1.'));
      expect(_flat(buildAiMarkdownSpans('2) 再检查胎压')), contains('再检查胎压'));
    });

    test('**加粗** 去掉星号并置为粗体', () {
      final spans = buildAiMarkdownSpans('结论是 **正常** 的');
      // 每行末尾会补一个 \n，比较时去掉尾部空白
      expect(_flat(spans).trim(), '结论是 正常 的');
      expect(_flat(spans), isNot(contains('*')));
      expect(_boldTexts(spans), contains('正常'));
    });

    test('--- 渲染成分隔线', () {
      expect(_flat(buildAiMarkdownSpans('---')), contains('──'));
    });

    test('空行保留换行（段落不粘连）', () {
      expect(_flat(buildAiMarkdownSpans('A\n\nB')).trim(), 'A\n\nB');
    });
  });

  group('SnapshotDigest 量化（第 9 轮）', () {
    SnapshotRow makeRow({
      int? fuel,
      int? range,
      double? odo,
      double? tIn,
      double? tOut,
      double? speed,
    }) {
      return SnapshotRow(
        id: 1,
        capturedAt: 1000,
        serverDataTime: null,
        vin: 'VIN-X',
        fuelPercent: fuel,
        rangeKm: range,
        odometerKm: odo,
        interiorTemp: tIn,
        exteriorTemp: tOut,
        latitude: null,
        longitude: null,
        journeyKm: null,
        speed: speed,
      );
    }

    test('空列表 → empty digest，hash 空字符串', () {
      final d = SnapshotDigest.fromLatest(const []);
      expect(d.hash, '');
      expect(d.label, '（无快照）');
    });

    test('单条 → hash 把所有量化字段拼接', () {
      final d = SnapshotDigest.fromLatest([
        makeRow(fuel: 82, range: 673, odo: 32288, tIn: 24, tOut: 21, speed: 0),
      ]);
      expect(d.hash, 'f82|r670|o32288|ti24|te21|s0');
      expect(d.label, contains('油量82%'));
      expect(d.label, contains('续航670km'));
      expect(d.label, contains('总里程32288 km'));
      expect(d.label, contains('车内24℃'));
    });

    test('多条 → 用 capturedAt 最大的那条', () {
      final rows = [
        makeRow(fuel: 82, range: 673, odo: 32288, tIn: 24, tOut: 21),
        makeRow(fuel: 81, range: 660, odo: 32300, tIn: 23, tOut: 20),
      ];
      // 第二条的 capturedAt 比第一条大
      rows[1] = SnapshotRow(
        id: 2,
        capturedAt: 2000,
        serverDataTime: null,
        vin: 'VIN-X',
        fuelPercent: 81,
        rangeKm: 660,
        odometerKm: 32300,
        interiorTemp: 23,
        exteriorTemp: 20,
        latitude: null,
        longitude: null,
        journeyKm: null,
        speed: null,
      );
      final d = SnapshotDigest.fromLatest(rows);
      expect(d.fuelPercent, 81);
      expect(d.rangeKm, 660);
    });

    test('续航自动分桶到 10km（673 → 670）', () {
      final d = SnapshotDigest.fromLatest([makeRow(range: 673)]);
      expect(d.rangeKm, 670);
    });

    test('isSameAs：hash 相同即视为"完全相同"', () {
      final a = SnapshotDigest.fromLatest(
          [makeRow(fuel: 82, range: 670, odo: 32288, tIn: 24, tOut: 21)]);
      final b = SnapshotDigest.fromLatest(
          [makeRow(fuel: 82, range: 670, odo: 32288, tIn: 24, tOut: 21)]);
      expect(a.isSameAs(b), isTrue);
    });

    test('isSimilarTo：油量差 ±1 视为相似', () {
      final a = SnapshotDigest.fromLatest([makeRow(fuel: 82, range: 670, odo: 32288)]);
      final b = SnapshotDigest.fromLatest([makeRow(fuel: 81, range: 670, odo: 32288)]);
      expect(a.isSimilarTo(b), isTrue);
    });

    test('isSimilarTo：油量差 ±3 视为不相似', () {
      final a = SnapshotDigest.fromLatest([makeRow(fuel: 82, range: 670, odo: 32288)]);
      final b = SnapshotDigest.fromLatest([makeRow(fuel: 79, range: 670, odo: 32288)]);
      expect(a.isSimilarTo(b), isFalse);
    });

    test('isSimilarTo：续航差 ±20km 内仍相似', () {
      final a = SnapshotDigest.fromLatest([makeRow(fuel: 82, range: 670, odo: 32288)]);
      final b = SnapshotDigest.fromLatest([makeRow(fuel: 82, range: 650, odo: 32288)]);
      expect(a.isSimilarTo(b), isTrue);
    });

    test('isSimilarTo：速度从静止到 1-30 视为不相似', () {
      final a = SnapshotDigest.fromLatest([makeRow(fuel: 82, range: 670, odo: 32288, speed: 0)]);
      final b = SnapshotDigest.fromLatest([makeRow(fuel: 82, range: 670, odo: 32288, speed: 25)]);
      expect(a.isSimilarTo(b), isFalse);
    });

    test('isSimilarTo：empty digest 永不相似（hash 为空）', () {
      final empty = SnapshotDigest.empty;
      final real = SnapshotDigest.fromLatest([makeRow(fuel: 82)]);
      expect(real.isSimilarTo(empty), isFalse);
      expect(empty.isSimilarTo(real), isFalse);
    });
  });

  group('saveSummary 三档去重（第 9 轮）', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    SnapshotRow makeRow({int? fuel, int? range, double? odo}) {
      return SnapshotRow(
        id: 1,
        capturedAt: 1000,
        serverDataTime: null,
        vin: 'VIN-A',
        fuelPercent: fuel,
        rangeKm: range,
        odometerKm: odo,
        interiorTemp: 24,
        exteriorTemp: 21,
        latitude: null,
        longitude: null,
        journeyKm: null,
        speed: 0,
      );
    }

    test('第 1 次写：inserted', () async {
      final r = AiReport(text: 'A', atMs: 1000);
      final d = SnapshotDigest.fromLatest([makeRow(fuel: 82)]);
      final outcome = await AiReportStore.saveSummary('VIN-A', r, digest: d);
      expect(outcome.action, 'inserted');
      expect(outcome.saved, isTrue);
    });

    test('★ digest 完全相同 + 跨时间窗口 → skipped_unchanged（不更新时间戳）', () async {
      final d1 = SnapshotDigest.fromLatest([makeRow(fuel: 82, range: 670, odo: 32288)]);
      final d2 = SnapshotDigest.fromLatest([makeRow(fuel: 82, range: 670, odo: 32288)]);
      await AiReportStore.saveSummary(
          'VIN-A', AiReport(text: 'A', atMs: 1000), digest: d1);
      // 1 小时后再写，仍然相同数据 → 跳过，时间戳也保持原状
      final outcome = await AiReportStore.saveSummary(
          'VIN-A',
          AiReport(text: '另一份内容', atMs: 1000 + 60 * 60 * 1000),
          digest: d2);
      expect(outcome.action, 'skipped_unchanged');
      expect(outcome.saved, isFalse);
      // 时间戳应保持 1000
      final latest = await AiReportStore.loadLatestSummary('VIN-A');
      expect(latest!.atMs, 1000);
      expect(latest.text, 'A'); // 没被覆盖
    });

    test('★ digest 相似 + 30 分钟内 → skipped_similar（不更新时间戳）', () async {
      // 相似容差：油量±2、续航±20、里程±1 —— 这里严格落在容差内
      final d1 = SnapshotDigest.fromLatest([makeRow(fuel: 82, range: 670, odo: 32288)]);
      final d2 = SnapshotDigest.fromLatest([makeRow(fuel: 81, range: 660, odo: 32289)]);
      expect(d2.isSimilarTo(d1), isTrue, reason: '测试数据必须真的相似');
      await AiReportStore.saveSummary(
          'VIN-A', AiReport(text: 'A', atMs: 1000), digest: d1);
      // 5 分钟后再写，数据微变 → 相似，30 分钟内 → 跳过
      final outcome = await AiReportStore.saveSummary(
          'VIN-A',
          AiReport(text: 'B', atMs: 1000 + 5 * 60 * 1000),
          digest: d2);
      expect(outcome.action, 'skipped_similar');
      expect(outcome.saved, isFalse);
    });

    test('digest 相似 + 30 分钟外 → 视为正常 insert', () async {
      final d1 = SnapshotDigest.fromLatest([makeRow(fuel: 82, range: 670, odo: 32288)]);
      final d2 = SnapshotDigest.fromLatest([makeRow(fuel: 81, range: 660, odo: 32290)]);
      await AiReportStore.saveSummary(
          'VIN-A', AiReport(text: 'A', atMs: 1000), digest: d1);
      final outcome = await AiReportStore.saveSummary(
          'VIN-A',
          AiReport(text: 'B', atMs: 1000 + 31 * 60 * 1000),
          digest: d2);
      expect(outcome.action, 'inserted');
      expect(outcome.saved, isTrue);
    });

    test('digest 差异大 → 立即 insert', () async {
      final d1 = SnapshotDigest.fromLatest([makeRow(fuel: 82, range: 670, odo: 32288)]);
      final d2 = SnapshotDigest.fromLatest([makeRow(fuel: 50, range: 300, odo: 32500)]);
      await AiReportStore.saveSummary(
          'VIN-A', AiReport(text: 'A', atMs: 1000), digest: d1);
      final outcome = await AiReportStore.saveSummary(
          'VIN-A',
          AiReport(text: 'B', atMs: 1000 + 60 * 1000),
          digest: d2);
      expect(outcome.action, 'inserted');
      expect(outcome.saved, isTrue);
    });

    test('不传 digest → 退化到老的"5 分钟同 text 覆盖"逻辑（向后兼容）', () async {
      await AiReportStore.saveSummary(
          'VIN-A', const AiReport(text: 'X', atMs: 1000));
      // 1 分钟后再写同 text → 应该覆盖
      final outcome = await AiReportStore.saveSummary(
          'VIN-A',
          const AiReport(text: 'X', atMs: 1000 + 60 * 1000));
      expect(outcome.action, 'overridden');
    });
  });
}
