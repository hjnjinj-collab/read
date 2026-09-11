import 'dart:io';
import 'dart:typed_data' show Uint8List;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    as frb;

import '../models/simple_models.dart';
import 'rust_bridge.dart/api.dart' as rust_api;
import 'rust_bridge.dart/frb_generated.dart';
import 'rust_bridge.dart/lib.dart' as rust_types;

/// Service to interact with Rust book parser and layout engine
class BookService {
  // Initialize FFI
  static Future<void> init() async {
    await RustLib.init();
  }

  /// Parse a TXT file and return book ID
  Future<String> parseTxtFile(String filePath, String? bookName) async {
    return await rust_api.parseTxtFile(filePath: filePath, bookName: bookName);
  }

  /// Parse a TXT file asynchronously（解析在线程池执行，不阻塞 UI）
  ///
  /// 大文件导入请优先使用此方法。
  /// [cleaningOptions] 非空时在导入阶段启用结构净化（去HTML/广告/智能分段等），
  /// 章节识别在净化后文本上完成。
  Future<String> parseTxtFileAsync(
    String filePath,
    String? bookName, {
    rust_api.ContentCleaningOptions? cleaningOptions,
  }) async {
    return await rust_api.parseTxtFileAsync(
      filePath: filePath,
      bookName: bookName,
      cleaningOptions: cleaningOptions,
    );
  }

  /// 运行中更新已打开书籍的净化设置（即时生效，自动失效相关缓存）
  Future<void> updateBookCleaning(
    String bookId, {
    required bool removeHtmlTags,
    required bool removeAds,
    required bool smartParagraph,
    required bool traditionalized,
    required bool simplified,
  }) async {
    final options = buildCleaningOptions(
      removeHtmlTags: removeHtmlTags,
      removeAds: removeAds,
      smartParagraph: smartParagraph,
      traditionalized: traditionalized,
      simplified: simplified,
    );
    await rust_api.updateBookCleaning(bookId: bookId, options: options);
  }

  /// 构建净化选项对象
  rust_api.ContentCleaningOptions buildCleaningOptions({
    required bool removeHtmlTags,
    required bool removeAds,
    required bool smartParagraph,
    required bool traditionalized,
    required bool simplified,
  }) {
    String convertMode = 'none';
    if (traditionalized) {
      convertMode = 's2t';
    } else if (simplified) {
      convertMode = 't2s';
    }
    String paragraphMode = smartParagraph ? 'smart' : 'none';

    return rust_api.ContentCleaningOptions(
      convertMode: convertMode,
      paragraphMode: paragraphMode,
      cleanHtml: removeHtmlTags,
      removeAds: removeAds,
    );
  }

  /// Get book title
  Future<String> getBookTitle(String bookId) async {
    return await rust_api.getBookTitle(bookId: bookId);
  }

  /// Get chapter list
  Future<List<Chapter>> getChapters(String bookId) async {
    final rustChapters = await rust_api.getChapters(bookId: bookId);
    return rustChapters
        .map(
          (ch) => Chapter(
            title: ch.title,
            startPos: ch.startPos.toInt(),
            endPos: ch.endPos.toInt(),
            level: ch.level,
            parentIndex: ch.parentIndex?.toInt(),
          ),
        )
        .toList();
  }

  /// Get chapter content
  Future<String> getChapterContent(
    String bookId, 
    int chapterIndex, {
    bool removeDuplicateTitle = false,
  }) async {
    return await rust_api.getChapterContent(
      bookId: bookId,
      chapterIndex: BigInt.from(chapterIndex),
      removeDuplicateTitle: removeDuplicateTitle,
    );
  }

  /// Layout chapter into pages
  Future<List<PageInfo>> layoutChapter(
    String bookId,
    int chapterIndex, {
    required double width,
    required double height,
    required double fontSize,
    required double lineHeightMultiplier,
    required double paddingLeft,
    required double paddingTop,
    required double paddingRight,
    required double paddingBottom,
    String fontName = 'default',
  }) async {
    final rustPages = await rust_api.layoutChapter(
      bookId: bookId,
      chapterIndex: BigInt.from(chapterIndex),
      width: width,
      height: height,
      fontSize: fontSize,
      lineHeightMultiplier: lineHeightMultiplier,
      paddingLeft: paddingLeft,
      paddingTop: paddingTop,
      paddingRight: paddingRight,
      paddingBottom: paddingBottom,
      fontName: fontName,
    );

    return rustPages.map(_mapPage).toList();
  }

