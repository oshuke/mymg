import 'package:flutter/services.dart';

/// Per-engine request coalescing; Android also coalesces across engines.
class BlePermissionController {
  BlePermissionController._();

  static final instance = BlePermissionController._();
  static const _channel = MethodChannel('mymg/ble');
  static const deniedMessage =
      '蓝牙权限未授予，请允许附近设备和定位权限后重试，或打开应用设置';

  Future<bool>? _pending;
  bool denied = false;

  Future<bool> request() => _pending ??= _request();

  Future<bool> _request() async {
    try {
      final granted =
          await _channel.invokeMethod<bool>('requestPermissions') == true;
      denied = !granted;
      return granted;
    } catch (_) {
      denied = true;
      return false;
    } finally {
      _pending = null;
    }
  }

  Future<bool> openAppSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openAppSettings') == true;
    } catch (_) {
      return false;
    }
  }
}
