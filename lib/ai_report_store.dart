// 「最近 AI 智能总结」的本机缓存。
//
// 历史记录：
//   - 第 4 轮：单条缓存（`loadDiagnose`），首页卡里跑分析、塞回去
//   - 第 5 轮：单条缓存改名（`loadSummary`），首页 2 行 peek + 历史页全展示
//   - 第 6 轮：用户要求「打开软件时自动跑一次 + 底部留最近 3 次可点开看」，
//     单条塞不下历史 → 升级成 list（最新在前、本地最多存 10 条，
//     卡片底部最多展示 3 条）。
//   - 第 9 轮（2026-09-10）：用户要求"变化不大就清掉类似的"，
//     新增 [SnapshotDigest] 字段，[saveSummary] 升级三档去重：
//     ① 5min 同 text 覆盖 ② digest 完全相同跳过
//     ③ digest 相似 + 30min 跳过。
//
// 仍然存 SharedPreferences（单 key、JSON 数组），读写 O(1)，没必要上 SQLite。
//
// 兼容：旧版本是单条 JSON（`{text, at, data_ts}`），解析时如果遇到会自动包成
// `[{…}]` 读出来，不会让用户在升级后看到空白。

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'store.dart';

/// 把"最新一条快照"的关键字段量化成一个指纹，用来判断两次 AI 总结是否基于
/// **差异过大**的数据。
///
/// ## 量化策略（避免 GPS 微移 / 浮点抖动导致的"无意义变化"）
///
/// | 字段         | 量化粒度 | 理由                             |
/// |--------------|----------|----------------------------------|
/// | fuelPercent  | 1 %      | 加油一般是 5% 一档               |
/// | rangeKm      | 10 km    | 续航数字本身就粗                 |
/// | odometerKm   | 1 km     | 行驶里程精度足够                 |
/// | interiorTemp | 1 ℃      | 探头 0.5℃ 抖动，桶到整数         |
/// | exteriorTemp | 1 ℃      | 同上                             |
/// | speed        | 0/1-30/30+ 三档 | 堵车 vs 高架 vs 高速 区分 |
/// | position     | 不参与   | GPS 经常 ±10m 抖动，无意义        |
///
/// ## 相似度
///
/// "完全相同" = hash 字符串相等。
/// "相似" = 各字段差值都在阈值内（油量±2、续航±20km、里程±1km、温度±1℃、速度同档）。
class SnapshotDigest {
  const SnapshotDigest._({
    required this.fuelPercent,
    required this.rangeKm,
    required this.odometerKm,
    required this.interiorTemp,
    required this.exteriorTemp,
    required this.speedBucket,
    required this.hash,
    required this.label,
  });

  /// 空 digest（用于没有快照的情况）
  static const SnapshotDigest empty = SnapshotDigest._(
    fuelPercent: null,
    rangeKm: null,
    odometerKm: null,
    interiorTemp: null,
    exteriorTemp: null,
    speedBucket: null,
    hash: '',
    label: '（无快照）',
  );

  final int? fuelPercent;
  final int? rangeKm;        // 分桶到 10km
  final int? odometerKm;     // 整数化
  final int? interiorTemp;   // 整数化
  final int? exteriorTemp;   // 整数化
  /// 0=静止 / 1=1-30 km/h / 2=30+ km/h
  final int? speedBucket;
  /// 量化的摘要字符串："f82|r670|o32288|ti24|te21|s0"
  final String hash;
  /// 人读标签："油量82% / 续航670km / 总里程32288km / 车内24℃"
  final String label;