  /// Get specific page
  Future<PageInfo> getPage(
    String bookId,
    int chapterIndex,
    int pageIndex, {
    required double width,
    required double height,
    required double fontSize,
    required double lineHeightMultiplier,
    required double paddingLeft,
    required double paddingTop,
    required double paddingRight,
    required double paddingBottom,
    String fontName = 'default',
    double pageFillThreshold = 1.0,
  }) async {
    final rustPage = await rust_api.getPage(
      bookId: bookId,
      chapterIndex: BigInt.from(chapterIndex),
      pageIndex: BigInt.from(pageIndex),
      width: width,
      height: height,
      fontSize: fontSize,
      lineHeightMultiplier: lineHeightMultiplier,
      paddingLeft: paddingLeft,
      paddingTop: paddingTop,
      paddingRight: paddingRight,
      paddingBottom: paddingBottom,
      fontName: fontName,
      pageFillThreshold: pageFillThreshold,
    );

    return _mapPage(rustPage);
  }

  /// Get page count for a chapter
  Future<int> getPageCount(
    String bookId,
    int chapterIndex, {
    required double width,
    required double height,
    required double fontSize,
    required double lineHeightMultiplier,
    required double paddingLeft,
    required double paddingTop,
    required double paddingRight,
    required double paddingBottom,
    String fontName = 'default',
    double pageFillThreshold = 1.0,
  }) async {
    final count = await rust_api.getPageCount(
      bookId: bookId,
      chapterIndex: BigInt.from(chapterIndex),
      width: width,
      height: height,
      fontSize: fontSize,
      lineHeightMultiplier: lineHeightMultiplier,
      paddingLeft: paddingLeft,
      paddingTop: paddingTop,
      paddingRight: paddingRight,
      paddingBottom: paddingBottom,
      fontName: fontName,
      pageFillThreshold: pageFillThreshold,
    );

    return count.toInt();
  }

  /// Get specific page with content preprocessing (带内容预处理)
  ///
  /// [replaceRules] 用户自定义替换规则，随请求传入（即时生效）。
  /// [segmentRules] A35-L2: 用户自定义分段规则，随请求传入（即时生效）。
  /// [anchorCharOffset] 进度锚点：提供时返回包含该章内字符偏移的页，
  /// 用于设置变更后停留在原阅读位置。
  Future<PageInfo> getPageProcessed(
    String bookId,
    int chapterIndex,
    int pageIndex, {
    required double width,
    required double height,
    required double fontSize,
    required double lineHeightMultiplier,
    required double paddingLeft,
    required double paddingTop,
    required double paddingRight,
    required double paddingBottom,
    String fontName = 'default',
    required bool removeDuplicateTitle,
    required bool reSegment,
    required int chineseConvert, // 0=none, 1=s2t, 2=t2s
    List<ReplaceRuleItem> replaceRules = const [],
    List<SegmentRuleItem> segmentRules = const [],
    int? anchorCharOffset,
    double pageFillThreshold = 1.0,
    BigInt? paraFormatHash,
  }) async {
    final rustPage = await rust_api.getPageProcessed(
      bookId: bookId,
      chapterIndex: BigInt.from(chapterIndex),
      pageIndex: BigInt.from(pageIndex),
      width: width,
      height: height,
      fontSize: fontSize,
      lineHeightMultiplier: lineHeightMultiplier,
      paddingLeft: paddingLeft,
      paddingTop: paddingTop,
      paddingRight: paddingRight,
      paddingBottom: paddingBottom,
      fontName: fontName,
      removeDuplicateTitle: removeDuplicateTitle,
      reSegment: reSegment,
      chineseConvert: chineseConvert,
      replaceRules: replaceRules
          .map(
            (r) => rust_api.FfiReplaceRule(
              pattern: r.pattern,
              replacement: r.replacement,
              ruleType: r.isRegex ? 1 : 0, // 0=字符串, 1=正则, 2=JS
              enabled: r.enabled,
            ),
          )
          .toList(),
      segmentRules: segmentRules
          .map(
            (r) => rust_api.FfiSegmentRule(
              id: r.id,
              pattern: r.pattern,
              action: r.actionIndex,
              enabled: r.enabled,
              isBuiltin: r.isBuiltin,
              isRegex: r.isRegex,
            ),
          )
          .toList(),
      anchorCharOffset: anchorCharOffset == null
          ? null
          : BigInt.from(anchorCharOffset),
      pageFillThreshold: pageFillThreshold,
      paraFormatHash: paraFormatHash ?? BigInt.zero,
    );

    return _mapPage(rustPage);
  }

