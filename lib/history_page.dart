// 历史数据页（路线 A Day 3a + Day 4 + Day 7+ 第 8 轮）
//
// 两 Tab 设计：
//   - 「趋势」：fl_chart 折线图 + 本地「变化概览」+ **AI 车况解读**板块（最新 + 最近 3 条）
//   - 「记录」：原始快照列表（按时间倒序）
//
// 第 8 轮重整（用户反馈：AI 卡才是历史+AI 的合一口子，HOME 卡做 peek，
// 这里做完整）：
//   - HOME 页 _AiEntryCard 只展示「横向关键数据 + 2 行最新总结」作为 peek，
//     点卡片任意位置 → 跳到这里；
//   - 历史页底部追加 _AiSummarySection：完整 Markdown 最新 + 3 条历史
//     可点开查看（read-only 弹层），外加「重新总结」按钮（手动重跑 AI）。

import 'package:flutter/material.dart';
import 'theme_controller.dart';

import 'package:mymg/src/rust/api.dart';

import 'ai_report_store.dart';
import 'ai_service.dart';
import 'ai_widgets.dart';
import 'err_util.dart';
import 'history_export.dart';
import 'store.dart';
import 'summary_cache.dart';
import 'trend_chart.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({
    super.key,
    required this.token,
    required this.vin,
  });
  final String token;
  final String vin;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);

  /// 按时间 **倒序**（最新在前），与 listByRange 返回一致
  List<SnapshotRow> _rows = const [];
  bool _loading = true;
  bool _capturing = false;
  String? _error;

  /// 趋势图需要时间正序
  List<SnapshotRow> get _rowsAsc => _rows.reversed.toList(growable: false);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final store = SnapshotStore.instance;
      // 先确保 DB 已初始化（用一次 count 触发 open）
      await store.count(widget.vin);
      final rows = await store.listByRange(vin: widget.vin, limit: 2000);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 立即向服务端拉一次车况并写入本地快照 —— 免去回主页下拉
  Future<void> _captureNow() async {
    if (_capturing) return;
    setState(() => _capturing = true);
    try {
      // 手动记录快照：必须唤醒车辆拿实时，不吃缓存
      final s = await SummaryCache.fetch(
        token: widget.token,
        vin: widget.vin,
        force: true,
      );
      await SnapshotStore.instance.insertFromSummary(s, vin: widget.vin);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已记录一条快照')),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('记录失败：${formatFrbError(e)}')),
      );
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _cleanOld() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清理 30 天前的快照？'),
        content: const Text(
          '历史曲线需要连续数据，请确认不再需要看 30 天前的曲线再清理。\n'
          '清理仅限本机数据，不影响服务端。',
          style: TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清理')),
        ],
      ),
    );
    if (ok != true) return;
    final n =
        await SnapshotStore.instance.cleanOlderThan(days: 30, vin: widget.vin);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已删除 $n 条')),
    );
    await _load();
  }

  Future<void> _exportCsv() async {
    try {
      final rows = await SnapshotStore.instance.listByRange(
        vin: widget.vin,
        limit: 100000,
      );
      if (rows.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('还没有历史数据可导出')),
        );
        return;
      }
      await HistoryExport.shareCsv(rows: rows, vin: widget.vin);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    }
  }

  Future<void> _deleteAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除全部本地快照？'),
        content: const Text('本机数据库的所有快照将清空，无法恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final n = await SnapshotStore.instance.deleteAll(widget.vin);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已删除 $n 条')),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('历史数据'),
        actions: [
          IconButton(
            tooltip: '立即记录一条',
            icon: _capturing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_circle_outline),
            onPressed: _capturing ? null : _captureNow,
          ),
          IconButton(
            tooltip: '清理 30 天前',
            icon: const Icon(Icons.cleaning_services_outlined),
            onPressed: _cleanOld,
          ),
          IconButton(
            tooltip: '导出 CSV',
            icon: const Icon(Icons.ios_share_outlined),
            onPressed: _exportCsv,
          ),
          IconButton(
            tooltip: '删除全部',
            icon: const Icon(Icons.delete_outline),
            onPressed: _deleteAll,
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: '趋势', icon: Icon(Icons.show_chart, size: 18)),
            Tab(text: '记录', icon: Icon(Icons.list_alt, size: 18)),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildError()
              : TabBarView(
                  controller: _tab,
                  children: [
                    _buildTrend(),
                    _buildList(),
                  ],
                ),
    );
  }

  Widget _tripStat(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 11, color: AppPalette.muted)),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppPalette.strong,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 56, color: AppPalette.muted),
              const SizedBox(height: 8),
              Text('读取失败：$_error',
                  style: TextStyle(color: AppPalette.strong)),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      ],
    );
  }

  // ── Tab 1：趋势（图表 + 行程摘要 + 变化概览 + 统计） ──
  Widget _buildTrend() {
    if (_rows.isEmpty) return _buildEmpty();
    final ov = _ChangeOverview.of(_rows);

    // 行程摘要：本机快照内可估的行程总和与里程跨度
    double journeySum = 0;
    int journeySamples = 0;
    double? odoFirst;
    double? odoLast;
    for (final r in _rows) {
      final j = r.journeyKm;
      if (j != null && j > 0) {
        journeySum += j;
        journeySamples += 1;
      }
      final o = r.odometerKm;
      if (o != null) {
        odoFirst ??= o;
        odoLast = o;
      }
    }
    final odoSpan =
        (odoFirst != null && odoLast != null) ? (odoLast - odoFirst) : null;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: _tripStat(
                      '快照条数',
                      '${_rows.length}',
                    ),
                  ),
                  Container(width: 1, height: 28, color: AppPalette.track),
                  Expanded(
                    child: _tripStat(
                      '行程合计',
                      journeySamples > 0
                          ? '${journeySum.toStringAsFixed(1)} km'
                          : '—',
                    ),
                  ),
                  Container(width: 1, height: 28, color: AppPalette.track),
                  Expanded(
                    child: _tripStat(
                      '里程跨度',
                      odoSpan != null
                          ? '${odoSpan.toStringAsFixed(0)} km'
                          : '—',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          TrendChart(rows: _rowsAsc),
          const SizedBox(height: 12),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.insights, size: 20, color: AppPalette.info),
                      SizedBox(width: 8),
                      Text('变化概览',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AppPalette.strong)),
                      const Spacer(),
                      Text('${ov.count} 个数据点',
                          style: TextStyle(
                              fontSize: 12, color: AppPalette.muted)),
                    ],
                  ),
                  SizedBox(height: 4),
                  Text(ov.spanText,
                      style: TextStyle(
                          fontSize: 12, color: AppPalette.muted)),
                  const Divider(height: 20),
                  ...ov.items.map(_deltaRow),
                ],
              ),
            ),
          ),

          SizedBox(height: 12),

          // ★ 第 8 轮：历史数据 + AI 车况解读（最新 + 3 条历史）。
          //   进到这里时如果上次回主页刚跑过总结，能直接看到完整内容。
          _AiSummarySection(vin: widget.vin),

          SizedBox(height: 24),
          Center(
            child: Text(
              '共 ${_rows.length} 个数据点 · 最早 ${_fmtFull(_rows.last.capturedAtDt)}',
              style: TextStyle(fontSize: 12, color: AppPalette.subtle),
            ),
          ),
          SizedBox(height: 32),
        ],
      ),
    );
  }

  // ── Tab 2：记录列表 ──
  Widget _buildList() {
    if (_rows.isEmpty) return _buildEmpty();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _rows.length + 1,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (ctx, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Text('共 ${_rows.length} 条快照',
                      style: TextStyle(
                          fontWeight: FontWeight.w600, color: AppPalette.strong)),
                  SizedBox(width: 8),
                  Text('（按时间倒序）',
                      style: TextStyle(color: AppPalette.muted, fontSize: 12)),
                ],
              ),
            );
          }
          return _rowTile(_rows[i - 1]);
        },
      ),
    );
  }

  /// 概览里的一行：标签 + 从→到 + 变化量（带方向配色）
  Widget _deltaRow(_Delta d) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 66,
              child: Text(d.label,
                  style: TextStyle(fontSize: 13, color: AppPalette.muted)),
            ),
            Expanded(
              child: Text(
                d.value,
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w500),
              ),
            ),
            if (d.delta != null)
              Text(d.delta!,
                  style: TextStyle(
                      fontSize: 12.5, color: d.color, fontWeight: FontWeight.w600)),
          ],
        ),
      );

  Widget _buildEmpty() {
    return ListView(
      children: [
        Padding(
          padding: EdgeInsets.all(40),
          child: Column(
            children: [
              Icon(Icons.timeline, size: 64, color: AppPalette.muted),
              SizedBox(height: 12),
              Text('本机还没有历史快照',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppPalette.strong)),
              SizedBox(height: 6),
              Text(
                '点右上角 ⊕ 立即记录一条，\n或回主页下拉刷新（每次自动存一条）。',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppPalette.muted, height: 1.5),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _rowTile(SnapshotRow r) {
    final dt = r.capturedAtDt;
    final ts =
        '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history, size: 16, color: AppPalette.info),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    ts,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: AppPalette.strong,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 6,
              children: [
                if (r.fuelPercent != null)
                  _chip('油量', '${r.fuelPercent}%'),
                if (r.rangeKm != null) _chip('续航', '${r.rangeKm}km'),
                if (r.odometerKm != null)
                  _chip('里程', '${r.odometerKm!.toStringAsFixed(0)}km'),
                if (r.interiorTemp != null)
                  _chip('车内', '${r.interiorTemp!.toStringAsFixed(0)}°C'),
                if (r.exteriorTemp != null)
                  _chip('车外', '${r.exteriorTemp!.toStringAsFixed(0)}°C'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String k, String v) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppPalette.chipBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$k $v',
        style: TextStyle(fontSize: 12, color: AppPalette.strong),
      ),
    );
  }

  Widget _kv(String k, String v) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$k ',
              style: TextStyle(color: AppPalette.muted, fontSize: 12)),
          Text(v,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
        ],
      );

  String _fmtFull(DateTime dt) =>
      '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}

// ── 本地「变化概览」（不花 token） ──────────────────────────────────────
//
// 先在本地把「有变化的项」算出来给用户看（瞬时），
// 想知道原因 / 建议就回到首页 AI 卡点「重新总结」（要花 token）。

class _Delta {
  const _Delta(this.label, this.value, {this.delta, this.color = const Color(0xFF5C5C5C)});
  final String label;
  final String value;
  final String? delta;
  final Color color;
}

class _ChangeOverview {
  _ChangeOverview({
    required this.count,
    required this.spanText,
    required this.items,
  });

  final int count;
  final String spanText;
  final List<_Delta> items;

  static _ChangeOverview of(List<SnapshotRow> desc) {
    final asc = desc.reversed.toList(growable: false);
    final a = asc.first;
    final b = asc.last;

    num? diff(num? x, num? y) => (x == null || y == null) ? null : (y - x);

    final fuelD = diff(a.fuelPercent, b.fuelPercent);
    final rangeD = diff(a.rangeKm, b.rangeKm);
    final odoD = diff(a.odometerKm, b.odometerKm);

    final interior =
        asc.map((e) => e.interiorTemp).whereType<double>().toList();
    final exterior =
        asc.map((e) => e.exteriorTemp).whereType<double>().toList();

    // 位置变化次数（5 位小数 ≈ 1m 精度）
    String? prev;
    var moves = 0;
    for (final r in asc) {
      if (r.latitude == null || r.longitude == null) continue;
      final cur = '${r.latitude},${r.longitude}';
      if (prev != null && cur != prev) moves++;
      prev = cur;
    }

    // 温度剔除极端噪声（传感器未上电时会返回 -40 / 85 之类）
    double? lo(List<double> v) {
      final ok = v.where((e) => e > -30 && e < 70).toList();
      if (ok.isEmpty) return null;
      return ok.reduce((p, q) => p < q ? p : q);
    }

    double? hi(List<double> v) {
      final ok = v.where((e) => e > -30 && e < 70).toList();
      if (ok.isEmpty) return null;
      return ok.reduce((p, q) => p > q ? p : q);
    }

    String pct(num? v) => v == null ? '—' : '${v.toInt()}%';
    String km(num? v) => v == null ? '—' : '${v.toInt()} km';

    Color dropUpGood(num? d) => d == null
        ? AppPalette.muted
        : (d < 0 ? AppPalette.warn : AppPalette.ok);

    final items = <_Delta>[
      _Delta('油量', '${pct(a.fuelPercent)} → ${pct(b.fuelPercent)}',
          delta: fuelD == null || fuelD == 0 ? null : '${fuelD > 0 ? '+' : ''}$fuelD%',
          color: dropUpGood(fuelD)),
      _Delta('续航', '${km(a.rangeKm)} → ${km(b.rangeKm)}',
          delta: rangeD == null || rangeD == 0
              ? null
              : '${rangeD > 0 ? '+' : ''}${rangeD.toInt()} km',
          color: dropUpGood(rangeD)),
      _Delta('总里程',
          '${a.odometerKm?.toStringAsFixed(0) ?? '—'} → ${b.odometerKm?.toStringAsFixed(0) ?? '—'} km',
          delta: odoD == null || odoD.abs() < 0.05
              ? null
              : '区间行驶 ${odoD.abs().toStringAsFixed(1)} km',
          color: odoD == null
              ? AppPalette.muted
              : (odoD < 0 ? AppPalette.danger : AppPalette.info)),
      _Delta(
        '车内温度',
        (lo(interior) == null || hi(interior) == null)
            ? '无有效数据'
            : '${lo(interior)!.toStringAsFixed(0)} ~ ${hi(interior)!.toStringAsFixed(0)} ℃',
        delta: (lo(interior) == null || hi(interior) == null)
            ? null
            : '波动 ${(hi(interior)! - lo(interior)!).toStringAsFixed(0)} ℃',
        color: Colors.blueGrey.shade600,
      ),
      _Delta(
        '车外温度',
        (lo(exterior) == null || hi(exterior) == null)
            ? '无有效数据'
            : '${lo(exterior)!.toStringAsFixed(0)} ~ ${hi(exterior)!.toStringAsFixed(0)} ℃',
        color: Colors.blueGrey.shade600,
      ),
      _Delta('停放位置', moves == 0 ? '全程同一位置' : '共 $moves 次位置变化',
          color: moves == 0 ? AppPalette.ok : AppPalette.warn),
    ];

    final span = b.capturedAtDt.difference(a.capturedAtDt);
    final spanStr = span.inMinutes < 60
        ? '${span.inMinutes} 分钟'
        : (span.inHours < 24
            ? '${span.inHours} 小时'
            : '${span.inDays} 天${span.inHours - span.inDays * 24 == 0 ? '' : ' ${span.inHours - span.inDays * 24} 小时'}');

    return _ChangeOverview(
      count: desc.length,
      spanText: '${_f(a.capturedAtDt)} → ${_f(b.capturedAtDt)} · 跨度 $spanStr',
      items: items,
    );
  }

  static String _f(DateTime d) =>
      '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

// ── AI 车况解读板块（历史页底部） ─────────────────────────────────────
//
// 第 8 轮：HOME 卡的 _AiEntryCard 已经做了"横向数据 + 2 行最新总结"的 peek；
//          点进来后，历史页底部新增这块——完整 Markdown 最新 + 历史 3 条可点开。
//
// 数据来源：与 HomePage 共享 AiReportStore（key = `mymg.ai.last.summary.<VIN>`），
// 所以 HOME 自动跑完 → 进这里立刻能看到，不需要再等。
//
// 独立持有自己的 _history 状态：刷新、重新总结、回 HOME 再回来都会 reload。

class _AiSummarySection extends StatefulWidget {
  const _AiSummarySection({required this.vin});
  final String vin;

  @override
  State<_AiSummarySection> createState() => _AiSummarySectionState();
}

class _AiSummarySectionState extends State<_AiSummarySection> {
  List<AiReport> _history = const [];
  bool _loading = false;
  String? _runError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _AiSummarySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // vin 没变 + key 不变（无切换场景），不重读；
    // 历史页被 push 多次回来时 onResume 触发 _load()——见 _HistoryPageState。
  }

  /// 由父级（HISTORY 页）从外部调用：
  ///   下拉刷新、回到前台、跑完 AI 后需要重新拿一次缓存。
  void reloadFromOutside() => _load();

  Future<void> _load() async {
    try {
      final list = await AiReportStore.loadSummaryList(widget.vin);
      if (!mounted) return;
      setState(() => _history = list);
    } catch (_) {
      // 缓存坏了当没有，不影响展示
    }
  }

  /// 在历史页内手动"重新总结"：拉全量快照 → 调大模型 → 写回缓存 → 刷新本地列表。
  ///
  /// **第 9 轮**：算 SnapshotDigest，三档去重——
  /// ① 数据完全没变 → 跳过；② 变化不大且 30 分钟内 → 跳过；
  /// ③ 其它 → 写入。UI 上无论哪档都给个轻提示，区分清楚"已更新 / 已跳过"。
  Future<void> _runAgain() async {
    if (_loading) return;
    // 默认近 24 小时；用户可选更长
    final since = await showModalBottomSheet<Duration>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text('分析时间段',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            ),
            ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text('最近 24 小时'),
              subtitle: const Text('推荐：省 token、速度快'),
              onTap: () => Navigator.pop(ctx, const Duration(hours: 24)),
            ),
            ListTile(
              leading: const Icon(Icons.date_range),
              title: const Text('最近 3 天'),
              onTap: () => Navigator.pop(ctx, const Duration(days: 3)),
            ),
            ListTile(
              leading: const Icon(Icons.date_range),
              title: const Text('最近 7 天'),
              onTap: () => Navigator.pop(ctx, const Duration(days: 7)),
            ),
            ListTile(
              leading: const Icon(Icons.all_inclusive),
              title: const Text('全部历史'),
              onTap: () => Navigator.pop(ctx, const Duration(days: 3650)),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (since == null || !mounted) return;

    setState(() {
      _loading = true;
      _runError = null;
    });
    try {
      final fromMs = DateTime.now().subtract(since).millisecondsSinceEpoch;
      final rows = await SnapshotStore.instance
          .listByRange(vin: widget.vin, fromMs: fromMs, limit: 2000);
      if (rows.isEmpty) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _runError = '所选时段内没有历史快照，先回主页下拉刷新几次再试。';
        });
        return;
      }
      final digest = SnapshotDigest.fromLatest(rows);

      // 提前检查"数据完全没变"——不调大模型
      final latest = await AiReportStore.loadLatestSummary(widget.vin);
      if (latest != null &&
          latest.digest != null &&
          digest.isSameAs(latest.digest!)) {
        if (!mounted) return;
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('数据无变化，跳过本次 AI 总结'),
            duration: Duration(seconds: 3),
          ),
        );
        return;
      }

      final text = await AiService.instance.analyzeHistory(
        rows,
        vin: widget.vin,
      );
      if (!mounted) return;
      final outcome = await AiReportStore.saveSummary(
        widget.vin,
        AiReport(text: text, atMs: DateTime.now().millisecondsSinceEpoch),
        digest: digest,
      );
      await _load();
      if (!mounted) return;
      setState(() => _loading = false);
      final rangeLabel = since.inDays >= 365
          ? '全部'
          : since.inHours < 24
              ? '近 ${since.inHours} 小时'
              : '近 ${since.inDays} 天';
      final msg = outcome.saved
          ? 'AI 车况已更新（$rangeLabel）'
          : (outcome.skippedReasonLabel.isEmpty
              ? 'AI 车况未保存'
              : outcome.skippedReasonLabel);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } on AiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _runError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _runError = e.toString();
      });
    }
  }

  /// 打开任意一条历史总结做只读查看（首页"最近总结"用的也是这个弹层）
  void _openReport(AiReport r) {
    showAiReport(
      context,
      title: 'AI 车况 · 历史总结',
      initialText: r.text,
    );
  }

  AiReport? get _latest => _history.isEmpty ? null : _history.first;

  /// 取「历史 3 条」——不含最新那条，按时间倒序展示
  List<AiReport> get _past => _history.length > 1
      ? _history.sublist(1, _history.length > 4 ? 4 : _history.length)
      : const [];

  @override
  Widget build(BuildContext context) {
    final latest = _latest;
    final past = _past;
    // 以 ThemeData 亮度为准，避免 ThemeController 与系统亮度不同步时白底浅字
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cardBg =
        dark ? const Color(0xFF1E1A2A) : const Color(0xFFFBFAFF);
    final fg = dark ? const Color(0xFFF5F5F7) : const Color(0xFF1A1A1E);
    final sub = dark ? const Color(0xFFB0B0B8) : const Color(0xFF5C5C5C);
    return Card(
      color: cardBg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题行
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF7B4DFF), Color(0xFF4D9BFF)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(Icons.auto_awesome,
                      color: Colors.white, size: 19),
                ),
                const SizedBox(width: 10),
                    Expanded(
                      child: Text('AI 车况解读',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: fg)),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _loading ? null : _runAgain,
                      icon: _loading
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(Icons.refresh, size: 16),
                      label: Text('重新总结'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        minimumSize: const Size(0, 34),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
              ],
            ),

            // 最新一条完整 Markdown
            SizedBox(height: 10),
            if (_loading && latest == null)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '正在调用大模型分析…首次响应通常 5~20 秒',
                        style: TextStyle(
                            fontSize: 12.5, color: AppPalette.muted),
                      ),
                    ),
                  ],
                ),
              )
            else if (latest != null) ...[
              Builder(builder: (context) {
                final dark =
                    Theme.of(context).brightness == Brightness.dark;
                final fg =
                    dark ? const Color(0xFFF5F5F7) : const Color(0xFF1A1A1E);
                final sub =
                    dark ? const Color(0xFFB0B0B8) : const Color(0xFF5C5C5C);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AiMarkdownText(latest.text, fontSize: 13.5, color: fg),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '基于 ${_latest!.at.month.toString().padLeft(2, '0')}-'
                        '${_latest!.at.day.toString().padLeft(2, '0')} '
                        '${_latest!.at.hour.toString().padLeft(2, '0')}:'
                        '${_latest!.at.minute.toString().padLeft(2, '0')} '
                        '生成的总结',
                        style: TextStyle(fontSize: 11, color: sub),
                      ),
                    ),
                  ],
                );
              }),
            ] else
              Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  '暂无 AI 总结。首次启动会自动跑一次（需已在设置里配好 AI）。',
                  style: TextStyle(color: AppPalette.muted, height: 1.5),
                ),
              ),

            if (_runError != null && !_loading) ...[
              SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppPalette.dangerBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '本次总结失败：$_runError',
                    style: TextStyle(
                        fontSize: 12, color: AppPalette.danger)),
              ),
            ],

            // 历史 3 条
            if (past.isNotEmpty) ...[
              SizedBox(height: 14),
              const Divider(height: 12),
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 6),
                child: Row(
                  children: [
                    Icon(Icons.history, size: 14, color: AppPalette.subtle),
                    SizedBox(width: 6),
                    Text('历史解读',
                        style: TextStyle(
                            fontSize: 12, color: AppPalette.muted)),
                  ],
                ),
              ),
              ...past.map((r) => _PastSummaryRow(
                    report: r,
                    onTap: () => _openReport(r),
                  )),
            ],
          ],
        ),
      ),
    );
  }
}

/// 「历史解读」列表里的一行：时间 + 一行预览
class _PastSummaryRow extends StatelessWidget {
  const _PastSummaryRow({required this.report, required this.onTap});
  final AiReport report;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dt = report.at;
    final when = '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
    final preview = report.text
        .split('\n')
        .map((l) => l.trim())
        .firstWhere(
          (l) => l.isNotEmpty && !l.startsWith('#'),
          orElse: () => '',
        );
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 92,
              child: Text(when,
                  style: TextStyle(
                      fontSize: 12, color: AppPalette.muted)),
            ),
            Expanded(
              child: Text(
                preview,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5),
              ),
            ),
            Icon(Icons.chevron_right, size: 16, color: AppPalette.subtle),
          ],
        ),
      ),
    );
  }
}
