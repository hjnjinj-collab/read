import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// 应用主题：松绿 seed 主导全应用色系（明暗均由 fromSeed 派生）。
/// 阅读页纸色/夜间仍在阅读菜单，不在此覆盖。
///
/// 玻璃准则：任何 BackdropFilter 必须叠加 [AppGlass.tint] 主色滤镜，
/// 禁止纯灰/无色模糊。
class AppTheme {
  AppTheme._();

  /// 书脊布色 —— 全应用主色系种子
  static const Color seed = Color(0xFF5B6C5A);

  static ThemeData light({Color? dynamicSeed}) {
    final scheme = ColorScheme.fromSeed(
      seedColor: dynamicSeed ?? seed,
      brightness: Brightness.light,
    );
    return _base(scheme);
  }

  static ThemeData dark({Color? dynamicSeed}) {
    final scheme = ColorScheme.fromSeed(
      seedColor: dynamicSeed ?? seed,
      brightness: Brightness.dark,
    );
    return _base(scheme);
  }

  static ThemeData _base(ColorScheme scheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
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
        height: 68,
        backgroundColor: Colors.transparent,
        indicatorColor: scheme.primaryContainer,
        elevation: 0,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 22,
            color: states.contains(WidgetState.selected)
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: states.contains(WidgetState.selected)
                ? scheme.onSurface
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shadowColor: scheme.shadow.withValues(alpha: 0.2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                ? scheme.primaryContainer
                : scheme.surfaceContainer,
          ),
          foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
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
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: ZoomPageTransitionsBuilder(),
        },
      ),
    );
  }
}

/// 毛玻璃准则：重模糊 + 干净近白遮罩；primary 只作发丝描边，避免脏色。
class AppGlass {
  AppGlass._();

  /// 底栏：高不透明近白/近黑，几乎不吃封面色相 →「净」
  static Color tint(ColorScheme scheme, {double strength = 0.55}) {
    final base = scheme.brightness == Brightness.light
        ? const Color(0xFFF4F6F3)
        : const Color(0xFF1A1D1A);
    // strength 仅极轻染 primary，防止整片橄榄
    return Color.lerp(base, scheme.primary, strength * 0.06)!
        .withValues(alpha: scheme.brightness == Brightness.light ? 0.78 : 0.72);
  }

  /// 顶栏：上更实、可下渐隐；同样近白，不混封面色
  static Color topTint(ColorScheme scheme) {
    final base = scheme.brightness == Brightness.light
        ? const Color(0xFFF7F8F5)
        : const Color(0xFF151815);
    return Color.lerp(base, scheme.primary, 0.04)!
        .withValues(alpha: scheme.brightness == Brightness.light ? 0.82 : 0.78);
  }

  /// 顶栏底部渐隐到此 alpha
  static double get topFadeAlpha => 0.0;

  /// 模糊半径：顶栏更重，把封面细节彻底糊掉
  static const double blurSigma = 48;
  static const double topBlurSigma = 64;

  /// 顶栏渐变模糊高度
  static const double topGlassHeight = 112;
}

/// 弹簧物理：统一曲线源（Flutter 系统弹簧族）
class AppMotion {
  AppMotion._();

  /// 轻快回弹（FAB / 按钮）
  static const Curve springOut = Curves.easeOutBack;

  /// 进入（网格 stagger）
  static const Curve enter = Curves.easeOutCubic;

  /// 离开
  static const Curve exit = Curves.easeInCubic;

  /// 布局切换
  static const Duration switchDuration = Duration(milliseconds: 260);

  /// 网格条目 stagger 步长
  static const Duration staggerStep = Duration(milliseconds: 28);

  /// 网格条目 stagger 总窗口上限
  static const int staggerMaxItems = 12;
}
