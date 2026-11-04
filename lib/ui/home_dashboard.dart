import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' show LatLng;

import '../coord.dart';
import '../app_config.dart';
import '../src/rust/vehicle/summary.dart';
import '../ui_design_tokens.dart';
import 'frosted_page.dart';
import 'glass_surface.dart';
import 'vehicle_hero.dart';
import 'vehicle_alert_message.dart';
import 'system_bars.dart';

/// Visual composition from the supplied reference. HomePage owns the data flow.
class HomeDashboard extends StatelessWidget {
  const HomeDashboard({
    super.key,
    required this.summary,
    required this.plate,
    required this.onRefresh,
    required this.onMessages,
    required this.onSettings,
    required this.onImage,
    required this.onLock,
    required this.onClimate,
    required this.onTrunk,
    required this.onFind,
    required this.onStatus,
    required this.onLocation,
    required this.onHistory,
    this.address,
    this.lastSynced,
    this.loading = false,
    this.error,
    this.details,
  });

  final VehicleSummary? summary;
  final String plate;
  final String? address;
  final DateTime? lastSynced;
  final bool loading;
  final Widget? error, details;
  final Future<void> Function() onRefresh;
  final VoidCallback onMessages,
      onSettings,
      onImage,
      onLock,
      onClimate,
      onTrunk,
      onFind,
      onStatus,
      onLocation,
      onHistory;

