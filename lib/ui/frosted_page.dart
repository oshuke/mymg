import 'package:flutter/material.dart';

import '../ui_design_tokens.dart';

/// Soft blue/lilac light behind the translucent surfaces, as in the references.
class FrostedBackground extends StatelessWidget {
  const FrostedBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [
                  MyMgDesignTokens.darkBackground,
                  Color(0xFF1C253C),
                  Color(0xFF141C2C),
                ]
              : const [
                  MyMgDesignTokens.mistBlue,
                  MyMgDesignTokens.mistLilac,
                  Color(0xFFF9FAFF),
                ],
        ),
      ),
      child: child,
    );
  }
}
