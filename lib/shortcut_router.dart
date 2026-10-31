// 长按 App 图标的快捷方式路由（Day 7）
//
// 链路：
//   res/xml/shortcuts.xml 里的静态快捷方式
//     → MainActivity 捕获 intent.action
//     → MethodChannel('mymg/shortcut')
//     → 这里把 action 分发给 HomePage
//
// 两种时机都要覆盖：
//   - 冷启动：App 没在跑，快捷方式拉起进程 → Flutter 启动后主动 getPendingAction
//   - 热启动：App 在后台 → 原生 onNewIntent 主动 invokeMethod('shortcut')

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 快捷方式语义化 id（与 MainActivity.shortcutName 一一对应）
class ShortcutAction {
  static const history = 'history';
  static const map = 'map';
  static const control = 'control';
  static const quickControl = 'quick_control';
}

class ShortcutRouter {
  ShortcutRouter._();

  static const _channel = MethodChannel('mymg/shortcut');

  static String? _pending;

  static final _controller = StreamController<String>.broadcast();

  /// HomePage 订阅它拿"运行中"到达的快捷方式
  static Stream<String> get stream => _controller.stream;

  /// 全局只调一次（main() 里）
  static void init() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shortcut') {
        final name = call.arguments as String?;
        if (name != null && name.isNotEmpty) _emit(name);
      }
      return null;
    });
  }

  /// Flutter 启动后主动拉一次冷启动遗留的 action
  static Future<void> pullInitial() async {
    try {
      final name = await _channel.invokeMethod<String>('getPendingAction');
      if (name != null && name.isNotEmpty) _pending = name;
    } on MissingPluginException {
      // 非 Android / 单元测试环境
    } catch (e) {
      debugPrint('[MYMG] 读取快捷方式失败: $e');
    }
  }

  /// 取走冷启动遗留的 action（取一次就清空，避免重复跳转）
  static String? consumePending() {
    final p = _pending;
    _pending = null;
    return p;
  }

  static void _emit(String name) {
    // 没有订阅者时先缓存，等 HomePage initState 来取
    if (!_controller.hasListener) {
      _pending = name;
      return;
    }
    _controller.add(name);
  }
}
