import 'package:flutter/material.dart';

import '../theme_controller.dart';
import '../ui_design_tokens.dart';
import 'glass_surface.dart';

class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
    this.icon,
    this.accent = MyMgDesignTokens.primaryBlue,
  });

  final String label;
  final String value;
  final String unit;
  final IconData? icon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) Icon(icon, size: 18, color: accent),
          if (icon != null) const SizedBox(height: 8),
          Text(label, style: TextStyle(color: context.muted, fontSize: 12)),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  value,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Text(unit, style: TextStyle(color: context.muted, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}