  /// Get page count with content preprocessing (带内容预处理的分页计数)
  Future<int> getPageCountProcessed(
    String bookId,
    int chapterIndex, {
    required double width,
    required double height,
    required double fontSize,
    required double lineHeightMultiplier,
    required double paddingLeft,
    required double paddingTop,
    required double paddingRight,
    required double paddingBottom,
    String fontName = 'default',
    required bool removeDuplicateTitle,
    required bool reSegment,
    required int chineseConvert, // 0=none, 1=s2t, 2=t2s
    List<ReplaceRuleItem> replaceRules = const [],
    List<SegmentRuleItem> segmentRules = const [],
    double pageFillThreshold = 1.0,
    BigInt? paraFormatHash,
  }) async {
    final count = await rust_api.getPageCountProcessed(
      bookId: bookId,
      chapterIndex: BigInt.from(chapterIndex),
      width: width,
      height: height,
      fontSize: fontSize,
      lineHeightMultiplier: lineHeightMultiplier,
      paddingLeft: paddingLeft,
      paddingTop: paddingTop,
      paddingRight: paddingRight,
      paddingBottom: paddingBottom,
      fontName: fontName,
      removeDuplicateTitle: removeDuplicateTitle,
      reSegment: reSegment,
      chineseConvert: chineseConvert,
      replaceRules: replaceRules
          .map(
            (r) => rust_api.FfiReplaceRule(
              pattern: r.pattern,
              replacement: r.replacement,
              ruleType: r.isRegex ? 1 : 0, // 0=字符串, 1=正则, 2=JS
              enabled: r.enabled,
            ),
          )
          .toList(),
      segmentRules: segmentRules
          .map(
            (r) => rust_api.FfiSegmentRule(
              id: r.id,
              pattern: r.pattern,
              action: r.actionIndex,
              enabled: r.enabled,
              isBuiltin: r.isBuiltin,
              isRegex: r.isRegex,
            ),
          )
          .toList(),
      pageFillThreshold: pageFillThreshold,
      paraFormatHash: paraFormatHash ?? BigInt.zero,
    );

    return count.toInt();
  }

  /// A30d：批量定位笔记锚点 → 每个 offset 对应的页索引（0-based）。
  ///
  /// 参数与 [getPageCountProcessed] 同口径；空 offsets 直接返回空列表。
  Future<List<int>> batchLocateNotes(
    String bookId,
    int chapterIndex, {
    required List<int> offsets,
    required double width,
    required double height,
    required double fontSize,
    required double lineHeightMultiplier,
    required double paddingLeft,
    required double paddingTop,
    required double paddingRight,
    required double paddingBottom,
    String fontName = 'default',
    required bool removeDuplicateTitle,
    required int chineseConvert,
    List<ReplaceRuleItem> replaceRules = const [],
    double pageFillThreshold = 1.0,
    bool showComments = true,
  }) async {
    if (offsets.isEmpty) return const [];
    // flutter_rust_bridge 的 Uint64List 与 dart:typed_data 不同源
    final pages = await rust_api.batchLocateNotes(
      bookId: bookId,
      chapterIndex: BigInt.from(chapterIndex),
      offsets: frb.Uint64List.fromList(offsets),
      width: width,
      height: height,
      fontSize: fontSize,
      lineHeightMultiplier: lineHeightMultiplier,
      paddingLeft: paddingLeft,
      paddingTop: paddingTop,
      paddingRight: paddingRight,
      paddingBottom: paddingBottom,
      fontName: fontName,
      chineseConvert: chineseConvert,
      pageFillThreshold: pageFillThreshold,
      showComments: showComments,
      removeDuplicateTitle: removeDuplicateTitle,
      replaceRules: replaceRules
          .map(
            (r) => rust_api.FfiReplaceRule(
              pattern: r.pattern,
              replacement: r.replacement,
              ruleType: r.isRegex ? 1 : 0,
              enabled: r.enabled,
            ),
          )
          .toList(),
    );
    return pages.map((e) => e.toInt()).toList();
  }

  /// Release book from memory
  Future<void> releaseBook(String bookId) async {
    await rust_api.releaseBook(bookId: bookId);
  }

