import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'features/reader/presentation/pages/reader_page.dart';
import 'package:file_picker/file_picker.dart';
import 'core/database/app_database.dart';
import 'features/reader/presentation/providers/reader_provider.dart';
import 'core/ffi/book_service.dart';
import 'core/services/reader_font.dart';
import 'core/ffi/rust_bridge.dart/api.dart' as rust_api;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Rust FFI
  await BookService.init();

  // Load system font
  await _loadSystemFont();

  runApp(const ProviderScope(child: MyApp()));
}

/// Load system font for text layout
///
/// M7 字体统一：候选表取首个成功路径，同一文件喂给两侧引擎——
/// Rust ab_glyph 测量断行 + Dart FontLoader 注册 'ReaderSerif' 绘制，
/// 保证 advance 同源。Dart 注册失败仅回退默认字体（排版仍用 Rust 结果）。
Future<void> _loadSystemFont() async {
  for (final path in ReaderFont.candidatePaths) {
    try {
      await rust_api.loadFontFile(
        fontName: 'default',
        fontPath: path,
      );
    } catch (e) {
      debugPrint('✗ Failed to load font $path: $e');
      continue; // Try next font
    }

    // Rust 已加载成功：Dart 侧注册同款供绘制（失败不影响排版）
    await ReaderFont.registerFromFile(path);
    debugPrint('✓ Font loaded successfully: $path');
    return; // Success, exit
  }

  debugPrint('⚠ Warning: No system font loaded. Text layout may fail.');
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Legado Flutter',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const BookshelfPage(),
    );
  }
}

/// 书架页（跨启动持久化：书籍/进度/书签均落库，drift）
///
/// 点击书目 → 打开阅读器并自动恢复上次位置（章节 + 字符锚点）；
/// 长按 → 移出书架（连同进度与书签）。
class BookshelfPage extends ConsumerStatefulWidget {
  const BookshelfPage({Key? key}) : super(key: key);

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
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ReaderPage(
          filePath: book.filePath,
          bookName: book.title,
        ),
      ),
    );
    // 返回书架后刷新（阅读期间进度已自动保存）
    _refresh();
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
    await (ref.read(appDatabaseProvider).deleteProgress(book.filePath));
    await ref.read(appDatabaseProvider).deleteBookmarks(book.filePath);
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

  Future<void> _pickAndOpenBook(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'epub'],
      );

      if (result != null && result.files.single.path != null) {
        final filePath = result.files.single.path!;
        final fileName = result.files.single.name;

        // Extract book name (remove extension)
        final bookName = fileName.contains('.')
            ? fileName.substring(0, fileName.lastIndexOf('.'))
            : fileName;

        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ReaderPage(
              filePath: filePath,
              bookName: bookName,
            ),
          ),
        );
        _refresh();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error opening file: $e')),
        );
      }
    }
  }

  /// 书架封面：有缓存封面（EPUB 打开时落盘）则显示，否则回退图标
  Widget _coverLeading(String filePath) {
    final cover = cachedCoverFor(filePath);
    if (cover != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: Image.file(
          cover,
          width: 40,
          height: 56,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const Icon(Icons.menu_book_outlined),
        ),
      );
    }
    return const Icon(Icons.menu_book_outlined, size: 40);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Legado Flutter'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.book, size: 100, color: Colors.grey),
                      SizedBox(height: 24),
                      Text(
                        '书架为空',
                        style: TextStyle(fontSize: 20, color: Colors.grey),
                      ),
                      SizedBox(height: 16),
                      Text(
                        '点击右下角 + 导入 TXT 书籍',
                        style: TextStyle(fontSize: 14, color: Colors.grey),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  itemCount: _entries.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final (book, progress) = _entries[index];
                    return ListTile(
                      leading: _coverLeading(book.filePath),
                      title: Text(
                        book.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(_subtitle(book, progress)),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: '移出书架',
                        onPressed: () => _removeBook(book),
                      ),
                      onTap: () => _openBook(book),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _pickAndOpenBook(context),
        tooltip: 'Add Book',
        child: const Icon(Icons.add),
      ),
    );
  }
}
