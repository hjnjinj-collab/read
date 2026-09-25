import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../../../core/theme/app_theme.dart' show AppGlass;
import '../../../../core/theme/reader_menu_icons.dart';
import '../../../../core/theme/shell_glass_style.dart';
import '../../../shell/providers/shell_settings.dart';
import 'page_turn/page_turn_types.dart';

/// 菜单形态：A 传统底栏 / B 悬浮图标
enum ReaderChromeMode { traditional, floating }

/// 阅读 chrome 液态玻璃圆键 —— **与书架底栏圆键同源**。
///
/// 样式走 [shellFrostLiquidStyle]（唯一实现），blur/tint 跟壳层设置；
/// 构造对齐 `ExpandableGlassNav` 的 `LiquidGlassTabBarAction`。
/// 图标：Iconsax 线性/面性/双色（`readerIconStyle`）。
/// 禁止：祖先 Clip≠none、ClipOval/saveLayer、另写折射参数。
class ReaderGlassCircle extends ConsumerWidget {
  const ReaderGlassCircle({
    super.key,
    required this.line,
    required this.fill,
    this.onTap,
    this.size = 52,
    this.selected = false,
    this.tooltip,
  });

  final IconData line;
  final IconData fill;
  final VoidCallback? onTap;
  final double size;
  final bool selected;
  final String? tooltip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final shell = ref.watch(shellSettingsProvider);
    final disable = MediaQuery.disableAnimationsOf(context);
    // 与壳层液态圆键一致：字形 **白色**（expandable_glass_nav /
    // LiquidGlassTabBarAction 默认白）；选中仅提亮，不用 onSurface 系染色
    final fg = selected
        ? Colors.white
        : Colors.white.withValues(alpha: 0.92);
    final glyph = ReaderMenuGlyph(
      line: line,
      fill: fill,
      style: shell.readerIconStyle,
      size: size * 0.42,
      color: fg,
      duotoneAccent: Colors.white.withValues(alpha: 0.40),
    );

    if (disable) {
      final solid = Material(
        color: scheme.primaryContainer.withValues(alpha: 0.92),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Center(child: glyph),
          ),
        ),
      );
      return tooltip == null ? solid : Tooltip(message: tooltip!, child: solid);
    }

    // 与 expandable_glass_nav 圆键同构：直接 Action + 壳层 frost 样式
    // 阅读页按钮：blur 强制 0（liquid_glass_lite 在 blur≠0 时挂 BF →
    // 页面挂载即触发 Impeller 缩放）。tint 跟随设置页保持颜色一致。
    // 按压果冻：lgMotionOn → pronounced；关 → subtle（减弱动态另走 disable）
    final flex = shell.lgMotionOn
        ? const LiquidGlassFlex.pronounced()
        : const LiquidGlassFlex.subtle();
    final glass = LiquidGlassTabBarAction(
      size: size,
      foregroundColor: fg,
      style: shellFrostLiquidStyle(
        scheme,
        navBlur: 0,
        navTint: shell.navTintStrength,
        radius: size / 2,
      ).copyWith(
        appearance: LiquidGlassAppearance(
          color: AppGlass.navGlass(scheme, strength: shell.navTintStrength),
          blur: const LiquidGlassBlur(sigmaX: 0, sigmaY: 0),
          shadow: null,
        ),
      ),
      touch: LiquidGlassTouch(flex: flex),
      onTap: onTap ?? () {},
      child: glyph,
    );
    return tooltip == null ? glass : Tooltip(message: tooltip!, child: glass);
  }
}

/// 菜单渐变雾垫（纯绘制，无 BF）。
///
/// **保留渐变**，末尾平滑收到**全透明**——过渡区无色块硬边，避免
/// 在页码/进度区叠出「阴影」感与色差。固定贴边，不随 slide 平移。
class ReaderMenuFog extends StatelessWidget {
  const ReaderMenuFog({
    super.key,
    required this.fromTop,
    required this.height,
  });

  final bool fromTop;
  final double height;

