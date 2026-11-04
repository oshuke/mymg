import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'coord.dart';
import 'app_config.dart';
import 'err_util.dart';
import 'geocode_service.dart';
import 'quick_control_sheet.dart';
import 'src/rust/vehicle/summary.dart';
import 'summary_cache.dart';
import 'theme_controller.dart';
import 'ui/frosted_page.dart';
import 'ui/glass_surface.dart';

typedef MapSummaryLoader = Future<VehicleSummary> Function({
  required String token,
  required String vin,
  required bool force,
});

/// 位置来自车辆上报；地图和导航分别按目标地图转换坐标。
class MapPage extends StatefulWidget {
  const MapPage({
    super.key,
    required this.token,
    required this.vin,
    this.loadSummary,
    this.resolveAddress,
    this.openFindControls,
    this.loadMapTiles = true,
  });

  final String token;
  final String vin;
  final MapSummaryLoader? loadSummary;
  final Future<String?> Function(double latitude, double longitude)?
  resolveAddress;
  final Future<void> Function(BuildContext context)? openFindControls;

  @visibleForTesting
  final bool loadMapTiles;

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final MapController _mapController = MapController();
  VehicleSummary? _summary;
  String? _error;
  bool _loading = false;
  bool _mapReady = false;
  bool _geoLoading = false;
  bool _openingFind = false;
  int _geoRequest = 0;
  LatLng? _vehicleLatLng;
  double? _wgsLat;
  double? _wgsLng;
  String? _geoLabel;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _geoRequest++;
    _mapReady = false;
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _resolveGeo(double lat, double lng, int request) async {
    String? address;
    try {
      address =
          await (widget.resolveAddress ?? GeocodeService.instance.labelFor)(
            lat,
            lng,
          );
    } catch (_) {
      // 地理编码失败不影响车位与导航，明确显示地址暂不可用。
    }
    if (!mounted || request != _geoRequest) return;
    setState(() {
      final label = address?.trim();
      _geoLabel = label == null || label.isEmpty || label.startsWith('坐标 ')
          ? null
          : label;
      _geoLoading = false;
    });
  }

