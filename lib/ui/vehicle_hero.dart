import 'dart:io';

import 'package:flutter/material.dart';

import '../car_image_store.dart';
import '../car_side_illustration.dart';
import '../ui_design_tokens.dart';

/// Shared, observable image source for the home, settings and other vehicle views.
class VehicleImage extends StatefulWidget {
  const VehicleImage({super.key, this.fit = BoxFit.contain});
  final BoxFit fit;

  @override
  State<VehicleImage> createState() => _VehicleImageState();
}

class _VehicleImageState extends State<VehicleImage> {
  late Future<String?> _path;

  @override
  void initState() {
    super.initState();
    _path = CarImageStore.heroPath();
    CarImageStore.revision.addListener(_reload);
  }

  void _reload() => setState(() => _path = CarImageStore.heroPath());

  @override
  void dispose() {
    CarImageStore.revision.removeListener(_reload);
    super.dispose();
  }

  Widget _fallback() => Semantics(
    label: '车辆示意图',
    image: true,
    child: LayoutBuilder(
      builder: (context, constraints) => Center(
        child: CarSideIllustration(
          width: constraints.maxWidth.isFinite ? constraints.maxWidth : 220,
          height: constraints.maxHeight.isFinite ? constraints.maxHeight : 88,
          accentColor: Theme.of(context).colorScheme.primary,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
    future: _path,
    builder: (_, snapshot) => snapshot.data == null
        ? _fallback()
        : Image.file(
            File(snapshot.data!),
            key: ValueKey(snapshot.data),
            fit: widget.fit,
            semanticLabel: '自定义车辆图片',
            errorBuilder: (_, __, ___) => _fallback(),
          ),
  );
}

class VehicleHeroCard extends StatelessWidget {
  const VehicleHeroCard({
    super.key,
    this.title,
    this.subtitle,
    this.onImageSettings,
  });
  final String? title;
  final String? subtitle;
  final VoidCallback? onImageSettings;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: 194,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(MyMgRadius.card),
        gradient: LinearGradient(
          colors: dark
              ? const [
                  MyMgDesignTokens.darkGlass,
                  MyMgDesignTokens.darkBackground,
                ]
              : const [MyMgDesignTokens.mistBlue, Color(0xFFF9FBFF)],
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          const Positioned.fill(
            child: Padding(
              padding: EdgeInsets.fromLTRB(12, 18, 12, 10),
              child: VehicleImage(),
            ),
          ),
          if (title != null || onImageSettings != null)
            Positioned(
              left: 16,
              top: 12,
              right: 6,
              child: Row(
                children: [
                  if (title != null)
                    Expanded(
                      child: Text(
                        title!,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  if (onImageSettings != null)
                    IconButton(
                      tooltip: '更换车辆图片',
                      onPressed: onImageSettings,
                      icon: const Icon(Icons.edit_outlined),
                    ),
                ],
              ),
            ),
          if (subtitle != null)
            Positioned(
              left: 16,
              bottom: 10,
              child: Text(
                subtitle!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class VehicleHero extends StatelessWidget {
  const VehicleHero({
    super.key,
    required this.title,
    this.subtitle,
    this.onImageSettings,
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onImageSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 246,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(MyMgRadius.card),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: Theme.of(context).brightness == Brightness.dark
              ? const [
                  MyMgDesignTokens.darkGlass,
                  MyMgDesignTokens.darkBackground,
                ]
              : const [MyMgDesignTokens.mistBlue, Color(0xFFF9FBFF)],
        ),
        boxShadow: MyMgDesignTokens.cardShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            top: 76,
            child: const Padding(
              padding: EdgeInsets.only(right: 4, bottom: 8),
              child: VehicleImage(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                    if (onImageSettings != null)
                      IconButton(
                        tooltip: '更换车辆图片',
                        onPressed: onImageSettings,
                        icon: const Icon(Icons.edit_outlined),
                      ),
                  ],
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
