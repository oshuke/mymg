import 'package:flutter/material.dart';

import 'theme_controller.dart';
import 'ui/frosted_page.dart';
import 'ui/glass_surface.dart';
import 'ui_design_tokens.dart';

/// Shared settings chrome for both the tab and pushed detail pages.
class SettingsPageFrame extends StatelessWidget {
  const SettingsPageFrame({
    super.key,
    required this.title,
    required this.child,
    this.embedded = false,
  });

  final String title;
  final Widget child;
  final bool embedded;

  @override
  Widget build(BuildContext context) => FrostedBackground(
    child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(title),
        automaticallyImplyLeading: !embedded,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: child,
    ),
  );
}

/// A single full-width destination, with room for large accessibility text.
class SettingsEntryRow extends StatelessWidget {
  const SettingsEntryRow({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final Widget? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    child: GlassSurface(
      onTap: onTap,
      padding: const EdgeInsets.all(MyMgSpacing.card),
      child: Row(
        children: [
          Container(
            width: MyMgSpacing.iconButton,
            height: MyMgSpacing.iconButton,
            decoration: BoxDecoration(
              color: context.info.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, size: 23, color: context.info),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                    color: context.strong,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  DefaultTextStyle.merge(
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: context.muted,
                    ),
                    child: subtitle!,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.chevron_right_rounded, size: 20, color: context.subtle),
        ],
      ),
    ),
  );
}
