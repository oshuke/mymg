// 内嵌地图页：展示车辆当前 GPS 位置。
//
// 路线 A 选用 flutter_map + OpenStreetMap tiles：
// - 无需开发者 Key（Tencent/高德/百度都要 Key）
// - 跨平台一致
// - 缺点：OSM tiles 在大陆访问慢，且坐标系为 WGS-84（与上汽车联的 GCJ-02 有约 500m 偏移）
//   视觉上能看到车在附近，不影响"看车在哪儿"的功能
//
// 后续如果想换更精准的国内地图（GCJ-02 完美对齐），可在 lbs.qq.com 申 Key 后切到腾讯瓦片。

import 'package:flutter/material.dart';
import 'theme_controller.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'dart:async';

import 'package:mymg/src/rust/api.dart';
import 'package:mymg/src/rust/vehicle/summary.dart';

import 'coord.dart';
import 'err_util.dart';
import 'geocode_service.dart';
import 'summary_cache.dart';

/// 车辆位置地图页
class MapPage extends StatefulWidget {
  const MapPage({super.key, required this.token, required this.vin});

  final String token;
  final String vin;

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final MapController _mapController = MapController();
  VehicleSummary? _summary;
  String? _error;
  bool _loading = true;

  // 上次拉到的坐标（用于 refresh）
  //   _vehicleLatLng = 纠偏后的 GCJ-02（高德瓦片 / marker 用）
  //   _wgsLat/_wgsLng = 车联原始 WGS-84（Google Maps / 展示原始值用）
  LatLng? _vehicleLatLng;
  double? _wgsLat;
  double? _wgsLng;
  String? _geoLabel;
  bool _geoLoading = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _resolveGeo(double wgsLat, double wgsLng) async {
    if (_geoLoading) return;
    _geoLoading = true;
    try {
      final label = await GeocodeService.instance.labelFor(wgsLat, wgsLng);
      if (!mounted) return;
      setState(() => _geoLabel = label);
    } catch (_) {
    } finally {
      _geoLoading = false;
    }
  }

  Future<void> _refresh({bool force = true}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 地图要看车位，打开/下拉都按实时
      final summary = await SummaryCache.fetch(
        token: widget.token,
        vin: widget.vin,
        force: force,
      );
      if (!mounted) return;
      final rawLat = double.tryParse(summary.latitude ?? '');
      final rawLng = double.tryParse(summary.longitude ?? '');
      // ★ 车联返回 WGS-84，高德瓦片是 GCJ-02 → 不纠偏会偏约 500m
      final gcj = (rawLat != null && rawLng != null)
          ? wgs84ToGcj02(rawLat, rawLng)
          : null;
      setState(() {
        _summary = summary;
        _wgsLat = rawLat;
        _wgsLng = rawLng;
        if (gcj != null) {
          _vehicleLatLng = LatLng(gcj.lat, gcj.lng);
        }
        _loading = false;
      });
      if (rawLat != null && rawLng != null) {
        unawaited(_resolveGeo(rawLat, rawLng));
      }
      // 拉到位置后，把地图移到车位置
      if (gcj != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _mapController
              .move(LatLng(gcj.lat, gcj.lng), _mapController.camera.zoom);
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = formatFrbError(e);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('车辆位置'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _summary == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _summary == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 56, color: Colors.grey),
              SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _refresh,
                icon: Icon(Icons.refresh),
                label: Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final pos = _vehicleLatLng;
    if (pos == null) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.location_off, size: 56, color: Colors.grey),
              SizedBox(height: 12),
              Text('车辆暂无 GPS 位置', style: TextStyle(fontSize: 16)),
              SizedBox(height: 4),
              Text('服务端未返回坐标，可能是车辆熄火/未联网',
                  style: TextStyle(color: AppPalette.muted, fontSize: 12)),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: pos,
            initialZoom: 16,
            minZoom: 4,
            maxZoom: 19,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            TileLayer(
              // 高德地图瓦片（GCJ-02 坐标系，与上汽车联返回的坐标一致）
              // 相比 OpenStreetMap：国内访问快、视觉精确对齐、中文标注
              urlTemplate:
                  'https://webrd0{s}.is.autonavi.com/appmaptile'
                  '?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
              subdomains: const ['1', '2', '3', '4'],
              userAgentPackageName: 'com.mymg.app',
              maxNativeZoom: 18,
              tileProvider: NetworkTileProvider(),
              errorTileCallback: (_, __, ___) {},
            ),
            // 一个 marker 显示车位置。
            // ★ 之前 width/height=48 + alignment=center，而图标实际是 38 圆 + 6 小尾巴，
            //   中心没对齐车坐标，视觉上往下/往上偏了 ~20px（zoom16 下约 30~40 米）。
            //   改成 38x38 + 中心对齐，红圆心正压在车坐标上。
            MarkerLayer(
              markers: [
                Marker(
                  point: pos,
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  // 与首页位置卡的 Hero 同 tag：从卡片飞入地图车标
                  child: const Hero(tag: 'map-car', child: _CarMarker()),
                ),
              ],
            ),
          ],
        ),
        // 顶部信息条
        Positioned(
          top: 12,
          left: 12,
          right: 12,
          child: _LocationInfoBar(
            summary: _summary,
            lat: pos.latitude,
            lng: pos.longitude,
            address: _geoLabel,
            geoLoading: _geoLoading,
          ),
        ),
        // 右下角放大缩小
        Positioned(
          right: 12,
          bottom: 100,
          child: _ZoomButtons(
            onZoomIn: () {
              final cur = _mapController.camera.zoom;
              final minZ = _mapController.camera.minZoom ?? 4;
              final maxZ = _mapController.camera.maxZoom ?? 19;
              _mapController.move(
                _mapController.camera.center,
                (cur + 1).clamp(minZ, maxZ),
              );
            },
            onZoomOut: () {
              final cur = _mapController.camera.zoom;
              final minZ = _mapController.camera.minZoom ?? 4;
              final maxZ = _mapController.camera.maxZoom ?? 19;
              _mapController.move(
                _mapController.camera.center,
                (cur - 1).clamp(minZ, maxZ),
              );
            },
          ),
        ),
        // 底部按钮条：重新定位到车 / 在系统地图查看
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: _BottomActions(
            onRecenter: () {
              _mapController.move(pos, 16);
            },
            // 传原始 WGS-84，内部再按目标 App 转对应坐标系
            wgsLat: _wgsLat ?? pos.latitude,
            wgsLng: _wgsLng ?? pos.longitude,
          ),
        ),
      ],
    );
  }
}

