import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The authenticated application's route boundary. Details pop one level and
/// main tabs return home. Dialogs retain dismiss-first behavior. Standalone
/// widget/tile engines do not use this navigator.
class HomeReturnNavigator extends StatefulWidget {
  const HomeReturnNavigator({
    super.key,
    required this.isHome,
    required this.onHome,
    required this.child,
  });

  final bool isHome;
  final VoidCallback onHome;
  final Widget child;

  @override
  State<HomeReturnNavigator> createState() => _HomeReturnNavigatorState();
}

class _HomeReturnNavigatorState extends State<HomeReturnNavigator> {
  final _navigator = GlobalKey<NavigatorState>();
  late final _observer = _HomeRouteObserver(_disarm);
  late final _content = ValueNotifier<Widget>(widget.child);
  static const _platform = MethodChannel('mymg/navigation');
  Timer? _confirmation;
  bool _moving = false;

  @override
  void didUpdateWidget(covariant HomeReturnNavigator oldWidget) {
    super.didUpdateWidget(oldWidget);
    _content.value = widget.child;
    if (oldWidget.isHome != widget.isHome) _disarm();
  }

  void _disarm() {
    _confirmation?.cancel();
    _confirmation = null;
  }

  Future<void> _back() async {
    final nav = _navigator.currentState;
    if (nav == null || _moving) return;
    if (nav.canPop()) {
      // Preserve the detail stack: a dialog/form may handle or veto the pop,
      // and a page returns only to its immediate parent.
      await nav.maybePop();
      return;
    }
    if (!widget.isHome) {
      _disarm();
      widget.onHome();
      return;
    }
    if (_confirmation != null) {
      _disarm();
      _moving = true;
      try {
        final moved = await _platform.invokeMethod<bool>('moveToBackground');
        if (moved != true) _showHint('暂时无法返回桌面，请使用系统主页键');
      } on PlatformException {
        _showHint('暂时无法返回桌面，请使用系统主页键');
      } on MissingPluginException {
        // Preserve the task rather than finish the activity on unsupported hosts.
        _showHint('请使用系统主页键返回桌面');
      } finally {
        _moving = false;
      }
      return;
    }
    _confirmation = Timer(const Duration(seconds: 2), _disarm);
    _showHint('再按一次返回桌面');
  }

  void _showHint(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(_navigator.currentContext!);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  void dispose() {
    _disarm();
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: false,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) unawaited(_back());
    },
    child: Navigator(
      key: _navigator,
      observers: [_observer],
      onGenerateInitialRoutes: (_, _) => [
        MaterialPageRoute<void>(
          builder: (_) => ValueListenableBuilder<Widget>(
            valueListenable: _content,
            builder: (_, child, _) => child,
          ),
        ),
      ],
    ),
  );
}

class _HomeRouteObserver extends NavigatorObserver {
  _HomeRouteObserver(this.onRouteChanged);
  final VoidCallback onRouteChanged;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    onRouteChanged();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    onRouteChanged();
  }
}
