import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/about/presentation/pages/about_page.dart';
import '../../features/reader/presentation/pages/reader_page.dart';
import '../../features/shell/app_shell.dart';
import '../../features/shell/book_sources_page.dart';
import '../../features/shell/bookshelf/bookshelf_layout.dart';
import '../../features/shell/bookshelf/bookshelf_page.dart';
import '../../features/shell/settings_page.dart';
import '../../core/theme/app_theme.dart';

/// 路由表：StatefulShell 三 Tab（状态保活）+ 全屏阅读/关于
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/bookshelf',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            AppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/bookshelf',
                pageBuilder: (context, state) =>
                    const NoTransitionPage(child: BookshelfPage()),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/sources',
                pageBuilder: (context, state) =>
                    const NoTransitionPage(child: BookSourcesPage()),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                pageBuilder: (context, state) =>
                    const NoTransitionPage(child: SettingsPage()),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/reader',
        pageBuilder: (context, state) {
          final extra = state.extra;
          if (extra is! Map) {
            return const MaterialPage(child: _InvalidReaderArgs());
          }
          final filePath = extra['filePath']?.toString() ?? '';
          if (filePath.isEmpty) {
            return const MaterialPage(child: _InvalidReaderArgs());
          }
          final shelfIndex = (extra['shelfIndex'] as num?)?.toInt() ?? 0;
          return CustomTransitionPage(
            key: state.pageKey,
            transitionDuration: AppMotion.readerShrinkDuration,
            reverseTransitionDuration: AppMotion.readerShrinkDuration,
            child: ReaderPage(
              filePath: filePath,
              bookName: extra['bookName']?.toString() ?? '',
            ),
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) {
              return _ReaderShrinkTransition(
                animation: animation,
                pushIndex: shelfIndex,
                child: child,
              );
            },
          );
        },
      ),
      GoRoute(
        path: '/about',
        builder: (context, state) => const AboutPage(),
      ),
    ],
  );
});

/// 阅读页进出：整页向书架槽位缩放 + 淡入淡出。
/// push：从当前书槽位放大铺满（从哪来）；pop：缩回第一本（去哪，落地即最近阅读）。
class _ReaderShrinkTransition extends StatelessWidget {
  const _ReaderShrinkTransition({
    required this.animation,
    required this.pushIndex,
    required this.child,
  });

  final Animation<double> animation;

  /// push 时书架上被点开的书的下标；pop 忽略、固定落 index 0
  final int pushIndex;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 缩放：整段 easeInOut，中段轨迹可读
    final scaleCurve = CurvedAnimation(
      parent: animation,
      curve: AppMotion.readerShrink,
      reverseCurve: AppMotion.readerShrink,
    );
    // 透明度：push 后段才铺满；pop 时先整段不透明、仅末段淡出
    // （reverse 时 animation.value 从 1→0；Interval(0, hold) 令
    //   value > hold 时恒为 1，缩放中段/接近落点始终可见）
    final fade = CurvedAnimation(
      parent: animation,
      curve: const Interval(0.25, 1.0, curve: Curves.easeOut),
      reverseCurve: Interval(
        0.0,
        AppMotion.readerShrinkFadeHold,
        curve: Curves.easeIn,
      ),
    );
    // 与书架顶栏玻璃同高，保证落点对准封面中心
    final topContent = MediaQuery.paddingOf(context).top + 96 + 4;
    final isPop = animation.status == AnimationStatus.reverse ||
        animation.status == AnimationStatus.dismissed;
    final alignIndex = isPop ? 0 : pushIndex;
    final alignment = BookshelfLayout.slotAlignment(
      context,
      index: alignIndex,
      topContent: topContent,
    );
    final scale = Tween<double>(
      begin: AppMotion.readerShrinkEndScale,
      end: 1.0,
    ).animate(scaleCurve);
    return FadeTransition(
      opacity: fade,
      child: ScaleTransition(
        scale: scale,
        alignment: alignment,
        child: child,
      ),
    );
  }
}

class _InvalidReaderArgs extends StatelessWidget {
  const _InvalidReaderArgs();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('无效的书籍参数')),
    );
  }
}