  /// A30：书内全文搜索（单次异步 FFI，全书扫描/匹配全在 Rust 线程池执行，
  /// UI 线程零参与）。命中词自动叠加双向简繁变体；超时/命中上限由 Rust
  /// 内置预算控制。
  ///
  /// [replaceRules] 与当前阅读设置同口径传入（TXT 预处理应用，EPUB 与
  /// 展示一致不应用）。
  /// [segmentRules] A35-L2: 分段规则与展示同口径。
  Future<List<SearchHit>> searchInBook(
    String bookId,
    String query, {
    required bool removeDuplicateTitle,
    required bool reSegment,
    required int chineseConvert, // 0=none, 1=s2t, 2=t2s
    List<ReplaceRuleItem> replaceRules = const [],
    List<SegmentRuleItem> segmentRules = const [],
    int maxHits = 200,
  }) async {
    final hits = await rust_api.searchInBook(
      bookId: bookId,
      query: query,
      removeDuplicateTitle: removeDuplicateTitle,
      reSegment: reSegment,
      chineseConvert: chineseConvert,
      replaceRules: replaceRules
          .map(
            (r) => rust_api.FfiReplaceRule(
              pattern: r.pattern,
              replacement: r.replacement,
              ruleType: r.isRegex ? 1 : 0,
              enabled: r.enabled,
            ),
          )
          .toList(),
      segmentRules: segmentRules
          .map(
            (r) => rust_api.FfiSegmentRule(
              id: r.id,
              pattern: r.pattern,
              action: r.actionIndex,
              enabled: r.enabled,
              isBuiltin: r.isBuiltin,
              isRegex: r.isRegex,
            ),
          )
          .toList(),
      maxHits: BigInt.from(maxHits),
    );
    return hits
        .map(
          (h) => SearchHit(
            chapterIndex: h.chapterIndex.toInt(),
            anchorCharOffset: h.anchorCharOffset.toInt(),
            excerpt: h.excerpt,
            matchOffsetInExcerpt: h.matchOffsetInExcerpt.toInt(),
          ),
        )
        .toList();
  }

  /// ReplaceRuleItem → FfiReplaceRule 统一转换（rule_type: 0=字符串 1=正则；
  /// A30b 起 EPUB 结构化路径也消费规则，转换收敛到单点）
  List<rust_api.FfiReplaceRule> _toFfiRules(List<ReplaceRuleItem> rules) =>
      rules
          .map(
            (r) => rust_api.FfiReplaceRule(
              pattern: r.pattern,
              replacement: r.replacement,
              ruleType: r.isRegex ? 1 : 0,
              enabled: r.enabled,
            ),
          )
          .toList();

  // ===== 结构化阅读路径（EPUB 路线2） =====

  /// 书籍格式标记（"epub" | "txt"），Dart 据此分流分页 API
  Future<String> getBookFormat(String bookId) async {
    return await rust_api.getBookFormat(bookId: bookId);
  }

  /// rust PageInfo → Dart PageInfo 的统一映射（文本/图片项 + 背景）
  PageInfo _mapPage(rust_types.PageInfo page) {
    return PageInfo(
      pageIndex: page.pageIndex.toInt(),
      chapterIndex: page.chapterIndex.toInt(),
      entries: page.entries
          .map(
            (e) => PageEntry(
              text: e.text,
              resourceHref: e.resourceHref,
              x: e.x,
              y: e.y,
              width: e.width,
              height: e.height,
              color: e.color,
              fontScale: e.fontScale,
              segments: e.segments
                  .map(
                    (s) => EntrySegment(
                      start: s.start.toInt(),
                      end: s.end.toInt(),
                      color: s.color,
                      backgroundColor: s.backgroundColor,
                      fontScale: s.fontScale,
                      bold: s.bold,
                      italic: s.italic,
                      underline: s.underline,
                      letterSpacing: s.letterSpacing,
                    ),
                  )
                  .toList(),
              isChapterStart: e.isChapterStart,
              isTableFrame: e.isTableFrame,
              isComment: e.isComment,
              letterGap: e.letterGap,
              startCharIndex: e.startCharIndex.toInt(),
              endCharIndex: e.endCharIndex.toInt(),
            ),
          )
          .toList(),
      backgroundHref: page.backgroundHref,
      backgroundSize: page.backgroundSize,
      backgroundPosition: page.backgroundPosition,
      startCharIndex: page.startCharIndex.toInt(),
      endCharIndex: page.endCharIndex.toInt(),
    );
  }

