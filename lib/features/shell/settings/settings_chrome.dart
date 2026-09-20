import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart' show AppGlass;
import '../providers/shell_settings.dart';
import '../widgets/shell_ambient.dart';

/// 设置页统一底：Scaffold 透明，这里铺色渗 base + 可选双息渐变。
/// **不要**再包 ColoredBox——会夹在 Material 与 ListTile 之间，
/// 导致 ink/背景断言（ListTile background color may be invisible）。
class SettingsBackdrop extends ConsumerWidget {
  const SettingsBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shell = ref.watch(shellSettingsProvider);
    return DecoratedBox(
      decoration: ShellAmbient.decoration(
        context,
        enabled: shell.ambientOn,
        dir: AmbientDir.parse(shell.ambientDir),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: child,
      ),
    );
  }
}

/// 含 `LiquidGlassLens` / 液态控件的滚动区。
///
/// Android M3 默认 **stretch** overscroll 会把内容隔离进 `ImageFiltered`
/// subpass，`BackdropFilter` 读不到真实背景 → 液态底层黑闪、霜面 rim
/// 高光/倒角消失。书架把玻璃放在滚动区外的 chrome Stack，所以没事；
/// 设置控件在列表内，这里改用 **glow**（画光晕，不隔离 layer）。
/// 见 `liquid_glass_easy` 的 `LiquidGlassLens` 文档。
class SettingsGlassScroll extends StatelessWidget {
  const SettingsGlassScroll({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: const _GlowOverscrollBehavior(),
      child: child,
    );
  }
}

class _GlowOverscrollBehavior extends MaterialScrollBehavior {
  const _GlowOverscrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (getPlatform(context) != TargetPlatform.android) {
      return super.buildOverscrollIndicator(context, child, details);
    }
    return GlowingOverscrollIndicator(
      axisDirection: details.direction,
      color: Theme.of(context).colorScheme.secondary,
      child: child,
    );
  }
}

/// 设置顶栏几何：与书架滤镜语言对齐，高度按 Material toolbar。
class SettingsChrome {
  SettingsChrome._();

  /// 标题带高度（不含系统 inset）——略高于 56，标题光学中心落在雾区内
  static const double headerContentH = 64;

  /// blur 向下延伸的衰减带（只盖内容、不占布局）
  static const double topBlurExtend = 64;

  /// 滚动显现区间（与书架 _scrollT 同源）
  static const double scrollRevealPx = 56;

  /// 系统顶 inset：edge-to-edge 下 padding 可能为 0，优先 viewPadding
  static double sysTop(BuildContext context) {
    final mq = MediaQuery.of(context);
    final v = mq.viewPadding.top;
    final p = mq.padding.top;
    return v > p ? v : p;
  }
}

/// 书架同款顶栏：滚动显现的**滤镜色渐变模糊**。
///
/// 层序契约：模糊/雾在 `ClipRect` 内；**标题与返回键在最外层 Stack 上
/// `Positioned` 叠放**，z 序高于模糊，垂直落在 `sysTop + headerContentH`
/// 标题带上（雾区上部），避免「文字在模糊下方 / 顶部留空」。
///
/// 液态玻璃返回键仅在 `scrollT ≥ 0.02` 时出现，静止为普通箭头。
class SettingsTopChrome extends StatelessWidget {
  const SettingsTopChrome({
    super.key,
    required this.title,
    required this.scrollT,
    this.showBack = true,
  });

  final String title;

  /// 0 静止 → 1 滚动（约 56px 内完成显现）
  final double scrollT;

  final bool showBack;

  /// 与模糊显现同一阈值：返回键液态效果同步开关
  static const double _blurEpsilon = 0.02;

  static const double _backSize = 40;

