// 自定义车辆图片：首页顶部 Hero 与桌面小组件共用一张图。
//
// 存储：
//   - 文件落到 App 沙盒 `car/custom_car.png`（卸载即清）
//   - SharedPreferences 记路径：`mymg.car.image_path`
//   - 空路径 = 用内置默认图（assets/car/car_hero.png）
//
// 小组件侧读同一路径：RemoteViews.setImageViewBitmap 可直接吃本地文件。

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kCarImagePathKey = 'mymg.car.image_path';
const String kCarImageAssetDefault = 'assets/car/car_hero.png';

class CarImageStore {
  CarImageStore._();

  static const _fileName = 'custom_car.png';

  /// 自定义图绝对路径；null/文件不存在 = 用默认资产图
  static Future<String?> customPath() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final path = prefs.getString(kCarImagePathKey);
      if (path == null || path.trim().isEmpty) return null;
      final f = File(path);
      return await f.exists() ? path : null;
    } catch (_) {
      return null;
    }
  }

  /// 供 Widget 渲染：优先自定义文件，否则返回 null（原生用内置 drawable）
  static Future<String?> widgetBitmapPath() => customPath();

  /// 从任意图片字节写入自定义车辆图（已解码/重编码为 PNG，限制最长边 1600）
  static Future<String> saveFromBytes(Uint8List bytes) async {
    final dir = await getApplicationDocumentsDirectory();
    final carDir = Directory(p.join(dir.path, 'car'));
    if (!await carDir.exists()) await carDir.create(recursive: true);
    final out = File(p.join(carDir.path, _fileName));

    Uint8List outBytes = bytes;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      var w = img.width;
      var h = img.height;
      const maxSide = 1600;
      if (w > maxSide || h > maxSide) {
        final scale = maxSide / (w > h ? w : h);
        w = (w * scale).round();
        h = (h * scale).round();
      }
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final paint = ui.Paint()..filterQuality = ui.FilterQuality.high;
      canvas.drawImageRect(
        img,
        ui.Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        paint,
      );
      final pic = recorder.endRecording();
      final outImg = await pic.toImage(w, h);
      final data = await outImg.toByteData(format: ui.ImageByteFormat.png);
      if (data != null) outBytes = data.buffer.asUint8List();
      img.dispose();
      outImg.dispose();
    } catch (e) {
      debugPrint('[MYMG] 车图重编码失败，按原字节落盘: $e');
    }

    await out.writeAsBytes(outBytes, flush: true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kCarImagePathKey, out.path);
    return out.path;
  }

  /// 从文件复制进来（相册/文件选择器给出的源路径）
  static Future<String> saveFromFile(String sourcePath) async {
    final bytes = await File(sourcePath).readAsBytes();
    return saveFromBytes(bytes);
  }

  /// 恢复默认车图（删自定义）
  static Future<void> resetToDefault() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final old = prefs.getString(kCarImagePathKey);
      await prefs.remove(kCarImagePathKey);
      if (old != null) {
        final f = File(old);
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
  }
}