  @override
  Widget build(BuildContext context) => FrostedBackground(
    child: RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(
          bottom: 20 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          AnnotatedRegion<SystemUiOverlayStyle>(
            // The vehicle image and horizon are light; only the darker header
            // below overrides this with light glyphs while it is onscreen.
            value: systemBarsFor(Brightness.light),
            child: _VehicleStage(
              summary: summary,
              plate: plate,
              onMessages: onMessages,
              onSettings: onSettings,
              onImage: onImage,
            ),
          ),
          Transform.translate(
            offset: const Offset(0, -20),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  GlassSurface(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 15,
                    ),
                    child: Row(
                      children: [
                        _RoundAction(
                          icon: CupertinoIcons.lock,
                          label: '车锁',
                          onTap: onLock,
                        ),
                        _RoundAction(
                          icon: CupertinoIcons.snow,
                          label: '空调',
                          onTap: onClimate,
                        ),
                        _RoundAction(
                          icon: CupertinoIcons.car_detailed,
                          label: '后备箱',
                          onTap: onTrunk,
                        ),
                        _RoundAction(
                          icon: CupertinoIcons.speaker_2,
                          label: '寻车',
                          onTap: onFind,
                        ),
                      ],
                    ),
                  ),
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: error,
                    ),
                  const SizedBox(height: 12),
                  _SafetyOverview(summary: summary, onTap: onStatus),
                  if (lastSynced != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '最近同步 ${lastSynced!.hour.toString().padLeft(2, '0')}:${lastSynced!.minute.toString().padLeft(2, '0')}',
                        style: TextStyle(
                          fontSize: 10,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  GlassSurface(
                    key: const ValueKey('home-history-entry'),
                    onTap: onHistory,
                    child: Row(
                      children: [
                        Icon(
                          CupertinoIcons.chart_bar_alt_fill,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '历史记录',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '车况趋势 · 行程与 AI 解读',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(CupertinoIcons.chevron_right, size: 16),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final location = _LocationPreview(
                        address: address,
                        summary: summary,
                        onTap: onLocation,
                      );
                      final health = _HealthOverview(
                        summary: summary,
                        onTap: onStatus,
                      );
                      if (constraints.maxWidth < 330 ||
                          MediaQuery.textScalerOf(context).scale(14) > 19) {
                        return Column(
                          children: [
                            location,
                            const SizedBox(height: 12),
                            health,
                          ],
                        );
                      }
                      return IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: location),
                            const SizedBox(width: 12),
                            Expanded(child: health),
                          ],
                        ),
                      );
                    },
                  ),
                  if (details != null) ...[
                    const SizedBox(height: 12),
                    details!,
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _VehicleStage extends StatelessWidget {
  const _VehicleStage({
    required this.summary,
    required this.plate,
    required this.onMessages,
    required this.onSettings,
    required this.onImage,
  });
  final VehicleSummary? summary;
  final String plate;
  final VoidCallback onMessages, onSettings, onImage;

  @override
  Widget build(BuildContext context) {
    final fuel = summary?.fuelPercent;
    return Container(
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            MyMgDesignTokens.heroSky,
            MyMgDesignTokens.heroHorizon,
            MyMgDesignTokens.heroGround,
          ],
          stops: [0, 0.56, 1],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnnotatedRegion<SystemUiOverlayStyle>(
            value: systemBarsFor(Brightness.dark),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                24,
                20 + MediaQuery.paddingOf(context).top,
                18,
                0,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'MYMG 汽车',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 23,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.4,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          '与爱车，一起出发',
                          style: TextStyle(
                            color: Color(0xE0FFFFFF),
                            fontSize: 13,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _HeroIcon(
                    icon: CupertinoIcons.bell,
                    label: '消息中心',
                    onTap: onMessages,
                  ),
                  const SizedBox(width: 6),
                  _HeroIcon(
                    icon: CupertinoIcons.gear_alt,
                    label: '设置',
                    onTap: onSettings,
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'MG5',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 29,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  plate.isEmpty || plate == '我的 MG5'
                      ? '2021 · 燃油版'
                      : '$plate · 燃油版',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 178,
            child: Stack(
              children: [
                const Positioned.fill(
                  child: CustomPaint(painter: _HorizonPainter()),
                ),
                Positioned(
                  left: -12,
                  right: -24,
                  top: 10,
                  bottom: 2,
                  child: Semantics(
                    label: '车辆主视觉，轻点更换图片',
                    button: true,
                    child: GestureDetector(
                      onTap: onImage,
                      child: const VehicleImage(),
                    ),
                  ),
                ),
                Positioned(
                  right: 18,
                  bottom: 0,
                  child: Material(
                    color: const Color(0x26FFFFFF),
                    shape: const CircleBorder(
                      side: BorderSide(color: Color(0x70FFFFFF)),
                    ),
                    child: IconButton(
                      tooltip: '更换车辆图片',
                      onPressed: onImage,
                      icon: const Icon(
                        CupertinoIcons.photo,
                        color: Colors.white,
                        size: 17,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 38),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _StageMetric(
                        value: summary?.rangeKm?.toString() ?? '—',
                        unit: 'km',
                        label: '剩余续航',
                        large: true,
                      ),
                    ),
                    Container(
                      width: 1,
                      height: 36,
                      color: const Color(0x60FFFFFF),
                    ),
                    const SizedBox(width: 24),
                    Expanded(
                      child: _StageMetric(
                        value: fuel?.toString() ?? '—',
                        unit: '%',
                        label: '剩余油量',
                      ),
                    ),
                    const Icon(
                      Icons.local_gas_station_outlined,
                      color: Colors.white,
                      size: 24,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: LinearProgressIndicator(
                    value: fuel == null ? 0 : fuel.clamp(0, 100) / 100,
                    minHeight: 5,
                    backgroundColor: const Color(0x50FFFFFF),
                    color: fuel != null && fuel <= 15
                        ? MyMgDesignTokens.fuelAccent
                        : const Color(0xFF70DFCD),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StageMetric extends StatelessWidget {
  const _StageMetric({
    required this.value,
    required this.unit,
    required this.label,
    this.large = false,
  });
  final String value, unit, label;
  final bool large;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: value,
                style: TextStyle(
                  fontSize: large ? 37 : 32,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.8,
                ),
              ),
              TextSpan(text: ' $unit', style: const TextStyle(fontSize: 14)),
            ],
          ),
          style: const TextStyle(color: Colors.white, height: 1.15),
        ),
      ),
      const SizedBox(height: 5),
      Text(
        label,
        style: const TextStyle(color: Color(0xEEFFFFFF), fontSize: 12),
      ),
    ],
  );
}

class _HeroIcon extends StatelessWidget {
  const _HeroIcon({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: label,
    onPressed: onTap,
    icon: Icon(icon, size: 22, color: Colors.white),
    style: IconButton.styleFrom(
      side: const BorderSide(color: Color(0x60FFFFFF)),
      backgroundColor: const Color(0x12FFFFFF),
    ),
  );
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Semantics(
        button: true,
        label: label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Column(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.07),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 25, color: scheme.onSurface),
                ),
                const SizedBox(height: 8),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SafetyOverview extends StatelessWidget {
  const _SafetyOverview({required this.summary, required this.onTap});
  final VehicleSummary? summary;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final s = summary;
    final known =
        s?.allLocked != null &&
        s?.allDoorsClosed != null &&
        s?.allWindowsClosed != null;
    final secure =
        known && s!.allLocked! && s.allDoorsClosed! && s.allWindowsClosed!;
    final alert = s?.alerts?.isNotEmpty == true;
    final title = s == null
        ? '车辆状态待更新'
        : alert
        ? '车辆有提醒'
        : secure
        ? '车辆已上锁'
        : known
        ? '请检查车辆状态'
        : '部分状态待确认';
    final subtitle = s == null
        ? '下拉刷新，获取最新车况'
        : [
            s.allLocked == null
                ? '车锁未知'
                : s.allLocked!
                ? '车门已锁'
                : '车门未锁',
            s.allDoorsClosed == null
                ? '车门未知'
                : s.allDoorsClosed!
                ? '车门已关'
                : '车门未关',
            s.allWindowsClosed == null
                ? '车窗未知'
                : s.allWindowsClosed!
                ? '车窗已关'
                : '车窗未关',
          ].join(' · ');
    final color = secure && !alert
        ? MyMgDesignTokens.success
        : s == null || !known
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : MyMgDesignTokens.warning;
    return GlassSurface(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(
              secure && !alert ? Icons.check_rounded : Icons.info_outline,
              color: Colors.white,
              size: 19,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 11,
                    height: 1.45,
                  ),
                ),
                if (alert) ...[
                  const SizedBox(height: 8),
                  Text(
                    formatVehicleAlert(
                      alertId: s!.alerts!.first.alertId,
                      alertType: s.alerts!.first.alertType,
                      alertData: s.alerts!.first.alertData,
                    ),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                  if (s.alerts!.length > 1)
                    Text(
                      '共 ${s.alerts!.length} 条提醒，点此查看全部',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontSize: 12,
                      ),
                    ),
                ],
              ],
            ),
          ),
          const Icon(CupertinoIcons.chevron_right, size: 16),
        ],
      ),
    );
  }
}

class _HealthOverview extends StatelessWidget {
  const _HealthOverview({required this.summary, required this.onTap});
  final VehicleSummary? summary;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final s = summary;
    final pressures = s?.tyreKpa?.whereType<int>().toList() ?? [];
    return GlassSurface(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(CupertinoIcons.heart, size: 18),
              SizedBox(width: 6),
              Flexible(
                child: Text(
                  '车辆健康',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 15),
          _row(
            context,
            Icons.tire_repair_outlined,
            '胎压',
            pressures.isEmpty
                ? '暂无数据'
                : '${pressures.reduce((a, b) => a < b ? a : b)}–${pressures.reduce((a, b) => a > b ? a : b)} kPa',
          ),
          const SizedBox(height: 10),
          _row(
            context,
            CupertinoIcons.speedometer,
            '平均油耗',
            s?.fuelConsumption == null
                ? '暂无数据'
                : '${s!.fuelConsumption!.toStringAsFixed(1)} L/100km',
          ),
          const SizedBox(height: 10),
          _row(
            context,
            CupertinoIcons.gauge,
            '总里程',
            s?.odometerKm == null
                ? '暂无数据'
                : '${s!.odometerKm!.toStringAsFixed(0)} km',
          ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 17),
      const SizedBox(width: 8),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    ],
  );
}

class _LocationPreview extends StatelessWidget {
  const _LocationPreview({
    required this.summary,
    required this.address,
    required this.onTap,
  });
  final VehicleSummary? summary;
  final String? address;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final lat = double.tryParse(summary?.latitude ?? '');
    final lng = double.tryParse(summary?.longitude ?? '');
    final valid =
        lat != null &&
        lng != null &&
        lat.isFinite &&
        lng.isFinite &&
        lat.abs() <= 90 &&
        lng.abs() <= 180 &&
        (lat != 0 || lng != 0);
    final gcj = valid ? wgs84ToGcj02(lat, lng) : null;
    final surface = Theme.of(context).colorScheme.surface;
    return GlassSurface(
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: SizedBox(
        height: 225,
        child: Stack(
          children: [
            if (gcj != null)
              Positioned.fill(
                child: ExcludeSemantics(
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: 0.65,
                      child: FlutterMap(
                        options: MapOptions(
                          initialCenter: LatLng(gcj.lat, gcj.lng),
                          initialZoom: 14,
                          interactionOptions: const InteractionOptions(
                            flags: InteractiveFlag.none,
                          ),
                        ),
                        children: [
                          if (AppConfig.mapTilesConfigured)
                            TileLayer(
                              urlTemplate: AppConfig.mapTileUrl,
                              subdomains: AppConfig.mapSubdomains,
                              userAgentPackageName: 'com.mymg.app',
                              errorTileCallback: (_, __, ___) {},
                            ),
                          MarkerLayer(
                            markers: [
                              Marker(
                                point: LatLng(gcj.lat, gcj.lng),
                                width: 34,
                                height: 34,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: MyMgDesignTokens.primaryBlue
                                        .withValues(alpha: 0.2),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.location_on,
                                    color: MyMgDesignTokens.primaryBlue,
                                    size: 27,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      surface.withValues(alpha: 0.93),
                      surface.withValues(alpha: 0.05),
                      surface.withValues(alpha: 0.35),
                    ],
                    stops: const [0, 0.65, 1],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(CupertinoIcons.location_solid, size: 17),
                      SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '车辆位置',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    address ?? (valid ? '已获取车辆位置' : '暂无位置信息'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, height: 1.5),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: onTap,
                      icon: const Icon(CupertinoIcons.location_fill, size: 14),
                      label: const Text('导航到车', style: TextStyle(fontSize: 12)),
                      style: FilledButton.styleFrom(
                        backgroundColor: surface.withValues(alpha: 0.92),
                        foregroundColor: Theme.of(context).colorScheme.primary,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size.fromHeight(42),
                        shape: const StadiumBorder(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (gcj != null && AppConfig.mapTilesConfigured)
              Positioned(
                left: 8,
                right: 8,
                bottom: 4,
                child: Text(
                  AppConfig.mapAttribution,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HorizonPainter extends CustomPainter {
  const _HorizonPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height * 0.61;
    final path = Path()
      ..moveTo(0, h)
      ..lineTo(0, h - 10)
      ..lineTo(size.width * .10, h - 22)
      ..lineTo(size.width * .19, h - 13)
      ..lineTo(size.width * .3, h - 18)
      ..lineTo(size.width * .42, h - 3)
      ..lineTo(size.width * .66, h - 8)
      ..lineTo(size.width * .82, h - 21)
      ..lineTo(size.width, h - 12)
      ..lineTo(size.width, h)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0x30617EA6));
    canvas.drawRect(
      Rect.fromLTRB(0, h, size.width, size.height),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x60E5EDF6), Color(0x00E5EDF6)],
        ).createShader(Rect.fromLTRB(0, h, size.width, size.height)),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