  /// 页码/进度组件区**保持浓度**，越过之后再向透明过渡。
  /// stop0=贴边强端（底/顶）→ 中段盖住工具排+页码 → 末段 fade 到 0。
  static const List<double> fogAlphas =
      [0.90, 0.88, 0.86, 0.84, 0.80, 0.74, 0.50, 0.15, 0.0];
  static const List<double> fogStops =
      [0.0, 0.18, 0.36, 0.52, 0.64, 0.74, 0.84, 0.93, 1.0];

  @override
  Widget build(BuildContext context) {
    final fog = AppGlass.topTint(Theme.of(context).colorScheme);
    return SizedBox(
      height: height,
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: fromTop ? Alignment.topCenter : Alignment.bottomCenter,
            end: fromTop ? Alignment.bottomCenter : Alignment.topCenter,
            colors: [
              for (final a in fogAlphas)
                a <= 0 ? Colors.transparent : fog.withValues(alpha: a),
            ],
            stops: fogStops,
          ),
        ),
      ),
    );
  }
}

/// 顶/底菜单垫（阅读页专用）。
/// [fromTop] true=顶→底，false=底→顶。
///
/// **纯渐变雾，禁止 BackdropFilter**：阅读页 Rust 文本画布 + BF = Impeller 缩放。
class ReaderBlurVeil extends StatelessWidget {
  const ReaderBlurVeil({
    super.key,
    required this.fromTop,
    required this.child,
    this.extend = 28,
    this.band = 56,
  });

  final bool fromTop;
  final Widget child;
  final double extend;
  final double band;

  @override
  Widget build(BuildContext context) {
    final disable = MediaQuery.disableAnimationsOf(context);
    final pad = MediaQuery.paddingOf(context);
    final padV = fromTop ? pad.top : pad.bottom;
    final h = padV + band + extend;
    final scheme = Theme.of(context).colorScheme;

    if (disable) {
      return ColoredBox(
        color: AppGlass.topTint(scheme).withValues(alpha: 0.92),
        child:
            SizedBox(height: padV + band, width: double.infinity, child: child),
      );
    }

    return SizedBox(
      height: h,
      width: double.infinity,
      // Clip.none：液态圆键是 child 后代，祖先裁切必须为 none
      child: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: ReaderMenuFog(fromTop: fromTop, height: h),
            ),
          ),
          Align(
            alignment: fromTop ? Alignment.topCenter : Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(top: fromTop ? padV : 0),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

class ReaderToolBall extends StatelessWidget {
  const ReaderToolBall({
    super.key,
    required this.line,
    required this.fill,
    required this.label,
    required this.onTap,
    this.showLabel = true,
  });

  final IconData line;
  final IconData fill;
  final String label;
  final VoidCallback onTap;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 单命中：不再包 InkWell，避免与玻璃键双触发
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ReaderGlassCircle(line: line, fill: fill, size: 52, onTap: onTap),
          if (showLabel) ...[
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 顶栏：返回 · 书名 · 页码 · 更多
/// [withVeil] 菜单态挂渐变模糊垫；平时轻量条，避免常驻 BF 拖死开书。
class ReaderTopChrome extends StatelessWidget {
  const ReaderTopChrome({
    super.key,
    required this.title,
    required this.pageLabel,
    required this.onBack,
    this.onMore,
    this.withVeil = false,
    this.showTitle = true,
    this.mergeButtons = false,
    this.titlePill = false,
  });

  final String title;
  final String pageLabel;
  final VoidCallback onBack;
  final VoidCallback? onMore;
  final bool withVeil;
  final bool showTitle;

  /// 返回/更多合并为一个胶囊
  final bool mergeButtons;

  /// 书名显示在胶囊内
  final bool titlePill;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final light = scheme.brightness == Brightness.light;

    final backBtn = ReaderGlassCircle(
      line: ReaderMenuIcons.lineBack,
      fill: ReaderMenuIcons.fillBack,
      size: 52,
      tooltip: '返回',
      onTap: onBack,
    );
    final moreBtn = ReaderGlassCircle(
      line: ReaderMenuIcons.lineMore,
      fill: ReaderMenuIcons.fillMore,
      size: 52,
      tooltip: '更多',
      onTap: onMore,
    );

    // 更多恒在右侧（真机反馈）：合并只把「页码+更多」收进右侧胶囊，
    // 不再把更多拉到返回旁。默认 mergeButtons=false → 更多独立右键。
    final Widget trailing = !mergeButtons
        ? moreBtn
        : DecoratedBox(
            decoration: BoxDecoration(
              color: AppGlass.restPillTint(scheme),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(
                color: Colors.white.withValues(
                  alpha: light ? 0.42 : 0.24,
                ),
                width: 1.0,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    pageLabel,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 2),
                  moreBtn,
                ],
              ),
            ),
          );

    Widget titleWidget;
    if (!showTitle) {
      titleWidget = const SizedBox.shrink();
    } else if (titlePill) {
      titleWidget = DecoratedBox(
        decoration: BoxDecoration(
          color: AppGlass.restPillTint(scheme),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: Colors.white.withValues(alpha: light ? 0.42 : 0.24),
            width: 1.0,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
        ),
      );
    } else {
      titleWidget = Text(
        title,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: scheme.onSurface,
          fontSize: 15,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
      );
    }

    final row = SizedBox(
      height: 60,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
        child: Row(
          children: [
            backBtn,
            const SizedBox(width: 8),
            Expanded(
              child: Center(child: titleWidget),
            ),
            if (!mergeButtons) ...[
              Text(
                pageLabel,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 8),
            ] else
              const SizedBox(width: 8),
            trailing,
          ],
        ),
      ),
    );

    if (!withVeil) {
      // 阅读中：无 BF 轻雾，保证开书/翻页不卡
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              scheme.surface.withValues(alpha: light ? 0.55 : 0.35),
              scheme.surface.withValues(alpha: 0.08),
              Colors.transparent,
            ],
            stops: const [0, 0.55, 1],
          ),
        ),
        child: Padding(
          padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
          child: row,
        ),
      );
    }

    return ReaderBlurVeil(
      fromTop: true,
      band: 60,
      extend: 40,
      child: row,
    );
  }
}

