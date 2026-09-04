import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'features/reader/presentation/pages/reader_page.dart';
import 'package:file_picker/file_picker.dart';
import 'core/database/app_database.dart';
import 'core/database/app_settings_service.dart';
import 'features/reader/presentation/providers/reader_provider.dart';
import 'features/reader/presentation/providers/reader_settings.dart';
import 'core/ffi/book_service.dart';
import 'core/services/reader_font.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Rust FFI（FontManager 内部自动 load_embedded_default，
  // 即从 rust/assets/NotoSansSC-Regular.otf 读字节注册为
  // 'embedded_default' 默认字体；内置 Noto Sans CJK SC，跨平台一致）
  await BookService.init();

  // 把同一份 Noto Sans CJK SC 注册到 Dart 端 FontLoader（从
  // assets/fonts/ 读），双引擎用同源字体 → 满足 M7 测量 / 绘制同源约束
  await ReaderFont.initialize();

  // P1 设置持久化（2026-09-04）：启动预加载设置快照——
  // 单行 KV 查询 <10ms；ReaderNotifier 同步构造即用内存快照。
  // db 实例经 ProviderScope override 注入，全局单例（避免多连接）。
  final db = AppDatabase();
  await AppSettingsService.instance.load(db);
  final settings = ReaderSettings.tryParse(
      AppSettingsService.instance.raw('reader'));

  // 段落格式同步 Rust 全局——必须先于任何 openBook 排版（openBook 在
  // 首帧 postFrame 之后，此处天然安全），杜绝 M9.2 类「Rust 已按默认
  // 排版、Dart 却持旧值」的启动错位。失败不阻塞启动（后续 apply 再同步）。
  try {
    await BookService().setParagraphFormatSettings(
      enableIndent: settings.enableIndent,
      indentSizeChars: settings.indentSizeChars,
      paragraphSpacingMultiplier: settings.paragraphSpacingMultiplier,
      reParagraphMode: settings.reParagraphMode,
      smartSplitThreshold: settings.smartSplitThreshold,
      aggressiveSplitThreshold: settings.aggressiveSplitThreshold,
      justify: settings.justify,
    );
  } catch (_) {}

  runApp(ProviderScope(
    overrides: [appDatabaseProvider.overrideWithValue(db)],
    child: const MyApp(),
  ));
}

/// 旧版 _loadSystemFont + ReaderFont.candidatePaths 已删除。
/// 见 docs/bugfixes/2026-08-29_字体架构重写_用户可选.md
/// 改用：
/// - Rust:  FontManager::new_with_embedded_default() 启动自动加载内置字体
/// - Dart:  ReaderFont.initialize() 读 assets/fonts/ 注册 'ReaderSerif'
/// - 用户:  FontProvider.pickAndLoadCustomFont() 选 .ttf/.otf/.ttc 注入两侧

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
      // file_picker 12.x: FilePicker.pickFiles() 直接调用（不再走 .platform），
      // 返回 List<PlatformFile>（空列表 = 用户取消）
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'epub'],
      );

      if (files.isNotEmpty && files.first.path != null) {
        final filePath = files.first.path!;
        final fileName = files.first.name;

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
