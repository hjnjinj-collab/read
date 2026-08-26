import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/models/simple_models.dart';
import '../../../../core/ffi/book_service.dart';
import '../services/book_image_store.dart';
import 'reader_render_state.dart';

/// 全局数据库实例（drift，进程内单例）
final appDatabaseProvider = Provider<AppDatabase>((ref) => AppDatabase());

class ReaderNotifier extends Notifier<ReadingState> {
  late final BookService _bookService;
  late final AppDatabase _db;
  late final ReaderRenderStateStore _renderStore;

  @override
  ReadingState build() {
    _bookService = ref.read(bookServiceProvider);
    _db = ref.read(appDatabaseProvider);
    _renderStore = ref.read(readerRenderStoreProvider);
    // M9.2：构造期即按默认值计算段落格式哈希，与 Rust 全局默认
    // （Smart+缩进开）对齐——消除"Rust 已按默认排版、Dart 却挂
    // hash=0 缓存键"的启动错位（设置无持久化，重启两侧同回默认）
    _paraFormatHash = _computeParaFormatHash();
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
  double _pageFillThreshold = 0.9;

  // Content processing settings
  bool _removeDuplicateTitle = true;
  ChineseConvertType _chineseConvert = ChineseConvertType.none;
  List<ReplaceRuleItem> _replaceRules = [];

  // Content cleaning settings
  bool _removeHtmlTags = true;
  bool _removeAds = true;

  // M9.3 清理说明：旧「智能重新分段」开关（_reSegment）已被 M9
  // ParagraphFormatter 取代，UI 移除、FFI 恒传 false；
  // 净化层「智能分段」（smart_paragraph）为导入/净化内部行为，
  // 恒用默认开启值，不再暴露设置项。

  // 字形样式开关（EPUB 行内粗斜体；TXT 章节标题加粗）。
  // 纯绘制期过滤：不进任何缓存键，切换零缓存失效
  bool _boldEnabled = true;
  bool _italicEnabled = true;

  // 本章说/注释显示开关（切换影响分页缓存键）
  bool _showComments = true;

  // M9-P4：段落格式设置（首行缩进/段间距/重新分段）
  bool _enableIndent = true;
  int _indentSizeChars = 2;
  double _paragraphSpacingMultiplier = 1.0;
  int _reParagraphMode = 1; // 0=不处理 1=智能分段 2=强制重排
  // M9.2：超长段切分阈值（字，用户可调；Rust 侧钳制 [20,2000]）
  int _smartSplitThreshold = 200;
  int _aggressiveSplitThreshold = 100;
  BigInt _paraFormatHash = BigInt.zero; // 段落格式设置哈希（FFI 缓存键）

  // M8-P4：章节页数内存缓存（消除翻页双 FFI）
  // key = 排版参数指纹，value = 该章总页数
  final Map<String, int> _chapterPageCounts = {};

  /// 当前书是否为 EPUB（结构化路径分流标记）
  bool _isEpub = false;

  // 只读访问器：供设置对话框回读当前生效的配置
  bool get removeDuplicateTitle => _removeDuplicateTitle;
  ChineseConvertType get chineseConvert => _chineseConvert;
  List<ReplaceRuleItem> get replaceRules => List.unmodifiable(_replaceRules);
  bool get removeHtmlTags => _removeHtmlTags;
  bool get removeAds => _removeAds;
  bool get boldEnabled => _boldEnabled;
  bool get italicEnabled => _italicEnabled;
  bool get showComments => _showComments;
  bool get enableIndent => _enableIndent;
  int get indentSizeChars => _indentSizeChars;
  double get paragraphSpacingMultiplier => _paragraphSpacingMultiplier;
  int get reParagraphMode => _reParagraphMode;
  int get smartSplitThreshold => _smartSplitThreshold;
  int get aggressiveSplitThreshold => _aggressiveSplitThreshold;

  /// 当前排版基准（M7：绘制端与 Rust 排版同源，替换 painter 硬编码 18/1.5）
  double get fontSize => _fontSize;
  double get lineHeight => _lineHeight;
  double get pageFillThreshold => _pageFillThreshold;

  /// 当前书是否按 EPUB 结构化路径渲染
  bool get renderAsEpub => _isEpub;

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
    _invalidatePageCountCache(); // M8-P4：窗口尺寸变更清页数缓存
    if (state.bookId == null || state.isLoading) return;
    await _loadCurrentPage(
      anchorCharOffset: state.currentPage?.startCharIndex,
    );
  }

