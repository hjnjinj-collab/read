import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_icons.dart';
import '../../core/theme/app_theme.dart';

/// 三 Tab 应用壳。
/// 准则：模糊必须叠主色滤镜；底栏悬浮 + extendBody，封面从玻璃四周穿过。
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  static const _tabs = ['/bookshelf', '/sources', '/settings'];

  int _indexForLocation(String location) {
    for (var i = 0; i < _tabs.length; i++) {
      if (location.startsWith(_tabs[i])) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.toString();
    final index = _indexForLocation(location);
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

    Widget bar;
    if (disableBlur) {
      bar = ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: ColoredBox(
          color: scheme.surfaceContainer,
          child: NavigationBar(
            selectedIndex: index,
            onDestinationSelected: (i) => context.go(_tabs[i]),
            backgroundColor: Colors.transparent,
            destinations: destinations,
          ),
        ),
      );
    } else {
      bar = ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: AppGlass.blurSigma,
            sigmaY: AppGlass.blurSigma,
          ),
          // 准则：模糊 + 净色主色滤镜（近白底，轻染 primary）
          child: ColoredBox(
            color: AppGlass.tint(scheme, strength: 0.5),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.12),
                  width: 0.8,
                ),
                boxShadow: [
                  BoxShadow(
                    color: scheme.shadow.withValues(alpha: 0.08),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: NavigationBar(
                selectedIndex: index,
                onDestinationSelected: (i) => context.go(_tabs[i]),
                backgroundColor: Colors.transparent,
                destinations: destinations,
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      extendBody: true,
      body: child,
      bottomNavigationBar: Padding(
        // 悬浮：左右留白，封面从侧边与底部露出
        padding: EdgeInsets.fromLTRB(16, 0, 16, 8 + bottomSafe * 0.3),
        child: bar,
      ),
    );
  }
}