  Future<void> _refresh({bool force = true}) async {
    if (!mounted || _loading) return;
    // 刷新期间保留上次错误说明，成功之后才撤销。
    setState(() => _loading = true);
    try {
      final summary = await (widget.loadSummary ?? SummaryCache.fetch)(
        token: widget.token,
        vin: widget.vin,
        force: force,
      );
      if (!mounted) return;
      final lat = double.tryParse(summary.latitude?.trim() ?? '');
      final lng = double.tryParse(summary.longitude?.trim() ?? '');
      // Web Mercator 无法显示极区；也拒绝缺失、NaN、Infinity 和零点占位。
      final valid =
          lat != null &&
          lng != null &&
          lat.isFinite &&
          lng.isFinite &&
          lat.abs() <= 85.05112878 &&
          lng.abs() <= 180 &&
          !(lat == 0 && lng == 0);
      final request = ++_geoRequest;
      if (!valid) {
        setState(() {
          _geoLoading = false;
          _error = _vehicleLatLng == null
              ? '车辆未提供有效位置，请稍后重新定位'
              : '本次位置无效，正在显示上次车辆位置';
        });
        return;
      }
      final gcj = wgs84ToGcj02(lat, lng);
      setState(() {
        if (_wgsLat != lat || _wgsLng != lng) _geoLabel = null;
        _summary = summary;
        _wgsLat = lat;
        _wgsLng = lng;
        _vehicleLatLng = LatLng(gcj.lat, gcj.lng);
        _geoLoading = true;
        _error = null;
      });
      unawaited(_resolveGeo(lat, lng, request));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _mapReady) _recenter();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        final reason = formatFrbError(e);
        _error = _vehicleLatLng == null
            ? '位置读取失败：$reason'
            : '刷新失败，正在显示上次车辆位置：$reason';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _recenter() {
    if (!mounted || !_mapReady || _vehicleLatLng == null) return;
    _mapController.move(_vehicleLatLng!, 16);
  }

  Future<void> _openFind() async {
    if (_openingFind) return;
    setState(() => _openingFind = true);
    try {
      final opener = widget.openFindControls;
      if (opener != null) {
        await opener(context);
      } else {
        // 只打开并突出寻车操作，用户点击后才发送指令。
        await showQuickControlSheet(context, initialAction: 'find');
      }
    } finally {
      if (mounted) setState(() => _openingFind = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pos = _vehicleLatLng;
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        backgroundColor: Colors.transparent,
        title: const Text('车辆位置'),
        actions: [
          IconButton(
            tooltip: '刷新位置',
            onPressed: _loading ? null : () => _refresh(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: FrostedBackground(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return RefreshIndicator(
              onRefresh: () => _refresh(),
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: (constraints.maxHeight * 0.58).clamp(
                        260.0,
                        560.0,
                      ),
                      child: pos == null
                          ? _emptyPosition()
                          : Stack(
                              children: [
                                FlutterMap(
                                  mapController: _mapController,
                                  options: MapOptions(
                                    initialCenter: pos,
                                    initialZoom: 16,
                                    minZoom: 4,
                                    maxZoom: 19,
                                    onMapReady: () {
                                      if (!mounted) return;
                                      _mapReady = true;
                                      _recenter();
                                    },
                                    interactionOptions:
                                        const InteractionOptions(
                                          flags:
                                              InteractiveFlag.all &
                                              ~InteractiveFlag.rotate,
                                        ),
                                  ),
                                  children: [
                                    if (widget.loadMapTiles &&
                                        AppConfig.mapTilesConfigured)
                                      TileLayer(
                                        urlTemplate: AppConfig.mapTileUrl,
                                        subdomains: AppConfig.mapSubdomains,
                                        userAgentPackageName: 'com.mymg.app',
                                        maxNativeZoom: 18,
                                        tileProvider: NetworkTileProvider(),
                                      ),
                                    if (widget.loadMapTiles &&
                                        AppConfig.mapTilesConfigured)
                                      RichAttributionWidget(
                                        attributions: [
                                          TextSourceAttribution(
                                            AppConfig.mapAttribution,
                                          ),
                                        ],
                                      ),
                                    MarkerLayer(
                                      markers: [
                                        Marker(
                                          point: pos,
                                          width: 52,
                                          height: 52,
                                          alignment: Alignment.center,
                                          child: const Hero(
                                            tag: 'map-car',
                                            child: _CarMarker(),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                Positioned(
                                  top: 16,
                                  left: 20,
                                  right: 20,
                                  child: GlassSurface(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Icon(
                                              Icons.place_outlined,
                                              size: 20,
                                              color: context.info,
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                _error == null
                                                    ? '车辆位置'
                                                    : '上次车辆位置',
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w600,
                                                  color: context.strong,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          _geoLabel ??
                                              (_geoLoading
                                                  ? '正在获取停车地址…'
                                                  : '已定位车辆，详细地址暂不可用'),
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 14,
                                            height: 1.5,
                                            color: context.strong,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                Positioned(
                                  right: 16,
                                  bottom: 16,
                                  child: IconButton.filledTonal(
                                    tooltip: '地图回到车辆位置',
                                    onPressed: _recenter,
                                    icon: const Icon(Icons.my_location_rounded),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: SafeArea(
                      top: false,
                      minimum: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                      child: GlassSurface(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              _updatedLabel(_summary),
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.5,
                                color: context.muted,
                              ),
                            ),
                            if (_loading) ...[
                              const SizedBox(height: 12),
                              LinearProgressIndicator(
                                minHeight: 2,
                                color: context.info,
                              ),
                            ],
                            if (_error != null) ...[
                              const SizedBox(height: 12),
                              Semantics(
                                liveRegion: true,
                                child: Text(
                                  _error!,
                                  style: TextStyle(
                                    fontSize: 13,
                                    height: 1.5,
                                    color: context.danger,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: pos == null
                                  ? null
                                  : () => _MapNavigation()._openInSystemMap(
                                      context,
                                      _wgsLat!,
                                      _wgsLng!,
                                    ),
                              style: FilledButton.styleFrom(
                                backgroundColor: context.info,
                                foregroundColor: Theme.of(context)
                                    .colorScheme
                                    .onPrimary,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 16,
                                ),
                                shape: const StadiumBorder(),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.navigation_rounded,
                                    size: 22,
                                  ),
                                  const SizedBox(width: 10),
                                  const Flexible(
                                    child: Text(
                                      '导航到车',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            LayoutBuilder(
                              builder: (context, panel) {
                                final buttons = [
                                  OutlinedButton(
                                    onPressed: _loading
                                        ? null
                                        : () => _refresh(),
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                      child: Text(
                                        '重新定位',
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  ),
                                  OutlinedButton(
                                    onPressed: _openingFind ? null : _openFind,
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                      child: Text(
                                        '闪灯鸣笛寻车',
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  ),
                                ];
                                return MediaQuery.textScalerOf(context)
                                                .scale(14) >
                                            22 ||
                                        panel.maxWidth < 250
                                    ? Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          buttons[0],
                                          const SizedBox(height: 8),
                                          buttons[1],
                                        ],
                                      )
                                    : Row(
                                        children: [
                                          Expanded(child: buttons[0]),
                                          const SizedBox(width: 12),
                                          Expanded(child: buttons[1]),
                                        ],
                                      );
                              },
                            ),
                            const SizedBox(height: 10),
                            Text(
                              '寻车需在控车面板中确认；闪灯和鸣笛不支持单独操作。',
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.5,
                                color: context.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _emptyPosition() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_loading && _error == null)
            const CircularProgressIndicator()
          else
            Icon(Icons.location_off_outlined, size: 48, color: context.info),
          const SizedBox(height: 16),
          Text(
            _loading ? '正在获取车辆位置…' : '车辆位置暂不可用',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: context.strong),
          ),
        ],
      ),
    ),
  );
}

String _updatedLabel(VehicleSummary? summary) {
  final raw = summary?.updateTime;
  if (raw == null || raw <= 0) return '最近更新时间未提供';
  try {
    final date = DateTime.fromMillisecondsSinceEpoch(
      raw > 1000000000000 ? raw : raw * 1000,
    ).toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '最近更新：${date.year}/${two(date.month)}/${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
  } on ArgumentError {
    return '最近更新时间未提供';
  }
}

class _CarMarker extends StatelessWidget {
  const _CarMarker();

  @override
  Widget build(BuildContext context) => Semantics(
    label: '车辆定位标记',
    child: Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: context.info.withValues(alpha: 0.18),
        shape: BoxShape.circle,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: context.info,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: [
            BoxShadow(
              color: context.info.withValues(alpha: 0.25),
              blurRadius: 12,
            ),
          ],
        ),
        child: const Icon(
          Icons.directions_car_rounded,
          color: Colors.white,
          size: 20,
        ),
      ),
    ),
  );
}

class _MapNavigation {
  Future<void> _openInSystemMap(
    BuildContext context,
    double wgsLat,
    double wgsLng,
  ) async {
    // ★ 高德 / 腾讯：GCJ-02；百度：BD-09
    final gcj = wgs84ToGcj02(wgsLat, wgsLng);
    final bd = gcj02ToBd09(gcj.lat, gcj.lng);
    final lat = gcj.lat.toStringAsFixed(6);
    final lng = gcj.lng.toStringAsFixed(6);
    final bdLat = bd.lat.toStringAsFixed(6);
    final bdLng = bd.lng.toStringAsFixed(6);
    final title = Uri.encodeComponent('车辆位置');

    final options = <_MapApp>[
      _MapApp(
        name: '高德地图',
        // 官方 nav 深链会直接把镜头挪到目的地；poi/viewMap 在新版常只打开 App 不跳点
        // dev=0 = GCJ-02
        uri: Uri.parse(
          'androidamap://navi?sourceApplication=MYMG'
          '&lat=$lat&lon=$lng&dev=0&style=2',
        ),
        fallbacks: [
          Uri.parse(
            'amapuri://navi?sourceApplication=MYMG'
            '&lat=$lat&lon=$lng&dev=0&style=2',
          ),
          // Web：to=经度,纬度,名称；callnative=1 尝试唤起 App
          Uri.parse(
            'https://uri.amap.com/navigation?to=$lng,$lat,$title'
            '&mode=car&coordinate=gaode&callnative=1',
          ),
        ],
      ),
      _MapApp(
        name: '百度地图',
        uri: Uri.parse(
          'baidumap://map/marker?location=$bdLat,$bdLng'
          '&title=$title&content=MYMG&src=MYMG',
        ),
      ),
      _MapApp(
        name: '腾讯地图',
        // tencentmap://map + coord=2(GCJ02) + point=lat,lng
        uri: Uri.parse(
          'tencentmap://map?mapype=0&coord=2'
          '&point=$lat,$lng&zoom=17&src=MYMG',
        ),
        fallbacks: [
          Uri.parse(
            'qqmap://map/marker?marker=coord:$lat,$lng;'
            'title:车辆位置;addr:&referer=MYMG',
          ),
        ],
      ),
    ];

    if (!context.mounted) return;
    final picked = await showModalBottomSheet<_MapApp>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Text(
                  '选择地图打开',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
              for (final app in options)
                ListTile(
                  leading: const Icon(Icons.map_outlined),
                  title: Text(app.name),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => Navigator.pop(ctx, app),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !context.mounted) return;

    await _launchMapApp(context, picked);
  }

  Future<void> _launchMapApp(BuildContext context, _MapApp app) async {
    Future<bool> tryLaunch(Uri uri) async {
      if (!context.mounted) return false;
      try {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        return false;
      }
    }

    var ok = await tryLaunch(app.uri);
    if (!ok) {
      for (final u in app.fallbacks) {
        ok = await tryLaunch(u);
        if (ok) break;
      }
    }
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('调起${app.name}失败，请确认已安装该 App')));
    }
  }
}

class _MapApp {
  const _MapApp({
    required this.name,
    required this.uri,
    this.fallbacks = const [],
  });
  final String name;
  final Uri uri;
  final List<Uri> fallbacks;
}
