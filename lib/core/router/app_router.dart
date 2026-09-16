import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/about/presentation/pages/about_page.dart';
import '../../features/reader/presentation/pages/reader_page.dart';
import '../../features/shell/app_shell.dart';
import '../../features/shell/book_sources_page.dart';
import '../../features/shell/bookshelf/book_cover_card.dart' show kCoverRadius;
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
          final coverPath = extra['coverPath']?.toString();
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
                coverPath: coverPath,
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
/// push：从当前书槽位放大铺满（从哪来）；pop：缩回第一本（去哪）。
/// 小尺寸叠封面图：先像封面再露阅读页（pop 反向同理）。
class _ReaderShrinkTransition extends StatelessWidget {
  const _ReaderShrinkTransition({
    required this.animation,
    required this.pushIndex,
    required this.coverPath,
    required this.child,
  });

  final Animation<double> animation;

  /// push 时书架上被点开的书的下标；pop 忽略、固定落 index 0
  final int pushIndex;
  final String? coverPath;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // push/pop 分曲线：起点/落点更慢，中段仍可读
    final scaleCurve = CurvedAnimation(
      parent: animation,
      curve: AppMotion.readerShrinkPush,
      reverseCurve: AppMotion.readerShrinkPop,
    );
    // push：整页立刻可见（否则前半段扩张被透明吃掉）
    // pop：前大半不透明，末段再淡出
    final fade = CurvedAnimation(
      parent: animation,
      curve: const Interval(0.0, 0.12, curve: Curves.easeOut),
      reverseCurve: Interval(
        0.0,
        AppMotion.readerShrinkFadeHold,
        curve: Curves.easeIn,
      ),
    );
    final topContent = MediaQuery.paddingOf(context).top +
        BookshelfLayout.headerContentH +
        BookshelfLayout.contentTopGap +
        BookshelfLayout.heroBannerH +
        8;
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
        child: AnimatedBuilder(
          animation: scaleCurve,
          builder: (context, child) {
            final s = scale.value.clamp(0.05, 1.0);
            final t = scaleCurve.value;
            final visualR = kCoverRadius * (1.0 - t);
            final clipR = visualR / s;
            // 前 ~58% 纯封面扩张；之后再交叉淡到阅读页，
            // 避免 openBook 未完成时露出空白/转圈
            final coverT = ((t - 0.58) / 0.34).clamp(0.0, 1.0);
            final coverOpacity = 1.0 - Curves.easeInOutCubic.transform(coverT);
            final cover = coverPath;
            return ClipRRect(
              borderRadius: BorderRadius.circular(clipR),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  child!,
                  if (cover != null && coverOpacity > 0.005)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: coverOpacity,
                          // 与阅读页同框铺满（同一尺寸）；短交叉淡化下裁切可接受
                          child: Image.file(
                            File(cover),
                            fit: BoxFit.cover,
                            alignment: Alignment.center,
                            gaplessPlayback: true,
                            errorBuilder: (_, _, _) => const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
          child: child,
        ),
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
