import 'package:flutter/material.dart';

import 'ui/vehicle_hero.dart';
import 'err_util.dart';
import 'src/rust/vehicle/summary.dart';
import 'summary_cache.dart';
import 'theme_controller.dart';
import 'ui/frosted_page.dart';
import 'ui/glass_surface.dart';
import 'ui/vehicle_alert_message.dart';

typedef VehicleStatusLoader = Future<VehicleSummary> Function({
  required String token,
  required String vin,
  required bool force,
});

class VehicleStatusPage extends StatefulWidget {
  const VehicleStatusPage({
    super.key,
    required this.token,
    required this.vin,
    this.loadSummary,
  });

  final String token;
  final String vin;
  final VehicleStatusLoader? loadSummary;

  @override
  State<VehicleStatusPage> createState() => _VehicleStatusPageState();
}

class _VehicleStatusPageState extends State<VehicleStatusPage> {
  VehicleSummary? _summary;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    if (!mounted || _loading) return;
    setState(() => _loading = true);
    try {
      final summary = await (widget.loadSummary ?? SummaryCache.fetch)(
        token: widget.token,
        vin: widget.vin,
        force: force,
      );
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = formatFrbError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _summary;
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        backgroundColor: Colors.transparent,
        title: const Text('车辆状态'),
        actions: [
          IconButton(
            tooltip: '刷新车况',
            onPressed: _loading ? null : () => _load(force: true),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: FrostedBackground(
        child: RefreshIndicator(
          onRefresh: () => _load(force: true),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              20,
              12,
              20,
              32 + MediaQuery.paddingOf(context).bottom,
            ),
            children: [
              const _StatusVehicleImage(),
              const SizedBox(height: 12),
              if (_loading) ...[
                LinearProgressIndicator(color: context.info, minHeight: 2),
                const SizedBox(height: 16),
              ],
              if (_error != null) ...[
                GlassSurface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s == null ? '车况暂时无法读取' : '刷新失败，以下为上次车况',
                        style: TextStyle(color: context.danger),
                      ),
                      const SizedBox(height: 6),
                      Text(_error!, style: TextStyle(color: context.muted)),
                      TextButton(
                        onPressed: _loading ? null : () => _load(force: true),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              if (s != null) ...[
                _StatusOverview(summary: s),
                const SizedBox(height: 24),
                GlassSurface(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Column(
                    children: [
                      _StatusDetail(
                        icon: Icons.tire_repair_outlined,
                        title: '胎压',
                        child: _TyreReadings(summary: s),
                      ),
                      _StatusDetail(
                        icon: Icons.lock_outline_rounded,
                        title: '车门与门锁',
                        value:
                            '${_stateText(s.allDoorsClosed, '车门已关', '有车门未关', '车门状态未知')}\n${_stateText(s.allLocked, '车辆已锁', '车辆未锁', '门锁状态未知')}',
                        warning:
                            s.allDoorsClosed == false || s.allLocked == false,
                      ),
                      _StatusDetail(
                        icon: Icons.window_outlined,
                        title: '车窗',
                        value: _stateText(
                          s.allWindowsClosed,
                          '车窗已关',
                          '有车窗未关',
                          '车窗状态未知',
                        ),
                        warning: s.allWindowsClosed == false,
                      ),
                      const _StatusDetail(
                        icon: Icons.battery_2_bar_outlined,
                        title: '12V 电压',
                        value: '未提供',
                      ),
                      _StatusDetail(
                        icon: Icons.route_outlined,
                        title: '行驶里程',
                        value:
                            s.odometerKm == null ||
                                !s.odometerKm!.isFinite ||
                                s.odometerKm! < 0
                            ? '未提供'
                            : '${s.odometerKm!.toStringAsFixed(0)} km',
                        last: true,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _stateText(bool? value, String yes, String no, String unknown) =>
    value == null ? unknown : (value ? yes : no);

class _StatusVehicleImage extends StatelessWidget {
  const _StatusVehicleImage();

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(
        'MG5',
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          color: context.strong,
        ),
      ),
      const SizedBox(height: 4),
      Text('2021 · 燃油版', style: TextStyle(fontSize: 13, color: context.muted)),
      const SizedBox(height: 8),
      AspectRatio(aspectRatio: 1.9, child: const VehicleImage()),
    ],
  );
}

class _StatusOverview extends StatelessWidget {
  const _StatusOverview({required this.summary});
  final VehicleSummary summary;

  @override
  Widget build(BuildContext context) {
    final concerns = <String>[
      if (summary.allDoorsClosed == false) '有车门未关',
      if (summary.allLocked == false) '车辆未锁',
      if (summary.allWindowsClosed == false) '有车窗未关',
      if (summary.alerts?.isNotEmpty ?? false)
        '有 ${summary.alerts!.length} 条车辆提醒',
    ];
    final unknown = <String>[
      if (summary.allDoorsClosed == null) '车门',
      if (summary.allLocked == null) '门锁',
      if (summary.allWindowsClosed == null) '车窗',
      if (summary.tyreKpa == null ||
          summary.tyreKpa!.length < 4 ||
          summary.tyreKpa!.take(4).any((value) => value == null))
        '胎压',
    ];
    return Semantics(
      liveRegion: true,
      child: Column(
        children: [
          Icon(
            concerns.isNotEmpty || unknown.isNotEmpty
                ? Icons.info_rounded
                : Icons.shield_outlined,
            color: concerns.isNotEmpty ? context.warning : context.info,
            size: 30,
          ),
          const SizedBox(height: 8),
          Text(
            concerns.isNotEmpty
                ? '请检查车辆'
                : unknown.isNotEmpty
                ? '部分状态待确认'
                : '门窗已关 · 车辆已锁',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: context.strong,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            [
              ...concerns,
              if (unknown.isNotEmpty) '${unknown.join('、')}状态待确认',
              if (concerns.isEmpty && unknown.isEmpty) '胎压请核对车辆建议值',
            ].join(' · '),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, height: 1.5, color: context.muted),
          ),
          if (summary.alerts?.isNotEmpty ?? false) ...[
            const SizedBox(height: 16),
            GlassSurface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final alert in summary.alerts!)
                    VehicleAlertMessage.fromAlert(alert),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TyreReadings extends StatelessWidget {
  const _TyreReadings({required this.summary});
  final VehicleSummary summary;

  @override
  Widget build(BuildContext context) {
    const wheels = ['左前', '右前', '左后', '右后'];
    final readings = summary.tyreKpa;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns =
            constraints.maxWidth < 200 ||
                MediaQuery.textScalerOf(context).scale(14) > 23
            ? 1
            : 2;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: List.generate(4, (index) {
            final value = readings != null && index < readings.length
                ? readings[index]
                : null;
            return SizedBox(
              width: (constraints.maxWidth - (columns - 1) * 8) / columns,
              child: Text(
                '${wheels[index]}  ${value == null ? '未提供' : '$value kPa'}',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: context.strong,
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

class _StatusDetail extends StatelessWidget {
  const _StatusDetail({
    required this.icon,
    required this.title,
    this.value,
    this.child,
    this.warning = false,
    this.last = false,
  });
  final IconData icon;
  final String title;
  final String? value;
  final Widget? child;
  final bool warning;
  final bool last;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 16),
    decoration: BoxDecoration(
      border: last
          ? null
          : Border(
              bottom: BorderSide(color: context.info.withValues(alpha: 0.08)),
            ),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final stacked =
            child != null ||
            constraints.maxWidth < 280 ||
            MediaQuery.textScalerOf(context).scale(14) > 20;
        final label = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: context.info, size: 22),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                title,
                style: TextStyle(fontSize: 14, color: context.strong),
              ),
            ),
          ],
        );
        final content =
            child ??
            Text(
              value!,
              textAlign: stacked ? TextAlign.start : TextAlign.end,
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color: warning ? context.warning : context.muted,
              ),
            );
        return stacked
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [label, const SizedBox(height: 10), content],
              )
            : Row(
                children: [
                  Expanded(child: label),
                  const SizedBox(width: 12),
                  Flexible(child: content),
                ],
              );
      },
    ),
  );
}
