import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/theme/app_icons.dart';
import '../../core/theme/app_theme.dart';
import 'providers/shell_actions.dart';
import 'providers/shell_settings.dart';
import 'widgets/expandable_glass_nav.dart';

/// 三 Tab 应用壳（StatefulShell 状态保活）。
/// 底栏：书架/书源 胶囊 + 右侧「更多」（设置 / 添加书籍）。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  bool _navExpanded = false;

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
      navigationShell.goBranch(
        i,
        initialLocation: i == navigationShell.currentIndex,
      );
      if (collapseNav && _navExpanded) {
        setState(() => _navExpanded = false);
      }
    }

    // glassMode 变了必须重建：Engine 是静态开关，Lens 不会自己 invalidate
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
            onToggleExpand: () =>
                setState(() => _navExpanded = !_navExpanded),
            onCollapse: () => setState(() => _navExpanded = false),
            // 设置/添加：只执行，不收起展开态
            onSettings: () => goBranch(2, collapseNav: false),
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

    return Scaffold(
      extendBody: true,
      body: Stack(
        children: [
          navigationShell,
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: AppGlass.bottomAmbientHeight,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      scheme.primary.withValues(alpha: 0.16),
                      scheme.primary.withValues(alpha: 0.06),
                      scheme.primary.withValues(alpha: 0),
                    ],
                    stops: const [0, 0.4, 1],
                  ),
                ),
              ),
            ),
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
