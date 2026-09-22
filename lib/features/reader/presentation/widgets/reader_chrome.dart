import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../../../core/theme/app_theme.dart' show AppGlass;
import '../../../../core/theme/shell_glass_style.dart';
import '../../../shell/providers/shell_settings.dart';
import 'page_turn/page_turn_types.dart';

/// 菜单形态：A 传统底栏 / B 悬浮图标
enum ReaderChromeMode { traditional, floating }

/// 阅读 chrome 液态玻璃圆键 —— **与书架底栏圆键同源**。
///
/// 样式走 [shellFrostLiquidStyle]（唯一实现），blur/tint 跟壳层设置；
/// 构造对齐 `ExpandableGlassNav` 的 `LiquidGlassTabBarAction`。
/// 禁止：祖先 Clip≠none、ClipOval/saveLayer、另写折射参数。
class ReaderGlassCircle extends ConsumerWidget {
  const ReaderGlassCircle({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 52,
    this.selected = false,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final bool selected;
  final String? tooltip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final shell = ref.watch(shellSettingsProvider);
    final disable = MediaQuery.disableAnimationsOf(context);
    final fg = selected ? scheme.primary : scheme.onSurface;

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
            child: Icon(icon, size: size * 0.42, color: fg),
          ),
        ),
      );
      return tooltip == null ? solid : Tooltip(message: tooltip!, child: solid);
    }

    // 与 expandable_glass_nav 圆键同构：直接 Action + 壳层 frost 样式
    final glass = LiquidGlassTabBarAction(
      icon: icon,
      size: size,
      foregroundColor: fg,
      style: shellFrostLiquidStyle(
        scheme,
        navBlur: shell.navBlurSigma,
        navTint: shell.navTintStrength,
        radius: size / 2,
      ),
      touch: const LiquidGlassTouch(flex: LiquidGlassFlex()),
      onTap: onTap ?? () {},
    );
    return tooltip == null ? glass : Tooltip(message: tooltip!, child: glass);
  }
}

/// 顶/底渐变雾垫（壳滤镜同语言）。
/// [fromTop] true=顶→底，false=底→顶。
///
/// **无 BackdropFilter**：菜单态已挂液态圆键（与书架同源 frost），
/// 再叠垫层 BF 违反 Impeller「禁止叠 BackdropFilter」。垫只做渐变雾。
/// 默认仅在菜单态挂载，避免阅读中常驻大模糊拖死首帧/开书。
class ReaderBlurVeil extends StatelessWidget {
  const ReaderBlurVeil({
    super.key,
    required this.fromTop,
    required this.child,
    this.extend = 64,
    this.band = 56,
  });

  final bool fromTop;
  final Widget child;
  final double extend;
  final double band;

  static const List<double> _stops = [0, 0.18, 0.38, 0.58, 0.78, 1];
  static const List<double> _fogAlphas = [0.72, 0.62, 0.48, 0.30, 0.12, 0];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final disable = MediaQuery.disableAnimationsOf(context);
    final pad = MediaQuery.paddingOf(context);
    final padV = fromTop ? pad.top : pad.bottom;
    final h = padV + band + extend;
    final begin = fromTop ? Alignment.topCenter : Alignment.bottomCenter;
    final end = fromTop ? Alignment.bottomCenter : Alignment.topCenter;
    final fog = AppGlass.topTint(scheme);

    if (disable) {
      return ColoredBox(
        color: scheme.surface.withValues(alpha: 0.92),
        child: SizedBox(height: padV + band, width: double.infinity, child: child),
      );
    }