  Widget _title(BuildContext context, ColorScheme scheme) {
    return Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: Theme.of(context).appBarTheme.titleTextStyle?.copyWith(
                color: scheme.onSurface,
              ) ??
          TextStyle(
            color: scheme.onSurface,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
          ),
    );
  }

  /// 静止：普通箭头；模糊生效：液态玻璃圆键（同一时刻只挂一棵 Lens）
  Widget _back(BuildContext context, ColorScheme scheme, {required bool glass}) {
    if (glass) {
      final light = scheme.brightness == Brightness.light;
      return LiquidGlassTabBarAction(
        icon: Icons.arrow_back_rounded,
        size: _backSize,
        foregroundColor: scheme.onSurface,
        style: LiquidGlassStyle(
          shape: LiquidGlassShape.continuousRoundedRectangle(
            cornerRadius: _backSize / 2,
            borderWidth: light ? 0.8 : 1.0,
            borderColor: Colors.white.withValues(alpha: light ? 0.40 : 0.22),
            lightIntensity: 1.05,
          ),
          appearance: LiquidGlassAppearance(
            // 与底栏圆键同族色渗，叠在顶栏 fog 上仍可辨
            color: AppGlass.navGlass(scheme, strength: 0.42),
            blur: const LiquidGlassBlur(sigmaX: 2.5, sigmaY: 2.5),
            shadow: LiquidGlassShadow(
              blur: 12,
              opacity: light ? 0.12 : 0.22,
              offset: const Offset(0, 4),
              cornerRadius: _backSize / 2,
            ),
          ),
          refraction: const LiquidGlassRefraction(
            distortion: 0.08,
            distortionWidth: 18,
            chromaticAberration: 0.002,
          ),
        ),
        touch: const LiquidGlassTouch(flex: LiquidGlassFlex()),
        onTap: () => Navigator.of(context).maybePop(),
      );
    }
    return IconButton(
      onPressed: () => Navigator.of(context).maybePop(),
      color: scheme.onSurface,
      iconSize: 24,
      icon: const Icon(Icons.arrow_back_rounded),
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
    );
  }

  /// 标题带前景：sysTop 安全区 + headerContentH，标题光学居中，返回键浮左。
  /// 必须作为模糊层**之后**的 Positioned 子节点绘制。
  Widget _titleBand(
    BuildContext context,
    ColorScheme scheme, {
    required bool disableBlur,
  }) {
    final sysTop = SettingsChrome.sysTop(context);
    final bandH = sysTop + SettingsChrome.headerContentH;
    final glassOn = showBack && scrollT >= _blurEpsilon;

    return SizedBox(
      height: bandH,
      child: Stack(
        children: [
          // 标题全宽水平居中；垂直落在标题带中心（含安全区上沿补白）
          Positioned(
            left: 0,
            right: 0,
            top: sysTop,
            height: SettingsChrome.headerContentH,
            child: Center(child: _title(context, scheme)),
          ),
          if (showBack)
            Positioned(
              left: 6,
              top: sysTop,
              height: SettingsChrome.headerContentH,
              child: Center(
                child: _back(
                  context,
                  scheme,
                  glass: glassOn && !disableBlur,
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final disableBlur = MediaQuery.disableAnimationsOf(context);
    final sysTop = SettingsChrome.sysTop(context);
    final bandH = sysTop + SettingsChrome.headerContentH;
    final band = _titleBand(context, scheme, disableBlur: disableBlur);

    if (disableBlur) {
      return Material(
        color: scheme.surface.withValues(
          alpha: scrollT > _blurEpsilon ? 0.92 : 0,
        ),
        child: band,
      );
    }

    // 静止：不叠模糊，标题带仍占位（与 spacer 一致）
    if (scrollT < _blurEpsilon) {
      return SizedBox(height: bandH, child: band);
    }

    final h = bandH + SettingsChrome.topBlurExtend;
    final fog = AppGlass.topTint(scheme);
    final fogA = scrollT;
    return SizedBox(
      height: h,
      child: Stack(
        children: [
          // 模糊 + 雾：ClipRect 内，z 序在下
          Positioned.fill(
            child: IgnorePointer(
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ShaderMask(
                      shaderCallback: (rect) {
                        return LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white,
                            Colors.white.withValues(alpha: 0.92),
                            Colors.white.withValues(alpha: 0.72),
                            Colors.white.withValues(alpha: 0.40),
                            Colors.white.withValues(alpha: 0.14),
                            Colors.transparent,
                          ],
                          stops: const [0, 0.22, 0.42, 0.62, 0.82, 1],
                        ).createShader(rect);
                      },
                      blendMode: BlendMode.dstIn,
                      child: BackdropFilter(
                        filter: ImageFilter.blur(
                          sigmaX: AppGlass.topBlurSigma,
                          sigmaY: AppGlass.topBlurSigma,
                        ),
                        child: ColoredBox(color: fog),
                      ),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            // 顶栏区雾更实，盖住标题带上沿内容渗色
                            fog.withValues(alpha: 0.72 * fogA),
                            fog.withValues(alpha: 0.58 * fogA),
                            fog.withValues(alpha: 0.40 * fogA),
                            fog.withValues(alpha: 0.20 * fogA),
                            fog.withValues(alpha: 0.06 * fogA),
                            Colors.transparent,
                          ],
                          stops: const [0, 0.22, 0.42, 0.62, 0.82, 1],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 标题/返回键：最外层 Positioned，叠在模糊之上
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: bandH,
            child: band,
          ),
        ],
      ),
    );
  }
}

/// 设置页外壳：顶栏滚动渐变模糊 + 玻璃分组列表。
/// 底栏由 AppShell 提供；本页只负责 chrome 与滚动区。
/// 顶栏在滚动区外（书架 chrome Stack 同理），避开 ImageFiltered subpass。
class SettingsScaffold extends StatefulWidget {
  const SettingsScaffold({
    super.key,
    required this.title,
    required this.slivers,
    this.showBack,
  });

  final String title;
  final List<Widget> slivers;

  /// null = 按路由 canPop 自动决定
  final bool? showBack;

  @override
  State<SettingsScaffold> createState() => _SettingsScaffoldState();
}

class _SettingsScaffoldState extends State<SettingsScaffold> {
  double _scrollT = 0;

  bool _onScrollNotification(ScrollNotification n) {
    if (n.depth != 0) return false;
    final metrics = n.metrics;
    if (metrics.axis != Axis.vertical) return false;
    final t =
        (metrics.pixels / SettingsChrome.scrollRevealPx).clamp(0.0, 1.0);
    if ((t - _scrollT).abs() < 0.01) return false;
    setState(() => _scrollT = t);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // 与顶栏前景同一几何：sysTop + headerContentH
    final chromeH =
        SettingsChrome.sysTop(context) + SettingsChrome.headerContentH;
    final showBack =
        widget.showBack ?? (ModalRoute.of(context)?.canPop ?? false);

    // 透明：渐变页底由 ShellAmbient / 外层壳提供，避免实色盖住
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SettingsBackdrop(
        child: Stack(
          children: [
            Positioned.fill(
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScrollNotification,
                child: SettingsGlassScroll(
                  child: CustomScrollView(
                    slivers: [
                      // 顶栏占位：内容可滚入模糊衰减带之下
                      SliverToBoxAdapter(child: SizedBox(height: chromeH)),
                      ...widget.slivers,
                      const SliverToBoxAdapter(child: SizedBox(height: 120)),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SettingsTopChrome(
                title: widget.title,
                scrollT: _scrollT,
                showBack: showBack,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 同宽外霜层：blur + 渐变，`ClipRRect` 贴合轮廓。
/// 可作**垫在子栏下面**的背景层（child 可传空内容如 SizedBox.shrink），
/// 也可包内容。
///
/// 裁剪契约：阴影 → Clip → Stack[BackdropFilter → 渐变 → 内容，
/// 前景 rim 描边层]。描边层画在模糊/渐变之上，整圈完整可见；
/// 内容层为非定位子节点，壳体由内容撑起。
class SettingsFrostShell extends StatelessWidget {
  const SettingsFrostShell({
    super.key,
    required this.child,
    this.radius = 16,
    this.blurSigma = 12,
    this.dir = AmbientDir.tlbr,
    this.showShadow = true,
    this.colorA,
    this.colorB,
    this.gradDepth = 1.0,
  });

  final Widget child;
  final double radius;
  final double blurSigma;
  final AmbientDir dir;

  /// 垫底层可关阴影：子栏各自带影时，外壳不再加整体影
  final bool showShadow;
  final Color? colorA;
  final Color? colorB;
  final double gradDepth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final light = scheme.brightness == Brightness.light;
    final r = BorderRadius.circular(radius);
    final stops = AppGlass.frostShellGradient(
      scheme,
      colorA: colorA,
      colorB: colorB,
      depth: gradDepth,
    );
    final (begin, end) = dir.alignment;
    // 描边按明暗分档：浅色 0.5px 细腻；深色 0.8px α0.28，
    // 否则白色 rim 在暗底上轮廓不可读、圆角边界消失
    final rim = light
        ? Colors.white.withValues(alpha: 0.32)
        : Colors.white.withValues(alpha: 0.28);
    final rimWidth = AppGlass.rimWidth(scheme);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: [
          if (showShadow) ...[
            BoxShadow(
              color: scheme.shadow.withValues(alpha: light ? 0.08 : 0.32),
              blurRadius: 18,
              offset: const Offset(0, 8),
              spreadRadius: -4,
            ),
            BoxShadow(
              color: scheme.shadow.withValues(alpha: light ? 0.05 : 0.18),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ],
      ),
      child: ClipRRect(
        borderRadius: r,
        child: Stack(
          children: [
            // 模糊 + 渐变层：非定位子节点，壳体由内容撑起
            // （Stack 全定位子节点会取 biggest，在 Column/Dialog
            // 的无界或松弛高度下崩溃/撑满，不可用）
            BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: blurSigma,
                sigmaY: blurSigma,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: begin,
                    end: end,
                    colors: stops,
                    stops: const [0, 0.48, 1],
                  ),
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: child,
                ),
              ),
            ),
            // 前景描边层：画在模糊/渐变之上。BackdropFilter 的采样在
            // 裁切边缘有一圈半透明带，描边若画在其下，圆角弧线处会被
            // 吃掉（视觉"缺一角"）；提到前景后整圈 rim 完整可见。
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: r,
                    border: Border.all(color: rim, width: rimWidth),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 子栏外壳：只绘制淡描边，不覆盖下层渐变。
class SettingsRowShell extends StatelessWidget {
  const SettingsRowShell({
    super.key,
    required this.borderRadius,
    required this.child,
    this.fill,
    this.gradient,
  });

  final BorderRadius borderRadius;
  final Widget child;
  final Color? fill;
  final Gradient? gradient;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        // 描边与 FrostShell 同语言（宽度走 AppGlass.rimWidth 分档）
        border: Border.all(
          color: AppGlass.floatRowRim(scheme),
          width: AppGlass.rimWidth(scheme),
        ),
        gradient: gradient,
        color: gradient == null ? fill : null,
      ),
      child: Material(
        type: MaterialType.transparency,
        clipBehavior: Clip.antiAlias,
        borderRadius: borderRadius,
        child: child,
      ),
    );
  }
}

/// 设置分组（MD3 Preference / Legado 规则页范式）。
///
/// [float] 根页：统一连续霜层（默认）或分栏切片；子栏软描边 + 主色微光。
/// [splitItems] 每条独立霜壳。
/// 默认 tonal：多行合卡 + 分割线。
class SettingsGroup extends ConsumerWidget {
  const SettingsGroup({
    super.key,
    this.header,
    required this.children,
    this.splitItems = false,
    this.itemGap = 12,
    this.float = false,
  });

  final String? header;
  final List<Widget> children;

  /// true = 每条独立卡 + 间距
  final bool splitItems;

  /// 分区之间 / [splitItems] 卡间垂直间距
  final double itemGap;

  /// true = 悬浮霜层垫底 + 折中版子栏
  final bool float;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final shell = ref.watch(shellSettingsProvider);
    final frostDir = AmbientDir.parse(shell.frostDir);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
              child: Text(
                header!,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                    ),
              ),
            ),
          if (splitItems)
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) SizedBox(height: itemGap),
              _wrapCard(context, scheme, [children[i]], frostDir, shell),
            ]
          else
            _wrapCard(context, scheme, children, frostDir, shell),
        ],
      ),
    );
  }

  Widget _wrapCard(
    BuildContext context,
    ColorScheme scheme,
    List<Widget> rows,
    AmbientDir frostDir,
    ShellSettings shell,
  ) {
    if (float) {
      return _floatGrouped(context, scheme, rows, frostDir, shell);
    }
    if (splitItems) {
      return SettingsFrostShell(
        dir: frostDir,
        colorA: shell.frostGradA != null
            ? Color(shell.frostGradA!)
            : null,
        colorB: shell.frostGradB != null
            ? Color(shell.frostGradB!)
            : null,
        gradDepth: shell.frostGradDepth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        ),
      );
    }
    return _tonalCard(scheme, rows);
  }

  /// 根页：unified = 整组连续渐变 + 联合轮廓（默认）；slice = 旧切片。
  Widget _floatGrouped(
    BuildContext context,
    ColorScheme scheme,
    List<Widget> rows,
    AmbientDir frostDir,
    ShellSettings shell,
  ) {
    final colorA =
        shell.frostGradA != null ? Color(shell.frostGradA!) : null;
    final colorB =
        shell.frostGradB != null ? Color(shell.frostGradB!) : null;
    if (shell.frostStyle == 'slice') {
      return _floatGroupedSlice(
        scheme,
        rows,
        frostDir,
        shell.frostOn,
        colorA: colorA,
        colorB: colorB,
        depth: shell.frostGradDepth,
      );
    }
    return SettingsFrostGroup(
      rows: rows,
      dir: frostDir,
      enabled: shell.frostOn,
      colorA: colorA,
      colorB: colorB,
      gradDepth: shell.frostGradDepth,
    );
  }

  /// 备选：每栏渐变切片 + 软描边/光晕
  Widget _floatGroupedSlice(
    ColorScheme scheme,
    List<Widget> rows,
    AmbientDir frostDir,
    bool frostOn, {
    Color? colorA,
    Color? colorB,
    double depth = 1.0,
  }) {
    final (begin, end) = frostDir.alignment;
    const rowGap = AppGlass.floatRowGap;
    const rowR = 12.0;
    final n = rows.length;
    final light = scheme.brightness == Brightness.light;

    BorderRadius rowRadius(int i) {
      if (n == 1) return BorderRadius.circular(rowR);
      if (i == 0) {
        return const BorderRadius.vertical(top: Radius.circular(rowR));
      }
      if (i == n - 1) {
        return const BorderRadius.vertical(bottom: Radius.circular(rowR));
      }
      return BorderRadius.zero;
    }

    return Container(
      decoration: frostOn
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(rowR),
              boxShadow: [
                BoxShadow(
                  color: scheme.shadow.withValues(alpha: light ? 0.06 : 0.28),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                  spreadRadius: -4,
                ),
                BoxShadow(
                  color: scheme.shadow.withValues(alpha: light ? 0.03 : 0.16),
                  blurRadius: 6,
                  offset: const Offset(0, 3),
                  spreadRadius: -1,
                ),
              ],
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < n; i++) ...[
            if (i > 0) const SizedBox(height: rowGap),
            SettingsRowShell(
              borderRadius: rowRadius(i),
              gradient: frostOn
                  ? LinearGradient(
                      begin: begin,
                      end: end,
                      colors: AppGlass.frostRowSlice(
                        scheme,
                        i,
                        n,
                        colorA: colorA,
                        colorB: colorB,
                        depth: depth,
                      ),
                    )
                  : null,
              fill: frostOn ? null : AppGlass.floatRowFill(scheme),
              child: rows[i],
            ),
          ],
        ],
      ),
    );
  }

  Widget _tonalCard(ColorScheme scheme, List<Widget> rows) {
    final radius = BorderRadius.circular(16);
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                indent: 56,
                endIndent: 12,
                color: scheme.outlineVariant.withValues(alpha: 0.55),
              ),
            rows[i],
          ],
        ],
      ),
    );
  }
}

