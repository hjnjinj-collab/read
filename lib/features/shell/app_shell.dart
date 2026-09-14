import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_icons.dart';
import '../../core/theme/app_theme.dart';

/// 三 Tab 应用壳（StatefulShell 状态保活）。
/// 底栏：主色滤镜玻璃（alpha 0.5）+ 上方氛围晕染；extendBody 让封面穿过。
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final index = navigationShell.currentIndex;
    final scheme = Theme.of(context).colorScheme;
    final disableBlur = MediaQuery.disableAnimationsOf(context);
    final bottomSafe = MediaQuery.paddingOf(context).bottom;

    final destinations = const [
      NavigationDestination(
        icon: Icon(AppIcons.bookshelf),
        label: '书架',
      ),
      NavigationDestination(
        icon: Icon(AppIcons.sources),
        label: '书源',
      ),
      NavigationDestination(
        icon: Icon(AppIcons.settings),
        label: '设置',
      ),
    ];

    final bar = NavigationBar(
      selectedIndex: index,
      onDestinationSelected: (i) => navigationShell.goBranch(
        i,
        initialLocation: i == navigationShell.currentIndex,
      ),
      backgroundColor: Colors.transparent,
      destinations: destinations,
    );

    Widget glassBar;
    if (disableBlur) {
      glassBar = ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: ColoredBox(
          color: scheme.primaryContainer.withValues(alpha: 0.92),
          child: bar,
        ),
      );
    } else {
      glassBar = ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: AppGlass.blurSigma,
            sigmaY: AppGlass.blurSigma,
          ),
          child: ColoredBox(
            color: AppGlass.tint(scheme, strength: 0.5),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.22),
                  width: 0.9,
                ),
                boxShadow: [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.14),
                    blurRadius: 28,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: bar,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      extendBody: true,
      body: Stack(
        children: [
          navigationShell,
          // 底部氛围：主色自下而上淡出，范围更大
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
                      scheme.primary.withValues(alpha: 0.18),
                      scheme.primary.withValues(alpha: 0.08),
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
        child: glassBar,
      ),
    );
  }
}
