import 'package:flutter/material.dart';

import '../ui_design_tokens.dart';

class QuickActionTile extends StatelessWidget {
  const QuickActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.active = false,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool active;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    final scheme = Theme.of(context).colorScheme;
    final color = active
        ? scheme.primary
        : Theme.of(context).colorScheme.onSurface;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: MyMgSpacing.controlMin),
        child: FilledButton.tonalIcon(
          onPressed: enabled ? onPressed : null,
          icon: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(icon, color: color),
          label: Text(label),
          style: FilledButton.styleFrom(
            foregroundColor: color,
            backgroundColor: active
                ? scheme.primary.withValues(alpha: 0.12)
                : scheme.surfaceContainerLow.withValues(alpha: 0.72),
            minimumSize: const Size.fromHeight(MyMgSpacing.controlMin),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(MyMgRadius.control),
            ),
          ),
        ),
      ),
    );
  }
}
