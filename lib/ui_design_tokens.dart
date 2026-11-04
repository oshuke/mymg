import 'package:flutter/material.dart';

/// Shared visual language for the light, frosted-glass oil-car UI.
class MyMgDesignTokens {
  MyMgDesignTokens._();

  static const primaryBlue = Color(0xFF247BFF);
  static const primaryBlueDark = Color(0xFF0F5FEA);
  static const fuelAccent = Color(0xFFF29B38);
  static const glassSurface = Color(0xBFFFFFFF);
  static const glassSurfaceStrong = Color(0xF2FFFFFF);
  static const glassBorder = Color(0x66FFFFFF);
  static const pageBackground = Color(0xFFF0F3FC);
  static const mistBlue = Color(0xFFE0E9FB);
  static const mistLilac = Color(0xFFEEEBF9);
  static const heroSky = Color(0xFF2865A1);
  static const heroHorizon = Color(0xFFB9D4EC);
  static const heroGround = Color(0xFFB2C7E1);
  static const darkBackground = Color(0xFF111725);
  static const darkGlass = Color(0xE6232D40);
  static const darkBlue = Color(0xFF8DB7FF);
  static const textPrimary = Color(0xFF151B2B);
  static const textSecondary = Color(0xFF65708A);
  static const success = Color(0xFF20B978);
  static const warning = Color(0xFFE58B22);
  static const danger = Color(0xFFD94B5B);

  static const cardShadow = [
    BoxShadow(color: Color(0x0C355389), blurRadius: 22, offset: Offset(0, 8)),
  ];

  static const navigationShadow = [
    BoxShadow(color: Color(0x19355389), blurRadius: 24, offset: Offset(0, 8)),
  ];
}

class MyMgSpacing {
  MyMgSpacing._();

  static const page = 16.0;
  static const section = 20.0;
  static const card = 16.0;
  static const controlMin = 48.0;
  static const iconButton = 44.0;
}

class MyMgRadius {
  MyMgRadius._();

  static const card = 22.0;
  static const navigation = 26.0;
  static const control = 16.0;
  static const pill = 999.0;
}

ThemeData buildMyMgLightTheme() {
  final base = ThemeData.light(useMaterial3: true);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: MyMgDesignTokens.primaryBlue,
        brightness: Brightness.light,
      ).copyWith(
        primary: MyMgDesignTokens.primaryBlue,
        onPrimary: Colors.white,
        surface: MyMgDesignTokens.pageBackground,
        onSurface: MyMgDesignTokens.textPrimary,
        onSurfaceVariant: MyMgDesignTokens.textSecondary,
      );

  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: MyMgDesignTokens.pageBackground,
    cardTheme: CardThemeData(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: MyMgDesignTokens.glassSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(MyMgRadius.card),
        side: const BorderSide(color: MyMgDesignTokens.glassBorder),
      ),
    ),
  );
}
