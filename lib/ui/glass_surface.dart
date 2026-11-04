import 'dart:ui';

import 'package:flutter/material.dart';

import '../ui_design_tokens.dart';

class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.onTap,
    this.tint,
    this.borderRadius = MyMgRadius.card,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final Color? tint;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Material(
          color:
              tint ??
              (dark
                  ? MyMgDesignTokens.darkGlass
                  : MyMgDesignTokens.glassSurface),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(borderRadius),
            side: BorderSide(
              color: dark
                  ? Colors.white.withValues(alpha: 0.09)
                  : MyMgDesignTokens.glassBorder,
            ),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(borderRadius),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
    return margin == null ? surface : Padding(padding: margin!, child: surface);
  }
}