  /// 从最新一条快照派生 digest；空 list 返回 [empty]。
  ///
  /// 用最新一条而不是聚合：AI 总结面向的就是"截至目前"的状态，
  /// 之前 N 条快照都已经被 SQLite 持久化了，不需要再算全局统计。
  factory SnapshotDigest.fromLatest(List<SnapshotRow> rows) {
    if (rows.isEmpty) return empty;
    // listByRange 顺序依赖实现（看 SnapshotStore），防御性地取 capturedAt 最大那条
    final latest = rows.reduce((a, b) => a.capturedAt >= b.capturedAt ? a : b);

    final fuel = latest.fuelPercent;
    final range = latest.rangeKm == null ? null : (latest.rangeKm! ~/ 10) * 10;
    final odo = latest.odometerKm?.round();
    final interior = latest.interiorTemp?.round();
    final exterior = latest.exteriorTemp?.round();
    final speed = latest.speed == null
        ? null
        : (latest.speed! <= 0
            ? 0
            : (latest.speed! <= 30 ? 1 : 2));

    final parts = <String>[
      'f${fuel ?? '_'}',
      'r${range ?? '_'}',
      'o${odo ?? '_'}',
      'ti${interior ?? '_'}',
      'te${exterior ?? '_'}',
      's${speed ?? '_'}',
    ];
    final hash = parts.join('|');

    final labelParts = <String>[];
    if (fuel != null) labelParts.add('油量$fuel%');
    if (range != null) labelParts.add('续航${range}km');
    if (odo != null) labelParts.add('总里程$odo km');
    if (interior != null) labelParts.add('车内$interior℃');

    return SnapshotDigest._(
      fuelPercent: fuel,
      rangeKm: range,
      odometerKm: odo,
      interiorTemp: interior,
      exteriorTemp: exterior,
      speedBucket: speed,
      hash: hash,
      label: labelParts.isEmpty ? '（无关键数据）' : labelParts.join(' / '),
    );
  }

  /// hash 字符串相等 = 数据指纹完全相同。
  bool isSameAs(SnapshotDigest other) =>
      hash.isNotEmpty && hash == other.hash;

  /// **车况关键字段**是否一致 —— 只比油量/续航/里程/速度档。
  ///
  /// 刻意忽略车内/车外温度：停着不动也会随日照波动，不能当"车况变了"。
  /// 自动总结的触发门槛用这个，避免每次开 App 都因 0.5℃ 抖动烧 token。
  bool isVehicleUnchangedFrom(SnapshotDigest other) {
    return fuelPercent == other.fuelPercent &&
        rangeKm == other.rangeKm &&
        odometerKm == other.odometerKm &&
        speedBucket == other.speedBucket;
  }

  /// 相对 [other] 是否**明显变化**（值得立刻自动总结）。
  ///
  /// 阈值：油量 ±5%、里程 ±5km（跑了一小段）、续航 ±50km。
  /// 轻微漂移不算，留给 stale 刷新窗口。
  bool isSignificantChangeFrom(SnapshotDigest other) {
    final fuelDiff = ((fuelPercent ?? 0) - (other.fuelPercent ?? 0)).abs();
    final odoDiff = ((odometerKm ?? 0) - (other.odometerKm ?? 0)).abs();
    final rangeDiff = ((rangeKm ?? 0) - (other.rangeKm ?? 0)).abs();
    return fuelDiff >= 5 || odoDiff >= 5 || rangeDiff >= 50;
  }

  /// 各字段差值都在容差内，用于"小变化但没必要重跑"的场景。
  ///
  /// 默认容差：油量 ±2%、续航 ±20km(2 桶)、里程 ±1km、温度 ±1℃、速度同档。
  bool isSimilarTo(SnapshotDigest other) {
    if (hash.isEmpty || other.hash.isEmpty) return false;
    if ((fuelPercent ?? 0) - (other.fuelPercent ?? 0) > 2) return false;
    if ((other.fuelPercent ?? 0) - (fuelPercent ?? 0) > 2) return false;
    if ((rangeKm ?? 0) - (other.rangeKm ?? 0) > 20) return false;
    if ((other.rangeKm ?? 0) - (rangeKm ?? 0) > 20) return false;
    if ((odometerKm ?? 0) - (other.odometerKm ?? 0) > 1) return false;
    if ((other.odometerKm ?? 0) - (odometerKm ?? 0) > 1) return false;
    if ((interiorTemp ?? 0) - (other.interiorTemp ?? 0) > 1) return false;
    if ((other.interiorTemp ?? 0) - (interiorTemp ?? 0) > 1) return false;
    if ((exteriorTemp ?? 0) - (other.exteriorTemp ?? 0) > 1) return false;
    if ((other.exteriorTemp ?? 0) - (exteriorTemp ?? 0) > 1) return false;
    if (speedBucket != other.speedBucket) return false;
    return true;
  }

