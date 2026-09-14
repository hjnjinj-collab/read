import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/app_database.dart';
import '../../../core/theme/app_icons.dart';
import '../../reader/presentation/providers/reader_provider.dart'
    show appDatabaseProvider;
import '../providers/shell_settings.dart';
import 'book_cover_card.dart';

/// 书架 Tab：岛屿网格 / 列表，导入本地 TXT/EPUB
class BookshelfPage extends ConsumerStatefulWidget {
  const BookshelfPage({super.key});

  @override
  ConsumerState<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends ConsumerState<BookshelfPage> {
  late final AppDatabase _db;
  List<(Book, ReadingProgressData?)> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _db = ref.read(appDatabaseProvider);
    _refresh();
  }

  Future<void> _refresh() async {
    final books = await _db.allBooksByLastRead();
    final entries = <(Book, ReadingProgressData?)>[];
    for (final b in books) {
      entries.add((b, await _db.progressOf(b.filePath)));
    }
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _openBook(Book book) async {
    await context.push('/reader', extra: {
      'filePath': book.filePath,
      'bookName': book.title,
    });
    if (mounted) _refresh();
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
          TextButton(
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
    if (width < 600) return 2;
    if (width < 900) return 3;
    return 4;
  }

  @override
  Widget build(BuildContext context) {
    final shell = ref.watch(shellSettingsProvider);
    final shellNotifier = ref.read(shellSettingsProvider.notifier);
    final width = MediaQuery.sizeOf(context).width;
    final bottomPad = MediaQuery.paddingOf(context).bottom + 88;

    return Scaffold(
      backgroundColor: Colors.transparent,
      // 外层壳 extendBody：内层 FAB 不会自动避开毛玻璃底栏，手动抬高 68
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 68),
        child: FloatingActionButton(
          onPressed: _pickAndOpenBook,
          tooltip: '导入书籍',
          child: const Icon(AppIcons.add),
        ),
      ),
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: const Text('书架'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: SegmentedButton<bool>(
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
                  onSelectionChanged: (s) =>
                      shellNotifier.setBookshelfGrid(s.first),
                ),
              ),
            ],
          ),
          if (_loading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_entries.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyShelf(onImport: _pickAndOpenBook),
            )
          else if (shell.bookshelfGrid)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(12, 4, 12, bottomPad),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: _columnsForWidth(width),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.58,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final (book, progress) = _entries[index];
                    return BookCoverCard(
                      book: book,
                      progress: progress,
                      onTap: () => _openBook(book),
                      onLongPress: () => _removeBook(book),
                    );
                  },
                  childCount: _entries.length,
                ),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.only(bottom: bottomPad),
              sliver: SliverList.separated(
                itemCount: _entries.length,
                separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                itemBuilder: (context, index) {
                  final (book, progress) = _entries[index];
                  return BookListTile(
                    book: book,
                    subtitle: _subtitle(book, progress),
                    onTap: () => _openBook(book),
                    onRemove: () => _removeBook(book),
                  );
                },
              ),
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
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 120),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(28),
              ),
              child: Icon(
                AppIcons.emptyBook,
                size: 48,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              '书架是空的',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
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
