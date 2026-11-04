import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui_design_tokens.dart';
import '../ui_navigation_contract.dart';
import 'frosted_page.dart';
import 'glass_surface.dart';
import 'system_bars.dart';

class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.currentIndex,
    required this.onIndexChanged,
    required this.body,
  });

  final int currentIndex;
  final ValueChanged<int> onIndexChanged;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icons = [
      CupertinoIcons.house,
      CupertinoIcons.car_detailed,
      CupertinoIcons.heart,
      CupertinoIcons.location,
    ];
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemBarsFor(Theme.of(context).brightness),
      child: FrostedBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          extendBody: true,
          body: SafeArea(top: false, bottom: false, child: body),
          // Paint the page behind the entire transparent dock slot. Scaffold
          // supplies its height as MediaQuery bottom padding to page content.
          bottomNavigationBar: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: MyMgSpacing.page,
                vertical: 8,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(MyMgRadius.navigation),
                  boxShadow: MyMgDesignTokens.navigationShadow,
                ),
                child: GlassSurface(
                  key: const ValueKey('main-navigation'),
                  borderRadius: MyMgRadius.navigation,
                  padding: EdgeInsets.zero,
                  tint: Theme.of(context).brightness == Brightness.dark
                      ? MyMgDesignTokens.darkGlass
                      : MyMgDesignTokens.glassSurfaceStrong,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 68),
                    child: IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < productDestinations.length; i++)
                            Expanded(
                              child: Semantics(
                                container: true,
                                selected: i == currentIndex,
                                button: true,
                                label: productDestinations[i].label,
                                onTap: () => onIndexChanged(i),
                                excludeSemantics: true,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(
                                    MyMgRadius.navigation,
                                  ),
                                  onTap: () => onIndexChanged(i),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 2,
                                      vertical: 8,
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          icons[i],
                                          size: 24,
                                          color: i == currentIndex
                                              ? scheme.primary
                                              : scheme.onSurfaceVariant,
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          productDestinations[i].label,
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            fontSize: 11,
                                            height: 16 / 11,
                                            color: i == currentIndex
                                                ? (Theme.of(context)
                                                              .brightness ==
                                                          Brightness.light
                                                      ? MyMgDesignTokens
                                                            .primaryBlueDark
                                                      : scheme.primary)
                                                : scheme.onSurfaceVariant,
                                            fontWeight: i == currentIndex
                                                ? FontWeight.w600
                                                : FontWeight.w400,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