/// **统一霜层**（默认）：整组一条连续渐变 + 单次 blur，
/// 用各行圆角矩形的**联合轮廓**裁切——缝里不画霜，透出页底。
/// 子栏前景只带各自阴影/描边，不各自开 BackdropFilter。
class SettingsFrostGroup extends StatefulWidget {
  const SettingsFrostGroup({
    super.key,
    required this.rows,
    this.dir = AmbientDir.tlbr,
    this.enabled = true,
    this.rowGap = AppGlass.floatRowGap,
    this.rowRadius = 12,
    this.blurSigma = 10,
    this.colorA,
    this.colorB,
    this.gradDepth = 1.0,
  });

  final List<Widget> rows;
  final AmbientDir dir;
  final bool enabled;
  final double rowGap;
  final double rowRadius;
  final double blurSigma;
  final Color? colorA;
  final Color? colorB;
  final double gradDepth;

  @override
  State<SettingsFrostGroup> createState() => _SettingsFrostGroupState();
}

class _SettingsFrostGroupState extends State<SettingsFrostGroup> {
  final List<GlobalKey> _keys = [];
  List<Rect> _rowRects = const [];

  int get _n => widget.rows.length;

  @override
  void initState() {
    super.initState();
    _syncKeys();
  }

  @override
  void didUpdateWidget(covariant SettingsFrostGroup old) {
    super.didUpdateWidget(old);
    if (old.rows.length != widget.rows.length) {
      _syncKeys();
      _rowRects = const [];
    }
  }