/// 工具排动作（网格切分用的轻量描述）
class _ToolAction {
  const _ToolAction({
    required this.line,
    required this.fill,
    required this.label,
    required this.onTap,
  });

  final IconData line;
  final IconData fill;
  final String label;
  final VoidCallback onTap;
}

/// A/B 形态切换胶囊：液态材质与圆键同源 + 图标 + 按压缩放。
class _ModeTogglePill extends ConsumerStatefulWidget {
  const _ModeTogglePill({
    required this.label,
    required this.line,
    required this.fill,
    required this.onTap,
  });

  final String label;
  final IconData line;
  final IconData fill;
  final VoidCallback onTap;

  @override
  ConsumerState<_ModeTogglePill> createState() => _ModeTogglePillState();
}

class _ModeTogglePillState extends ConsumerState<_ModeTogglePill> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shell = ref.watch(shellSettingsProvider);
    final disable = MediaQuery.disableAnimationsOf(context);
    final fg = scheme.primary;

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ReaderMenuGlyph(
            line: widget.line,
            fill: widget.fill,
            style: shell.readerIconStyle,
            size: 16,
            color: fg,
            duotoneAccent: scheme.tertiary.withValues(alpha: 0.45),
          ),
          const SizedBox(width: 6),
          Text(
            widget.label,
            style: TextStyle(
              fontSize: 13,
              color: fg,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );

    final scale = _pressed && !disable ? 0.94 : 1.0;

    if (disable) {
      return GestureDetector(
        onTap: widget.onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppGlass.restPillTint(scheme),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.white.withValues(
                alpha: scheme.brightness == Brightness.light ? 0.42 : 0.24,
              ),
            ),
          ),
          child: content,
        ),
      );
    }

    // 液态胶囊（与齿轮中心面同配方 blur0）；按压缩放果冻
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: scale,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        child: IntrinsicWidth(
          child: LiquidGlassLens(
            style: shellFrostLiquidStyle(
              scheme,
              navBlur: 0,
              navTint: shell.navTintStrength,
              radius: 16,
            ).copyWith(
              appearance: LiquidGlassAppearance(
                color: AppGlass.restPillTint(scheme),
                blur: const LiquidGlassBlur(sigmaX: 0, sigmaY: 0),
                shadow: null,
              ),
            ),
            child: content,
          ),
        ),
      ),
    );
  }
}

