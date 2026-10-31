// 历史趋势折线图（路线 A Day 4）
//
// 把 SQLite 里的快照按时间画成曲线，支持切换指标：
// 油量% / 续航km / 总里程km / 车内温度 / 车外温度 / 单次行程km
//
// 输入 rows 要求 **时间正序**（最旧在前），HistoryPage 会在传入前反转。

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'store.dart';
import 'theme_controller.dart';

/// 可切换的趋势指标
enum TrendMetric {
  fuel('油量', '%'),
  range('续航', 'km'),
  odometer('总里程', 'km'),
  interior('车内温度', '°C'),
  exterior('车外温度', '°C'),
  journey('单次行程', 'km');

  const TrendMetric(this.label, this.unit);
  final String label;
  final String unit;

  /// 从快照取该指标的值；无数据返回 null
  double? pick(SnapshotRow r) {
    switch (this) {
      case TrendMetric.fuel:
        return r.fuelPercent?.toDouble();
      case TrendMetric.range:
        return r.rangeKm?.toDouble();
      case TrendMetric.odometer:
        return r.odometerKm;
      case TrendMetric.interior:
        return r.interiorTemp;
      case TrendMetric.exterior:
        return r.exteriorTemp;
      case TrendMetric.journey:
        return r.journeyKm;
    }
  }

  /// 该指标越小越好？用于给"变化量"上色（油量/续航/里程是消耗，温度中性）
  bool get lowerIsBetter =>
      this == TrendMetric.fuel || this == TrendMetric.range;

  bool get isNeutral =>
      this == TrendMetric.interior || this == TrendMetric.exterior;
}

class TrendChart extends StatefulWidget {
  const TrendChart({
    super.key,
    required this.rows,
    this.defaultMetric = TrendMetric.fuel,
  });

  /// 时间正序的快照列表
  final List<SnapshotRow> rows;
  final TrendMetric defaultMetric;

  @override
  State<TrendChart> createState() => _TrendChartState();
}

class _TrendChartState extends State<TrendChart> {
  late TrendMetric _metric = widget.defaultMetric;

  @override
  Widget build(BuildContext context) {
    // 抽出有效点
    final pts = <FlSpot>[];
    final validRows = <SnapshotRow>[];
    for (var i = 0; i < widget.rows.length; i++) {
      final v = _metric.pick(widget.rows[i]);
      if (v != null) {
        pts.add(FlSpot(pts.length.toDouble(), v));
        validRows.add(widget.rows[i]);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _metricBar(),
        const SizedBox(height: 12),
        if (pts.length < 2)
          _notEnough(pts.length)
        else ...[
          _statsBar(pts, validRows),
          const SizedBox(height: 12),
          SizedBox(height: 240, child: _chart(pts, validRows)),
        ],
      ],
    );
  }

