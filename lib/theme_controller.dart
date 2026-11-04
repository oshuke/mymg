import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ui_design_tokens.dart';
import 'ui/system_bars.dart';

/// 主题模式：跟随系统 / 浅色 / 深色
enum AppThemeMode { system, light, dark }

const kThemeModeKey = 'mymg.theme_mode';

/// 全局主题状态：MaterialApp 与设置页共用。
class ThemeController extends ChangeNotifier {
  ThemeController._();

  static final ThemeController instance = ThemeController._();

  AppThemeMode _mode = AppThemeMode.system;
  AppThemeMode get mode => _mode;

  ThemeMode get materialMode => switch (_mode) {
    AppThemeMode.system => ThemeMode.system,
    AppThemeMode.light => ThemeMode.light,
    AppThemeMode.dark => ThemeMode.dark,
  };

  String get label => switch (_mode) {
    AppThemeMode.system => '跟随系统',
    AppThemeMode.light => '浅色',
    AppThemeMode.dark => '深色',
  };

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(kThemeModeKey);
      _mode = AppThemeMode.values.firstWhere(
        (e) => e.name == raw,
        orElse: () => AppThemeMode.system,
      );
    } catch (_) {
      _mode = AppThemeMode.system;
    }
    notifyListeners();
  }

  Future<void> setMode(AppThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(kThemeModeKey, mode.name);
    } catch (_) {}
  }
}

/// 供子树监听主题变化（设置页切换后重建 UI）
class ThemeScope extends InheritedNotifier<ThemeController> {
  const ThemeScope({
    super.key,
    required ThemeController controller,
    required super.child,
  }) : super(notifier: controller);

  static ThemeController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThemeScope>();
    return scope?.notifier ?? ThemeController.instance;
  }
}

/// 浅色 / 深色共用的主题工厂
ThemeData buildAppTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  // 深色：手写高对比 surface 阶梯，避免 fromSeed 在暗色下发灰、字读不清
  final scheme = isDark
      ? ColorScheme.fromSeed(
          seedColor: MyMgDesignTokens.primaryBlue,
          brightness: Brightness.dark,
        ).copyWith(
          surface: const Color(0xFF121214),
          onSurface: const Color(0xFFF5F5F7),
          surfaceContainerLowest: const Color(0xFF0C0C0E),
          surfaceContainerLow: const Color(0xFF1A1A1E),
          surfaceContainer: const Color(0xFF232328),
          surfaceContainerHigh: const Color(0xFF2C2C32),
          surfaceContainerHighest: const Color(0xFF38383F),
          onSurfaceVariant: const Color(0xFFD0D0D6),
          outline: const Color(0xFFA0A0A8),
          outlineVariant: const Color(0xFF4A4A52),
          primary: MyMgDesignTokens.darkBlue,
          onPrimary: const Color(0xFF14213B),
          secondaryContainer: const Color(0xFF203554),
          onSecondaryContainer: const Color(0xFFD6E6FF),
        )
      : ColorScheme.fromSeed(
          seedColor: MyMgDesignTokens.primaryBlue,
          brightness: Brightness.light,
        ).copyWith(
          primary: MyMgDesignTokens.primaryBlue,
          onPrimary: Colors.white,
          surface: MyMgDesignTokens.pageBackground,
          onSurface: MyMgDesignTokens.textPrimary,
          onSurfaceVariant: const Color(0xFF5C5C5C),
        );

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: scheme.surface,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeUpPageTransitionsBuilder(),
        TargetPlatform.iOS: FadeUpPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      systemOverlayStyle: systemBarsFor(brightness),
      centerTitle: false,
      scrolledUnderElevation: 0.5,
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      // 深色下用实色 elevated surface，保证卡片与字对比
      color: isDark
          ? MyMgDesignTokens.darkGlass
          : MyMgDesignTokens.glassSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: isDark
              ? Colors.white.withOpacity(0.06)
              : Colors.white.withOpacity(0.48),
          width: 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 2,
      backgroundColor: scheme.primaryContainer,
      foregroundColor: scheme.onPrimaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: scheme.primary,
      unselectedLabelColor: scheme.onSurfaceVariant,
      indicatorColor: scheme.primary,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: Colors.transparent,
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      iconColor: scheme.onSurfaceVariant,
    ),
    textTheme: isDark
        ? Typography.material2021().white.merge(
            TextTheme(
              bodyLarge: TextStyle(color: scheme.onSurface, fontSize: 16),
              bodyMedium: TextStyle(color: scheme.onSurface, fontSize: 14),
              bodySmall: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 12,
              ),
              labelSmall: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 11,
              ),
              titleMedium: TextStyle(
                color: scheme.onSurface,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          )
        : null,
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF1A1A1C),
      contentTextStyle: const TextStyle(
        color: Colors.white,
        fontSize: 13.5,
        height: 1.4,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        foregroundColor: scheme.onPrimary,
        backgroundColor: scheme.primary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      filled: true,
      fillColor: isDark ? scheme.surfaceContainerHighest : null,
      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
    ),
  );
}

