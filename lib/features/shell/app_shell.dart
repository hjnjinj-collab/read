import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/theme/app_icons.dart';
import '../../core/theme/app_theme.dart';
import 'home_page.dart' show homeIntroTick;
import 'providers/shell_actions.dart';
import 'providers/shell_settings.dart';
import 'widgets/expandable_glass_nav.dart';
import 'widgets/shell_ambient.dart' show AmbientDir, ShellAmbient;

/// 四 Tab 应用壳（StatefulShell 状态保活）：0 首页 · 1 书架 · 2 书源 · 3 设置。
/// 底栏主胶囊 `[首页|书架]` + 更多（默认进设置；在设置展开 `[书源|设置]`）。
/// Tab 切换：AppShell 自播 Fade+方向轻 slide（shell 不 remount，状态保活）。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell>
    with SingleTickerProviderStateMixin {
  bool _navExpanded = false;
  late final AnimationController _tabAnim = AnimationController(
    vsync: this,
    duration: AppMotion.tabDuration,
  );
  Offset _tabSlideBegin = AppMotion.tabSlideBegin;

  @override
  void dispose() {
    _tabAnim.dispose();
    super.dispose();
  }

  void _playTabTransition(int from, int to) {
    if (MediaQuery.disableAnimationsOf(context)) return;
    if (from == to) return;
    // index 增大：新页自右滑入；减小：自左
    _tabSlideBegin = to > from
        ? AppMotion.tabSlideBegin
        : Offset(-AppMotion.tabSlideBegin.dx, 0);
    _tabAnim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final navigationShell = widget.navigationShell;
    final scheme = Theme.of(context).colorScheme;
    final disableBlur = MediaQuery.disableAnimationsOf(context);
    final bottomSafe = MediaQuery.paddingOf(context).bottom;
    final shell = ref.watch(shellSettingsProvider);
    final navBlur = shell.navBlurSigma;
    final navTint = shell.navTintStrength;

    void goBranch(int i, {bool collapseNav = true}) {
      final from = navigationShell.currentIndex;
      navigationShell.goBranch(
        i,
        initialLocation: i == from,
      );
      _playTabTransition(from, i);
      // 回首页：重播 Dashboard 入场（StatefulShell 保活不会重建）
      if (i == 0) {
        homeIntroTick.value++;
      }
      if (collapseNav && _navExpanded) {
        setState(() => _navExpanded = false);
      }
    }

    // 更多：先展开导航（320ms），再落到设置——路由不抢在动画前
    void onToggleExpand() {
      final opening = !_navExpanded;
      setState(() => _navExpanded = opening);
      if (opening) {
        Future.delayed(const Duration(milliseconds: 280), () {
          if (!mounted) return;
          goBranch(3, collapseNav: false);
        });
      }
    }

    final chrome = disableBlur
        ? _SolidBottomNav(
            key: ValueKey('solid-${shell.glassMode}'),
            index: navigationShell.currentIndex,
            onIndexChanged: (i) => goBranch(i),
          )
        : ExpandableGlassNav(
            key: ValueKey(
              'glass-${shell.glassMode}-${shell.navBlurSigma}-${shell.navTintStrength}',
            ),
            selectedIndex: navigationShell.currentIndex,
            onChanged: (i) => goBranch(i),
            expanded: _navExpanded,
            onToggleExpand: onToggleExpand,
            onCollapse: () => setState(() => _navExpanded = false),
            onSettings: () => goBranch(3, collapseNav: false),
            onSources: () => goBranch(2, collapseNav: true),
            onImport: () => requestBookImport(ref),
            barStyle: _shellFrost(
              scheme,
              navBlur: navBlur,
              navTint: navTint,
              radius: AppGlass.navBarRadius,
            ),
            circleStyle: _shellFrost(
              scheme,
              navBlur: navBlur,
              navTint: navTint,
              radius: 32,
            ),
            selectedColor: scheme.primary,
            unselectedColor: scheme.onSurfaceVariant,
          );

    final curved = CurvedAnimation(
      parent: _tabAnim,
      curve: AppMotion.tabCurve,
    );
    final tabFade = Tween<double>(begin: 0.55, end: 1.0).animate(curved);
    final tabSlide = Tween<Offset>(
      begin: _tabSlideBegin,
      end: Offset.zero,
    ).animate(curved);

    return Scaffold(
      extendBody: true,
      body: Stack(
        children: [
          // 三 Tab 共用细腻主色氛围（全高缓坡，非底部硬条）
          Positioned.fill(
            child: IgnorePointer(
              child: ShellAmbient(
                enabled: shell.ambientOn,
                dir: AmbientDir.parse(shell.ambientDir),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          // 不 remount navigationShell：IndexedStack 分支状态保活
          AnimatedBuilder(
            animation: _tabAnim,
            builder: (context, child) {
              // 静止（含减弱动态 / 动画结束前未触发）：直接挂 shell
              if (_tabAnim.isDismissed) return child!;
              return FadeTransition(
                opacity: tabFade,
                child: SlideTransition(position: tabSlide, child: child),
              );
            },
            child: navigationShell,
          ),
        ],
      ),
      bottomNavigationBar: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 8 + bottomSafe * 0.3),
        // 包一层，避免底栏命中/形变影响 body 滚动
        child: Material(
          type: MaterialType.transparency,
          child: chrome,
        ),
      ),
    );
  }
}

LiquidGlassStyle _shellFrost(
  ColorScheme scheme, {
  required double navBlur,
  required double navTint,
  double radius = 28,
}) {
  return LiquidGlassStyle(
    shape: LiquidGlassShape.continuousRoundedRectangle(
      cornerRadius: radius,
      borderWidth: 1.0,
      borderColor: Colors.white.withValues(
        alpha: scheme.brightness == Brightness.light ? 0.45 : 0.22,
      ),
      lightIntensity: 1.1,
    ),
    appearance: LiquidGlassAppearance(
      color: AppGlass.navGlass(scheme, strength: navTint),
      blur: LiquidGlassBlur(sigmaX: navBlur, sigmaY: navBlur),
      shadow: LiquidGlassShadow(
        blur: 18,
        opacity: 0.16,
        offset: const Offset(0, 6),
        cornerRadius: radius,
      ),
    ),
    refraction: const LiquidGlassRefraction(
      distortion: 0.1,
      distortionWidth: 28,
      chromaticAberration: 0.002,
    ),
  );
}

/// 减弱动态：实底三 Tab
class _SolidBottomNav extends StatelessWidget {
  const _SolidBottomNav({
    super.key,
    required this.index,
    required this.onIndexChanged,
  });

  final int index;
  final ValueChanged<int> onIndexChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const items = [
      (AppIcons.home, '首页'),
      (AppIcons.bookshelf, '书架'),
      (AppIcons.sources, '书源'),
      (AppIcons.settings, '设置'),
    ];
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppGlass.navBarRadius),
      child: ColoredBox(
        color: scheme.primaryContainer.withValues(alpha: 0.92),
        child: SizedBox(
          height: 64,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (var i = 0; i < items.length; i++)
                _SolidTab(
                  icon: items[i].$1,
                  label: items[i].$2,
                  selected: i == index,
                  onTap: () => onIndexChanged(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SolidTab extends StatelessWidget {
  const _SolidTab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
