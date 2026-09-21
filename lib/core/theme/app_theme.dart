import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// 应用主题：松绿 seed 主导全应用色系（明暗均由 flex_color_scheme 引擎派生）。
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
    (id: 'navy', label: '藏蓝', color: Color(0xFF2C3E6B)),
    (id: 'amber', label: '琥珀', color: Color(0xFFB8860B)),
    (id: 'mint', label: '薄荷', color: Color(0xFF3D8B6E)),
    (id: 'coral', label: '珊瑚', color: Color(0xFFC46A5A)),
    (id: 'graphite', label: '石墨', color: Color(0xFF4A5568)),
    (id: 'gold', label: '玫瑰金', color: Color(0xFFA67C6D)),
  ];

  /// 调色板 16 色扩展色板（外观页取色用；seedSource 旧数据迁移也按它推断）
  static const List<Color> palettePresets = [
    Color(0xFFE57373), Color(0xFFF06292), Color(0xFFBA68C8), Color(0xFF9575CD),
    Color(0xFF7986CB), Color(0xFF64B5F6), Color(0xFF4FC3F7), Color(0xFF4DD0E1),
    Color(0xFF4DB6AC), Color(0xFF81C784), Color(0xFFAED581), Color(0xFFFFD54F),
    Color(0xFFFFB74D), Color(0xFFA1887F), Color(0xFF90A4AE), Color(0xFF607D8B),
  ];

  static ThemeData light({
    Color? dynamicSeed,
    Color? seedOverride,
    double pageTint = 0.35,
  }) {
    // flex_color_scheme 引擎：默认 FlexKeyColors + FlexTones.material 与
    // ColorScheme.fromSeed 同源，但派生出完整的 M3 surfaceContainer 角色
    final scheme = FlexColorScheme.light(
      primary: dynamicSeed ?? seedOverride ?? seed,
      keyColors: const FlexKeyColors(),
    ).toScheme;
    return _base(scheme, pageTint: pageTint);
  }

  static ThemeData dark({
    Color? dynamicSeed,
    Color? seedOverride,
    double pageTint = 0.0,
  }) {
    final key = dynamicSeed ?? seedOverride ?? seed;
    // primaryLightRef 与 primary 同值：seed 即浅色 primary 引用，
    // 消除 flex 引擎 fixed 色派生警告
    final scheme = FlexColorScheme.dark(
      primary: key,
      primaryLightRef: key,
      keyColors: const FlexKeyColors(),
    ).toScheme;
    return _base(scheme, pageTint: pageTint);
  }

  /// 整页均匀主色倾向底（非底部堆色）：
  /// 浅色 = 带色相的纸；深色 = 黑底偏主色的夜灰（如蓝 seed → 蓝灰）
  static Color pageSurface(
    ColorScheme scheme, {
    double? lightTint,
    double? darkTint,
  }) {
    final amount = scheme.brightness == Brightness.light
        ? (lightTint ?? 0.35)
        : (darkTint ?? 0.0);
    return Color.lerp(scheme.surface, scheme.primary, amount)!;
  }

  static ThemeData _base(ColorScheme scheme, {required double pageTint}) {
    final page = pageSurface(
      scheme,
      lightTint: scheme.brightness == Brightness.light ? pageTint : null,
      darkTint: scheme.brightness == Brightness.dark ? pageTint : null,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: page,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: page,
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

  /// 顶栏/次级控件色渗：混 **secondary**（非 container，避免色相被稀释）。
  /// secondary 饱和高，混入比例压低；再叠轻描边保证静止可读。
  static Color chromeGlass(ColorScheme scheme, {double strength = 0.4}) {
    final base = scheme.brightness == Brightness.light
        ? scheme.surface
        : scheme.surfaceContainerHighest;
    final mixed = Color.lerp(base, scheme.secondary, strength * 0.55)!;
    final a = scheme.brightness == Brightness.light
        ? 0.32 + 0.42 * strength
        : 0.36 + 0.38 * strength;
    return mixed.withValues(alpha: a);
  }

  /// 顶栏控件描边：secondary 系，比 outlineVariant 更贴色相
  static Color chromeBorder(ColorScheme scheme, {double alpha = 0.45}) {
    return scheme.secondary.withValues(alpha: alpha);
  }

  /// 悬浮卡多层阴影（明/暗分档）。
  /// 浅色：冷灰软影；深色：更重 ambient + 主色微渗，避免纯黑压死页底。
  static List<BoxShadow> floatShadows(ColorScheme scheme) {
    final light = scheme.brightness == Brightness.light;
    if (light) {
      return [
        // 环境大影：拉开「离开纸面」
        BoxShadow(
          color: const Color(0xFF1A2A22).withValues(alpha: 0.08),
          blurRadius: 28,
          offset: const Offset(0, 14),
          spreadRadius: -6,
        ),
        // 接触短影：贴地
        BoxShadow(
          color: const Color(0xFF1A2A22).withValues(alpha: 0.10),
          blurRadius: 8,
          offset: const Offset(0, 3),
          spreadRadius: -1,
        ),
        // 顶缘极淡反光影（负 offset 近似）
        BoxShadow(
          color: Colors.white.withValues(alpha: 0.35),
          blurRadius: 0,
          offset: const Offset(0, 1),
          spreadRadius: 0,
        ),
      ];
    }
    final tint = Color.lerp(scheme.shadow, scheme.primary, 0.22)!;
    return [
      BoxShadow(
        color: tint.withValues(alpha: 0.55),
        blurRadius: 32,
        offset: const Offset(0, 16),
        spreadRadius: -8,
      ),
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.45),
        blurRadius: 10,
        offset: const Offset(0, 4),
        spreadRadius: -2,
      ),
    ];
  }

  /// 行块填色：更透，让下层霜面渐变透上来；关霜时略提高实体感
  static Color floatRowFill(ColorScheme scheme) {
    final light = scheme.brightness == Brightness.light;
    return (light ? scheme.surface : scheme.surfaceContainerHighest)
        .withValues(alpha: light ? 0.22 : 0.22);
  }

  /// 行块描边（霜层**关态**）：浅色不能用纯白——在浅底上轮廓消失。
  /// 混一点 primary 的 outline 系，保证圆角边界可辨。
  static Color floatRowRim(ColorScheme scheme) {
    final light = scheme.brightness == Brightness.light;
    if (light) {
      return Color.lerp(scheme.outlineVariant, scheme.primary, 0.12)!
          .withValues(alpha: 0.55);
    }
    return Colors.white.withValues(alpha: 0.40);
  }

  /// 关态壳描边宽（开态 FrostShell 仍用 [rimWidth]）
  static double floatRowRimWidth(ColorScheme scheme) =>
      scheme.brightness == Brightness.light ? 1.0 : 1.0;

  /// 玻璃描边宽度：浅色 0.5 细腻，深色 0.8 保证轮廓/圆角可辨
  /// （霜层**开态**前景 rim；关态用 [floatRowRimWidth]）
  static double rimWidth(ColorScheme scheme) =>
      scheme.brightness == Brightness.light ? 0.5 : 0.8;

  /// 静止选中 pill 派生色（设置分段 / 底栏统一）：
  /// **较高透明度**——向 surface 混淡 + α0.42，避免 α0.9 过实。
  static Color restPillTint(ColorScheme scheme) {
    return Color.lerp(scheme.primaryContainer, scheme.surface, 0.28)!
        .withValues(alpha: 0.42);
  }

  /// 子栏行缝（两套方案共用）
  static const double floatRowGap = 5;

  /// 霜层渐变：低透明度双息。
  /// [colorA]/[colorB] 可覆盖起点/终点色（null = primary/tertiary）。
  /// [depth] 整体透明度倍率 0.3–1.8（默认 1.0）。
  static List<Color> frostShellGradient(
    ColorScheme scheme, {
    Color? colorA,
    Color? colorB,
    double depth = 1.0,
  }) {
    final light = scheme.brightness == Brightness.light;
    final base = light ? scheme.surface : scheme.surfaceContainerHighest;
    final d = depth.clamp(0.3, 1.8);
    final a = Color.lerp(base, colorA ?? scheme.primary, light ? 0.55 : 0.45)!
        .withValues(alpha: (light ? 0.40 : 0.36) * d);
    final mid = base.withValues(alpha: (light ? 0.28 : 0.30) * d);
    final b = Color.lerp(base, colorB ?? scheme.tertiary, light ? 0.48 : 0.38)!
        .withValues(alpha: (light ? 0.36 : 0.32) * d);
    return [a, mid, b];
  }

  /// 组内第 [i]/[n] 段的霜层色（连续渐变切片，缝不铺色）。
  static List<Color> frostRowSlice(
    ColorScheme scheme,
    int i,
    int n, {
    Color? colorA,
    Color? colorB,
    double depth = 1.0,
  }) {
    final stops = frostShellGradient(
      scheme,
      colorA: colorA,
      colorB: colorB,
      depth: depth,
    );
    double t(int k) => n <= 1 ? 0.5 : k / n;
    Color at(double u) {
      if (u <= 0.5) return Color.lerp(stops[0], stops[1], u * 2)!;
      return Color.lerp(stops[1], stops[2], (u - 0.5) * 2)!;
    }

    return [at(t(i)), at(t(i + 1))];
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
