import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// 应用主题：松绿 seed 主导全应用色系（明暗均由 fromSeed 派生）。
/// 阅读页纸色/夜间仍在阅读菜单，不在此覆盖。
///
/// 玻璃准则：任何 BackdropFilter 必须叠加 [AppGlass.tint] 主色滤镜，
/// 禁止纯灰/无色模糊。模糊本身允许较高 sigma——卡顿根因是每帧
/// 读封面/取色，不是双层模糊。
class AppTheme {
  AppTheme._();

  static const Color seed = Color(0xFF5B6C5A);

  /// 预置主题色（松绿为首，默认）
  static const List<({String id, String label, Color color})> seedPresets = [
    (id: 'pine', label: '松绿', color: Color(0xFF5B6C5A)),
    (id: 'indigo', label: '靛青', color: Color(0xFF3D5A80)),
    (id: 'plum', label: '梅紫', color: Color(0xFF6B4E71)),
    (id: 'clay', label: '陶土', color: Color(0xFF8B5E3C)),
    (id: 'teal', label: '湖青', color: Color(0xFF2F6F6A)),
    (id: 'rose', label: '绯红', color: Color(0xFF8C3A4A)),
  ];

  static ThemeData light({Color? dynamicSeed, Color? seedOverride}) {
    final scheme = ColorScheme.fromSeed(
      seedColor: dynamicSeed ?? seedOverride ?? seed,
      brightness: Brightness.light,
    );
    return _base(scheme);
  }

  static ThemeData dark({Color? dynamicSeed, Color? seedOverride}) {
    final scheme = ColorScheme.fromSeed(
      seedColor: dynamicSeed ?? seedOverride ?? seed,
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

/// 毛玻璃准则：模糊层必须叠主色滤镜；滤镜必须是**低透明度着色**，
/// 禁止「半实色板」盖在 blur 上（会读成两层叠加）。
class AppGlass {
  AppGlass._();

  static Color tint(ColorScheme scheme, {double strength = 0.55}) {
    final base = scheme.brightness == Brightness.light
        ? const Color(0xFFF2F5F1)
        : const Color(0xFF1A1D1A);
    return Color.lerp(base, scheme.primaryContainer, strength)!
        .withValues(alpha: 0.5);
  }

  /// 悬浮导航柔光玻璃：主色只作「色渗」，不形成第二层色板
  /// [strength] = primaryContainer 混入比例 0–1；alpha 同步抬升，100% 才有可见色渗
  static Color navGlass(ColorScheme scheme, {double strength = 0.38}) {
    final base = scheme.brightness == Brightness.light
        ? scheme.surface
        : scheme.surfaceContainerHighest;
    final mixed = Color.lerp(base, scheme.primaryContainer, strength)!;
    // 色相 + 浓度都随 strength：否则 100% 仍像隔了一层纱
    final a = scheme.brightness == Brightness.light
        ? 0.24 + 0.36 * strength // 0→0.24, 1→0.60
        : 0.28 + 0.34 * strength; // 0→0.28, 1→0.62
    return mixed.withValues(alpha: a);
  }

  static Color topTint(ColorScheme scheme) {
    final base = scheme.brightness == Brightness.light
        ? const Color(0xFFF7F8F5)
        : const Color(0xFF151815);
    // 顶栏主色滤镜：混入 primary 更重
    return Color.lerp(base, scheme.primary, 0.52)!;
  }

  /// 底栏液态玻璃：更高圆角 + 内侧高光
  static const double navBarRadius = 32;

  static const double bottomAmbientHeight = 160;

  /// 双层模糊允许较高 sigma；性能靠「封面/主色只读缓存」保证
  static const double blurSigma = 40;
  static const double topBlurSigma = 48;

  static const double topGlassHeight = 148;
}

/// 弹簧物理：统一曲线源（Flutter 系统弹簧族）
class AppMotion {
  AppMotion._();

  static const Curve springOut = Curves.easeOutBack;
  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;
  // 网格重排：直接位移，禁止回弹/缩放
  static const Curve reorder = Curves.easeOutCubic;
  static const Duration reorderDuration = Duration(milliseconds: 300);
  // 阅读页 ↔ 书架：整页缩向第一本槽位
  // push：起点慢（看清从哪本放大）；pop：末段慢（细腻落回封面）
  static const Curve readerShrinkPush = Curves.easeInOutQuart;
  static const Curve readerShrinkPop = Curves.easeInOutQuart;
  static const Duration readerShrinkDuration = Duration(milliseconds: 720);
  static const double readerShrinkEndScale = 0.22;
  /// pop 时 reverse 动画的前 (1 - hold) 段保持不透明，仅末段淡出
  static const double readerShrinkFadeHold = 0.28;
  static const Duration switchDuration = Duration(milliseconds: 260);
  static const Duration staggerStep = Duration(milliseconds: 28);
  static const int staggerMaxItems = 12;
}
