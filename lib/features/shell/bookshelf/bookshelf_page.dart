import 'dart:async';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/app_database.dart';
import '../../../core/ffi/book_service.dart' show CoverStore;
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../reader/presentation/providers/reader_provider.dart'
    show appDatabaseProvider;
import '../providers/shell_settings.dart';
import 'book_cover_card.dart';

/// 书架 Tab：紧凑顶栏 + 满铺封面网格 / 列表
class BookshelfPage extends ConsumerStatefulWidget {
  const BookshelfPage({super.key});

  @override
  ConsumerState<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends ConsumerState<BookshelfPage>
    with AutomaticKeepAliveClientMixin {
  late final AppDatabase _db;
  List<(Book, ReadingProgressData?)> _entries = [];
  bool _loading = true;
  bool _shellEnteredOnce = false;
  String? _highlightPath;
  Timer? _highlightTimer;
  Timer? _justMovedTimer;
  List<String> _prevOrder = const [];
  String? _justMovedPath;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _db = ref.read(appDatabaseProvider);
    _refresh(initial: true);
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _justMovedTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool initial = false}) async {
    final books = await _db.allBooksByLastRead();
    final progress = await Future.wait(
      books.map((b) => _db.progressOf(b.filePath)),
    );
    if (!mounted) return;
    final entries = <(Book, ReadingProgressData?)>[
      for (var i = 0; i < books.length; i++) (books[i], progress[i]),
    ];
    final order = [for (final b in books) b.filePath];
    String? moved;
    if (!initial &&
        _prevOrder.isNotEmpty &&
        order.isNotEmpty &&
        order.first != _prevOrder.first) {
      moved = order.first;
    }
    setState(() {
      _entries = entries;
      _prevOrder = order;
      _justMovedPath = moved;
      if (initial) _loading = false;
    });
    if (initial) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // 只读封面文件 + sidecar，不取色
        CoverStore.preload(order);
      });
    }
  }

  Future<void> _openBook(Book book) async {
    await _db.touchLastRead(book.filePath);
    if (!mounted) return;
    await context.push('/reader', extra: {
      'filePath': book.filePath,
      'bookName': book.title,
    });
    if (!mounted) return;
    _highlightTimer?.cancel();
    setState(() => _highlightPath = book.filePath);
    _highlightTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      setState(() {
        _highlightPath = null;
        _justMovedPath = null;
      });
    });
    await _refresh();
    // 推入动画结束后清标记，避免残留导致下次无动画
    _justMovedTimer?.cancel();
    _justMovedTimer = Timer(const Duration(milliseconds: 420), () {
      if (mounted) setState(() => _justMovedPath = null);
    });
  }

  Future<void> _removeBook(Book book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('移出《${book.title}》？'),
        content: const Text('将同时删除该书进度与书签。文件本身不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _db.deleteBook(book.filePath);
    await _db.deleteProgress(book.filePath);
    await _db.deleteBookmarks(book.filePath);
    await _db.deleteNotes(book.filePath);
    _refresh();
  }

  String _subtitle(Book book, ReadingProgressData? progress) {
    final parts = <String>[];
    if (progress != null && progress.totalChapters > 0) {
      parts.add('第 ${progress.chapterIndex + 1}/${progress.totalChapters} 章');
    } else {
      parts.add('未读');
    }
    final t = book.lastReadAt ?? book.addedAt;
    parts.add('${t.year}-${_two(t.month)}-${_two(t.day)} '
        '${_two(t.hour)}:${_two(t.minute)}');
    return parts.join(' · ');
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  Future<void> _pickAndOpenBook() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'epub'],
      );
      if (files.isEmpty || files.first.path == null) return;
      final filePath = files.first.path!;
      final fileName = files.first.name;
      final bookName = fileName.contains('.')
          ? fileName.substring(0, fileName.lastIndexOf('.'))
          : fileName;
      if (!mounted) return;
      await context.push('/reader', extra: {
        'filePath': filePath,
        'bookName': bookName,
      });
      if (mounted) _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开文件失败：$e')),
        );
      }
    }
  }

  int _columnsForWidth(double width) {
    if (width < 360) return 2;
    if (width < 700) return 3;
    if (width < 1000) return 4;
    return 5;
  }

  Widget _buildHeader(BuildContext context, ShellSettings shell,
      ShellSettingsNotifier notifier, ColorScheme scheme) {
    final disableBlur = MediaQuery.disableAnimationsOf(context);
    final topPad = MediaQuery.paddingOf(context).top;

    final row = SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '书架',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.4,
                        ),
                  ),
                  if (!_loading && _entries.isNotEmpty)
                    Text(
                      '${_entries.length} 本',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                ],
              ),
            ),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: true,
                  icon: Icon(AppIcons.grid, size: 18),
                  tooltip: '网格',
                ),
                ButtonSegment(
                  value: false,
                  icon: Icon(AppIcons.list, size: 18),
                  tooltip: '列表',
                ),
              ],
              selected: {shell.bookshelfGrid},
              showSelectedIcon: false,
              onSelectionChanged: (s) => notifier.setBookshelfGrid(s.first),
            ),
          ],
        ),
      ),
    );

    if (disableBlur) {
      return Material(color: scheme.surface, child: row);
    }

    // 全宽渐变模糊（对齐系统设置参考图）：上雾重、下缘完全消散
    final h = topPad + 96;
    final fog = scheme.brightness == Brightness.light
        ? const Color(0xFFF4F5F3)
        : const Color(0xFF181B18);
    return SizedBox(
      height: h,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: AppGlass.topBlurSigma,
                sigmaY: AppGlass.topBlurSigma,
              ),
              child: const SizedBox.expand(),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    fog.withValues(alpha: 0.88),
                    fog.withValues(alpha: 0.82),
                    fog.withValues(alpha: 0.68),
                    fog.withValues(alpha: 0.45),
                    fog.withValues(alpha: 0.2),
                    fog.withValues(alpha: 0),
                  ],
                  stops: const [0, 0.25, 0.45, 0.65, 0.85, 1],
                ),
              ),
            ),
            Align(
              alignment: Alignment.topCenter,
              child: row,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final shell = ref.watch(shellSettingsProvider);
    final shellNotifier = ref.read(shellSettingsProvider.notifier);
    final width = MediaQuery.sizeOf(context).width;
    // 悬浮底栏高度约 64 + 边距；内容可滚入其下，末尾略留空避免贴死
    final bottomPad = MediaQuery.paddingOf(context).bottom + 96;
    final scheme = Theme.of(context).colorScheme;
    final topPad = MediaQuery.paddingOf(context).top;
    // 与全宽渐变模糊条同高：topPad + 96
    final topGlass = topPad + 96;

    late final Widget content;
    if (_loading) {
      content = const Center(child: CircularProgressIndicator());
    } else if (_entries.isEmpty) {
      content = _EmptyShelf(onImport: _pickAndOpenBook);
    } else if (shell.bookshelfGrid) {
      content = GridView.builder(
        key: const ValueKey('grid'),
        padding: EdgeInsets.fromLTRB(12, topGlass + 4, 12, bottomPad),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _columnsForWidth(width),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.68,
        ),
        itemCount: _entries.length,
        itemBuilder: (context, index) {
          final (book, progress) = _entries[index];
          final highlighted = _highlightPath == book.filePath;
          final moved = _justMovedPath == book.filePath;
          Widget card = BookCoverCard(
            key: ValueKey(book.filePath),
            book: book,
            progress: progress,
            staggerIndex: index,
            animateEnter: !_shellEnteredOnce,
            highlighted: highlighted,
            onTap: () => _openBook(book),
            onLongPress: () => _removeBook(book),
          );
          if (moved) {
            // 最近阅读插到首位：从下方推入
            card = TweenAnimationBuilder<double>(
              key: ValueKey('move-${book.filePath}'),
              tween: Tween(begin: 1, end: 0),
              duration: const Duration(milliseconds: 360),
              curve: Curves.easeOutCubic,
              builder: (context, t, child) {
                return Transform.translate(
                  offset: Offset(0, 28 * t),
                  child: Opacity(
                    opacity: 1 - t * 0.35,
                    child: child,
                  ),
                );
              },
              child: card,
            );
          }
          return card;
        },
      );
      if (!_shellEnteredOnce) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _shellEnteredOnce = true);
        });
      }
    } else {
      content = ListView.separated(
        key: const ValueKey('list'),
        padding: EdgeInsets.fromLTRB(0, topGlass + 4, 0, bottomPad),
        itemCount: _entries.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
        itemBuilder: (context, index) {
          final (book, progress) = _entries[index];
          return BookListTile(
            key: ValueKey(book.filePath),
            book: book,
            subtitle: _subtitle(book, progress),
            onTap: () => _openBook(book),
            onRemove: () => _removeBook(book),
          );
        },
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 88),
        child: _SpringImportFab(onPressed: _pickAndOpenBook),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0, 0.04),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: content,
            ),
          ),
          // 顶栏渐变毛玻璃叠在内容上，滚动时封面从下穿入
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _buildHeader(context, shell, shellNotifier, scheme),
          ),
        ],
      ),
    );
  }
}