  // ── 指标切换 ──
  Widget _metricBar() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: TrendMetric.values.map((m) {
        return ChoiceChip(
          label: Text(m.label),
          selected: _metric == m,
          onSelected: (_) => setState(() => _metric = m),
        );
      }).toList(),
    );
  }

  // ── 统计条 ──
  Widget _statsBar(List<FlSpot> pts, List<SnapshotRow> rows) {
    final vals = pts.map((e) => e.y).toList();
    final first = vals.first;
    final last = vals.last;
    final delta = last - first;
    final maxV = vals.reduce((a, b) => a > b ? a : b);
    final minV = vals.reduce((a, b) => a < b ? a : b);
    final avg = vals.reduce((a, b) => a + b) / vals.length;

    final Color deltaColor;
    if (_metric.isNeutral) {
      deltaColor = AppPalette.muted;
    } else if (delta == 0) {
      deltaColor = AppPalette.muted;
    } else if (_metric.lowerIsBetter) {
      deltaColor = delta < 0 ? AppPalette.warn : AppPalette.ok;
    } else {
      deltaColor = delta > 0 ? AppPalette.ok : AppPalette.warn;
    }

    final sign = delta > 0 ? '+' : '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppPalette.chipBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          _stat('最新', '${_fmt(last)}${_metric.unit}',
              color: AppPalette.strong),
          _stat('变化', '$sign${_fmt(delta)}${_metric.unit}', color: deltaColor),
          _stat('最低', _fmt(minV), color: AppPalette.muted),
          _stat('最高', _fmt(maxV), color: AppPalette.muted),
          _stat('平均', _fmt(avg), color: AppPalette.muted),
        ],
      ),
    );
  }

  Widget _stat(String k, String v, {required Color color}) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(k, style: TextStyle(fontSize: 11, color: AppPalette.muted)),
            const SizedBox(height: 2),
            Text(
              v,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: color,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      );

  // ── 折线图本体 ──
  Widget _chart(List<FlSpot> pts, List<SnapshotRow> rows) {
    final vals = pts.map((e) => e.y).toList();
    final maxV = vals.reduce((a, b) => a > b ? a : b);
    final minV = vals.reduce((a, b) => a < b ? a : b);

    // 数据全平时给一个虚拟跨度，否则 log(0) 会炸
    var range = maxV - minV;
    if (range < 1e-9) range = (maxV.abs() * 0.1).clamp(1.0, double.infinity);

    // y 轴刻度取"整数好看"的步长：60/70/80/90 而不是 61/67.3/74.8…
    final stepV = _niceStep(range / 4);
    var minY = ((minV - range * 0.10) / stepV).floor() * stepV;
    final maxY = ((maxV + range * 0.10) / stepV).ceil() * stepV;
    // 数据全为非负（油量/续航/行程）时不要把下界拉到负数
    if (minY < 0 && vals.every((v) => v >= 0)) minY = 0;

    // 底轴标签：按步长取网格点，且最后一个点若离网格太近就不额外加（防重叠）
    final shownIdx = <int>{};
    final xStep = (pts.length / 5).ceil().clamp(1, 999);
    for (var i = 0; i < pts.length; i += xStep) {
      shownIdx.add(i);
    }
    final lastIdx = pts.length - 1;
    final lastGrid = shownIdx.isEmpty ? 0 : shownIdx.reduce(math.max);
    if (lastIdx - lastGrid >= (xStep * 0.7).ceil()) shownIdx.add(lastIdx);

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: (pts.length - 1).toDouble(),
        minY: minY,
        maxY: maxY,
        clipData: const FlClipData.all(),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: stepV,
          getDrawingHorizontalLine: (v) => FlLine(
            color: AppPalette.track,
            strokeWidth: 1,
          ),
        ),
        borderData: FlBorderData(
          show: true,
          border: Border(
            left: BorderSide(color: AppPalette.track),
            bottom: BorderSide(color: AppPalette.track),
            top: BorderSide.none,
            right: BorderSide.none,
          ),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 42,
              interval: stepV,
              getTitlesWidget: (value, meta) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(
                  _fmt(value),
                  style: TextStyle(fontSize: 10, color: AppPalette.muted),
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: 1,
              getTitlesWidget: (value, meta) {
                final i = value.round();
                if (i < 0 || i >= rows.length) return const SizedBox.shrink();
                if (!shownIdx.contains(i)) return const SizedBox.shrink();
                final dt = rows[i].capturedAtDt;
                final label =
                    '${dt.month}/${dt.day}\n${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
                // fitInside 让首尾标签自动内缩，不会被图表边界裁掉
                return SideTitleWidget(
                  axisSide: meta.axisSide,
                  space: 6,
                  fitInside: SideTitleFitInsideData.fromTitleMeta(
                    meta,
                    distanceFromEdge: 2,
                  ),
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 9, color: AppPalette.muted),
                    textAlign: TextAlign.center,
                  ),
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          enabled: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => AppPalette.chartTooltipBg,
            tooltipRoundedRadius: 8,
            getTooltipItems: (touched) => touched.map((t) {
              final i = t.x.round();
              final dt = (i >= 0 && i < rows.length)
                  ? rows[i].capturedAtDt
                  : null;
              final when = dt == null
                  ? ''
                  : '${dt.month}/${dt.day} '
                      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
              return LineTooltipItem(
                '$when\n${_fmt(t.y)}${_metric.unit}',
                TextStyle(
                  color: AppPalette.chartTooltipFg,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              );
            }).toList(),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: pts,
            isCurved: true,
            curveSmoothness: 0.22,
            color: AppPalette.chartLine,
            barWidth: 2.4,
            dotData: FlDotData(
              show: true,
              getDotPainter: (s, p, b, i) => FlDotCirclePainter(
                radius: 3,
                color: Theme.of(context).colorScheme.surface,
                strokeWidth: 2,
                strokeColor: AppPalette.chartLine,
              ),
            ),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppPalette.chartLine.withValues(alpha: 0.28),
                  AppPalette.chartLine.withValues(alpha: 0.03),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _notEnough(int n) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
      decoration: BoxDecoration(
        color: AppPalette.chipBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(Icons.show_chart, size: 48, color: AppPalette.muted),
          const SizedBox(height: 10),
          Text(
            n == 0 ? '该指标暂无数据' : '至少需要 2 个数据点才能画曲线',
            style: TextStyle(fontSize: 15, color: AppPalette.strong),
          ),
          const SizedBox(height: 4),
          Text(
            '回主页多下拉刷新几次就会自动累积',
            style: TextStyle(color: AppPalette.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  /// 数值格式化：整数不带小数点，小数保留 1 位
  String _fmt(double v) {
    if (v.abs() >= 1000) return v.toStringAsFixed(0);
    if ((v - v.roundToDouble()).abs() < 0.05) {
      return v.toStringAsFixed(0);
    }
    return v.toStringAsFixed(1);
  }

  /// 把任意"粗略步长"吸附到 1 / 2 / 5 × 10^n 这几个好读的刻度
  double _niceStep(double rough) {
    if (rough <= 0 || !rough.isFinite) return 1;
    final exp = (math.log(rough) / math.ln10).floor();
    final base = math.pow(10, exp).toDouble();
    final n = rough / base;
    final double m;
    if (n <= 1) {
      m = 1;
    } else if (n <= 2) {
      m = 2;
    } else if (n <= 5) {
      m = 5;
    } else {
      m = 10;
    }
    return m * base;
  }
}