// ── 子部件 ──────────────────────────────────────────────────────

/// 车位置图标（红圈 + 🚗）
class _CarMarker extends StatelessWidget {
  const _CarMarker();
  @override
  Widget build(BuildContext context) {
    // 只保留 38x38 红圈，中心对齐车坐标；去掉下方 6px 小尾巴，
    // 否则 marker 用 center 对齐时视觉中心会偏离真实 GPS 点。
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: Colors.red.shade600,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(blurRadius: 4, color: AppPalette.track, offset: Offset(0, 2)),
        ],
      ),
      child: const Icon(Icons.directions_car, color: Colors.white, size: 20),
    );
  }
}

/// 顶部信息条：文字地址 + 坐标 + 服务端时间
class _LocationInfoBar extends StatelessWidget {
  const _LocationInfoBar({
    this.summary,
    required this.lat,
    required this.lng,
    this.address,
    this.geoLoading = false,
  });
  final VehicleSummary? summary;
  final double lat;
  final double lng;
  final String? address;
  final bool geoLoading;

  @override
  Widget build(BuildContext context) {
    final upd = summary?.updateTime;
    String ts = '—';
    if (upd != null) {
      final dt = DateTime.fromMillisecondsSinceEpoch(
        upd > 1000000000000 ? upd : upd * 1000,
      );
      ts = dt.toLocal().toString().split('.').first;
    }
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      elevation: 4,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.place, color: Colors.red, size: 18),
                SizedBox(width: 6),
                Expanded(
                  child: Text('车辆位置',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                Text('已纠偏 GCJ-02',
                    style: TextStyle(fontSize: 11, color: AppPalette.subtle)),
              ],
            ),
            SizedBox(height: 4),
            Text(
              address ??
                  (geoLoading
                      ? '地址解析中…'
                      : '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}'),
              style: TextStyle(fontSize: 13, color: AppPalette.strong),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            Text('服务端时间：$ts',
                style: TextStyle(fontSize: 11, color: AppPalette.muted)),
          ],
        ),
      ),
    );
  }
}

/// 右下角放大缩小按钮组
class _ZoomButtons extends StatelessWidget {
  const _ZoomButtons({required this.onZoomIn, required this.onZoomOut});
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        FloatingActionButton.small(
          heroTag: 'zoom_in',
          onPressed: onZoomIn,
          child: const Icon(Icons.add),
        ),
        const SizedBox(height: 8),
        FloatingActionButton.small(
          heroTag: 'zoom_out',
          onPressed: onZoomOut,
          child: const Icon(Icons.remove),
        ),
      ],
    );
  }
}

/// 底部操作条：重新定位到车 + 在系统地图查看
class _BottomActions extends StatelessWidget {
  const _BottomActions({
    required this.onRecenter,
    required this.wgsLat,
    required this.wgsLng,
  });
  final VoidCallback onRecenter;
  /// 车联原始 WGS-84 坐标（调起 Maps 时按目标 App 转对应坐标系）
  final double wgsLat;
  final double wgsLng;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.tonalIcon(
            onPressed: onRecenter,
            icon: const Icon(Icons.my_location),
            label: const Text('定位到车'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton.icon(
            onPressed: () => _openInSystemMap(context, wgsLat, wgsLng),
            icon: const Icon(Icons.open_in_new),
            label: const Text('系统地图打开'),
          ),
        ),
      ],
    );
  }

  Future<void> _openInSystemMap(
      BuildContext context, double wgsLat, double wgsLng) async {
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
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text('选择地图打开',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
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
    );
    if (picked == null) return;

    await _launchMapApp(context, picked);
  }

  Future<void> _launchMapApp(BuildContext context, _MapApp app) async {
    Future<bool> tryLaunch(Uri uri) async {
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('调起${app.name}失败，请确认已安装该 App')),
      );
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
