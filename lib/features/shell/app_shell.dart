import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_icons.dart';

/// 三 Tab 应用壳：书架 / 书源 / 设置
/// 底栏为毛玻璃 NavigationBar，内容 extendBody 从其下穿过。
class AppShell extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).uri.toString();
    final index = _indexForLocation(location);
    final scheme = Theme.of(context).colorScheme;
    final disableBlur = MediaQuery.disableAnimationsOf(context);

    final bar = NavigationBar(
      selectedIndex: index,
      onDestinationSelected: (i) => context.go(_tabs[i]),
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
      extendBody: true,
      body: child,
      bottomNavigationBar: disableBlur
          ? bar
          : ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                child: ColoredBox(
                  color: scheme.surfaceContainer.withValues(alpha: 0.55),
                  child: bar,
                ),
              ),
            ),
    );
  }
}
