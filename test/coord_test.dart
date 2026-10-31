// 坐标系转换单测（WGS-84 → GCJ-02）
//
// ★ 用真机实测的标定数据当"金标准"：
//   车联 `getVehicleStatus` 返回的是 WGS-84，用户手机高德显示的真实停车点是
//   河北省衡水市桃城区路北街道永安西路1278号鸿缘烟酒超市前
//   (37.75926196905066, 115.66435211055108)（GCJ-02）。
//   车联原始返回 (37.758645, 115.658482)，直接画就差 520 米；
//   转成 GCJ-02 后应与之相差 < 1 米。

import 'package:flutter_test/flutter_test.dart';
import 'package:mymg/coord.dart';

void main() {
  group('wgs84ToGcj02', () {
    test('衡水实测标定：车联 WGS-84 → GCJ-02 应贴合真实停车点', () {
      const clLat = 37.758645;   // 车联原始（WGS-84）
      const clLng = 115.658482;
      const realLat = 37.75926196905066; // 高德真实（GCJ-02）
      const realLng = 115.66435211055108;

      final g = wgs84ToGcj02(clLat, clLng);

      // 转之前差 520 米，转之后应 < 1 米
      final before = distanceMeters(clLat, clLng, realLat, realLng);
      final after = distanceMeters(g.lat, g.lng, realLat, realLng);
      expect(before, greaterThan(400), reason: '原始坐标本就该偏 ~500m');
      expect(after, lessThan(1.0),
          reason: '纠偏后应贴合真实停车点，实际偏差 ${after.toStringAsFixed(2)}m');
    });

    test('境外坐标不做偏移', () {
      final g = wgs84ToGcj02(48.8566, 2.3522); // 巴黎
      expect(g.lat, closeTo(48.8566, 1e-9));
      expect(g.lng, closeTo(2.3522, 1e-9));
    });

    test('国内偏移量在合理范围（0.001~0.01 度）', () {
      final g = wgs84ToGcj02(39.9042, 116.4074); // 北京
      final dLat = g.lat - 39.9042;
      final dLng = g.lng - 116.4074;
      expect(dLat.abs(), inInclusiveRange(0.001, 0.01));
      expect(dLng.abs(), inInclusiveRange(0.001, 0.01));
    });

    test('GCJ-02 → WGS-84 往返误差 < 1 米', () {
      const lat = 37.758645;
      const lng = 115.658482;
      final back = gcj02ToWgs84(wgs84ToGcj02(lat, lng).lat, wgs84ToGcj02(lat, lng).lng);
      expect(distanceMeters(lat, lng, back.lat, back.lng), lessThan(1.0));
    });
  });
}
