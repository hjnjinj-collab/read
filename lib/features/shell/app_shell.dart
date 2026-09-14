import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_icons.dart';
import '../../core/theme/app_theme.dart';

/// 三 Tab 应用壳：书架 / 书源 / 设置
/// 底栏为「主色滤镜毛玻璃」NavigationBar（见 AppGlass 准则）。
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

    final bar = NavigationBar(
      selectedIndex: index,
      onDestinationSelected: (i) => context.go(_tabs[i]),
      backgroundColor: Colors.transparent,
      destinations: const [
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
      ],
    );

    return Scaffold(
      extendBody: !disableBlur,
      body: child,
      bottomNavigationBar: disableBlur
          ? ColoredBox(color: scheme.surfaceContainer, child: bar)
          : ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: AppGlass.blurSigma,
                  sigmaY: AppGlass.blurSigma,
                ),
                // 准则：模糊必须叠主色滤镜
                child: ColoredBox(
                  color: AppGlass.tint(scheme, strength: 0.62),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(
                          color: scheme.primary.withValues(alpha: 0.12),
                          width: 0.8,
                        ),
                      ),
                    ),
                    child: bar,
                  ),
                ),
              ),
            ),
    );
  }
}
