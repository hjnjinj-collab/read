import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/models/simple_models.dart';
import '../../../../core/ffi/book_service.dart';
import '../services/book_image_store.dart';

/// 全局数据库实例（drift，进程内单例）
final appDatabaseProvider = Provider<AppDatabase>((ref) => AppDatabase());

class ReaderNotifier extends Notifier<ReadingState> {
  late final BookService _bookService;
  late final AppDatabase _db;

  @override
  ReadingState build() {
    _bookService = ref.read(bookServiceProvider);
    _db = ref.read(appDatabaseProvider);
    return const ReadingState();
  }

  // Screen dimensions for layout
  double _screenWidth = 360.0;
  double _screenHeight = 640.0;

  // Reading settings
  double _fontSize = 18.0;
  double _lineHeight = 1.5;
  double _paddingHorizontal = 20.0;
  double _paddingVertical = 20.0;

  // Content processing settings
  bool _removeDuplicateTitle = true;
  bool _reSegment = false;
  ChineseConvertType _chineseConvert = ChineseConvertType.none;
  List<ReplaceRuleItem> _replaceRules = [];

  // Content cleaning settings
  bool _removeHtmlTags = true;
  bool _removeAds = true;
  bool _smartParagraph = true;

  /// 当前书是否为 EPUB（结构化路径分流标记）
  bool _isEpub = false;

  // 只读访问器：供设置对话框回读当前生效的配置
  bool get removeDuplicateTitle => _removeDuplicateTitle;
  bool get reSegment => _reSegment;
  ChineseConvertType get chineseConvert => _chineseConvert;
  List<ReplaceRuleItem> get replaceRules => List.unmodifiable(_replaceRules);
  bool get removeHtmlTags => _removeHtmlTags;
  bool get removeAds => _removeAds;
  bool get smartParagraph => _smartParagraph;

  void setScreenSize(double width, double height) {
    _screenWidth = width;
    _screenHeight = height;
  }

  /// 窗口尺寸变化：更新布局参数并带锚点重排当前页
  ///
  /// 分页缓存键含排版配置，新旧尺寸的页互不污染；锚点保证
  /// resize 后停留在原阅读位置（图片项不消耗锚点）。
  Future<void> onWindowResized(double width, double height) async {
    if (width == _screenWidth && height == _screenHeight) return;
    _screenWidth = width;
    _screenHeight = height;
    if (state.bookId == null || state.isLoading) return;
    await _loadCurrentPage(
      anchorCharOffset: state.currentPage?.startCharIndex,
    );
  }

  void setFontSize(double fontSize) {
    _fontSize = fontSize;
    // Reload current page with new settings
    if (state.bookId != null) {
      _loadCurrentPage();
    }
  }

  /// 应用内容处理设置（对话框「应用设置」唯一入口）
  ///
  /// 统一处理净化选项与阅读级选项：更新 parser 净化器、失效缓存后
  /// 仅触发一次带锚点的页面重载，避免双重加载竞态。
  Future<void> applyContentProcessingSettings({
    required bool removeDuplicateTitle,
    required bool reSegment,
    required ChineseConvertType chineseConvert,
    required List<ReplaceRuleItem> replaceRules,
    required bool removeHtmlTags,
    required bool removeAds,
    required bool smartParagraph,
  }) async {
    _removeDuplicateTitle = removeDuplicateTitle;
    _reSegment = reSegment;
    _chineseConvert = chineseConvert;
    _replaceRules = replaceRules;
    _removeHtmlTags = removeHtmlTags;
    _removeAds = removeAds;
    _smartParagraph = smartParagraph;

    if (state.bookId == null) return;

    // EPUB：净化选项不作用于结构化路径（去广告在 JS 提取层恒开），
    // 仅重载页面（字号等排版参数经缓存键隔离自然生效）
    if (_isEpub) {
      await _loadCurrentPage(
        anchorCharOffset: state.currentPage?.startCharIndex,
      );
      return;
    }

    // 更新 parser 净化器并失效相关缓存（含全局选项同步）
    await _bookService.updateBookCleaning(
      state.bookId!,
      removeHtmlTags: removeHtmlTags,
      removeAds: removeAds,
      smartParagraph: smartParagraph,
      traditionalized: chineseConvert == ChineseConvertType.s2t,
      simplified: chineseConvert == ChineseConvertType.t2s,
    );

    // 单次重载：简繁/规则经 options_hash 隔离缓存自然重算，锚点保持进度
    await _loadCurrentPage(
      anchorCharOffset: state.currentPage?.startCharIndex,
    );
  }

  /// Open a book file
  Future<void> openBook(String filePath, String bookName) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      // 构建导入级净化选项（结构净化在导入时一次完成，
      // 章节识别在净化后文本上执行）
      final cleaningOptions = _bookService.buildCleaningOptions(
        removeHtmlTags: _removeHtmlTags,
        removeAds: _removeAds,
        smartParagraph: _smartParagraph,
        traditionalized: _chineseConvert == ChineseConvertType.s2t,
        simplified: _chineseConvert == ChineseConvertType.t2s,
      );