/// 底部 chrome：坐在**底→顶**渐变模糊垫上（菜单态）。
class ReaderBottomChrome extends StatelessWidget {
  const ReaderBottomChrome({
    super.key,
    required this.mode,
    required this.onToggleMode,
    required this.progress,
    required this.progressLabel,
    required this.onSeek,
    required this.fontSize,
    required this.onFontSize,
    required this.pageTurnMode,
    required this.onPageTurnMode,
    required this.pageTurnSpeed,
    required this.onPageTurnSpeed,
    required this.brightness,
    required this.onBrightness,
    required this.onCatalog,
    required this.onSearch,
    required this.onBookmark,
    required this.onNotes,
    required this.onSettings,
    this.onMore,
    this.embedVeil = true,
    this.iconShowText = true,
    this.iconItemsPerRow = 5,
    this.iconRowCount = 1,
  });

  final ReaderChromeMode mode;
  final VoidCallback onToggleMode;
  final double progress;
  final String progressLabel;
  final ValueChanged<double> onSeek;
  final double fontSize;
  final ValueChanged<double> onFontSize;
  final PageTurnMode pageTurnMode;
  final ValueChanged<PageTurnMode> onPageTurnMode;
  final PageTurnSpeed pageTurnSpeed;
  final ValueChanged<PageTurnSpeed> onPageTurnSpeed;

  /// 页面亮度 0.25–1（与正文遮罩共用，拖动不整页重建）
  final ValueListenable<double> brightness;
  final ValueChanged<double> onBrightness;
  final VoidCallback onCatalog;
  final VoidCallback onSearch;
  final VoidCallback onBookmark;
  final VoidCallback onNotes;
  final VoidCallback onSettings;
  final VoidCallback? onMore;

  /// false：外层已铺 [ReaderMenuFog]（固定贴底），此处只出内容。
  /// 开合 slide 只平移内容，雾垫不跟走，避免底边空白。
  final bool embedVeil;

  /// 工具排文字标签（ShellSettings.readerIconShowText）
  final bool iconShowText;

  /// 每行个数 4–6（ShellSettings.readerIconItemsPerRow）
  final int iconItemsPerRow;

  /// 行数 1–2（ShellSettings.readerIconRowCount）
  final int iconRowCount;