  /// 结构化分页获取（EPUB）
  ///
  /// [anchorCharOffset] 进度锚点：章内文本字符偏移，图片项不消耗锚点；
  /// 提供时返回包含该偏移的页（自动跳过纯图装饰页）。
  /// [chineseConvert] 阅读级简繁转换：0=无 1=简→繁 2=繁→简（与 TXT 同编码）
  Future<PageInfo> getPageStructured(
    String bookId,
    int chapterIndex,
    int pageIndex, {
    required double width,
    required double height,
    required double fontSize,
    required double lineHeightMultiplier,
    required double paddingLeft,
    required double paddingTop,
    required double paddingRight,
    required double paddingBottom,
    String fontName = 'default',
    int? anchorCharOffset,
    int chineseConvert = 0,
    double pageFillThreshold = 1.0,
    bool showComments = true,
    BigInt? paraFormatHash,
    bool removeDuplicateTitle = false,
    List<ReplaceRuleItem> replaceRules = const [],
  }) async {
    final rustPage = await rust_api.getPageStructured(
      bookId: bookId,
      chapterIndex: BigInt.from(chapterIndex),
      pageIndex: BigInt.from(pageIndex),
      width: width,
      height: height,
      fontSize: fontSize,
      lineHeightMultiplier: lineHeightMultiplier,
      paddingLeft: paddingLeft,
      paddingTop: paddingTop,
      paddingRight: paddingRight,
      paddingBottom: paddingBottom,
      fontName: fontName,
      anchorCharOffset: anchorCharOffset == null
          ? null
          : BigInt.from(anchorCharOffset),
      chineseConvert: chineseConvert,
      pageFillThreshold: pageFillThreshold,
      showComments: showComments,
      paraFormatHash: paraFormatHash ?? BigInt.zero,
      removeDuplicateTitle: removeDuplicateTitle,
      replaceRules: _toFfiRules(replaceRules),
    );
    return _mapPage(rustPage);
  }

  /// 结构化分页计数（EPUB）
  Future<int> getPageCountStructured(
    String bookId,
    int chapterIndex, {
    required double width,
    required double height,
    required double fontSize,
    required double lineHeightMultiplier,
    required double paddingLeft,
    required double paddingTop,
    required double paddingRight,
    required double paddingBottom,
    String fontName = 'default',
    int chineseConvert = 0,
    double pageFillThreshold = 1.0,
    bool showComments = true,
    BigInt? paraFormatHash,
    bool removeDuplicateTitle = false,
    List<ReplaceRuleItem> replaceRules = const [],
  }) async {
    final count = await rust_api.getPageCountStructured(
      bookId: bookId,
      chapterIndex: BigInt.from(chapterIndex),
      width: width,
      height: height,
      fontSize: fontSize,
      lineHeightMultiplier: lineHeightMultiplier,
      paddingLeft: paddingLeft,
      paddingTop: paddingTop,
      paddingRight: paddingRight,
      paddingBottom: paddingBottom,
      fontName: fontName,
      chineseConvert: chineseConvert,
      pageFillThreshold: pageFillThreshold,
      showComments: showComments,
      paraFormatHash: paraFormatHash ?? BigInt.zero,
      removeDuplicateTitle: removeDuplicateTitle,
      replaceRules: _toFfiRules(replaceRules),
    );
    return count.toInt();
  }

  /// EPUB 翻章预取：预计算目标章分页写入缓存（幂等；前台占用写锁时让路）。
  ///
  /// ⚠ 参数必须与 getPageStructured/getPageCountStructured 完全一致
  /// （f32 按 bits 入缓存键），否则入键错位、预取无效。
  /// 返回 true=已入缓存（含本就命中），false=前台忙被跳过。
  Future<bool> prefetchStructuredChapter(
    String bookId,
    int chapterIndex, {
    required double width,
    required double height,
    required double fontSize,
    required double lineHeightMultiplier,
    required double paddingLeft,
    required double paddingTop,
    required double paddingRight,
    required double paddingBottom,
    String fontName = 'default',
    int chineseConvert = 0,
    double pageFillThreshold = 1.0,
    bool showComments = true,
    BigInt? paraFormatHash,
    bool removeDuplicateTitle = false,
    List<ReplaceRuleItem> replaceRules = const [],
  }) async {
    return await rust_api.prefetchStructuredChapter(
      bookId: bookId,
      chapterIndex: BigInt.from(chapterIndex),
      width: width,
      height: height,
      fontSize: fontSize,
      lineHeightMultiplier: lineHeightMultiplier,
      paddingLeft: paddingLeft,
      paddingTop: paddingTop,
      paddingRight: paddingRight,
      paddingBottom: paddingBottom,
      fontName: fontName,
      chineseConvert: chineseConvert,
      pageFillThreshold: pageFillThreshold,
      showComments: showComments,
      paraFormatHash: paraFormatHash ?? BigInt.zero,
      removeDuplicateTitle: removeDuplicateTitle,
      replaceRules: _toFfiRules(replaceRules),
    );
  }