  Map<String, Object?> toJson() => {
        'h': hash,
        'l': label,
        // 数值字段必须一起落盘：fromJson 若只回填 hash，
        // isSimilarTo 会拿 null 当 0 比，永远判"不相似"，
        // 「变化不大 30 分钟内跳过」这条去重就失效了。
        'f': fuelPercent,
        'r': rangeKm,
        'o': odometerKm,
        'ti': interiorTemp,
        'te': exteriorTemp,
        's': speedBucket,
      };

  static SnapshotDigest fromJson(Object? raw) {
    if (raw is! Map) return empty;
    final h = raw['h'];
    final l = raw['l'];
    if (h is! String || h.isEmpty) return empty;
    return SnapshotDigest._(
      fuelPercent: (raw['f'] as num?)?.toInt(),
      rangeKm: (raw['r'] as num?)?.toInt(),
      odometerKm: (raw['o'] as num?)?.toInt(),
      interiorTemp: (raw['ti'] as num?)?.toInt(),
      exteriorTemp: (raw['te'] as num?)?.toInt(),
      speedBucket: (raw['s'] as num?)?.toInt(),
      hash: h,
      label: l is String ? l : '',
    );
  }
}

/// 一次 AI 总结的结果
class AiReport {
  const AiReport({
    required this.text,
    required this.atMs,
    this.dataTs,
    this.digest,
  });

  /// 模型输出的 Markdown 原文
  final String text;

  /// 本地生成时间（毫秒时间戳）
  final int atMs;

  /// 生成时所依据的**数据时间**。分析历史快照时意义不大，留作占位
  final int? dataTs;

  /// 第 9 轮新增：本次总结所基于的最新快照指纹，用于去重判断
  final SnapshotDigest? digest;

  DateTime get at => DateTime.fromMillisecondsSinceEpoch(atMs);

  AiReport copyWith({
    String? text,
    int? atMs,
    int? dataTs,
    SnapshotDigest? digest,
  }) {
    return AiReport(
      text: text ?? this.text,
      atMs: atMs ?? this.atMs,
      dataTs: dataTs ?? this.dataTs,
      digest: digest ?? this.digest,
    );
  }

  Map<String, Object?> toJson() => {
        'text': text,
        'at': atMs,
        if (dataTs != null) 'data_ts': dataTs,
        if (digest != null) 'digest': digest!.toJson(),
      };

  /// 从 prefs 里的 JSON 串还原；任何异常都返回 null（坏数据不能让首页崩）
  static AiReport? decode(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return null;
    try {
      final d = jsonDecode(raw);
      if (d is! Map) return null;
      final text = d['text'];
      if (text is! String || text.trim().isEmpty) return null;
      return AiReport(
        text: text,
        atMs: (d['at'] as num?)?.toInt() ?? 0,
        dataTs: (d['data_ts'] as num?)?.toInt(),
        digest: SnapshotDigest.fromJson(d['digest']),
      );
    } catch (_) {
      return null;
    }
  }

  String encode() => jsonEncode(toJson());
}

/// saveSummary 的返回结果 —— 让调用方知道本次**到底发生了什么**，
/// 方便 UI 提示"数据无变化，已跳过"或"覆盖了上一次"。
class SaveSummaryOutcome {
  const SaveSummaryOutcome({required this.action, this.report});

  /// 'inserted'         — 新增了一条（数据变化足够大）
  /// 'overridden'       — 同 text 在 5 分钟内，覆盖了最新一条（用户连点两次）
  /// 'skipped_unchanged' — digest 完全相同，跳过保存
  /// 'skipped_similar'  — digest 相似 + 30 分钟内，跳过保存（变化不大）
  final String action;

  /// 当 action 是 'inserted' / 'overridden' 时是本次写入的对象；
  /// 'skipped_*' 时是被跳过的最新一条（用于 UI 提示"已存在"）。
  final AiReport? report;

  bool get saved => action == 'inserted' || action == 'overridden';

  String get skippedReasonLabel {
    switch (action) {
      case 'skipped_unchanged':
        return '数据无变化，已跳过';
      case 'skipped_similar':
        return '变化不大，30 分钟内已总结过';
      default:
        return '';
    }
  }
}

class AiReportStore {
  AiReportStore._();

