import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// 应用主题：中性纸面 + 松绿只作强调色。
/// 阅读页纸色/夜间仍在阅读菜单，不在此覆盖。
class AppTheme {
  AppTheme._();

  /// 强调色（书脊布）
  static const Color seed = Color(0xFF4A5D4E);

  /// 浅色纸面（刻意中性，避免 seed 染绿整页）
  static const Color paper = Color(0xFFFAF9F5);
  static const Color paperDim = Color(0xFFF1F0EA);
  static const Color paperLine = Color(0xFFE4E2D9);

  static ThemeData light({Color? dynamicSeed}) {
    final base = ColorScheme.fromSeed(
      seedColor: dynamicSeed ?? seed,
      brightness: Brightness.light,
    );
    final scheme = base.copyWith(
      surface: dynamicSeed == null ? paper : base.surface,
      surfaceContainerLowest: const Color(0xFFFFFEFB),
      surfaceContainerLow: const Color(0xFFF7F6F1),
      surfaceContainer: paperDim,
      surfaceContainerHigh: const Color(0xFFEAE8E0),
      surfaceContainerHighest: const Color(0xFFE0DED4),
      outlineVariant: paperLine,
    );
    return _base(scheme);
  }

  static ThemeData dark({Color? dynamicSeed}) {
    final base = ColorScheme.fromSeed(
      seedColor: dynamicSeed ?? seed,
      brightness: Brightness.dark,
    );
    return _base(base);
  }

  static ThemeData _base(ColorScheme scheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 64,
        backgroundColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        elevation: 0,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 22,
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shadowColor: scheme.shadow.withValues(alpha: 0.18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        iconColor: scheme.onSurfaceVariant,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? scheme.primary.withValues(alpha: 0.12)
                : scheme.surfaceContainerLow,
          ),
          foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 0.6,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(color: scheme.onInverseSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          // Zoom：Flutter 原生缩放过渡，比 FadeUpwards 更有「推近」感
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: ZoomPageTransitionsBuilder(),
        },
      ),
    );
  }
}