  void _syncKeys() {
    while (_keys.length < _n) {
      _keys.add(GlobalKey());
    }
    if (_keys.length > _n) {
      _keys.removeRange(_n, _keys.length);
    }
  }

  void _measure() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final origin = box.localToGlobal(Offset.zero);
    final rects = <Rect>[];
    for (var i = 0; i < _n; i++) {
      final ro = _keys[i].currentContext?.findRenderObject();
      if (ro is! RenderBox || !ro.attached || !ro.hasSize) return;
      final topLeft = ro.localToGlobal(Offset.zero) - origin;
      rects.add(topLeft & ro.size);
    }
    if (!mounted) return;
    var changed = rects.length != _rowRects.length;
    if (!changed) {
      for (var i = 0; i < rects.length; i++) {
        if (rects[i] != _rowRects[i]) {
          changed = true;
          break;
        }
      }
    }
    if (changed) setState(() => _rowRects = rects);
  }

  BorderRadius _radius(int i) {
    final r = widget.rowRadius;
    if (_n == 1) return BorderRadius.circular(r);
    if (i == 0) {
      return BorderRadius.vertical(top: Radius.circular(r));
    }
    if (i == _n - 1) {
      return BorderRadius.vertical(bottom: Radius.circular(r));
    }
    return BorderRadius.zero;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (begin, end) = widget.dir.alignment;
    final stops = AppGlass.frostShellGradient(
      scheme,
      colorA: widget.colorA,
      colorB: widget.colorB,
      depth: widget.gradDepth,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    final light = scheme.brightness == Brightness.light;

    return Container(
      decoration: widget.enabled
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(widget.rowRadius),
              boxShadow: [
                BoxShadow(
                  color: scheme.shadow.withValues(alpha: light ? 0.06 : 0.28),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                  spreadRadius: -4,
                ),
                BoxShadow(
                  color: scheme.shadow.withValues(alpha: light ? 0.03 : 0.16),
                  blurRadius: 6,
                  offset: const Offset(0, 3),
                  spreadRadius: -1,
                ),
              ],
            )
          : null,
      child: Stack(
        children: [
          if (widget.enabled && _rowRects.length == _n)
            Positioned.fill(
              child: IgnorePointer(
                child: ClipPath(
                  clipper: _RowUnionClipper(_rowRects, widget.rowRadius),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: widget.blurSigma,
                      sigmaY: widget.blurSigma,
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: begin,
                          end: end,
                          colors: stops,
                          stops: const [0, 0.48, 1],
                        ),
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < _n; i++) ...[
                if (i > 0) SizedBox(height: widget.rowGap),
                SettingsRowShell(
                  key: _keys[i],
                  borderRadius: _radius(i),
                  fill: widget.enabled
                      ? null
                      : AppGlass.floatRowFill(scheme),
                  child: widget.rows[i],
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 各行圆角矩形的并集路径（缝不落在 path 内 → 不画霜）。
class _RowUnionClipper extends CustomClipper<Path> {
  _RowUnionClipper(this.rects, this.radius);

  final List<Rect> rects;
  final double radius;

  @override
  Path getClip(Size size) {
    final path = Path();
    final n = rects.length;
    for (var i = 0; i < n; i++) {
      final r = n == 1
          ? RRect.fromRectAndRadius(rects[i], Radius.circular(radius))
          : i == 0
              ? RRect.fromRectAndCorners(
                  rects[i],
                  topLeft: Radius.circular(radius),
                  topRight: Radius.circular(radius),
                )
              : i == n - 1
                  ? RRect.fromRectAndCorners(
                      rects[i],
                      bottomLeft: Radius.circular(radius),
                      bottomRight: Radius.circular(radius),
                    )
                  : RRect.fromRectAndRadius(rects[i], Radius.zero);
      path.addRRect(r);
    }
    return path;
  }

  @override
  bool shouldReclip(covariant _RowUnionClipper oldClipper) {
    if (oldClipper.radius != radius) return true;
    if (oldClipper.rects.length != rects.length) return true;
    for (var i = 0; i < rects.length; i++) {
      if (oldClipper.rects[i] != rects[i]) return true;
    }
    return false;
  }
}

/// 根页分类入口行：icon + 标题 | 摘要右贴 chevron
class SettingNavRow extends StatelessWidget {
  const SettingNavRow({
    super.key,
    required this.icon,
    required this.title,
    required this.summary,
    required this.onTap,
    this.padV = 20,
  });

  final IconData icon;
  final String title;
  final String summary;
  final VoidCallback onTap;

  /// 上下 padding，控制每栏高度
  final double padV;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: padV),
        child: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: Colors.white.withValues(
                    alpha: scheme.brightness == Brightness.light ? 0.34 : 0.12,
                  ),
                ),
              ),
              child: SizedBox(
                width: 36,
                height: 36,
                child: Icon(icon, size: 22, color: scheme.primary),
              ),
            ),
            const SizedBox(width: 14),
            // 标题不撑满，给右侧摘要让出固定贴边区
            Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const Spacer(),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 148),
              child: Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(AppIcons.chevronRight, size: 18, color: scheme.outline),
          ],
        ),
      ),
    );
  }
}