  /// 键形如 `mymg.ai.last.summary.<VIN>`（shared_preferences 会自动加 `flutter.` 前缀）
  static const String _prefix = 'mymg.ai.last.summary.';

  /// 本地最多存多少条 —— 防止 prefs 越来越大
  static const int _maxKept = 10;

  /// 5 分钟内同 text 视为重复（已有逻辑）
  static const int _sameTextWindowMs = 5 * 60 * 1000;

  /// 数据相似时，30 分钟内不重复总结
  static const int _similarWindowMs = 30 * 60 * 1000;

  static String _key(String vin) => '$_prefix$vin';

  /// 读「最近 N 条」总结（最新在前），N ≤ [_maxKept]。
  ///
  /// 自动兼容旧版的「单条 JSON」格式（遇到时返回长度为 1 的列表）。
  static Future<List<AiReport>> loadSummaryList(String vin) async {
    if (vin.isEmpty) return const [];
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key(vin));
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final d = jsonDecode(raw);
      if (d is! Map) return const [];
      // 新格式：`{"items": [AiReport, AiReport, ...]}`
      final items = d['items'];
      if (items is List) {
        final out = <AiReport>[];
        for (final e in items) {
          final r = _fromJsonMap(e);
          if (r != null) out.add(r);
        }
        return out;
      }
      // 旧格式：直接就是单个 AiReport 的字段（text/at/data_ts）
      final single = _fromJsonMap(d);
      if (single != null) return [single];
      return const [];
    } catch (_) {
      return const [];
    }
  }

  /// 从 JSON 解出来的 Map 还原 AiReport；用来代替 `AiReport.decode(String)`
  /// 以免在 loadSummaryList 里做多余的 encode→decode 往返。
  static AiReport? _fromJsonMap(Object? raw) {
    if (raw is! Map) return null;
    final text = raw['text'];
    if (text is! String || text.trim().isEmpty) return null;
    return AiReport(
      text: text,
      atMs: (raw['at'] as num?)?.toInt() ?? 0,
      dataTs: (raw['data_ts'] as num?)?.toInt(),
      digest: SnapshotDigest.fromJson(raw['digest']),
    );
  }

  /// 读最新一条（没有就 null）—— 给只关心"现在内容"的调用方省事
  static Future<AiReport?> loadLatestSummary(String vin) async {
    final list = await loadSummaryList(vin);
    return list.isEmpty ? null : list.first;
  }

  /// 写入：分四档处理，详见 [SaveSummaryOutcome]。
  ///
  /// ## 三档去重（2026-09-10 用户要求"变化不大就把类似的清掉"）
  ///
  /// 1. **同 text + 5 分钟内** → 覆盖最新一条（用户连点两次"重新总结"）
  /// 2. **digest 完全相同** → 跳过保存，**不更新时间戳**
  ///    （防止每 5 分钟自动跑都新建一条完全一样的）
  /// 3. **digest 相似 + 30 分钟内** → 跳过保存，**不更新时间戳**
  ///    （"变化不大"）
  /// 4. **其他** → 插到最前，截断到 [_maxKept] 条
  static Future<SaveSummaryOutcome> saveSummary(
    String vin,
    AiReport report, {
    SnapshotDigest? digest,
    /// true：绕过「相似 30 分钟」跳过（冷启动自动总结用）
    bool force = false,
  }) async {
    if (vin.isEmpty) {
      return SaveSummaryOutcome(action: 'inserted', report: report);
    }
    final list = (await loadSummaryList(vin)).toList();
    final now = report.atMs;

    // 1) 同 text + 5 分钟内 → 覆盖最新一条
    if (list.isNotEmpty &&
        list.first.text == report.text &&
        (now - list.first.atMs).abs() < _sameTextWindowMs) {
      final updated = report.copyWith(digest: digest);
      list[0] = updated;
      await _persist(vin, list);
      return SaveSummaryOutcome(action: 'overridden', report: updated);
    }

    // 2) digest 完全相同 → 跳过（数据真的没变）
    final latestDigest = list.isEmpty ? null : list.first.digest;
    if (digest != null &&
        latestDigest != null &&
        digest.isSameAs(latestDigest)) {
      return SaveSummaryOutcome(
        action: 'skipped_unchanged',
        report: list.first,
      );
    }

    // 3) digest 相似 + 30 分钟内 → 跳过（变化不大）；force 时不跳
    if (!force &&
        digest != null &&
        latestDigest != null &&
        digest.isSimilarTo(latestDigest) &&
        list.isNotEmpty &&
        (now - list.first.atMs).abs() < _similarWindowMs) {
      return SaveSummaryOutcome(
        action: 'skipped_similar',
        report: list.first,
      );
    }

    // 4) 正常插入
    final reportWithDigest = report.copyWith(digest: digest);
    list.insert(0, reportWithDigest);
    final capped = list.length > _maxKept ? list.sublist(0, _maxKept) : list;
    await _persist(vin, capped);
    return SaveSummaryOutcome(action: 'inserted', report: reportWithDigest);
  }

  static Future<void> _persist(String vin, List<AiReport> list) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _key(vin),
      jsonEncode({
        'items': list.map((e) => e.toJson()).toList(),
      }),
    );
  }

  /// 清空（换车 / 退出登录时用）
  static Future<void> clearSummary(String vin) async {
    if (vin.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    await p.remove(_key(vin));
  }
}

