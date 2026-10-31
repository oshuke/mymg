// 坐标系转换（WGS-84 / GCJ-02 / BD-09）
//
// ★ 关键结论（2026-09-10 实测标定）：
//   上汽车联 `getVehicleStatus` 返回的经纬度是 **WGS-84**（GPS 原始坐标），
//   而高德 / 腾讯 / 百度等国内地图用的是 **GCJ-02（火星坐标）**。
//   直接拿 WGS-84 画在高德瓦片上会偏 **约 500 米**（本次实测 520m）。
//
//   实测：车联 (37.758645, 115.658482) --WGS84→GCJ02--> (37.759263, 115.664350)，
//   与用户真机高德显示的停车点 (37.75926197, 115.66435211) 仅差 **0.2 米**。
//
//   所以在任何"贴到地图上"的地方（内嵌高德瓦片 / 调起高德百度 / 显示给用户），
//   都必须先 wgs84ToGcj02 纠偏。数据库里仍保存原始 WGS-84，保持数据"干净"。

import 'dart:math' as math;

const double _a = 6378245.0; // 克拉索夫斯基椭球长半轴
const double _ee = 0.00669342162296594323; // 偏心率平方

/// 中国大陆以外不偏移（境外 WGS-84 与 GCJ-02 等同）
bool _outOfChina(double lat, double lng) {
  return lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271;
}

double _transformLat(double x, double y) {
  double ret = -100.0 +
      2.0 * x +
      3.0 * y +
      0.2 * y * y +
      0.1 * x * y +
      0.2 * math.sqrt(x.abs());
  ret += (20.0 * math.sin(6.0 * x * math.pi) +
          20.0 * math.sin(2.0 * x * math.pi)) *
      2.0 /
      3.0;
  ret += (20.0 * math.sin(y * math.pi) +
          40.0 * math.sin(y / 3.0 * math.pi)) *
      2.0 /
      3.0;
  ret += (160.0 * math.sin(y / 12.0 * math.pi) +
          320 * math.sin(y * math.pi / 30.0)) *
      2.0 /
      3.0;
  return ret;
}

double _transformLng(double x, double y) {
  double ret = 300.0 +
      x +
      2.0 * y +
      0.1 * x * x +
      0.1 * x * y +
      0.1 * math.sqrt(x.abs());
  ret += (20.0 * math.sin(6.0 * x * math.pi) +
          20.0 * math.sin(2.0 * x * math.pi)) *
      2.0 /
      3.0;
  ret += (20.0 * math.sin(x * math.pi) +
          40.0 * math.sin(x / 3.0 * math.pi)) *
      2.0 /
      3.0;
  ret += (150.0 * math.sin(x / 12.0 * math.pi) +
          300.0 * math.sin(x / 30.0 * math.pi)) *
      2.0 /
      3.0;
  return ret;
}

/// WGS-84 → GCJ-02（火星坐标）。境外原样返回。
///
/// 返回 (lat, lng)。
({double lat, double lng}) wgs84ToGcj02(double lat, double lng) {
  if (_outOfChina(lat, lng)) return (lat: lat, lng: lng);
  double dLat = _transformLat(lng - 105.0, lat - 35.0);
  double dLng = _transformLng(lng - 105.0, lat - 35.0);
  final double radLat = lat / 180.0 * math.pi;
  double magic = math.sin(radLat);
  magic = 1 - _ee * magic * magic;
  final double sqrtMagic = math.sqrt(magic);
  dLat = (dLat * 180.0) /
      ((_a * (1 - _ee)) / (magic * sqrtMagic) * math.pi);
  dLng = (dLng * 180.0) / (_a / sqrtMagic * math.cos(radLat) * math.pi);
  return (lat: lat + dLat, lng: lng + dLng);
}

/// GCJ-02 → WGS-84（迭代逼近，误差 < 1e-6 度 ≈ 0.1 米）
({double lat, double lng}) gcj02ToWgs84(double lat, double lng) {
  if (_outOfChina(lat, lng)) return (lat: lat, lng: lng);
  double wLat = lat, wLng = lng;
  for (int i = 0; i < 10; i++) {
    final g = wgs84ToGcj02(wLat, wLng);
    wLat += lat - g.lat;
    wLng += lng - g.lng;
  }
  return (lat: wLat, lng: wLng);
}

/// GCJ-02 → BD-09（百度坐标）。百度地图 SDK / 网页版用这套。
({double lat, double lng}) gcj02ToBd09(double lat, double lng) {
  const double xPi = math.pi * 3000.0 / 180.0;
  final double z =
      math.sqrt(lng * lng + lat * lat) + 0.00002 * math.sin(lat * xPi);
  final double theta =
      math.atan2(lat, lng) + 0.000003 * math.cos(lng * xPi);
  return (
    lat: z * math.sin(theta) + 0.006,
    lng: z * math.cos(theta) + 0.0065,
  );
}

/// 经纬度两点间距离（米），Haversine。用于调试 / 标定展示。
double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  const double r = 6371000.0;
  final double p1 = lat1 * math.pi / 180.0;
  final double p2 = lat2 * math.pi / 180.0;
  final double dp = (lat2 - lat1) * math.pi / 180.0;
  final double dl = (lng2 - lng1) * math.pi / 180.0;
  final double h = math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.asin(math.sqrt(h));
}