      // Parse book（异步：不阻塞 UI 线程）
      final bookId = await _bookService.parseTxtFileAsync(
        filePath,
        bookName,
        cleaningOptions: cleaningOptions,
      );
      final title = await _bookService.getBookTitle(bookId);
      final chapters = await _bookService.getChapters(bookId);

      // 格式分流：EPUB 走结构化分页，TXT 走旧文本路径
      final format = await _bookService.getBookFormat(bookId);
      _isEpub = format == 'epub';
      if (_isEpub) {
        BookImageStore.instance.bind(_bookService, bookId);
        // 封面落盘供书架显示（异步，不阻塞打开）
        unawaited(persistBookCover(_bookService, bookId, filePath));
      }

      state = state.copyWith(
        bookId: bookId,
        filePath: filePath,
        bookTitle: title,
        chapters: chapters,
        currentChapterIndex: 0,
        currentPageIndex: 0,
        isLoading: false,
      );

      // 书架登记
      await _db.upsertBook(filePath, title);

      // 跨启动进度恢复（债#2/#3）：章节 + 字符锚点精确定位；
      // 锚点机制同时覆盖「改字号/净化配置后位置漂移」的迁移场景。
      // 无进度或索引失效时自然落到第 1 章第 1 页。
      final saved = await _db.progressOf(filePath);
      if (saved != null &&
          saved.chapterIndex > 0 &&
          saved.chapterIndex < chapters.length) {
        state = state.copyWith(currentChapterIndex: saved.chapterIndex);
        await _loadCurrentPage(anchorCharOffset: saved.charOffset);
      } else {
        await _loadCurrentPage();
      }
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  /// Load current page
  /// 加载当前页
  ///
  /// [anchorCharOffset] 进度锚点：设置变更后用章内字符偏移重新定位，
  /// 返回页的 pageIndex 会同步回状态，保证停留在原阅读位置。
  Future<void> _loadCurrentPage({int? anchorCharOffset}) async {
    if (state.bookId == null) return;

    try {
      // 分流：EPUB 结构化分页 / TXT 文本分页
      final PageInfo page;
      if (_isEpub) {
        page = await _bookService.getPageStructured(
          state.bookId!,
          state.currentChapterIndex,
          state.currentPageIndex,
          width: _screenWidth,
          height: _screenHeight,
          fontSize: _fontSize,
          lineHeightMultiplier: _lineHeight,
          paddingLeft: _paddingHorizontal,
          paddingTop: _paddingVertical,
          paddingRight: _paddingHorizontal,
          paddingBottom: _paddingVertical,
          anchorCharOffset: anchorCharOffset,
        );
      } else {
        // 转换简繁设置为数字代码
        int chineseConvertCode = _chineseConvert == ChineseConvertType.s2t ? 1
            : _chineseConvert == ChineseConvertType.t2s ? 2
            : 0;

        // 使用带预处理的 API
        page = await _bookService.getPageProcessed(
          state.bookId!,
          state.currentChapterIndex,
          state.currentPageIndex,
          width: _screenWidth,
          height: _screenHeight,
          fontSize: _fontSize,
          lineHeightMultiplier: _lineHeight,
          paddingLeft: _paddingHorizontal,
          paddingTop: _paddingVertical,
          paddingRight: _paddingHorizontal,
          paddingBottom: _paddingVertical,
          removeDuplicateTitle: _removeDuplicateTitle,
          reSegment: _reSegment,
          chineseConvert: chineseConvertCode,
          replaceRules: _replaceRules,
          anchorCharOffset: anchorCharOffset,
        );
      }

      // 锚点定位后页码可能与请求不同：同步回状态
      state = state.copyWith(
        currentPage: page,
        currentPageIndex: page.pageIndex,
      );

      // 进度自动保存（债#3）：每次成功加载页面即落库。
      // charOffset 为章内锚点，恢复时经 locate_page_for_offset 精确定位；
      // 本地 sqlite 写入微秒级，无需节流；失败静默（不阻塞阅读）。
      final filePath = state.filePath;
      if (filePath != null) {
        try {
          await _db.saveProgress(
            bookPath: filePath,
            chapterIndex: state.currentChapterIndex,
            charOffset: page.startCharIndex,
            totalChapters: state.chapters.length,
          );
          await _db.touchLastRead(filePath);
        } catch (_) {
          // 进度保存失败不影响阅读
        }
      }
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  // ===== 书签 =====

  /// 在当前位置添加书签（摘录当前页首行便于辨识）
  Future<void> addBookmark() async {
    final filePath = state.filePath;
    final page = state.currentPage;
    if (filePath == null || page == null) return;

    String preview = '';
    for (final line in page.lines) {
      final t = line.text.trim();
      if (t.isNotEmpty) {
        preview = t;
        break;
      }
    }
    if (preview.isEmpty && page.entries.isNotEmpty) {
      preview = '（图片页）';
    }
    if (preview.isEmpty) preview = '（空白页）';
    if (preview.length > 50) preview = preview.substring(0, 50);

    try {
      await _db.addBookmark(
        bookPath: filePath,
        chapterIndex: state.currentChapterIndex,
        charOffset: page.startCharIndex,
        preview: preview,
      );
    } catch (_) {
      // 静默：书签失败不阻塞阅读
    }
  }

  /// 当前书的书签列表（新→旧）
  Future<List<Bookmark>> bookmarksForCurrentBook() async {
    final filePath = state.filePath;
    if (filePath == null) return const [];
    return _db.bookmarksOf(filePath);
  }

  Future<void> deleteBookmark(int id) => _db.deleteBookmark(id);

  /// 跳转到书签位置（章节 + 字符锚点，与进度恢复同一机制）
  Future<void> jumpToBookmark(Bookmark bookmark) async {
    if (bookmark.chapterIndex >= state.chapters.length) return;
    state = state.copyWith(
      currentChapterIndex: bookmark.chapterIndex,
      currentPageIndex: 0,
    );
    await _loadCurrentPage(anchorCharOffset: bookmark.charOffset);
  }

  /// 章节页数（按格式分流；供翻页边界判定）
  Future<int> _pageCountOf(int chapterIndex) async {
    final common = (
      width: _screenWidth,
      height: _screenHeight,
      fontSize: _fontSize,
      lineHeight: _lineHeight,
      padH: _paddingHorizontal,
      padV: _paddingVertical,
    );
    if (_isEpub) {
      return _bookService.getPageCountStructured(
        state.bookId!,
        chapterIndex,
        width: common.width,
        height: common.height,
        fontSize: common.fontSize,
        lineHeightMultiplier: common.lineHeight,
        paddingLeft: common.padH,
        paddingTop: common.padV,
        paddingRight: common.padH,
        paddingBottom: common.padV,
      );
    }
    int chineseConvertCode = _chineseConvert == ChineseConvertType.s2t ? 1
        : _chineseConvert == ChineseConvertType.t2s ? 2
        : 0;
    return _bookService.getPageCountProcessed(
      state.bookId!,
      chapterIndex,
      width: common.width,
      height: common.height,
      fontSize: common.fontSize,
      lineHeightMultiplier: common.lineHeight,
      paddingLeft: common.padH,
      paddingTop: common.padV,
      paddingRight: common.padH,
      paddingBottom: common.padV,
      removeDuplicateTitle: _removeDuplicateTitle,
      reSegment: _reSegment,
      chineseConvert: chineseConvertCode,
      replaceRules: _replaceRules,
    );
  }

  /// Go to next page
  Future<void> nextPage() async {
    if (state.bookId == null) return;

    try {
      final pageCount = await _pageCountOf(state.currentChapterIndex);

      if (state.currentPageIndex < pageCount - 1) {
        // Next page in current chapter
        state = state.copyWith(currentPageIndex: state.currentPageIndex + 1);
        await _loadCurrentPage();
      } else if (state.currentChapterIndex < state.chapters.length - 1) {
        // Next chapter
        state = state.copyWith(
          currentChapterIndex: state.currentChapterIndex + 1,
          currentPageIndex: 0,
        );
        await _loadCurrentPage();
      }
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  /// Go to previous page
  Future<void> previousPage() async {
    if (state.bookId == null) return;

    if (state.currentPageIndex > 0) {
      // Previous page in current chapter
      state = state.copyWith(currentPageIndex: state.currentPageIndex - 1);
      await _loadCurrentPage();
    } else if (state.currentChapterIndex > 0) {
      // Previous chapter, last page
      try {
        final prevChapterIndex = state.currentChapterIndex - 1;
        final pageCount = await _pageCountOf(prevChapterIndex);

        state = state.copyWith(
          currentChapterIndex: prevChapterIndex,
          currentPageIndex: pageCount - 1,
        );
        await _loadCurrentPage();
      } catch (e) {
        state = state.copyWith(error: e.toString());
      }
    }
  }

  /// Jump to specific chapter and page
  Future<void> jumpTo(int chapterIndex, int pageIndex) async {
    if (state.bookId == null) return;
    if (chapterIndex < 0 || chapterIndex >= state.chapters.length) return;

    state = state.copyWith(
      currentChapterIndex: chapterIndex,
      currentPageIndex: pageIndex,
    );
    await _loadCurrentPage();
  }

  /// Close current book
  Future<void> closeBook() async {
    if (state.bookId != null) {
      await _bookService.releaseBook(state.bookId!);
    }
    BookImageStore.instance.clear();
    state = const ReadingState();
  }
}

// Provider
final bookServiceProvider = Provider((ref) => BookService());

final readerProvider = NotifierProvider<ReaderNotifier, ReadingState>(() {
  return ReaderNotifier();
});