/// 设置容器内部分隔线：细线，左右缩进对齐内容。
///
/// MD3：分隔线取强调色派生（primary 低透明度），标准 1dp 厚度。
class SettingsDivider extends StatelessWidget {
  const SettingsDivider({super.key, this.indent = 4});

  final double indent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: indent, vertical: 8),
      child: Divider(
        height: 1,
        thickness: 1,
        color: scheme.primary.withValues(alpha: 0.18),
      ),
    );
  }
}

/// 带图标的栏目标签行
class SettingIconLabel extends StatelessWidget {
  const SettingIconLabel({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// 行尾控件（如取色按钮），与标题/副标题水平同行
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      // 水平 16 与容器内容网格对齐（此前 4px 导致标签贴壳边）
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// 子页内的标签行（标题 + 副文案），控件由调用方放在下方 padding 里
class SettingLabel extends StatelessWidget {
  const SettingLabel({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 子页内开关行：**液态开关**（设置页允许的玻璃控件之一）。
class SettingSwitchRow extends ConsumerWidget {
  const SettingSwitchRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final shell = ref.read(shellSettingsProvider);
    // 关闭果冻时：expanded = rest，取消弹簧缩放，只保留切换
    final layout = shell.lgMotionOn
        ? const LiquidGlassSwitchLayout()
        : const LiquidGlassSwitchLayout(
            thumbWidth: 37,
            thumbHeight: 24,
            expandedThumbWidth: 37,
            expandedThumbHeight: 24,
          );
    return Padding(
      // 左右对称：文字距左 16，开关距右 16；垂直 12 → 行高 60，
      // 与明暗模式分段容器统一（书架/动态取色/玻璃设置页共用）
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
              ],
            ),
          ),
          LiquidGlassSwitch(
            value: value,
            onChanged: onChanged,
            activeColor: scheme.primary,
            inactiveColor: scheme.outlineVariant.withValues(alpha: 0.9),
            layout: layout,
            // 布局占位必须等于轨道（63×28）：reserveSwellRoom 会把占位
            // 撑到 120px（两侧各 28.5px 隐形空白），视觉右边距变成
            // 16+28.5px，与文字左边距 16px 不对称。按住时玻璃膨胀
            // 最多超出轨道 8.5px，仍在 FrostShell 裁切边内，无需预留。
            reserveSwellRoom: false,
          ),
        ],
      ),
    );
  }
}