  void setFontSize(double fontSize) {
    _fontSize = fontSize;
    _invalidatePageCountCache(); // M8-P4：排版参数变更清页数缓存
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
    required ChineseConvertType chineseConvert,
    required List<ReplaceRuleItem> replaceRules,
    required bool removeHtmlTags,
    required bool removeAds,
    required bool boldEnabled,
    required bool italicEnabled,
    required double pageFillThreshold,
    required bool showComments,
    required bool enableIndent,
    required int indentSizeChars,
    required double paragraphSpacingMultiplier,
    required int reParagraphMode,
    required int smartSplitThreshold,
    required int aggressiveSplitThreshold,
  }) async {
    _removeDuplicateTitle = removeDuplicateTitle;
    _chineseConvert = chineseConvert;
    _replaceRules = replaceRules;
    _removeHtmlTags = removeHtmlTags;
    _removeAds = removeAds;
    _boldEnabled = boldEnabled;
    _italicEnabled = italicEnabled;
    _pageFillThreshold = pageFillThreshold;
    _showComments = showComments;

    // M9-P4：段落格式设置——同步 Rust 全局设置并计算缓存键哈希
    _enableIndent = enableIndent;
    _indentSizeChars = indentSizeChars;
    _paragraphSpacingMultiplier = paragraphSpacingMultiplier;
    _reParagraphMode = reParagraphMode;
    _smartSplitThreshold = smartSplitThreshold;
    _aggressiveSplitThreshold = aggressiveSplitThreshold;
    await _bookService.setParagraphFormatSettings(
      enableIndent: enableIndent,
      indentSizeChars: indentSizeChars,
      paragraphSpacingMultiplier: paragraphSpacingMultiplier,
      reParagraphMode: reParagraphMode,
      smartSplitThreshold: smartSplitThreshold,
      aggressiveSplitThreshold: aggressiveSplitThreshold,
    );
    _paraFormatHash = _computeParaFormatHash();

    _invalidatePageCountCache(); // M8-P4：排版参数变更清页数缓存

    if (state.bookId == null) return;

    // EPUB：净化选项经 getPageStructured 的 chineseConvert 参数随调用
    // 下发（缓存键含转换位，切换即换键重算）；去广告在 JS 提取层恒开，
    // 不调 updateBookCleaning（无导入级净化缓存）
    if (_isEpub) {
      await _loadCurrentPage(
        anchorCharOffset: state.currentPage?.startCharIndex,
      );
      return;
    }

    // 更新 parser 净化器并失效相关缓存（含全局选项同步）；
    // 智能分段为净化层内部行为恒开（M9.3 起不暴露设置项）
    await _bookService.updateBookCleaning(
      state.bookId!,
      removeHtmlTags: removeHtmlTags,
      removeAds: removeAds,
      smartParagraph: true,
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
    // P1：发布 loading 状态到 render store
    _renderStore.publishStructure(isLoading: true, message: '正在打开书籍…');

    try {
      // 构建导入级净化选项（结构净化在导入时一次完成，
      // 章节识别在净化后文本上执行）
      final cleaningOptions = _bookService.buildCleaningOptions(
        removeHtmlTags: _removeHtmlTags,
        removeAds: _removeAds,
        smartParagraph: true, // 净化层智能分段恒开（M9.3 起不暴露设置项）
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
        // 简繁编码与 TXT 同口径（0=无 1=简→繁 2=繁→简）
        int chineseConvertCode = _chineseConvert == ChineseConvertType.s2t ? 1
            : _chineseConvert == ChineseConvertType.t2s ? 2
            : 0;
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
          chineseConvert: chineseConvertCode,
          pageFillThreshold: _pageFillThreshold,
          showComments: _showComments,
          paraFormatHash: _paraFormatHash,
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
          reSegment: false, // M9.3：旧重排已被 ParagraphFormatter 取代，恒关
          chineseConvert: chineseConvertCode,
          replaceRules: _replaceRules,
          anchorCharOffset: anchorCharOffset,
          pageFillThreshold: _pageFillThreshold,
          paraFormatHash: _paraFormatHash,
        );
      }

      // 锚点定位后页码可能与请求不同：同步回状态
      state = state.copyWith(
        currentPage: page,
        currentPageIndex: page.pageIndex,
      );

      // P1 接线层：发布三页结构态到 render store（fire-and-forget，
      // 当前页已就绪可渲染，邻居页加载不阻塞 UI）
      _publishRenderStructureAsync(page);

      // EPUB 翻章预取（M6）：当前章已渲染，后台预计算下一章分页入缓存，
      // 翻章零延迟。fire-and-forget：失败/被前台让路均静默不影响阅读
      _prefetchNextChapterEpub();

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

  /// P1 接线层：异步加载邻居页并发布三页结构态到 render store
  ///
  /// 当前页已在 state 中，这里并行加载 prev/next 页后一次性发布。
  /// 失败静默（邻居页缺失不影响当前页渲染）。
  Future<void> _publishRenderStructureAsync(PageInfo currentPage) async {
    try {
      final chapterIndex = state.currentChapterIndex;
      final pageIndex = state.currentPageIndex;

      // 并行加载前后页
      final results = await Future.wait([
        _loadNeighborPage(chapterIndex, pageIndex - 1), // prev
        _loadNeighborPage(chapterIndex, pageIndex + 1), // next
      ]);

      _renderStore.publishStructure(
        previousPage: results[0],
        currentPage: currentPage,
        nextPage: results[1],
        durPageIndex: pageIndex,
      );
    } catch (_) {
      // 邻居页加载失败，仅发布当前页
      _renderStore.publishStructure(
        currentPage: currentPage,
        durPageIndex: state.currentPageIndex,
      );
    }
  }

  /// 安全加载相邻页：越界或异常返回 null
  Future<PageInfo?> _loadNeighborPage(
    int chapterIndex,
    int pageIndex,
  ) async {
    try {
      if (pageIndex < 0) {
        // 跨章到上一章末页
        if (chapterIndex <= 0) return null;
        final prevChapter = chapterIndex - 1;
        final count = await _pageCountOf(prevChapter);
        if (count <= 0) return null;
        return await _loadSinglePage(prevChapter, count - 1);
      }

      final count = await _pageCountOf(chapterIndex);
      if (pageIndex >= count) {
        // 跨章到下一章首页
        if (chapterIndex >= state.chapters.length - 1) return null;
        return await _loadSinglePage(chapterIndex + 1, 0);
      }

      return await _loadSinglePage(chapterIndex, pageIndex);
    } catch (_) {
      return null;
    }
  }

  /// 加载单页（复用 _loadCurrentPage 的参数管线，但不修改 state）
  Future<PageInfo> _loadSinglePage(int chapterIndex, int pageIndex) async {
    if (_isEpub) {
      int chineseConvertCode = _chineseConvert == ChineseConvertType.s2t ? 1
          : _chineseConvert == ChineseConvertType.t2s ? 2
          : 0;
      return _bookService.getPageStructured(
        state.bookId!,
        chapterIndex,
        pageIndex,
        width: _screenWidth,
        height: _screenHeight,
        fontSize: _fontSize,
        lineHeightMultiplier: _lineHeight,
        paddingLeft: _paddingHorizontal,
        paddingTop: _paddingVertical,
        paddingRight: _paddingHorizontal,
        paddingBottom: _paddingVertical,
        chineseConvert: chineseConvertCode,
        pageFillThreshold: _pageFillThreshold,
        showComments: _showComments,
        paraFormatHash: _paraFormatHash,
      );
    } else {
      int chineseConvertCode = _chineseConvert == ChineseConvertType.s2t ? 1
          : _chineseConvert == ChineseConvertType.t2s ? 2
          : 0;
      return _bookService.getPageProcessed(
        state.bookId!,
        chapterIndex,
        pageIndex,
        width: _screenWidth,
        height: _screenHeight,
        fontSize: _fontSize,
        lineHeightMultiplier: _lineHeight,
        paddingLeft: _paddingHorizontal,
        paddingTop: _paddingVertical,
        paddingRight: _paddingHorizontal,
        paddingBottom: _paddingVertical,
        removeDuplicateTitle: _removeDuplicateTitle,
        reSegment: false,
        chineseConvert: chineseConvertCode,
        replaceRules: _replaceRules,
        pageFillThreshold: _pageFillThreshold,
        paraFormatHash: _paraFormatHash,
      );
    }
  }

  /// EPUB 翻章预取（M6）：预计算下一章全部分页写入 Rust LRU 缓存。
  ///
  /// 参数必须与上方 getPageStructured 完全一致（f32 按 bits 入缓存键，
  /// 不同参则入键错位、预取无效）。幂等：下一章已在缓存时 Rust 秒回；
  /// 前台占用写锁时让路返回 false。仅向后一章——向前翻章目标通常
  /// 已在 LRU 中；并发多章无收益（JS 提取器进程级单 Context）。
  void _prefetchNextChapterEpub() {
    final bookId = state.bookId;
    if (bookId == null || !_isEpub) return;
    final next = state.currentChapterIndex + 1;
    if (next >= state.chapters.length) return;
    final convertCode = _chineseConvert == ChineseConvertType.s2t ? 1
        : _chineseConvert == ChineseConvertType.t2s ? 2
        : 0;
    unawaited(_bookService.prefetchStructuredChapter(
      bookId,
      next,
      width: _screenWidth,
      height: _screenHeight,
      fontSize: _fontSize,
      lineHeightMultiplier: _lineHeight,
      paddingLeft: _paddingHorizontal,
      paddingTop: _paddingVertical,
      paddingRight: _paddingHorizontal,
      paddingBottom: _paddingVertical,
      chineseConvert: convertCode,
      pageFillThreshold: _pageFillThreshold,
      showComments: _showComments,
      paraFormatHash: _paraFormatHash,
    ));
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
  ///
  /// M8-P4：先查内存缓存 `_chapterPageCounts`，命中直接返回；
  /// 未命中调 FFI getPageCountStructured / getPageCountProcessed 并缓存。
  /// 缓存失效：fontSize/lineHeight/pageFillThreshold/showComments 变更时
  /// 由调用方 `_invalidatePageCountCache()` 清空。
  Future<int> _pageCountOf(int chapterIndex) async {
    final cacheKey = _pageCountCacheKey(chapterIndex);
    final cached = _chapterPageCounts[cacheKey];
    if (cached != null) return cached;

    final count = await _pageCountOfUncached(chapterIndex);
    _chapterPageCounts[cacheKey] = count;
    return count;
  }

  /// 生成页数缓存键（排版参数指纹 + 章节索引）
  String _pageCountCacheKey(int chapterIndex) {
    return '${_screenWidth}_${_screenHeight}_'
        '${_fontSize}_${_lineHeight}_'
        '${_paddingHorizontal}_${_paddingVertical}_'
        '${_pageFillThreshold}_${_showComments}_'
        '${_removeDuplicateTitle}_'
        '${_chineseConvert.index}_'
        '${_replaceRules.length}_'
        '${_paraFormatHash}_$chapterIndex';
  }

  /// M9-P4：计算段落格式设置哈希（u64，用作 Rust 分页缓存键）
  ///
  /// 组合 enableIndent/indentSizeChars/paragraphSpacingMultiplier/
  /// reParagraphMode 为确定性整数哈希；任一设置变更即产生不同哈希值，
  /// 使 Rust 侧缓存自然按新设置重算。
  BigInt _computeParaFormatHash() {
    int h = 17;
    h = h * 31 + (_enableIndent ? 1 : 0);
    h = h * 31 + _indentSizeChars;
    h = h * 31 + _reParagraphMode;
    // 段间距乘数放大 1000 倍取整，保留 3 位精度差异
    h = h * 31 + (_paragraphSpacingMultiplier * 1000).round();
    // M9.2：切分阈值参与哈希（调整即换缓存键重排）
    h = h * 31 + _smartSplitThreshold;
    h = h * 31 + _aggressiveSplitThreshold;
    return BigInt.from(h & 0x7FFFFFFFFFFFFFFF);
  }

  /// 未缓存的页数获取（真正走 FFI）
  Future<int> _pageCountOfUncached(int chapterIndex) async {
    final common = (
      width: _screenWidth,
      height: _screenHeight,
      fontSize: _fontSize,
      lineHeight: _lineHeight,
      padH: _paddingHorizontal,
      padV: _paddingVertical,
    );
    if (_isEpub) {
      // 简繁编码与 TXT 同口径；页数与页内容必须同参（否则错位）
      int chineseConvertCode = _chineseConvert == ChineseConvertType.s2t ? 1
          : _chineseConvert == ChineseConvertType.t2s ? 2
          : 0;
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
        chineseConvert: chineseConvertCode,
        pageFillThreshold: _pageFillThreshold,
        showComments: _showComments,
        paraFormatHash: _paraFormatHash,
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
      reSegment: false, // M9.3：旧重排已被 ParagraphFormatter 取代，恒关
      chineseConvert: chineseConvertCode,
      replaceRules: _replaceRules,
      pageFillThreshold: _pageFillThreshold,
      paraFormatHash: _paraFormatHash,
    );
  }

  /// M8-P4：排版参数变更时清空页数缓存
  void _invalidatePageCountCache() {
    _chapterPageCounts.clear();
  }

  /// Go to next page
  ///
  /// [preloaded] 翻页动画层传入的预载目标页（render store 邻居页）：
  /// 直接采用、跳过 FFI 往返，实现翻页完成零延迟定格
  /// （对齐 legado onAnimStop→fillPage 同步换页机制）。
  Future<void> nextPage({PageInfo? preloaded}) async {
    if (state.bookId == null) return;

    // 预载直采必须先于一切 await：目标页本就出自 render store 邻居，
    // 状态换页作为首个同步动作——提交窗口期内新拖拽绝不会读到
    // 「目标页==可见页」的陈旧邻居索引（内容重复闪现的根源）
    if (preloaded != null) {
      await _adoptPreloadedPage(preloaded);
      return;
    }

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
  ///
  /// [preloaded] 语义同 [nextPage]。
  Future<void> previousPage({PageInfo? preloaded}) async {
    if (state.bookId == null) return;

    // 预载直采先于一切 await（语义同 nextPage）
    if (preloaded != null) {
      await _adoptPreloadedPage(preloaded);
      return;
    }

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

  /// 直接采用预载页（零 FFI）：state 切换 + 三页重发布 + 进度落库 + EPUB 预取
  ///
  /// 收尾逻辑与 _loadCurrentPage 相同，仅省去取页的 FFI 往返——
  /// 预载页本就出自同一分页缓存，内容一致。
  Future<void> _adoptPreloadedPage(PageInfo page) async {
    state = state.copyWith(
      currentPage: page,
      currentPageIndex: page.pageIndex,
    );
    // 先同步发布 current-only 结构：model.currentPage 与 state 立即
    // 一致，陈旧邻居从结构上不可能被新拖拽读到；邻居页由异步发布
    // 就绪后补全（窗口期内 target=null 走既有直翻兜底，安全）
    _renderStore.publishStructure(
      currentPage: page,
      durPageIndex: page.pageIndex,
    );
    _publishRenderStructureAsync(page);
    _prefetchNextChapterEpub();

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
    _invalidatePageCountCache(); // M8-P4：关书清页数缓存
    state = const ReadingState();
    // P1：清空三页渲染状态
    _renderStore.publishStructure(
      isLoading: false,
    );
  }
}

// Provider
final bookServiceProvider = Provider((ref) => BookService());

final readerProvider = NotifierProvider<ReaderNotifier, ReadingState>(() {
  return ReaderNotifier();
});
