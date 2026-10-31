import 'package:flutter/material.dart';

/// 全局页面过渡：轻量淡入 + 微上移，避免默认 Material 滑动过“重”。
class FadeSlidePageRoute<T> extends PageRouteBuilder<T> {
  FadeSlidePageRoute({required this.page, super.settings})
      : super(
          transitionDuration: const Duration(milliseconds: 280),
          reverseTransitionDuration: const Duration(milliseconds: 220),
          pageBuilder: (_, __, ___) => page,
          transitionsBuilder: (context, animation, secondary, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return FadeTransition(
              opacity: curved,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.04),
                  end: Offset.zero,
                ).animate(curved),
                child: child,
              ),
            );
          },
        );

  final Widget page;
}

/// 子项错落入场：仅首次播放，刷新数据时不重放入场，省 GPU/动效开销。
class StaggeredAppear extends StatefulWidget {
  const StaggeredAppear({
    super.key,
    required this.index,
    required this.child,
    this.baseDelay = const Duration(milliseconds: 24),
    this.step = const Duration(milliseconds: 28),
    this.animate = true,
  });

  final int index;
  final Widget child;
  final Duration baseDelay;
  final Duration step;

  /// false 时直接展示子组件（用于刷新后的重建，避免反复动画）
  final bool animate;

  @override
  State<StaggeredAppear> createState() => _StaggeredAppearState();
}

class _StaggeredAppearState extends State<StaggeredAppear>
    with SingleTickerProviderStateMixin {
  AnimationController? _ctrl;
  Animation<double>? _fade;
  Animation<Offset>? _slide;

  @override
  void initState() {
    super.initState();
    if (!widget.animate) return;
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _fade = CurvedAnimation(parent: _ctrl!, curve: Curves.easeOut);
    _slide = Tween<Offset>(begin: const Offset(0, 0.04), end: Offset.zero)
        .animate(CurvedAnimation(parent: _ctrl!, curve: Curves.easeOutCubic));
    final delay = widget.baseDelay + widget.step * widget.index;
    Future<void>.delayed(delay, () {
      if (mounted) _ctrl?.forward();
    });
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _ctrl;
    final fade = _fade;
    final slide = _slide;
    if (ctrl == null || fade == null || slide == null) {
      return widget.child;
    }
    return FadeTransition(
      opacity: fade,
      child: SlideTransition(position: slide, child: widget.child),
    );
  }
}

/// 品牌红脉冲：用于加载中的指示，比纯转圈更有产品感。
class BrandPulse extends StatefulWidget {
  const BrandPulse({super.key, required this.child, this.playing = true});

  final Widget child;
  final bool playing;

  @override
  State<BrandPulse> createState() => _BrandPulseState();
}

class _BrandPulseState extends State<BrandPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant BrandPulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing && !_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    } else if (!widget.playing && _ctrl.isAnimating) {
      _ctrl.stop();
      _ctrl.value = 0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.45, end: 1).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
      ),
      child: widget.child,
    );
  }
}

/// 数值变化时的轻量交叉淡入（首页油量/续航等）。
class ValueFade extends StatelessWidget {
  const ValueFade({
    super.key,
    required this.value,
    required this.builder,
  });

  final String value;
  final Widget Function(BuildContext, String) builder;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOut,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.2),
            end: Offset.zero,
          ).animate(anim),
          child: child,
        ),
      ),
      child: KeyedSubtree(key: ValueKey(value), child: builder(context, value)),
    );
  }
}

/// 按压缩放反馈：控车按钮 / 关键操作用，提供明确的触觉视觉回应。
class ScalePress extends StatefulWidget {
  const ScalePress({
    super.key,
    required this.onPressed,
    required this.child,
    this.scaleDown = 0.92,
    this.enabled = true,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final double scaleDown;
  final bool enabled;

  @override
  State<ScalePress> createState() => _ScalePressState();
}

class _ScalePressState extends State<ScalePress> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && widget.onPressed != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled
          ? (_) {
              setState(() => _pressed = false);
              widget.onPressed?.call();
            }
          : null,
      onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
      child: IgnorePointer(
        child: AnimatedScale(
          scale: _pressed && enabled ? widget.scaleDown : 1,
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          child: AnimatedOpacity(
            opacity: _pressed && enabled ? 0.85 : 1,
            duration: const Duration(milliseconds: 90),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
