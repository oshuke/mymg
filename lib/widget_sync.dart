// 桌面小组件的数据通道（Day 7）
//
// 职责划分：
//   Flutter 侧：把最新车况序列化成一条 JSON 写进 SharedPreferences
//               （最终落在 Android 的 `FlutterSharedPreferences` XML 里，
//                键为 `flutter.mymg.widget.json`）；
//   原生侧  ：AppWidgetProvider 直接读这个 XML 渲染 RemoteViews。
//
// 为什么走 SharedPreferences 而不是自定义 MethodChannel 传数据？
//   - 后台 WorkManager 跑在独立 Dart isolate 里，**拿不到自定义 MethodChannel**，
//     但它能写 SharedPreferences。走 prefs 让"后台刷新也能更新桌面小组件"成立。
//   - 自定义 channel 只用来"敲门"（通知原生立刻重绘），数据不从这里过。
//
// 注意：shared_preferences 到 Android 的键名会自动加 `flutter.` 前缀，
// 原生侧读的时候必须带上（Constants 里写死，别用字面量手滑）。

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mymg/src/rust/vehicle/summary.dart';

/// SharedPreferences 里的键（Dart 侧视角，不含 `flutter.` 前缀）
const String kWidgetJsonKey = 'mymg.widget.json';

class WidgetSync {
  WidgetSync._();

  static const _channel = MethodChannel('mymg/widget');

  /// 把一次车况写入小组件数据槽，并请求原生立即重绘。
  ///
  /// 在后台 isolate 里调用时 channel 不可用 —— 会静默跳过敲门，
  /// 但数据已经落盘，小组件下一次 onUpdate 就能读到。
  ///
  /// [plate] 与 [vinTail] 用于小组件顶部的身份标题：车牌优先，没填则显示 VIN 尾号。
  /// [carImagePath] 自定义车辆图绝对路径（可选），小组件用它覆盖默认车图。
  static Future<void> push(
    VehicleSummary s, {
    required String vin,
    String plate = '',
    String? carImagePath,
  }) async {
    final payload = <String, Object?>{
      // 车牌不再上小组件（布局已去掉身份行），字段保留兼容旧包
      'plate': plate,
      'vin_tail': vin.length >= 6 ? vin.substring(vin.length - 6) : vin,
      'fuel': s.fuelPercent,
      'range': s.rangeKm,
      'odometer': s.odometerKm,
      'journey': s.journeyKm,
      'consumption': s.fuelConsumption,
      'locked': s.allLocked,
      'doors': s.allDoorsClosed,
      'windows': s.allWindowsClosed,
      'ac': s.acOn,
      'interior': s.interiorTemp,
      'exterior': s.exteriorTemp,
      'tyres': s.tyreKpa,
      'alert_count': (s.alerts ?? const []).length,
      'server_time': s.updateTime,
      'captured_at': DateTime.now().millisecondsSinceEpoch,
      'car_image': carImagePath,
    };
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(kWidgetJsonKey, jsonEncode(payload));
    } catch (e) {
      debugPrint('[MYMG] 小组件数据写入失败: $e');
      return;
    }
    await refresh();
  }

  /// 请求原生立刻重绘小组件。返回 true 表示至少有一个小组件实例被刷新。
  ///
  /// 若用户还没往桌面添加小组件，Android 没有任何 widget id 可更新，
  /// 原生会返回 false（不是错误，只是"没装"）。
  static Future<bool> refresh() async {
    try {
      final ok = await _channel.invokeMethod<bool>('refresh');
      return ok ?? false;
    } on MissingPluginException {
      // 后台 isolate / 单元测试环境：没有原生端，正常
      return false;
    } catch (e) {
      debugPrint('[MYMG] 小组件刷新请求失败: $e');
      return false;
    }
  }

  /// 车辆图片变更后立刻重绘（不带新数据，只换图）。
  static Future<void> refreshCarImage(String? path) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(kCarImagePrefsKey, path ?? '');
    } catch (_) {}
    await refresh();
  }

  /// 小组件专用车辆图（可与首页 Hero 分开）；空 = 回退共用键。
  static Future<void> setWidgetCarImage(String? path) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(kWidgetCarImagePrefsKey, path ?? '');
    } catch (_) {}
    await refresh();
  }

  /// 小组件整体背景图路径；空 = 用默认底。
  static Future<void> setWidgetBgImage(String? path) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(kWidgetBgPrefsKey, path ?? '');
    } catch (_) {}
    await refresh();
  }

  /// 背景透明度 0–255（255 不透明）。
  static Future<void> setWidgetBgAlpha(int alpha) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(kWidgetBgAlphaPrefsKey, alpha.clamp(0, 255));
    } catch (_) {}
    await refresh();
  }
}

/// 自定义车辆图在 SharedPreferences 的键（原生读 `flutter.` 前缀版本）
const String kCarImagePrefsKey = 'mymg.car.image_path';

/// 小组件专用车辆图（优先于 kCarImagePrefsKey）
const String kWidgetCarImagePrefsKey = 'mymg.widget.car_image_path';

/// 小组件整体背景图
const String kWidgetBgPrefsKey = 'mymg.widget.bg_path';

/// 小组件背景透明度 0–255
const String kWidgetBgAlphaPrefsKey = 'mymg.widget.bg_alpha';
