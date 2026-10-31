// 车辆身份信息（车牌号等）—— 本机手动维护，不来自服务端。
//
// 为什么手动：上汽车联 `getVehicleStatus` 的 127 个字段里**没有车牌号**
// （已核对字段字典与真实响应样本）；唯一带车牌的接口是登录链路的
// `findBoundVinList`（字段 `vehicle_no`），而那条链路要过 sign + 易盾滑块。
// 所以车牌号走本机设置，用户在设置页填一次即可，全 App 复用。

import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences 键
const String kPlateKey = 'mymg.plate';

class VehicleProfile {
  VehicleProfile._();

  static String? _cached;

  /// 读取已保存的车牌号（未填返回空串）
  static Future<String> plate({bool force = false}) async {
    if (!force && _cached != null) return _cached!;
    final p = await SharedPreferences.getInstance();
    final v = p.getString(kPlateKey) ?? '';
    _cached = v;
    return v;
  }

  /// 同步读缓存（UI 首帧用，可能为 null）
  static String? get cachedPlate => _cached;

  /// 清掉内存缓存（WebDAV 恢复后强制重读）
  static void invalidateCache() {
    _cached = null;
  }

  /// 保存车牌号。空白 → 视为清空。
  static Future<void> setPlate(String value) async {
    final normalized = normalize(value);
    final p = await SharedPreferences.getInstance();
    if (normalized.isEmpty) {
      await p.remove(kPlateKey);
    } else {
      await p.setString(kPlateKey, normalized);
    }
    _cached = normalized;
  }

  /// 规范化：去空格、字母转大写、把全角符号换成半角。
  ///
  /// 只做无害清洗，**不**自作聪明插 "·"（不同地区车牌格式差异大）。
  static String normalize(String raw) {
    var s = raw
        .replaceAll('　', '')
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll('－', '-')
        .replaceAll('・', '·')
        .replaceAll('。', '.');
    // 单个字母小写 → 大写（车牌字母一律大写）
    final m = RegExp(r'^([\u4e00-\u9fa5])([a-zA-Z])').firstMatch(s);
    if (m != null) {
      s = '${m.group(1)}${m.group(2)!.toUpperCase()}${s.substring(m.end)}';
    } else {
      s = s.toUpperCase();
    }
    return s;
  }

  /// 车牌展示串；没填时给个占位
  static String display(String plate) => plate.isEmpty ? '未设置车牌' : plate;

  /// 车架号尾号（VIN 后 6 位）—— 车牌未填时的兜底显示
  static String vinTail(String vin) =>
      vin.length >= 6 ? vin.substring(vin.length - 6) : vin;

  /// 优先车牌，其次 VIN 尾号，都没有则给通用文案
  static String primaryLabel({required String plate, required String vin}) {
    if (plate.isNotEmpty) return plate;
    final tail = vinTail(vin);
    return tail.isEmpty ? '我的车' : '尾号$tail';
  }
}