/// 主题语义色：替换硬编码 Colors.black54 等
///
/// 使用全局 ThemeController + 系统亮度推断，便于在无 context 的
/// 构造默认值 / 辅助方法中引用；有 context 时仍可用扩展 getter。
class AppPalette {
  AppPalette._();

  static bool get _isDark {
    switch (ThemeController.instance.mode) {
      case AppThemeMode.dark:
        return true;
      case AppThemeMode.light:
        return false;
      case AppThemeMode.system:
        final w = WidgetsBinding.instance.platformDispatcher.platformBrightness;
        return w == Brightness.dark;
    }
  }

  /// 次要说明文字
  static Color get muted =>
      _isDark ? const Color(0xFFD0D0D6) : const Color(0xFF5C5C5C);

  /// 更弱的辅助信息
  static Color get subtle =>
      _isDark ? const Color(0xFFB0B0B8) : const Color(0xFF757575);

  /// 主文字
  static Color get strong =>
      _isDark ? const Color(0xFFF5F5F7) : const Color(0xDD000000);

  /// 进度条轨道 / 分割
  static Color get track =>
      _isDark ? Colors.white.withOpacity(0.24) : Colors.black.withOpacity(0.12);

  // ── 状态色：保证深浅底上都够亮 ──

  /// 警示图标/文字（橙）
  static Color get warn =>
      _isDark ? const Color(0xFFFFB74D) : const Color(0xFFE65100);

  /// 错误图标/文字（红）
  static Color get danger =>
      _isDark ? const Color(0xFFFF8A80) : const Color(0xFFC62828);

  /// 成功（绿）
  static Color get ok =>
      _isDark ? const Color(0xFF81C784) : const Color(0xFF2E7D32);

  /// 信息/链接（蓝）
  static Color get info =>
      _isDark ? const Color(0xFF90CAF9) : const Color(0xFF1565C0);

  /// 告警容器底
  static Color get warnBg =>
      _isDark ? const Color(0xFF3E2E12) : const Color(0xFFFFF8E1);

  /// 错误容器底
  static Color get dangerBg =>
      _isDark ? const Color(0xFF3E1618) : const Color(0xFFFFEBEE);

  /// 成功容器底
  static Color get okBg =>
      _isDark ? const Color(0xFF1B3A24) : const Color(0xFFE8F5E9);

  /// 中性弱底（chip）
  static Color get chipBg =>
      _isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.04);

  /// AI 卡片底：浅色微紫 / 深色深紫，避免浅字贴白底
  static Color get aiCardBg =>
      _isDark ? const Color(0xFF1E1A2A) : const Color(0xFFFBFAFF);

  /// AI 指标 pill 底
  static Color get aiPillBg =>
      _isDark ? const Color(0xFF2A2440) : const Color(0xFFEDE7FF);

  /// AI pill 主文字
  static Color get aiPillFg =>
      _isDark ? const Color(0xFFF0EBFF) : const Color(0xFF2A1F5C);

  /// AI pill 标签
  static Color get aiPillLabel =>
      _isDark ? const Color(0xFFB8B0D0) : const Color(0xFF5C4D8C);

  /// 图表系列色（品牌红，深浅底都可读）
  static const Color chartLine = Color(0xFFEF5350);
  static const Color chartFillTop = Color(0x66EF5350);
  static const Color chartFillBottom = Color(0x11EF5350);
  static const Color chartGrid = Color(0x33FFFFFF);
  static const Color chartGridLight = Color(0x22000000);

  static Color get chartLabel => muted;
  static Color get chartTooltipBg =>
      _isDark ? const Color(0xFF2C2C32) : const Color(0xF2212121);
  static Color get chartTooltipFg => const Color(0xFFF5F5F7);
}

/// 主题语义色扩展（有 context 时优先使用真实 ThemeData）
extension AppThemeColors on BuildContext {
  ColorScheme get _cs => Theme.of(this).colorScheme;

  Color get muted => _cs.onSurfaceVariant;

  Color get subtle => _cs.onSurfaceVariant.withOpacity(0.8);

  Color get strong => _cs.onSurface;

  Color get track => Theme.of(this).brightness == Brightness.dark
      ? Colors.white24
      : Colors.black12;

  Color get iconMuted => _cs.onSurfaceVariant;

  Color get info => _cs.primary;

  Color get success => AppPalette.ok;

  Color get warning => AppPalette.warn;

  Color get danger => AppPalette.danger;
}

/// 淡入 + 微上移页面过渡（与 main 内私有类行为一致，抽出共用）
class FadeUpPageTransitionsBuilder extends PageTransitionsBuilder {
  const FadeUpPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.035),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}