class _EmptyShelf extends StatelessWidget {
  const _EmptyShelf({required this.onImport});

  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 120, 32, 100),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Icon(
                AppIcons.emptyBook,
                size: 42,
                color: scheme.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '书架是空的',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '从文件导入 TXT 或 EPUB，开始阅读',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onImport,
              icon: const Icon(AppIcons.importFile),
              label: const Text('导入书籍'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 弹簧 FAB：按下缩放回弹 + 阴影随压感变化
class _SpringImportFab extends StatefulWidget {
  const _SpringImportFab({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_SpringImportFab> createState() => _SpringImportFabState();
}

class _SpringImportFabState extends State<_SpringImportFab>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onPressed();
      },
      child: AnimatedScale(
        scale: _pressed ? 0.88 : 1.0,
        duration: Duration(milliseconds: _pressed ? 90 : 220),
        curve: _pressed ? Curves.easeOut : AppMotion.springOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withValues(
                  alpha: _pressed ? 0.15 : 0.28,
                ),
                blurRadius: _pressed ? 6 : 14,
                offset: Offset(0, _pressed ? 2 : 6),
              ),
            ],
          ),
          child: Icon(
            AppIcons.add,
            color: scheme.onPrimaryContainer,
            size: 28,
          ),
        ),
      ),
    );
  }
}
