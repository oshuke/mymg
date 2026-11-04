// 自定义车辆图片：首页顶部 Hero 与桌面小组件共用一张图。
//
// 存储：
//   - 文件落到 App 沙盒 `car/custom_car_<revision>.png`（卸载即清）
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

  static final revision = ValueNotifier<int>(0);

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

  /// 首页 Hero 与桌面小组件共用同一张用户车辆图片。
  static Future<String?> heroPath() => customPath();

  /// 从任意图片字节写入自定义车辆图（已解码/重编码为 PNG，限制最长边 1600）
  static Future<String> saveFromBytes(Uint8List bytes) async {
    final dir = await getApplicationDocumentsDirectory();
    final carDir = Directory(p.join(dir.path, 'car'));
    if (!await carDir.exists()) await carDir.create(recursive: true);
    final out = File(
      p.join(
        carDir.path,
        'custom_car_${DateTime.now().microsecondsSinceEpoch}.png',
      ),
    );
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString(kCarImagePathKey);

    late Uint8List outBytes;
    ui.Codec? codec;
    ui.Image? img;
    ui.Image? outImg;
    ui.Picture? pic;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      img = frame.image;
      var w = img.width;
      var h = img.height;
      const maxSide = 1600;
      if (w > maxSide || h > maxSide) {
        final scale = maxSide / (w > h ? w : h);
        w = (w * scale).round().clamp(1, maxSide);
        h = (h * scale).round().clamp(1, maxSide);
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
      pic = recorder.endRecording();
      outImg = await pic.toImage(w, h);
      final data = await outImg.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw const FormatException('无法读取图片');
      outBytes = data.buffer.asUint8List();
    } finally {
      codec?.dispose();
      img?.dispose();
      pic?.dispose();
      outImg?.dispose();
    }

    await out.writeAsBytes(outBytes, flush: true);
    if (!await prefs.setString(kCarImagePathKey, out.path)) {
      await out.delete();
      throw const FileSystemException('无法保存车辆图片设置');
    }
    revision.value++;
    await _removeOwnedFile(previous, carDir);
    return out.path;
  }

  /// 从文件复制进来（相册/文件选择器给出的源路径）
  static Future<String> saveFromFile(String sourcePath) async {
    final bytes = await File(sourcePath).readAsBytes();
    return saveFromBytes(bytes);
  }

  /// 恢复默认车图（删自定义）
  static Future<void> resetToDefault() async {
    final prefs = await SharedPreferences.getInstance();
    final old = prefs.getString(kCarImagePathKey);
    if (!await prefs.remove(kCarImagePathKey)) {
      throw const FileSystemException('无法恢复默认车辆图片');
    }
    revision.value++;
    final dir = await getApplicationDocumentsDirectory();
    await _removeOwnedFile(old, Directory(p.join(dir.path, 'car')));
  }

  static Future<void> _removeOwnedFile(String? path, Directory carDir) async {
    if (path == null ||
        p.dirname(p.absolute(path)) != p.absolute(carDir.path) ||
        !RegExp(r'^custom_car_[0-9]+\.png$').hasMatch(p.basename(path))) {
      return;
    }
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // The active preference is already saved; obsolete-file cleanup is best effort.
    }
  }
}