/// MD3 分段：段间留缝；仅首尾段有外侧圆角，中间段直角。
///
/// 对应 SegmentedButton 的外轮廓规则（>2 段时中间无圆角）。
class SettingsMd3Segments extends StatelessWidget {
  const SettingsMd3Segments({
    super.key,
    required this.segments,
    required this.values,
    required this.selected,
    required this.onPick,
    this.height = 40,
    this.gap = 8,
  });

  final List<String> segments;
  final List<String> values;
  final String selected;
  final ValueChanged<String> onPick;
  final double height;
  final double gap;

  static const double _radius = 12;

  BorderRadius _corner(int index, int count) {
    if (count == 1) return BorderRadius.circular(_radius);
    if (index == 0) {
      return const BorderRadius.horizontal(left: Radius.circular(_radius));
    }
    if (index == count - 1) {
      return BorderRadius.horizontal(right: Radius.circular(_radius));
    }
    return BorderRadius.zero;
  }

  @override
  Widget build(BuildContext context) {
    final n = segments.length;
    return SizedBox(
      height: height,
      child: Row(
        children: [
          for (var i = 0; i < n; i++) ...[
            if (i > 0) SizedBox(width: gap),
            Expanded(
              child: _Md3Segment(
                label: segments[i],
                selected: values[i] == selected,
                borderRadius: _corner(i, n),
                onTap: () => onPick(values[i]),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Md3Segment extends StatelessWidget {
  const _Md3Segment({
    required this.label,
    required this.selected,
    required this.borderRadius,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final BorderRadius borderRadius;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = selected
        ? scheme.secondaryContainer
        : scheme.surfaceContainerHighest.withValues(alpha: 0.55);
    final fg = selected
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;
    return Material(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: borderRadius,
        side: BorderSide(
          color: selected
              ? scheme.secondary.withValues(alpha: 0.35)
              : scheme.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: fg,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
          ),
        ),
      ),
    );
  }
}