  Widget _tools(BuildContext context) {
    final showLabel = iconShowText;
    final perRow = iconItemsPerRow.clamp(4, 6);
    final rowCount = iconRowCount.clamp(1, 2);
    final capacity = perRow * rowCount;

    final actions = <_ToolAction>[
      _ToolAction(
        line: ReaderMenuIcons.lineCatalog,
        fill: ReaderMenuIcons.fillCatalog,
        label: '目录',
        onTap: onCatalog,
      ),
      _ToolAction(
        line: ReaderMenuIcons.lineSearch,
        fill: ReaderMenuIcons.fillSearch,
        label: '搜索',
        onTap: onSearch,
      ),
      _ToolAction(
        line: ReaderMenuIcons.lineBookmark,
        fill: ReaderMenuIcons.fillBookmark,
        label: '书签',
        onTap: onBookmark,
      ),
      _ToolAction(
        line: ReaderMenuIcons.lineNotes,
        fill: ReaderMenuIcons.fillNotes,
        label: '笔记',
        onTap: onNotes,
      ),
      _ToolAction(
        line: ReaderMenuIcons.lineSettings,
        fill: ReaderMenuIcons.fillSettings,
        label: '设置',
        onTap: onSettings,
      ),
    ];

    // 容量不够：末位让给「更多」，溢出动作进弹出菜单
    final bool needMore = actions.length > capacity;
    final int visibleCount = needMore ? capacity - 1 : actions.length;
    final visible = actions.sublist(0, visibleCount.clamp(0, actions.length));
    final overflow = actions.sublist(visibleCount.clamp(0, actions.length));

    final cells = <Widget>[
      for (final a in visible)
        ReaderToolBall(
          line: a.line,
          fill: a.fill,
          label: a.label,
          showLabel: showLabel,
          onTap: a.onTap,
        ),
      if (needMore)
        ReaderToolBall(
          line: ReaderMenuIcons.lineMore,
          fill: ReaderMenuIcons.fillMore,
          label: '更多',
          showLabel: showLabel,
          onTap: () => _showOverflowMenu(context, overflow),
        ),
    ];

    // 按 perRow 切行；末行 spaceEvenly 拉开
    final rows = <Widget>[];
    for (var i = 0; i < cells.length; i += perRow) {
      final end = (i + perRow).clamp(0, cells.length);
      rows.add(
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: cells.sublist(i, end),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var r = 0; r < rows.length; r++) ...[
          if (r > 0) const SizedBox(height: 2),
          rows[r],
        ],
      ],
    );
  }

  void _showOverflowMenu(BuildContext context, List<_ToolAction> overflow) {
    if (overflow.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final a in overflow)
                    ListTile(
                      leading: Icon(
                        // 溢出菜单用线性字形，避免与圆键双重命中
                        a.line,
                        size: 22,
                        color: scheme.onSurfaceVariant,
                      ),
                      title: Text(a.label),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        a.onTap();
                      },
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final content = mode == ReaderChromeMode.floating
        ? Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _liquidProgress(context),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                _tools(context),
                Center(
                  child: _ModeTogglePill(
                    label: '传统形态',
                    line: ReaderMenuIcons.lineModeTraditional,
                    fill: ReaderMenuIcons.fillModeTraditional,
                    onTap: onToggleMode,
                  ),
                ),
              ],
            ),
          )
        : Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 3),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _row(
                  context,
                  label: '进度',
                  child: Row(
                    children: [
                      Expanded(
                        child: _liquidProgress(context),
                      ),
                      SizedBox(
                        width: 48,
                        child: Text(
                          progressLabel,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                _row(
                  context,
                  label: '字号',
                  child: Row(
                    children: [
                      ReaderGlassCircle(
                        line: ReaderMenuIcons.lineMinus,
                        fill: ReaderMenuIcons.fillMinus,
                        size: 52,
                        onTap: () => onFontSize((fontSize - 1).clamp(12, 28)),
                      ),
                      SizedBox(
                        width: 36,
                        child: Text(
                          '${fontSize.round()}',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                      ReaderGlassCircle(
                        line: ReaderMenuIcons.linePlus,
                        fill: ReaderMenuIcons.fillPlus,
                        size: 52,
                        onTap: () => onFontSize((fontSize + 1).clamp(12, 28)),
                      ),
                      const Spacer(),
                      _ModeTogglePill(
                        label: '悬浮形态',
                        line: ReaderMenuIcons.lineModeFloating,
                        fill: ReaderMenuIcons.fillModeFloating,
                        onTap: onToggleMode,
                      ),
                    ],
                  ),
                ),
                _row(
                  context,
                  label: '翻页',
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '翻页方式：',
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            _GearScrollPicker(
                              items: [
                                for (final m in PageTurnMode.values)
                                  _pageTurnLabel(m),
                              ],
                          icons: const [
                            Icons.auto_stories_outlined,
                            Icons.swap_vert_rounded,
                            Icons.waves_rounded,
                            Icons.vertical_align_bottom_rounded,
                          ],
                          selectedIndex:
                              PageTurnMode.values.indexOf(pageTurnMode),
                          onChanged: (i) =>
                              onPageTurnMode(PageTurnMode.values[i]),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '翻页速度：',
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            _GearScrollPicker(
                              items: [
                                for (final s in PageTurnSpeed.values)
                                  _pageSpeedLabel(s),
                              ],
                          icons: const [
                            Icons.bolt_rounded,
                            Icons.directions_walk_rounded,
                            Icons.hourglass_bottom_rounded,
                          ],
                          selectedIndex:
                              PageTurnSpeed.values.indexOf(pageTurnSpeed),
                          onChanged: (i) =>
                              onPageTurnSpeed(PageTurnSpeed.values[i]),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                _row(
                  context,
                  label: '亮度',
                  child: Row(
                    children: [
                      const Icon(Icons.brightness_6_outlined, size: 20),
                      Expanded(
                        child: ValueListenableBuilder<double>(
                          valueListenable: brightness,
                          builder: (context, b, _) => _GlassTrackSlider(
                            value: b.clamp(0.25, 1.0),
                            min: 0.25,
                            max: 1,
                            onChanged: onBrightness,
                            activeColor: scheme.primary,
                            inactiveColor: scheme.onSurface.withValues(
                              alpha: 0.14,
                            ),
                            thumbColor: AppGlass.sliderThumb(scheme),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                _tools(context),
              ],
            ),
          );

    final body = Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.paddingOf(context).bottom * 0.4,
      ),
      child: content,
    );
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {},
      onPointerMove: (_) {},
      onPointerUp: (_) {},
      child: embedVeil
          ? ReaderBlurVeil(
              fromTop: false,
              band: mode == ReaderChromeMode.floating ? 220 : 330,
              // 保持进度栏可读，但不再把整块菜单向正文方向撑高。
              extend: 96,
              child: body,
            )
          : body,
    );
  }

  /// 进度滑轨：纯绘制（LiquidGlassSlider 内部 BF 触发缩放）
  Widget _liquidProgress(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _GlassTrackSlider(
      value: progress.clamp(0.0, 1.0),
      onChanged: onSeek,
      activeColor: scheme.primary,
      inactiveColor: scheme.onSurface.withValues(alpha: 0.14),
      thumbColor: AppGlass.sliderThumb(scheme),
    );
  }

  Widget _row(BuildContext context, {required String label, required Widget child}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: child),
        ],
      ),
    );
  }

  static String _pageTurnLabel(PageTurnMode m) {
    switch (m) {
      case PageTurnMode.simulation:
        return '卷曲';
      case PageTurnMode.verticalScroll:
        return '滚动';
      case PageTurnMode.ripple:
        return '水波纹';
      case PageTurnMode.collapse:
        return '坍塌';
    }
  }

  static String _pageSpeedLabel(PageTurnSpeed s) {
    switch (s) {
      case PageTurnSpeed.fast:
        return '快';
      case PageTurnSpeed.medium:
        return '中';
      case PageTurnSpeed.slow:
        return '慢';
    }
  }
}

/// 无 BackdropFilter 的玻璃外观滑轨。
/// 液态玻璃滑轨内部 BF 在 Impeller 上会导致正文缩放，此处用纯绘制模拟。
class _GlassTrackSlider extends StatelessWidget {
  const _GlassTrackSlider({
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    required this.activeColor,
    required this.inactiveColor,
    required this.thumbColor,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final Color activeColor;
  final Color inactiveColor;
  final Color thumbColor;

  @override
  Widget build(BuildContext context) {
    final t = ((value - min) / (max - min)).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 240.0;
        const thumbW = 28.0;
        const thumbH = 18.0;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) {
            final dx = d.localPosition.dx.clamp(0.0, w);
            onChanged(min + (dx / w) * (max - min));
          },
          onTapDown: (d) {
            final dx = d.localPosition.dx.clamp(0.0, w);
            onChanged(min + (dx / w) * (max - min));
          },
          child: SizedBox(
            width: w,
            height: 44,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                // 轨道底：细线（对齐设置页 4px）
                Positioned(
                  left: thumbW / 2,
                  right: thumbW / 2,
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: inactiveColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                // 填充
                Positioned(
                  left: thumbW / 2,
                  child: Container(
                    height: 4,
                    width: ((w - thumbW) * t).clamp(0.0, (w - thumbW).clamp(0.0, double.infinity)),
                    decoration: BoxDecoration(
                      color: activeColor,
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                ),
                // 拇指：胶囊形（对齐设置页 LiquidGlassSlider）
                Positioned(
                  left: (thumbW / 2 + (w - thumbW) * t - thumbW / 2)
                      .clamp(0.0, (w - thumbW).clamp(0.0, double.infinity)),
                  child: Container(
                    width: thumbW,
                    height: thumbH,
                    decoration: BoxDecoration(
                      color: thumbColor,
                      borderRadius: BorderRadius.circular(thumbH / 2),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.45),
                        width: 1.2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _GearScrollPicker extends StatefulWidget {
  const _GearScrollPicker({
    required this.items,
    required this.selectedIndex,
    required this.onChanged,
    this.icons,
  });

  final List<String> items;
  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final List<IconData>? icons;

  @override
  State<_GearScrollPicker> createState() => _GearScrollPickerState();
}

/// 齿轮滚动：
/// 1. 选中值**贴在固定胶囊面上**（同框居中，不是空间上方）
/// 2. 图标与文字**对中**（同一水平基线）
/// 3. 清晰度**向中间递增**（选中最清，两侧渐糊）
class _GearScrollPickerState extends State<_GearScrollPicker> {
  // 24 轮足够循环拖动；800 轮会让 SliverFillViewport 在大数
  // 浮点下触发 "not an even multiple of itemExtent" 断言。
  static const int _loopCycles = 24;

  late final PageController _controller;
  late int _basePage;
  double _page = 0;

  int get _len => widget.items.length;

  int get _virtualCount => _len * _loopCycles;

  int _virtToIndex(int virt) {
    final m = virt % _len;
    return m < 0 ? m + _len : m;
  }

  int get _centerVirt {
    final p = _controller.hasClients ? (_controller.page ?? _page) : _page;
    return p.round().clamp(0, _virtualCount - 1);
  }

  /// 当前最近项（滚动中实时，供胶囊面选中值用）
  int get _nearestIndex => _virtToIndex(_centerVirt);

  int? _lastEmitted;
  Timer? _commitTimer;

  @override
  void initState() {
    super.initState();
    _basePage = _loopCycles ~/ 2 * _len;
    _lastEmitted = widget.selectedIndex;
    _page = (_basePage + widget.selectedIndex).toDouble();
    // 手势层使用整页宽度，避免 viewportFraction × 大循环页数的
    // 浮点累计误差触发 RenderSliverFixedExtentBoxAdaptor 断言。
    _controller = PageController(
      initialPage: _basePage + widget.selectedIndex,
    );
    _controller.addListener(() {
      final p = _controller.page;
      if (p != null && mounted) setState(() => _page = p);
    });
  }

  @override
  void didUpdateWidget(covariant _GearScrollPicker old) {
    super.didUpdateWidget(old);
    if (old.selectedIndex == widget.selectedIndex) return;
    // 自身滚动回写绝不能 animate（跟手抢会「卡住」）
    if (widget.selectedIndex == _lastEmitted) return;
    if (_controller.position.isScrollingNotifier.value) return;
    final target = _basePage + widget.selectedIndex;
    if (_controller.hasClients && _centerVirt != target) {
      _controller.animateToPage(
        target,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    }
    _lastEmitted = widget.selectedIndex;
  }

  @override
  void dispose() {
    _commitTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// **停稳后再提交**，避免未停住就锁定
  void _onPageChanged(int virt) {
    final idx = _virtToIndex(virt);
    _commitTimer?.cancel();
    _commitTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      _lastEmitted = idx;
      widget.onChanged(idx);
    });
    if (virt < _len * 2 || virt > _virtualCount - _len * 2) {
      final wrapped = _basePage + idx;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_controller.hasClients) return;
        _controller.jumpToPage(wrapped);
        setState(() => _page = wrapped.toDouble());
      });
    }
  }

  IconData? _iconAt(int i) {
    final icons = widget.icons;
    if (icons == null || i < 0 || i >= icons.length) return null;
    return icons[i];
  }

  /// 选中值：**贴在胶囊面上**（与胶囊同框居中），变更时轻微落入面心
  Widget _capsuleSelected(ColorScheme scheme, int index) {
    final icon = _iconAt(index);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) {
        return FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.22),
              end: Offset.zero,
            ).animate(anim),
            child: child,
          ),
        );
      },
      child: Row(
        key: ValueKey<int>(index),
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: scheme.primary),
            const SizedBox(width: 4),
          ],
          Text(
            widget.items[index],
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: scheme.primary,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  /// 单个邻项字面（无 3D）
  Widget _peekLabel(
    ColorScheme scheme,
    int virtIndex, {
    required double opacity,
    required double blur,
    required double scale,
  }) {
    final i = _virtToIndex(virtIndex);
    final icon = _iconAt(i);
    Widget content = Row(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Icon(icon, size: (11 * scale).clamp(8.0, 12.0), color: scheme.onSurfaceVariant),
          const SizedBox(width: 2),
        ],
        Flexible(
          child: Text(
            widget.items[i],
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: (11 * scale).clamp(9.0, 12.0),
              fontWeight: FontWeight.w500,
              color: scheme.onSurface,
              height: 1.0,
            ),
          ),
        ),
      ],
    );
    if (blur >= 0.05) {
      content = ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: content,
      );
    }
    return Opacity(opacity: opacity.clamp(0.0, 1.0), child: content);
  }

  /// 固定三段齿槽：左右槽位独立裁剪，邻项只在自己的槽内连续移动。
  /// 这样不会因为 picker 父级 Stack 或 PageView viewport 而把邻项裁掉。
  Widget _sideTrack(ColorScheme scheme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 120.0;
        const capsuleWidth = 72.0;
        // 槽位总宽严格等于实际宽度减去中心胶囊宽度，绝不向 Row
        // 要求超出约束；picker 很窄时槽位可收缩为 0。
        final sideWidth = ((w - capsuleWidth) / 2).clamp(0.0, 90.0);
        final p = _page;
        final base = p.floor();
        final fraction = p - base;

        Widget slot({required bool left}) {
          final values = left
              ? <int>[base - 1, base - 2]
              : <int>[base + 1, base + 2];
          return SizedBox(
            width: sideWidth,
            height: 56,
            child: ClipRect(
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  for (var rank = 0; rank < values.length; rank++)
                    Positioned(
                      left: left
                          ? sideWidth - 48 - rank * 44 - fraction * 44
                          : rank * 44 - fraction * 44,
                      top: 8,
                      width: 48,
                      height: 40,
                      child: IgnorePointer(
                        child: _peekLabel(
                          scheme,
                          values[rank],
                          opacity: (rank == 0 ? 0.78 : 0.30) - fraction * 0.12,
                          blur: rank == 0 ? 0.8 + fraction * 0.8 : 2.2,
                          scale: rank == 0 ? 0.96 : 0.82,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        }

        return SizedBox(
          width: w,
          height: 56,
          child: Row(
            mainAxisSize: MainAxisSize.max,
            children: [
              slot(left: true),
              SizedBox(
                width: capsuleWidth,
                height: 56,
                child: const SizedBox.expand(),
              ),
              slot(left: false),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 无 3D 变换（Matrix4/rotateY 开菜单挂载会导致 Windows 正文缩放观感）
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          // 手势层：透明 PageView 只负责横滑
          Positioned.fill(
            child: PageView.builder(
              controller: _controller,
              itemCount: _virtualCount,
              onPageChanged: _onPageChanged,
              itemBuilder: (context, virt) => const SizedBox.expand(),
            ),
          ),
          // 外侧滚动轨（随 _page 连续滑动）；放在手势层上方，避免透明
          // PageView 的 viewport/绘制层把窄槽邻项视觉上吞掉。
          Positioned.fill(child: _sideTrack(scheme)),
          // 中心液态胶囊：固定不动（面心留给选中值）
          // 尺寸与 _sideTrack.capsuleWidth(72) 对齐；blur0 液态镜片（同圆键）
          Positioned(
            child: IgnorePointer(
              child: SizedBox(
                width: 72,
                height: 44,
                child: LiquidGlassLens(
                  style: shellFrostLiquidStyle(
                    scheme,
                    navBlur: 0,
                    navTint: 0.38,
                    radius: 16,
                  ).copyWith(
                    appearance: LiquidGlassAppearance(
                      color: AppGlass.restPillTint(scheme),
                      blur: const LiquidGlassBlur(sigmaX: 0, sigmaY: 0),
                      shadow: null,
                    ),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
          // 选中值**贴在胶囊面上**（同框居中，不是空间上方）
          Positioned(
            child: IgnorePointer(
              child: SizedBox(
                width: 72,
                height: 44,
                child: Center(child: _capsuleSelected(scheme, _nearestIndex)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

void readerChromeStub(BuildContext context, String action) {
  // 真机排障：stub 也打 trace，避免「点了没反应且无日志」
  // ignore: avoid_print
  print('[reader-chrome] stub $action');
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('$action · 待接入'),
      duration: const Duration(milliseconds: 900),
    ),
  );
}