    return SizedBox(
      height: h,
      width: double.infinity,
      // Clip.none：液态圆键是 child 后代，祖先裁切必须为 none
      //（Stack 默认 hardEdge 会切断 lens 采样/阴影外溢）
      child: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: begin,
                    end: end,
                    colors: [
                      for (final a in _fogAlphas)
                        a == 0
                            ? Colors.transparent
                            : fog.withValues(alpha: a * 0.9),
                    ],
                    stops: _stops,
                  ),
                ),
              ),
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
    required this.icon,
    required this.label,
    required this.onTap,
    this.showLabel = true,
  });

  final IconData icon;
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
          ReaderGlassCircle(icon: icon, size: 52, onTap: onTap),
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
  });

  final String title;
  final String pageLabel;
  final VoidCallback onBack;
  final VoidCallback? onMore;
  final bool withVeil;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final light = scheme.brightness == Brightness.light;
    final row = SizedBox(
      height: 60,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
        child: Row(
          children: [
            ReaderGlassCircle(
              icon: Icons.arrow_back_rounded,
              size: 52,
              tooltip: '返回',
              onTap: onBack,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            Text(
              pageLabel,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 8),
            ReaderGlassCircle(
              icon: Icons.more_horiz_rounded,
              size: 52,
              tooltip: '更多',
              onTap: onMore,
            ),
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
      extend: 48,
      child: row,
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
    required this.onCatalog,
    required this.onSearch,
    required this.onBookmark,
    required this.onNotes,
    required this.onSettings,
    this.onMore,
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
  final VoidCallback onCatalog;
  final VoidCallback onSearch;
  final VoidCallback onBookmark;
  final VoidCallback onNotes;
  final VoidCallback onSettings;
  final VoidCallback? onMore;

  Widget _tools() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        ReaderToolBall(icon: Icons.menu_book_rounded, label: '目录', onTap: onCatalog),
        ReaderToolBall(icon: Icons.search_rounded, label: '搜索', onTap: onSearch),
        ReaderToolBall(icon: Icons.bookmark_outline, label: '书签', onTap: onBookmark),
        ReaderToolBall(icon: Icons.edit_note_rounded, label: '笔记', onTap: onNotes),
        ReaderToolBall(icon: Icons.settings_outlined, label: '设置', onTap: onSettings),
      ],
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
                    ReaderGlassCircle(
                      icon: Icons.chevron_left_rounded,
                      size: 52,
                      onTap: () => onSeek((progress - 0.02).clamp(0, 1)),
                    ),
                    Expanded(
                      child: Slider(value: progress.clamp(0, 1), onChanged: onSeek),
                    ),
                    ReaderGlassCircle(
                      icon: Icons.chevron_right_rounded,
                      size: 52,
                      onTap: () => onSeek((progress + 0.02).clamp(0, 1)),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                _tools(),
                TextButton(
                  onPressed: onToggleMode,
                  child: Text(
                    '传统形态',
                    style: TextStyle(fontSize: 11, color: scheme.primary),
                  ),
                ),
              ],
            ),
          )
        : Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _row(
                  context,
                  label: '进度',
                  child: Row(
                    children: [
                      ReaderGlassCircle(
                        icon: Icons.chevron_left_rounded,
                        size: 52,
                        onTap: () => onSeek((progress - 0.02).clamp(0, 1)),
                      ),
                      Expanded(
                        child: Slider(value: progress.clamp(0, 1), onChanged: onSeek),
                      ),
                      ReaderGlassCircle(
                        icon: Icons.chevron_right_rounded,
                        size: 52,
                        onTap: () => onSeek((progress + 0.02).clamp(0, 1)),
                      ),
                      SizedBox(
                        width: 48,
                        child: Text(
                          progressLabel,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 11,
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
                        icon: Icons.remove_rounded,
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
                        icon: Icons.add_rounded,
                        size: 52,
                        onTap: () => onFontSize((fontSize + 1).clamp(12, 28)),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: onToggleMode,
                        child: Text(
                          '悬浮形态',
                          style: TextStyle(fontSize: 11, color: scheme.primary),
                        ),
                      ),
                    ],
                  ),
                ),
                _row(
                  context,
                  label: '翻页方式',
                  child: Wrap(
                    spacing: 6,
                    children: [
                      for (final m in PageTurnMode.values)
                        _Chip(
                          label: _pageTurnLabel(m),
                          selected: pageTurnMode == m,
                          onTap: () => onPageTurnMode(m),
                        ),
                    ],
                  ),
                ),
                _row(
                  context,
                  label: '翻页速度',
                  child: Wrap(
                    spacing: 6,
                    children: [
                      for (final s in PageTurnSpeed.values)
                        _Chip(
                          label: _pageSpeedLabel(s),
                          selected: pageTurnSpeed == s,
                          onTap: () => onPageTurnSpeed(s),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                _tools(),
              ],
            ),
          );

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {},
      onPointerMove: (_) {},
      onPointerUp: (_) {},
      child: ReaderBlurVeil(
        fromTop: false,
        band: mode == ReaderChromeMode.floating ? 180 : 280,
        extend: 96,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.paddingOf(context).bottom * 0.4,
          ),
          child: content,
        ),
      ),
    );
  }

  Widget _row(BuildContext context, {required String label, required Widget child}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
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

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final light = scheme.brightness == Brightness.light;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.16)
          : Colors.white.withValues(alpha: light ? 0.45 : 0.14),
      shape: StadiumBorder(
        side: BorderSide(
          color: selected
              ? scheme.primary.withValues(alpha: 0.45)
              : Colors.white.withValues(alpha: light ? 0.45 : 0.22),
          width: light ? 0.6 : 0.8,
        ),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? scheme.primary : scheme.onSurface,
            ),
          ),
        ),
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
