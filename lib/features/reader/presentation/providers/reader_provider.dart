import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/models/simple_models.dart';
import '../../../../core/ffi/book_service.dart';
import '../../../../core/services/measure_text_service.dart';
import '../../../../core/services/reader_font.dart';
import '../services/book_image_store.dart';
import '../widgets/page_turn/page_turn_types.dart';
import 'page_frame.dart';
import 'reader_render_state.dart';
import '../diagnostics/reader_trace.dart';

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

  /// 异步页面/frame 请求代际。旧请求完成后不得覆盖新阅读位置。
  int _requestGeneration = 0;

  /// 排版参数指纹变更重排的递归深度护栏（_loadCurrentPage 内自增/递减）。
  /// 连续 resize 逐次收敛属正常；≥4 说明参数在极速抖动，放弃本次、
  /// 交给绘制层 mismatch 兜底与下一次 LayoutBuilder 触发。
  int _fpReloadDepth = 0;

  /// 会话世代：换书/设置/窗口变化递增，旧 FrameSet 全部作废（不变量 6）。
  int _sessionEpoch = 0;

  /// 在途 FrameSet 准备批次计数（degraded 补发判定用）。
  int _prepareInFlight = 0;

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

  /// 权威 viewport（SafeArea 内实际可用区域，逻辑像素）
  ///
  /// viewport 尺寸单源化：排版 LayoutConfig、绘制 canvas、翻页几何
  /// 三者同源于此。reader_page 的 LayoutBuilder 负责测量与登记——
  /// 任何代码不得再从 MediaQuery.size 取排版/绘制尺寸（那是全屏值，
  /// 含状态栏/手势条区域，移动端与 SafeArea 内 canvas 不一致）。
  double get screenWidth => _screenWidth;
  double get screenHeight => _screenHeight;

  /// 是否已开书（viewport 尺寸变化时决定走锚点重排还是仅同步登记）
  bool get hasBook => state.bookId != null;

  /// 窗口尺寸变化：更新布局参数并带锚点重排当前页
  ///
  /// 分页缓存键含排版配置，新旧尺寸的页互不污染；锚点保证
  /// resize 后停留在原阅读位置（图片项不消耗锚点）。
  Future<void> onWindowResized(double width, double height) async {
    if (width == _screenWidth && height == _screenHeight) return;
    _screenWidth = width;
    _screenHeight = height;
    _invalidatePageCountCache(); // M8-P4：窗口尺寸变更清页数缓存
    _invalidateFrames(reason: 'window-resized'); // 旧尺寸 FrameSet 作废
    if (state.bookId == null || state.isLoading) return;
    await _loadCurrentPage(anchorCharOffset: state.currentPage?.startCharIndex);
  }

  void setFontSize(double fontSize) {
    _fontSize = fontSize;
    // M10-B：字号变更 → 清 Dart 端测量缓存（key 包含 fontSize）
    MeasureTextService.instance.configure(
      fontFamily: ReaderFont.family,
      fontSize: _fontSize,
    );
    _invalidatePageCountCache(); // M8-P4：排版参数变更清页数缓存
    _invalidateFrames(reason: 'font-size'); // 旧指纹 FrameSet 作废
    // Reload current page with new settings
    if (state.bookId != null) {
      _loadCurrentPage();
    }
  }

  /// 应用内容处理设置（对话框「应用设置」唯一入口）
  ///
  /// 统一处理净化选项与阅读级选项：更新 parser 净化器、失效缓存后
  /// 仅触发一次带锚点的页面重载，避免双重加载竞态。
  /// 
  /// 2026-09-02 优化：区分净化选项和段落格式变更，避免过度清空缓存。
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
    // 设置开始变化即使旧页面请求失效，避免在等待 Rust 同步期间回写旧帧。
    ++_requestGeneration;
    _invalidateFrames(reason: 'settings'); // 旧指纹 FrameSet 与待决手势作废
    
    // 检测净化选项是否变更（影响 PreprocessedCache）
    final bool needsCleaningUpdate = (
      _removeHtmlTags != removeHtmlTags ||
      _removeAds != removeAds ||
      _chineseConvert != chineseConvert ||
      _replaceRules.length != replaceRules.length ||
      !_listEquals(_replaceRules, replaceRules)
    );
    
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

    // 2026-09-03 修复：_paraFormatHash 更新后，需要再次更新 store.configFingerprint
    // 确保 store.configFingerprint 与后续发布的 FrameSet.configFingerprint 一致
    _renderStore.advanceSession(
      sessionEpoch: _sessionEpoch,  // 复用已递增的 epoch
      configFingerprint: layoutFingerprint(),  // 使用更新后的 fingerprint
    );

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

    // 2026-09-02 优化：仅当净化选项变更时才清空所有缓存
    // 段落格式变更仅触发自然换键（L1/L2 缓存键含 para_format_hash）
    if (needsCleaningUpdate) {
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
    }

    // 单次重载：简繁/规则经 options_hash 隔离缓存自然重算，锚点保持进度
    await _loadCurrentPage(anchorCharOffset: state.currentPage?.startCharIndex);
  }
  
  /// 辅助方法：比较两个 ReplaceRuleItem 列表是否相等
  bool _listEquals(List<ReplaceRuleItem> a, List<ReplaceRuleItem> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].pattern != b[i].pattern || 
          a[i].replacement != b[i].replacement ||
          a[i].isRegex != b[i].isRegex) {
        return false;
      }
    }
    return true;
  }

  /// Open a book file
  Future<void> openBook(String filePath, String bookName) async {
    ++_requestGeneration;
    _invalidateFrames(reason: 'open-book');
    state = state.copyWith(isLoading: true, error: null);
    // 发布 loading 占位（无 frame；会话已推进，旧集合全部作废）
    _renderStore.publishEmpty(isLoading: true, message: '正在打开书籍…');

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
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Load current page
  /// 加载当前页
  ///
  /// [anchorCharOffset] 进度锚点：设置变更后用章内字符偏移重新定位，
  /// 返回页的 pageIndex 会同步回状态，保证停留在原阅读位置。
  Future<void> _loadCurrentPage({int? anchorCharOffset}) async {
    if (state.bookId == null) return;

    final generation = ++_requestGeneration;
    // 排版参数指纹快照：FFI 返回时若指纹已变（窗口 resize/系统栏 insets
    // 就位/设置变更发生在 FFI await 途中），本次排版结果作废——否则
    // 「旧宽度排版画新宽度画布」= 内容偏右/右侧空白消失（曲面屏实测）。
    final fpSnapshot = layoutFingerprint();
    final requestedBookId = state.bookId!;
    final requestedChapterIndex = state.currentChapterIndex;
    final requestedPageIndex = state.currentPageIndex;
    readerTrace('page.load.start', {
      'generation': generation,
      'book': requestedBookId,
      'chapter': requestedChapterIndex,
      'page': requestedPageIndex,
      'anchor': anchorCharOffset,
    });

    try {
      // 分流：EPUB 结构化分页 / TXT 文本分页
      final PageInfo page;
      if (_isEpub) {
        // 简繁编码与 TXT 同口径（0=无 1=简→繁 2=繁→简）
        int chineseConvertCode = _chineseConvert == ChineseConvertType.s2t
            ? 1
            : _chineseConvert == ChineseConvertType.t2s
            ? 2
            : 0;
        page = await _bookService.getPageStructured(
          requestedBookId,
          requestedChapterIndex,
          requestedPageIndex,
          width: _screenWidth,
          height: _screenHeight,
          fontSize: _fontSize,
          lineHeightMultiplier: _lineHeight,
          paddingLeft: _paddingHorizontal,
          paddingTop: _paddingVertical,
          paddingRight: _paddingHorizontal,
          paddingBottom: _paddingVertical,
          fontName: ReaderFont.family, // M11：与 MeasureCache key 对齐
          anchorCharOffset: anchorCharOffset,
          chineseConvert: chineseConvertCode,
          pageFillThreshold: _pageFillThreshold,
          showComments: _showComments,
          paraFormatHash: _paraFormatHash,
        );
      } else {
        // 转换简繁设置为数字代码
        int chineseConvertCode = _chineseConvert == ChineseConvertType.s2t
            ? 1
            : _chineseConvert == ChineseConvertType.t2s
            ? 2
            : 0;

        // 使用带预处理的 API
        page = await _bookService.getPageProcessed(
          requestedBookId,
          requestedChapterIndex,
          requestedPageIndex,
          width: _screenWidth,
          height: _screenHeight,
          fontSize: _fontSize,
          lineHeightMultiplier: _lineHeight,
          paddingLeft: _paddingHorizontal,
          paddingTop: _paddingVertical,
          paddingRight: _paddingHorizontal,
          paddingBottom: _paddingVertical,
          fontName: ReaderFont.family, // M11：与 MeasureCache key 对齐
          removeDuplicateTitle: _removeDuplicateTitle,
          reSegment: false, // M9.3：旧重排已被 ParagraphFormatter 取代，恒关
          chineseConvert: chineseConvertCode,
          replaceRules: _replaceRules,
          anchorCharOffset: anchorCharOffset,
          pageFillThreshold: _pageFillThreshold,
          paraFormatHash: _paraFormatHash,
        );
      }

      // 结果回写前校验请求代际和阅读会话，防止旧请求覆盖新页。
      if (generation != _requestGeneration ||
          state.bookId != requestedBookId ||
          state.currentChapterIndex != requestedChapterIndex) {
        readerTrace('page.load.drop', {
          'generation': generation,
          'currentGeneration': _requestGeneration,
          'requested': '$requestedChapterIndex/$requestedPageIndex',
          'actual': '${state.currentChapterIndex}/${state.currentPageIndex}',
        });
        return;
      }

      // 排版参数指纹校验（通用根治）：FFI 途中 layoutFingerprint 变更
      // （窗口 resize、曲面屏 insets 就位、旋转屏、设置变更）时，本次
      // 结果是旧参数排版——丢弃并立即用当前参数重排一次。重排内部会
      // 以新指纹再快照，连续变更天然逐次收敛；深度护栏防极端抖动。
      if (fpSnapshot != layoutFingerprint()) {
        if (_fpReloadDepth >= 4) {
          readerTrace('page.load.fp-reload.giveup', {
            'generation': generation,
            'depth': _fpReloadDepth,
          });
          return;
        }
        readerTrace('page.load.fp-reload', {
          'generation': generation,
          'snapshot': fpSnapshot,
          'current': layoutFingerprint(),
        });
        _fpReloadDepth++;
        try {
          await _loadCurrentPage(anchorCharOffset: anchorCharOffset);
        } finally {
          _fpReloadDepth--;
        }
        return;
      }

      // 锚点定位后页码可能与请求不同：同步回状态
      state = state.copyWith(
        currentPage: page,
        currentPageIndex: page.pageIndex,
      );
      readerTrace('page.load.commit', {
        'generation': generation,
        'pageId': readerPageId(page),
        'page': '${page.chapterIndex}/${page.pageIndex}',
        'range': '${page.startCharIndex}-${page.endCharIndex}',
      });

      // P1 接线层：发布三页结构态到 render store（fire-and-forget，
      // 当前页已就绪可渲染，邻居页加载不阻塞 UI）
      _prepareAndPublishFrameSet(page);

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
      readerTrace('page.next.error', {
        'error': e.toString(),
        'current': '${state.currentChapterIndex}/${state.currentPageIndex}',
      });
      state = state.copyWith(error: e.toString());
    }
  }

  /// FrameSet 发布管线：并行加载邻居槽位 → 统一预热资源 → 原子发布。
  ///
  /// 协议要求（PageFrame 不变量 3）：
  /// - 任何失配（generation/sessionEpoch/页面实例）不得静默丢弃——
  ///   store 无 frame 或已标脏时用 state 现值补发 degraded 集合，
  ///   保证 store 永不滞后于 state。旧协议在此直接 return 会让三页
  ///   模型永久陈旧：前向翻页被 identical 守卫无限延迟（点击无响应），
  ///   后向翻页取到「2 页前」旧邻居展开错误内容。
  /// - 邻居槽位缺失必须有明确原因（越界/失败/加载中），永不静默 null。
  Future<void> _prepareAndPublishFrameSet(PageInfo currentPage) async {
    final generation = _requestGeneration;
    final epoch = _sessionEpoch;
    final requestedBookId = state.bookId;
    final requestedChapterIndex = state.currentChapterIndex;
    final requestedPageIndex = state.currentPageIndex;
    final sw = Stopwatch()..start();
    _prepareInFlight++;
    try {
      final chapterIndex = requestedChapterIndex;
      final pageIndex = requestedPageIndex;
      // 并行加载前后邻居槽位（含跨章回退，槽位态明确）
      final slots = await Future.wait([
        _loadNeighborSlot(chapterIndex, pageIndex - 1),
        _loadNeighborSlot(chapterIndex, pageIndex + 1),
      ]);
      readerTrace('frame.neighbors.ready', {
        'generation': generation,
        'prev': frameSlotTrace(slots[0]),
        'next': frameSlotTrace(slots[1]),
      });

      // 三页资源统一预热（背景图 + 图片 entry 去重），完成后 frame 资源态
      // 聚合为终态、动画门控据此判定可用性。
      // 
      // 2026-09-02 阶段2优化：检测挂起的翻页手势方向，优先预热目标方向
      final states = <String, BookImageState>{};
      final pendingDirection = _renderStore.pendingTurnDirection;
      
      final List<Set<String>> resourceGroups;
      if (pendingDirection == PageDirection.next) {
        // 用户想往后翻 → 优先预热 next
        resourceGroups = [
          slots[1].frame != null
              ? ResourceManifest.of(slots[1].frame!.page).hrefs
              : <String>{},
          ResourceManifest.of(currentPage).hrefs,
          slots[0].frame != null
              ? ResourceManifest.of(slots[0].frame!.page).hrefs
              : <String>{},
        ];
      } else if (pendingDirection == PageDirection.prev) {
        // 用户想往前翻 → 优先预热 prev
        resourceGroups = [
          slots[0].frame != null
              ? ResourceManifest.of(slots[0].frame!.page).hrefs
              : <String>{},
          ResourceManifest.of(currentPage).hrefs,
          slots[1].frame != null
              ? ResourceManifest.of(slots[1].frame!.page).hrefs
              : <String>{},
        ];
      } else {
        // 无挂起手势 → 默认顺序（next → current → prev）
        resourceGroups = [
          slots[1].frame != null
              ? ResourceManifest.of(slots[1].frame!.page).hrefs
              : <String>{},
          ResourceManifest.of(currentPage).hrefs,
          slots[0].frame != null
              ? ResourceManifest.of(slots[0].frame!.page).hrefs
              : <String>{},
        ];
      }
      
      for (final group in resourceGroups) {
        final pending = group.where((h) => !states.containsKey(h)).toSet();
        if (pending.isEmpty) continue;
        states.addAll(await BookImageStore.instance.prewarmManifest(pending));
      }
      readerTrace('frame.resources.ready', {
        'generation': generation,
        'latencyMs': sw.elapsedMilliseconds,
      });

      if (_isStale(generation, epoch, requestedBookId, requestedChapterIndex,
          requestedPageIndex, currentPage)) {
        readerTrace('frame.prepare.stale', {
          'generation': generation,
          'currentGeneration': _requestGeneration,
          'epoch': epoch,
          'currentEpoch': _sessionEpoch,
        });
        // 完整 FrameSet 因失配弃发：降级补发保证 store 不滞后于 state
        // （发布协议原则②，杜绝静默丢弃）
        _publishDegradedFromState();
        return;
      }

      final current = _frameWithResources(
        _buildFrame(currentPage, generation: generation, epoch: epoch),
        states,
      );
      
      // 2026-09-03 修复：在发布前重新捕获 fingerprint
      // 原因：异步操作期间 para_format_hash 可能已改变
      final finalFingerprint = layoutFingerprint();
      
      _publishPinned(FrameSet(
        setRevision: _renderStore.nextSetRevision(),
        current: current,
        previous: _finalizeSlot(slots[0], states),
        next: _finalizeSlot(slots[1], states),
        configFingerprint: finalFingerprint,
        sessionEpoch: epoch,
      ));
      readerTrace('frame.commit', {
        'generation': generation,
        'set': _renderStore.frameSet?.id,
        'latencyMs': sw.elapsedMilliseconds,
      });
    } catch (e) {
      readerTrace('frame.prepare.error', {
        'error': e.toString(),
        'generation': generation,
      });
      if (_isStale(generation, epoch, requestedBookId, requestedChapterIndex,
          requestedPageIndex, currentPage)) {
        _publishDegradedFromState();
        return;
      }
      // 邻居/预热异常：发布 current + failed 槽位（绝不 null 邻居不留标记）
      // 2026-09-03 修复：在发布前重新捕获 fingerprint
      final finalFingerprint = layoutFingerprint();
      
      _publishPinned(FrameSet(
        setRevision: _renderStore.nextSetRevision(),
        current: _frameWithResources(
          _buildFrame(currentPage, generation: generation, epoch: epoch),
          const {},
        ),
        previous: const FrameSlot.failed(),
        next: const FrameSlot.failed(),
        configFingerprint: finalFingerprint,
        sessionEpoch: epoch,
      ));
    } finally {
      _prepareInFlight--;
    }
  }

  /// 批次新鲜度校验：任一会话/位置/实例变化即视为陈旧
  bool _isStale(
    int generation,
    int epoch,
    String? bookId,
    int chapterIndex,
    int pageIndex,
    PageInfo currentPage,
  ) {
    return generation != _requestGeneration ||
        epoch != _sessionEpoch ||
        state.bookId != bookId ||
        state.currentChapterIndex != chapterIndex ||
        state.currentPageIndex != pageIndex ||
        !identical(state.currentPage, currentPage);
  }

  /// 构建页面帧（资源态先置 loading，预热后由 [_frameWithResources] 聚合）
  PageFrame _buildFrame(
    PageInfo page, {
    required int generation,
    required int epoch,
  }) {
    return PageFrame(
      identity: FrameIdentity.of(state.bookId ?? '', page),
      configFingerprint: layoutFingerprint(),
      sessionEpoch: epoch,
      requestGeneration: generation,
      page: page,
      manifest: ResourceManifest.of(page),
      resourceState: FrameResourceState.loading,
    );
  }

  /// 按预热结果聚合帧资源态：全 ready→ready；任一稳定 failed→failed
  /// （不变量 4 允许稳定失败帧启动动画，恒画占位无随机跳变）。
  PageFrame _frameWithResources(
    PageFrame frame,
    Map<String, BookImageState> states,
  ) {
    return PageFrame(
      identity: frame.identity,
      configFingerprint: frame.configFingerprint,
      sessionEpoch: frame.sessionEpoch,
      requestGeneration: frame.requestGeneration,
      page: frame.page,
      manifest: frame.manifest,
      resourceState: _aggregateResourceState(frame.manifest, states),
    );
  }

  FrameSlot _finalizeSlot(FrameSlot slot, Map<String, BookImageState> states) {
    final frame = slot.frame;
    if (frame == null) return slot;
    return FrameSlot.ready(_frameWithResources(frame, states));
  }

  FrameResourceState _aggregateResourceState(
    ResourceManifest manifest,
    Map<String, BookImageState> states,
  ) {
    if (manifest.isEmpty) return FrameResourceState.ready;
    var allReady = true;
    var anyFailed = false;
    for (final href in manifest.hrefs) {
      final s = states[href];
      if (s == BookImageState.failed) {
        anyFailed = true;
        allReady = false;
      } else if (s != BookImageState.ready) {
        allReady = false;
      }
    }
    if (allReady) return FrameResourceState.ready;
    if (anyFailed) return FrameResourceState.failed;
    return FrameResourceState.pending;
  }

  /// 陈旧/失效场景的兜底发布：用 state.currentPage 现值构建 degraded
  /// FrameSet（邻居槽 pending、资源态 pending → 手势等待新批次）。
  /// 仅在「store 无 frame 或已标脏，且没有更新的批次在途」时发布，
  /// 避免覆盖即将落地的新鲜批次。
  void _publishDegradedFromState() {
    if (_prepareInFlight > 1) return;
    if (_renderStore.frameSet != null && !_renderStore.dirty) return;
    final current = state.currentPage;
    if (current == null) return;
    _publishPinned(FrameSet(
      setRevision: _renderStore.nextSetRevision(),
      current: PageFrame(
        identity: FrameIdentity.of(state.bookId ?? '', current),
        configFingerprint: layoutFingerprint(),
        sessionEpoch: _sessionEpoch,
        requestGeneration: _requestGeneration,
        page: current,
        manifest: ResourceManifest.of(current),
        resourceState: FrameResourceState.pending,
      ),
      previous: const FrameSlot.pending(),
      next: const FrameSlot.pending(),
      configFingerprint: layoutFingerprint(),
      sessionEpoch: _sessionEpoch,
    ));
    readerTrace('frame.commit.degraded', {
      'generation': _requestGeneration,
      'page': '${current.chapterIndex}/${current.pageIndex}',
    });
  }

  /// FrameSet 发布统一出口：pin 资源清单（存活帧引用的图片不淘汰）
  /// 后原子发布。pin/unpin 收敛在此单点，保证 dispose 安全。
  /// 
  /// 2026-09-02 阶段2优化：投机性资源预解码
  /// 2026-09-02 阶段2修复：资源状态监控，确保资源就绪后重新通知监听器
  void _publishPinned(FrameSet set) {
    final hrefs = <String>{...set.current.manifest.hrefs};
    for (final slot in [set.previous, set.next]) {
      final frame = slot.frame;
      if (frame != null) hrefs.addAll(frame.manifest.hrefs);
    }
    BookImageStore.instance.setPinned(hrefs);
    _renderStore.publishFrameSet(set);
    
    // 🔍 资源状态监控：如果资源仍在 loading，定期检查并在就绪时重新通知
    _startResourceMonitoring(set);
    
    // 🚀 投机性预热：假设用户会继续翻下一页
    unawaited(_speculativePrewarmNext());
  }
  
  Timer? _resourceMonitorTimer;
  
  /// 监控 FrameSet 的资源状态，当资源从 pending 变为 ready 时重新通知监听器
  /// 
  /// 关键修复（2026-09-02）：解决"参数变更后动画永久失效"问题
  /// - 问题：FrameSet 发布时资源状态可能是 pending（图片解码中）
  /// - 结果：frame.usableForAnimation == false → 动画门控一直返回 TargetWait()
  /// - 即使图片最终解码完成，也没有事件触发 _retryPendingTurn()
  /// - 解决：定期轮询资源状态，当全部就绪时重新发布 FrameSet（触发监听器）
  void _startResourceMonitoring(FrameSet set) {
    _resourceMonitorTimer?.cancel();
    
    // 检查是否有资源需要监控
    final allHrefs = <String>{};
    allHrefs.addAll(set.current.manifest.hrefs);
    for (final slot in [set.previous, set.next]) {
      final frame = slot.frame;
      if (frame != null) allHrefs.addAll(frame.manifest.hrefs);
    }
    
    if (allHrefs.isEmpty) return;
    
    // 检查是否已经全部就绪
    if (BookImageStore.instance.isManifestReady(allHrefs)) {
      return; // 已经就绪，无需监控
    }
    
    // 启动监控定时器（每 100ms 检查一次，最多 10 秒）
    int checkCount = 0;
    const maxChecks = 100; // 10 秒 / 100ms
    final monitorEpoch = _sessionEpoch; // 捕获当前 epoch
    
    _resourceMonitorTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (timer) {
        checkCount++;
        
        // 超时或会话已变更（参数再次变更 → epoch 递增 → 停止监控旧 FrameSet）
        if (checkCount >= maxChecks || monitorEpoch != _sessionEpoch) {
          timer.cancel();
          _resourceMonitorTimer = null;
          return;
        }
        
        // 检查资源状态
        if (BookImageStore.instance.isManifestReady(allHrefs)) {
          timer.cancel();
          _resourceMonitorTimer = null;
          
          // 资源已就绪！重新发布 FrameSet 触发监听器
          readerTrace('frame.resources.monitor.ready', {
            'set': set.id,
            'checkCount': checkCount,
            'timeMs': checkCount * 100,
          });
          
          // 重新发布会触发 _onModelPublished → _retryPendingTurn
          _renderStore.publishFrameSet(set);
        }
      },
    );
  }
  
  /// 投机性预热：在 FrameSet 发布后立即预热下一页的资源
  /// 
  /// 2026-09-02 阶段2优化：用户连续翻页时几乎无等待
  Future<void> _speculativePrewarmNext() async {
    try {
      // 获取当前页信息
      final currentChapter = state.currentChapterIndex;
      final currentPageIndex = state.currentPageIndex;
      
      // 计算 N+2 页（当前 FrameSet 已包含 N+1）
      int nextChapter = currentChapter;
      int nextPageIndex = currentPageIndex + 2;
      
      // 检查是否跨章
      final currentChapterPageCount = await _pageCountOf(currentChapter);
      if (nextPageIndex >= currentChapterPageCount) {
        // 跨到下一章
        nextChapter = currentChapter + 1;
        nextPageIndex = nextPageIndex - currentChapterPageCount;
        
        // 检查章节是否越界
        final totalChapters = state.chapters.length;
        if (nextChapter >= totalChapters) {
          return; // 已到最后一章,无需预热
        }
      }
      
      // 异步预热，不阻塞当前发布
      unawaited(_speculativeLoadPage(
        chapterIndex: nextChapter,
        pageIndex: nextPageIndex,
      ));
    } catch (e) {
      // 投机预热失败不影响主流程，静默忽略
      readerTrace('speculative.prewarm.error', {'error': e.toString()});
    }
  }
  
  /// 投机性加载页面：加载并预热 N+2 页的资源
  Future<void> _speculativeLoadPage({
    required int chapterIndex,
    required int pageIndex,
  }) async {
    try {
      // 加载页面
      final page = await _loadSinglePage(chapterIndex, pageIndex);
      
      // 预热该页的图片资源
      final manifest = ResourceManifest.of(page);
      if (manifest.hrefs.isNotEmpty) {
        await BookImageStore.instance.prewarmManifest(manifest.hrefs);
        readerTrace('speculative.prewarm.done', {
          'chapter': chapterIndex,
          'page': pageIndex,
          'imageCount': manifest.hrefs.length,
        });
      }
    } catch (e) {
      // 投机预热失败不影响主流程
      readerTrace('speculative.load.error', {
        'chapter': chapterIndex,
        'page': pageIndex,
        'error': e.toString(),
      });
    }
  }

  /// 加载邻居槽位：越界→outOfRange；FFI 异常→failed（永不静默 null）。
  /// 缺失原因必须明确，手势门控与降级发布的语义依赖槽位态。
  Future<FrameSlot> _loadNeighborSlot(int chapterIndex, int pageIndex) async {
    try {
      if (pageIndex < 0) {
        // 跨章到上一章末页
        if (chapterIndex <= 0) return const FrameSlot.outOfRange();
        final prevChapter = chapterIndex - 1;
        final count = await _pageCountOf(prevChapter);
        if (count <= 0) return const FrameSlot.outOfRange();
        final page = await _loadSinglePage(prevChapter, count - 1);
        return FrameSlot.ready(
          _buildFrame(
            page,
            generation: _requestGeneration,
            epoch: _sessionEpoch,
          ),
        );
      }

      final count = await _pageCountOf(chapterIndex);
      if (pageIndex >= count) {
        // 跨章到下一章首页
        if (chapterIndex >= state.chapters.length - 1) {
          return const FrameSlot.outOfRange();
        }
        final page = await _loadSinglePage(chapterIndex + 1, 0);
        return FrameSlot.ready(
          _buildFrame(
            page,
            generation: _requestGeneration,
            epoch: _sessionEpoch,
          ),
        );
      }

      final page = await _loadSinglePage(chapterIndex, pageIndex);
      return FrameSlot.ready(
        _buildFrame(
          page,
          generation: _requestGeneration,
          epoch: _sessionEpoch,
        ),
      );
    } catch (e) {
      readerTrace('frame.neighbor.failed', {
        'page': '$chapterIndex/$pageIndex',
        'error': e.toString(),
      });
      return const FrameSlot.failed();
    }
  }

  /// 加载单页（复用 _loadCurrentPage 的参数管线，但不修改 state）
  Future<PageInfo> _loadSinglePage(int chapterIndex, int pageIndex) async {
    if (_isEpub) {
      int chineseConvertCode = _chineseConvert == ChineseConvertType.s2t
          ? 1
          : _chineseConvert == ChineseConvertType.t2s
          ? 2
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
        fontName: ReaderFont.family, // M11：与 MeasureCache key 对齐
        chineseConvert: chineseConvertCode,
        pageFillThreshold: _pageFillThreshold,
        showComments: _showComments,
        paraFormatHash: _paraFormatHash,
      );
    } else {
      int chineseConvertCode = _chineseConvert == ChineseConvertType.s2t
          ? 1
          : _chineseConvert == ChineseConvertType.t2s
          ? 2
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
        fontName: ReaderFont.family, // M11：与 MeasureCache key 对齐
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
    final convertCode = _chineseConvert == ChineseConvertType.s2t
        ? 1
        : _chineseConvert == ChineseConvertType.t2s
        ? 2
        : 0;
    unawaited(
      _bookService.prefetchStructuredChapter(
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
      ),
    );
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

  /// 排版/内容处理配置指纹（单一来源）。
  ///
  /// 页数缓存键、FrameSet 身份、adopt 批次校验共用：任一参与 Rust
  /// 分页缓存键的参数变化都会改变指纹，旧指纹帧与缓存永不复用
  /// （不变量 6：配置变更后旧 fingerprint 的缓存结果不得复用）。
  String layoutFingerprint() {
    return '${_screenWidth}_${_screenHeight}_'
        '${_fontSize}_${_lineHeight}_'
        '${_paddingHorizontal}_${_paddingVertical}_'
        '${_pageFillThreshold}_${_showComments}_'
        '${_removeDuplicateTitle}_'
        '${_chineseConvert.index}_'
        '${_replaceRulesFingerprint()}_'
        '${_paraFormatHash}';
  }

  /// 生成页数缓存键（排版参数指纹 + 章节索引）
  String _pageCountCacheKey(int chapterIndex) =>
      '${layoutFingerprint()}_$chapterIndex';

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

  /// 替换规则必须按内容参与 Dart 页数缓存键；仅使用数量会在同数量改规则
  /// 时错误复用旧页数，进而把跨页边界判断带到旧排版结果。
  int _replaceRulesFingerprint() {
    var hash = 17;
    for (final rule in _replaceRules) {
      for (final value in [
        rule.pattern,
        rule.replacement,
        rule.isRegex.toString(),
        rule.enabled.toString(),
      ]) {
        for (final codeUnit in value.codeUnits) {
          hash = (hash * 31 + codeUnit) & 0x7fffffff;
        }
        hash = (hash * 31 + 1) & 0x7fffffff;
      }
    }
    return hash;
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
      int chineseConvertCode = _chineseConvert == ChineseConvertType.s2t
          ? 1
          : _chineseConvert == ChineseConvertType.t2s
          ? 2
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
    int chineseConvertCode = _chineseConvert == ChineseConvertType.s2t
        ? 1
        : _chineseConvert == ChineseConvertType.t2s
        ? 2
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

  /// Frame 失效统一入口：推进会话世代，旧 FrameSet 与待决手势全部作废。
  /// 不清 BookImageStore 解码图（图片内容与排版无关；换书仍走 bind/clear）。
  void _invalidateFrames({required String reason}) {
    _renderStore.advanceSession(
      sessionEpoch: ++_sessionEpoch,
      configFingerprint: layoutFingerprint(),
    );
    BookImageStore.instance.advanceSession(_sessionEpoch);
    readerTrace('frame.invalidate', {'reason': reason, 'epoch': _sessionEpoch});
  }

  /// Go to next page
  ///
  /// [preloaded] 翻页动画层传入的预载目标页（render store 邻居页）：
  /// 直接采用、跳过 FFI 往返，实现翻页完成零延迟定格
  /// （对齐 legado onAnimStop→fillPage 同步换页机制）。
  Future<void> nextPage({PageInfo? preloaded}) async {
    if (state.bookId == null) return;

    try {
      final pageCount = await _pageCountOf(state.currentChapterIndex);

      if (state.currentPageIndex < pageCount - 1) {
        // Next page in current chapter
        if (preloaded != null) {
          if (await _adoptPreloadedPage(preloaded, forward: true)) return;
          // adopt 失败 → 回退到 FFI 重载；adopt.reject 已记录原因
        }
        state = state.copyWith(currentPageIndex: state.currentPageIndex + 1);
        await _loadCurrentPage();
      } else if (state.currentChapterIndex < state.chapters.length - 1) {
        // Next chapter
        if (preloaded != null &&
            preloaded.chapterIndex == state.currentChapterIndex + 1 &&
            preloaded.pageIndex == 0) {
          if (await _adoptPreloadedPage(preloaded, forward: true)) return;
        }
        state = state.copyWith(
          currentChapterIndex: state.currentChapterIndex + 1,
          currentPageIndex: 0,
        );
        await _loadCurrentPage();
      } else {
        // 越界：最后章最后页，不动 state
        readerTrace('page.next.out-of-range', {
          'pageCount': pageCount,
          'currentIndex': state.currentPageIndex,
          'chapter': state.currentChapterIndex,
        });
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

    if (state.currentPageIndex > 0) {
      // Previous page in current chapter
      if (preloaded != null) {
        if (await _adoptPreloadedPage(preloaded, forward: false)) return;
      }
      state = state.copyWith(currentPageIndex: state.currentPageIndex - 1);
      await _loadCurrentPage();
    } else if (state.currentChapterIndex > 0) {
      // Previous chapter, last page
      if (preloaded != null &&
          preloaded.chapterIndex == state.currentChapterIndex - 1) {
        if (await _adoptPreloadedPage(preloaded, forward: false)) return;
      }
      try {
        final prevChapterIndex = state.currentChapterIndex - 1;
        final pageCount = await _pageCountOf(prevChapterIndex);

        state = state.copyWith(
          currentChapterIndex: prevChapterIndex,
          currentPageIndex: pageCount - 1,
        );
        await _loadCurrentPage();
      } catch (e) {
        readerTrace('page.previous.error', {
          'error': e.toString(),
          'current': '${state.currentChapterIndex}/${state.currentPageIndex}',
        });
        state = state.copyWith(error: e.toString());
      }
    } else {
      // 越界：第一章第一页，不动 state
      readerTrace('page.previous.out-of-range', {
        'currentIndex': state.currentPageIndex,
        'chapter': state.currentChapterIndex,
      });
    }
  }

  /// 直接采用预载页（零 FFI）：批次校验 + 三页预发布 + 进度落库 + EPUB 预取
  ///
  /// 两道校验后先发布 provisional FrameSet 再切 state（store 永不滞后）：
  /// provisional 的 current=目标帧、previous=旧当前帧、next=pending，
  /// 异步 [_prepareAndPublishFrameSet] 随后补全真实邻居。
  Future<bool> _adoptPreloadedPage(
    PageInfo page, {
    required bool forward,
  }) async {
    // ── 第一道：FrameSet 批次身份校验 ──
    // 目标必须 identical 于当前发布集合对应槽位的帧，且集合的
    // epoch/指纹/批次与当前会话一致——排除旧排版、旧批次邻居回写
    // （设置变更窗口内采纳旧排版邻居实例的根因修复）。
    final set = _renderStore.frameSet;
    final slot =
        set?.slotFor(forward ? PageDirection.next : PageDirection.prev);
    final frame = slot?.frame;
    final batchOk = set != null &&
        frame != null &&
        identical(frame.page, page) &&
        set.sessionEpoch == _sessionEpoch &&
        set.configFingerprint == layoutFingerprint() &&
        _requestGeneration == set.current.requestGeneration;
    if (!batchOk) {
      readerTrace('page.adopt.reject', {'reason': 'frame-batch'});
      return false;
    }

    // ── 第二道：位置相邻性（防御方向/位置错配）──
    final chapterIndex = page.chapterIndex;
    if (chapterIndex < 0 || chapterIndex >= state.chapters.length) {
      readerTrace('page.adopt.reject', {'reason': 'chapter-range'});
      return false;
    }
    final sameChapter = chapterIndex == state.currentChapterIndex;
    final validNext = sameChapter
        ? page.pageIndex == state.currentPageIndex + 1
        : chapterIndex == state.currentChapterIndex + 1 && page.pageIndex == 0;
    final validPrev = sameChapter
        ? page.pageIndex == state.currentPageIndex - 1
        : chapterIndex == state.currentChapterIndex - 1;
    readerTrace('page.adopt.attempt', {
      'forward': forward,
      'target': '$chapterIndex/${page.pageIndex}',
      'current': '${state.currentChapterIndex}/${state.currentPageIndex}',
      'valid': forward ? validNext : validPrev,
    });
    if (forward ? !validNext : !validPrev) {
      readerTrace('page.adopt.reject', {'reason': 'not-adjacent'});
      return false;
    }

    ++_requestGeneration;

    // 先模型后 state：provisional 集合让门控立即与可见页对齐
    _publishPinned(FrameSet(
      setRevision: _renderStore.nextSetRevision(),
      current: frame,
      previous: FrameSlot.ready(set.current),
      next: const FrameSlot.pending(),
      configFingerprint: set.configFingerprint,
      sessionEpoch: set.sessionEpoch,
    ));
    state = state.copyWith(
      currentChapterIndex: chapterIndex,
      currentPage: page,
      currentPageIndex: page.pageIndex,
    );
    _prepareAndPublishFrameSet(page);
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
    return true;
  }

  /// Jump to specific chapter and page
  Future<void> jumpTo(int chapterIndex, int pageIndex) async {
    if (state.bookId == null) return;
    if (chapterIndex < 0 || chapterIndex >= state.chapters.length) return;

    ++_requestGeneration;
    state = state.copyWith(
      currentChapterIndex: chapterIndex,
      currentPageIndex: pageIndex,
    );
    await _loadCurrentPage();
  }

  /// Close current book
  Future<void> closeBook() async {
    ++_requestGeneration;
    
    // 2026-09-02 清理资源监控定时器
    _resourceMonitorTimer?.cancel();
    _resourceMonitorTimer = null;
    
    if (state.bookId != null) {
      await _bookService.releaseBook(state.bookId!);
    }
    BookImageStore.instance.clear();
    _invalidatePageCountCache(); // M8-P4：关书清页数缓存
    state = const ReadingState();
    readerTrace('session.close', {'generation': _requestGeneration});
    // 清空渲染状态：会话作废 + 无 frame 占位
    _invalidateFrames(reason: 'close-book');
    _renderStore.publishEmpty(isLoading: false);
  }
}

// Provider
final bookServiceProvider = Provider((ref) => BookService());

final readerProvider = NotifierProvider<ReaderNotifier, ReadingState>(() {
  return ReaderNotifier();
});
