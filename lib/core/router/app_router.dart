import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/about/presentation/pages/about_page.dart';
import '../../features/reader/presentation/pages/reader_page.dart';
import '../../features/shell/app_shell.dart';
import '../../features/shell/book_sources_page.dart';
import '../../features/shell/bookshelf/bookshelf_page.dart';
import '../../features/shell/settings_page.dart';

/// 路由表：Shell 三 Tab + 全屏阅读/关于
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/bookshelf',
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: '/bookshelf',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: BookshelfPage()),
          ),
          GoRoute(
            path: '/sources',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: BookSourcesPage()),
          ),
          GoRoute(
            path: '/settings',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: SettingsPage()),
          ),
        ],
      ),
      GoRoute(
        path: '/reader',
        builder: (context, state) {
          final extra = state.extra as Map<String, String>;
          return ReaderPage(
            filePath: extra['filePath']!,
            bookName: extra['bookName'] ?? '',
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