  /// 读取书内资源字节（EPUB 图片；ZIP 全路径与 IR resourceHref 同基准）
  Future<Uint8List> getBookResource(String bookId, String resourceHref) async {
    return await rust_api.getBookResource(
      bookId: bookId,
      resourceHref: resourceHref,
    );
  }

  /// 读取书封面字节（空返回=无封面）
  Future<Uint8List> getBookCover(String bookId) async {
    return await rust_api.getBookCover(bookId: bookId);
  }

  /// Set content cleaning options (设置内容净化选项，供非 parser 路径使用)
  Future<void> setContentCleaningOptions({
    required bool removeHtmlTags,
    required bool removeAds,
    required bool smartParagraph,
    required bool traditionalized,
    required bool simplified,
  }) async {
    final options = buildCleaningOptions(
      removeHtmlTags: removeHtmlTags,
      removeAds: removeAds,
      smartParagraph: smartParagraph,
      traditionalized: traditionalized,
      simplified: simplified,
    );
    await rust_api.setContentCleaningOptions(options: options);
  }

  /// Clear content cleaning options (清除内容净化选项)
  Future<void> clearContentCleaningOptions() async {
    await rust_api.clearContentCleaningOptions();
  }

  /// M9-P4：设置全局段落格式化参数（缩进/段间距/重新分段/切分阈值）
  ///
  /// Dart 侧调用：用户在设置 UI 修改段落格式时通过此方法同步 Rust 全局
  /// 设置，随后 FFI 分页调用自动应用。配合 paraFormatHash 作为缓存键。
  Future<void> setParagraphFormatSettings({
    required bool enableIndent,
    required int indentSizeChars,
    required double paragraphSpacingMultiplier,
    required int reParagraphMode,
    required int smartSplitThreshold,
    required int aggressiveSplitThreshold,
    required bool justify,
    required bool punctuationCompress,
  }) async {
    await rust_api.setParagraphFormatSettings(
      enableIndent: enableIndent,
      indentSizeChars: indentSizeChars,
      paragraphSpacingMultiplier: paragraphSpacingMultiplier,
      reParagraphMode: reParagraphMode,
      smartSplitThreshold: smartSplitThreshold,
      aggressiveSplitThreshold: aggressiveSplitThreshold,
      justify: justify,
      punctuationCompress: punctuationCompress,
    );
  }

  /// Get default content cleaning options (获取默认净化选项)
  Future<rust_api.ContentCleaningOptions> getDefaultCleaningOptions() async {
    return await rust_api.ContentCleaningOptions.default_();
  }
}

/// 源路径 → 封面缓存文件（FNV-1a 命名，跨启动稳定；无缓存返回 null）
File? cachedCoverFor(String sourcePath) {
  final file = coverCacheFile(sourcePath);
  return file.existsSync() ? file : null;
}

/// 封面缓存文件路径（{temp}/legado_covers/{fnv1a}.img）
File coverCacheFile(String sourcePath) {
  var hash = 0x811c9dc5;
  for (final unit in sourcePath.codeUnits) {
    hash ^= unit & 0xff;
    hash = (hash * 0x01000193) & 0xffffffff;
    hash ^= (unit >> 8) & 0xff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return File(
    '${Directory.systemTemp.path}/legado_covers/${hash.toRadixString(16)}.img',
  );
}

/// 打开 EPUB 书时提取封面并落盘（书架跨启动显示；失败静默）
Future<void> persistBookCover(
  BookService service,
  String bookId,
  String sourcePath,
) async {
  try {
    final bytes = await service.getBookCover(bookId);
    if (bytes.isEmpty) return;
    final file = coverCacheFile(sourcePath);
    if (file.existsSync()) return;
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  } catch (_) {
    // 封面持久化失败不影响阅读
  }
}
