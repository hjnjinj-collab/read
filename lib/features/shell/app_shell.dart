import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/theme/app_icons.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/shell_glass_style.dart';
import 'home_page.dart' show homeIntroTick;
import 'providers/shell_actions.dart';
import 'providers/shell_settings.dart';
import 'widgets/expandable_glass_nav.dart';
import 'widgets/shell_ambient.dart' show AmbientDir, ShellAmbient;

/// 四 Tab 应用壳（StatefulShell 状态保活）：0 首页 · 1 书架 · 2 书源 · 3 设置。
/// 底栏 IA（玻璃/Solid 同构）：默认 `[首页|书架|书源]` + 更多；
/// 更多态左「首页」圆键 + 右 `[设置|添加书籍]`。
/// Tab 切换：AppShell 自播方向轻 slide（禁止 Fade/Opacity 包 shell，
/// Impeller 下页内液态在 opacity layer 会采样变暗）。
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
      final sameTab = i == from;
      // 仅设置子页：同 Tab 重置回 hub；其它同 Tab no-op（保留滚动位/栈）
      var resetToHub = false;
      if (sameTab && i == 3) {
        final path = GoRouter.of(context).state.uri.path;
        resetToHub = path != '/settings';
      }
      if (sameTab && !resetToHub) {
        if (collapseNav && _navExpanded) {
          setState(() => _navExpanded = false);
        }
        return;
      }
      navigationShell.goBranch(
        i,
        initialLocation: resetToHub,
      );
      _playTabTransition(from, i);
      // 仅跨 Tab 进首页：重播 Dashboard 入场（同 Tab 重选不叠戏）
      if (i == 0 && from != 0) {
        homeIntroTick.value++;
      }
      if (collapseNav && _navExpanded) {
        setState(() => _navExpanded = false);
      }
    }

    // 更多：先展开导航（320ms），再落到设置——路由不抢在动画前
    // 减弱动态：立即进设置（无展开延迟）
    void onToggleExpand() {
      final opening = !_navExpanded;
      setState(() => _navExpanded = opening);
      if (opening) {
        if (MediaQuery.disableAnimationsOf(context)) {
          goBranch(3, collapseNav: false);
          return;
        }
        Future.delayed(const Duration(milliseconds: 280), () {
          if (!mounted) return;
          // 快速开→收：延迟回调不得在收起态仍强制进设置
          if (!_navExpanded) return;
          goBranch(3, collapseNav: false);
        });
      }
    }

    final chrome = disableBlur
        ? _SolidBottomNav(
            key: ValueKey('solid-${shell.glassMode}'),
            selectedIndex: navigationShell.currentIndex,
            onChanged: (i) => goBranch(i),
            expanded: _navExpanded,
            onToggleExpand: onToggleExpand,
            onCollapse: () => setState(() => _navExpanded = false),
            onSettings: () => goBranch(3, collapseNav: false),
            onImport: () => requestBookImport(ref),
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
              // 仅 slide：禁止 Fade/Opacity 包住含 LiquidGlass 的 navigationShell
              return SlideTransition(position: tabSlide, child: child);
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
  // 与书架/阅读 chrome 同源唯一实现
  return shellFrostLiquidStyle(
    scheme,
    navBlur: navBlur,
    navTint: navTint,
    radius: radius,
  );
}

/// 减弱动态：实底底栏 —— **与玻璃 IA 同构**（左三段 + 更多 / 更多态左首页 + 右设置|添加书籍）。
/// 无液态、无宽度动画；布局与命中区对齐 `ExpandableGlassNav`。
class _SolidBottomNav extends StatelessWidget {
  const _SolidBottomNav({
    super.key,
    required this.selectedIndex,
    required this.onChanged,
    required this.expanded,
    required this.onToggleExpand,
    required this.onCollapse,
    required this.onSettings,
    required this.onImport,
  });

  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final bool expanded;
  final VoidCallback onToggleExpand;
  final VoidCallback onCollapse;
  final VoidCallback onSettings;
  final VoidCallback onImport;

  /// 与玻璃底栏放大后同高（真机反馈整体偏大，收回 60/208）
  static const double _height = 60;
  static const double _barW = 208;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = scheme.primaryContainer.withValues(alpha: 0.92);
    final radius = AppGlass.navBarRadius;
    final height = _height;
    final circle = height;
    final available = MediaQuery.sizeOf(context).width - 32;
    const tightGap = 8.0;
    var barW = (available - circle - tightGap).clamp(120.0, _barW);
    if (barW + circle > available) {
      barW = (available - circle - 4).clamp(80.0, _barW);
    }
    // 展开面板：居右、向右满宽填充（与玻璃同构原布局）
    final panelW = (available - circle - tightGap).clamp(120.0, available);

    final mainHasSel = selectedIndex <= 2;
    final mainBar = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: ColoredBox(
        color: bg,
        child: SizedBox(
          width: barW,
          height: height - 4,
          child: Row(
            children: [
              for (var i = 0; i < 3; i++)
                Expanded(
                  child: _SolidTab(
                    icon: const [AppIcons.home, AppIcons.bookshelf, AppIcons.sources][i],
                    label: const ['首页', '书架', '书源'][i],
                    selected: mainHasSel && selectedIndex == i,
                    onTap: () => onChanged(i),
                    iconSize: 22,
                    fontSize: 11,
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    final settingsSel = selectedIndex == 3;
    final morePanel = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: ColoredBox(
        color: bg,
        child: SizedBox(
          width: panelW,
          height: height - 4,
          child: Row(
            children: [
              Expanded(
                child: _SolidTab(
                  icon: AppIcons.settings,
                  label: '设置',
                  selected: settingsSel,
                  onTap: onSettings,
                  horizontal: true,
                  iconSize: 20,
                  fontSize: 12,
                ),
              ),
              Expanded(
                child: _SolidTab(
                  icon: AppIcons.importFile,
                  label: '添加书籍',
                  selected: false,
                  onTap: onImport,
                  horizontal: true,
                  iconSize: 20,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    Widget solidCircle(IconData icon, VoidCallback onTap, {bool selected = false}) {
      return ClipOval(
        child: Material(
          color: bg,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: circle,
              height: circle,
              child: Icon(
                icon,
                size: 24,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: height,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) {},
        onPointerMove: (_) {},
        onPointerUp: (_) {},
        child: Row(
          mainAxisAlignment: expanded
              ? MainAxisAlignment.start
              : MainAxisAlignment.spaceBetween,
          children: [
            SizedBox(
              width: expanded ? circle : barW,
              height: height,
              child: expanded
                  ? solidCircle(
                      AppIcons.home,
                      () {
                        onCollapse();
                        onChanged(0);
                      },
                      selected: selectedIndex == 0,
                    )
                  : mainBar,
            ),
            if (expanded) const SizedBox(width: tightGap),
            SizedBox(
              width: expanded ? panelW : circle,
              height: height,
              child: expanded
                  ? morePanel
                  : solidCircle(Icons.more_horiz_rounded, onToggleExpand),
            ),
          ],
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
    this.horizontal = false,
    this.iconSize = 22,
    this.fontSize = 11,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool horizontal;
  final double iconSize;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: horizontal ? 10 : 12,
          vertical: 8,
        ),
        child: horizontal
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: iconSize, color: color),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: fontSize,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: color,
                    ),
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: iconSize, color: color),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: fontSize,
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