/// 一次「要不要自动跑 AI」的判定结果。
class AiAutoDecision {
  const AiAutoDecision._({required this.shouldRun, required this.note, this.significant = false});

  /// 跑（或跳过）的简短原因，可直接展示在 AI 卡状态栏。
  final String note;
  final bool shouldRun;

  /// 是否属于「明显变化」（可突破最小间隔）。
  final bool significant;

  factory AiAutoDecision.run(String note, {bool significant = false}) =>
      AiAutoDecision._(shouldRun: true, note: note, significant: significant);

  factory AiAutoDecision.skip(String note) =>
      AiAutoDecision._(shouldRun: false, note: note);
}

/// 自动总结时机策略（纯函数，便于单测）。
///
/// 目标：在**最合适**的时候自动生成，而不是"一打开 App 就跑"：
///   1. 首次（还没有总结）→ 跑
///   2. 车况关键字段（油量/续航/里程/速度）明显变化 → 立刻跑
///   3. 车况没变（温度/天气波动）→ 不跑，沿用上次结论
///   4. 轻微变化也受 [minInterval] / [similarWindow] 限流，避免频繁烧 token
class AiAutoPolicy {
  /// 两次自动总结的最小间隔（明显变化除外）。
  static const Duration minInterval = Duration(hours: 2);

  /// 「变化不大」的静默窗口（与 saveSummary 的 similar 档对齐）。
  static const Duration similarWindow = Duration(minutes: 30);

  static AiAutoDecision decide({
    required AiReport? lastReport,
    required SnapshotDigest current,
    required DateTime now,
    Duration minInterval = minInterval,
    Duration similarWindow = similarWindow,
  }) {
    if (current.hash.isEmpty) {
      return AiAutoDecision.skip('暂无快照可分析');
    }
    if (lastReport == null) {
      return AiAutoDecision.run('生成首份车况解读', significant: true);
    }

    final lastDigest = lastReport.digest;
    final age = now.difference(
      DateTime.fromMillisecondsSinceEpoch(lastReport.atMs),
    );
    final vehicleChanged = lastDigest == null ||
        !current.isVehicleUnchangedFrom(lastDigest);

    // 车况关键字段没动：温度波动不触发，也不为同一份数据反复调大模型
    if (!vehicleChanged) {
      return AiAutoDecision.skip('车况无变化，沿用上次总结');
    }

    // 明显变化（跑了一段 / 油量明显升降）→ 立刻跑，不受 minInterval 限制
    final significant =
        lastDigest == null || current.isSignificantChangeFrom(lastDigest);
    if (significant) {
      return AiAutoDecision.run('车况明显变化，自动更新解读', significant: true);
    }

    // 轻微变化 + 刚总结过 → 再等等
    if (age < similarWindow) {
      return AiAutoDecision.skip('变化不大，${similarWindow.inMinutes} 分钟内已总结过');
    }
    if (age < minInterval) {
      return AiAutoDecision.skip('距上次自动总结不足 ${minInterval.inHours} 小时');
    }
    return AiAutoDecision.run('车况已更新，自动更新解读');
  }
}
