// Simplified models without freezed for testing

/// 简繁转换方向
enum ChineseConvertType {
  none('不转换'),
  s2t('简转繁'),
  t2s('繁转简');

  final String label;
  const ChineseConvertType(this.label);
}

class Chapter {
  final String title;
  final int startPos;
  final int endPos;

  /// 章节层级：1=顶层（EPUB 嵌套目录；TXT 平铺恒为 1）
  final int level;

  /// 父章节索引（null=顶层）
  final int? parentIndex;

  const Chapter({
    required this.title,
    required this.startPos,
    required this.endPos,
    this.level = 1,
    this.parentIndex,
  });

  Chapter copyWith({
    String? title,
    int? startPos,
    int? endPos,
    int? level,
    int? Function()? parentIndex,
  }) {
    return Chapter(
      title: title ?? this.title,
      startPos: startPos ?? this.startPos,
      endPos: endPos ?? this.endPos,
      level: level ?? this.level,
      parentIndex: parentIndex != null ? parentIndex() : this.parentIndex,
    );
  }
}

class LineInfo {
  final String text;
  final double x;
  final double y;
  final double width;

  const LineInfo({
    required this.text,
    required this.x,
    required this.y,
    required this.width,
  });
}

/// 页面内容项：文本行或图片
///
/// 判别方式与 Rust 侧一致：[resourceHref] 非空即图片项，
/// 否则为文本项（[text] 必非空）。
class PageEntry {
  /// 文本行内容（图片项为 null）
  final String? text;

  /// 图片资源 ZIP 路径（文本项为 null；经 BookService.getBookResource 取字节）
  final String? resourceHref;
  final double x;
  final double y;
  final double width;
  final double height;

  /// 行级默认色（#rrggbb；null=主题默认色）
  final String? color;

  /// 行级字号倍率（null=1.0）
  final double? fontScale;

  /// 行内富文本分段（span 等样式覆盖；空=整行统一用行级样式）
  final List<EntrySegment> segments;

  /// 章节首行标记（TXT 强制分页；绘制端按粗体开关渲染标题加粗）
  final bool isChapterStart;

  /// 表格单元格线框矩形（x/y/width/height 为几何；绘制端描边不填充）
  final bool isTableFrame;

  /// 注释行标记（小号渲染；开关隐藏时 char_index 照常累计）
  final bool isComment;

  /// P2 两端对齐：行内字符间隙（px；0=左对齐/豁免行；绘制端转 letterSpacing）
  final double letterGap;

  /// A31: 本行章内字符区间 [startCharIndex, endCharIndex)（锚点口径）。
  /// 笔记/划线渲染与长按命中测试依赖；null 或 start>=end = 未知（表格行）不高亮
  final int? startCharIndex;
  final int? endCharIndex;

  const PageEntry({
    this.text,
    this.resourceHref,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.color,
    this.fontScale,
    this.segments = const [],
    this.isChapterStart = false,
    this.isTableFrame = false,
    this.isComment = false,
    this.letterGap = 0.0,
    this.startCharIndex,
    this.endCharIndex,
  });

  bool get isImage => resourceHref != null;

  /// A31: 行级字符区间是否可用于笔记渲染/命中
  bool get hasCharRange =>
      startCharIndex != null &&
      endCharIndex != null &&
      startCharIndex! < endCharIndex!;
}

/// 行内样式分段：`[start, end)` 字符区间的覆盖样式
/// （null 字段继承行级默认）
class EntrySegment {
  final int start;
  final int end;
  final String? color;

  /// A31-v6: 段级背景色（#AARRGGBB；笔记高亮用；null=无背景）
  final String? backgroundColor;

  final double? fontScale;

  /// 字形样式（绘制端按用户开关决定粗/斜是否应用；下划线恒应用）
  final bool bold;
  final bool italic;
  final bool underline;

  /// P2 justify 拉丁词保护（null=继承行级 letterGap；0=该区间不加间隙）
  final double? letterSpacing;

  /// A34：脚注引用目标 id（如 m1）；上标绘制 + 点按弹层
  final String? footnoteRef;

  const EntrySegment({
    required this.start,
    required this.end,
    this.color,
    this.backgroundColor,
    this.fontScale,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.letterSpacing,
    this.footnoteRef,
  });
}

class PageInfo {
  final int pageIndex;

  /// 章节索引；页面身份不能只依赖章节内 pageIndex。
  final int chapterIndex;
  final List<PageEntry> entries;

  /// 文本行视图（兼容便捷访问；图片项被过滤）
  Iterable<LineInfo> get lines sync* {
    for (final e in entries) {
      if (e.text != null) {
        yield LineInfo(text: e.text!, x: e.x, y: e.y, width: e.width);
      }
    }
  }

  /// 整页背景图 ZIP 路径（仅 EPUB 装饰页/卷首页；null=普通页）
  final String? backgroundHref;

  /// 背景缩放模式："cover" | "contain" | "stretch"（CSS background-size
  /// 物化；绘制严格按 CSS 语义——cover=等比铺满窗口、溢出按 position
  /// 锚点裁切）
  final String? backgroundSize;

  /// 背景位置关键字原文（"bottom center"/"left top"...），
  /// 决定 cover/contain 的锚点方位；null=居中
  final String? backgroundPosition;
  final int startCharIndex;
  final int endCharIndex;

  /// A34：章末脚注表（id → 正文；每页重复携带）
  final Map<String, String> footnotes;

  const PageInfo({
    required this.pageIndex,
    this.chapterIndex = 0,
    this.entries = const [],
    this.backgroundHref,
    this.backgroundSize,
    this.backgroundPosition,
    required this.startCharIndex,
    required this.endCharIndex,
    this.footnotes = const {},
  });
}

/// A30：书内全文搜索单条命中（Dart 友好模型，int 已从 FFI BigInt 转换）
class SearchHit {
  /// 命中所在章节
  final int chapterIndex;

  /// 章内字符锚点（与书签 charOffset 同机制，跳转直接复用）
  final int anchorCharOffset;

  /// 命中前后摘录（约 ±40 字符）
  final String excerpt;

  /// 命中词在摘录中的字符偏移（高亮用）
  final int matchOffsetInExcerpt;

  const SearchHit({
    required this.chapterIndex,
    required this.anchorCharOffset,
    required this.excerpt,
    required this.matchOffsetInExcerpt,
  });
}

class ReadingState {
  final String? bookId;

  /// 书籍文件路径（持久化身份键：进度/书签以此关联）
  final String? filePath;
  final String? bookTitle;
  final List<Chapter> chapters;
  final int currentChapterIndex;
  final int currentPageIndex;
  final PageInfo? currentPage;
  final bool isLoading;
  final String? error;

  const ReadingState({
    this.bookId,
    this.filePath,
    this.bookTitle,
    this.chapters = const [],
    this.currentChapterIndex = 0,
    this.currentPageIndex = 0,
    this.currentPage,
    this.isLoading = false,
    this.error,
  });

  ReadingState copyWith({
    String? bookId,
    String? filePath,
    String? bookTitle,
    List<Chapter>? chapters,
    int? currentChapterIndex,
    int? currentPageIndex,
    PageInfo? currentPage,
    bool? isLoading,
    String? error,
  }) {
    return ReadingState(
      bookId: bookId ?? this.bookId,
      filePath: filePath ?? this.filePath,
      bookTitle: bookTitle ?? this.bookTitle,
      chapters: chapters ?? this.chapters,
      currentChapterIndex: currentChapterIndex ?? this.currentChapterIndex,
      currentPageIndex: currentPageIndex ?? this.currentPageIndex,
      currentPage: currentPage ?? this.currentPage,
      isLoading: isLoading ?? this.isLoading,
      error: error ?? this.error,
    );
  }
}

/// 用户自定义替换规则（设置界面编辑，传入内容处理流水线）
class ReplaceRuleItem {
  final String pattern;
  final String replacement;
  final bool isRegex;
  final bool enabled;

  const ReplaceRuleItem({
    required this.pattern,
    required this.replacement,
    required this.isRegex,
    required this.enabled,
  });

  ReplaceRuleItem copyWith({
    String? pattern,
    String? replacement,
    bool? isRegex,
    bool? enabled,
  }) {
    return ReplaceRuleItem(
      pattern: pattern ?? this.pattern,
      replacement: replacement ?? this.replacement,
      isRegex: isRegex ?? this.isRegex,
      enabled: enabled ?? this.enabled,
    );
  }
}

/// A35-L2: 用户自定义分段规则（设置界面编辑，传入内容处理流水线）
///
/// 统一规则模型：内置规则 + 用户规则同模型。
/// [id] 规则标识（内置："builtin:quote_unclosed" 等；用户：任意字符串）
/// [pattern] 正则模式（kind=Regex 时使用；kind=Builtin 时忽略）
/// [action] 动作类型：0=ForceBreakAfter, 1=ForceBreakBefore, 2=KeepIndependent, 3=MergeWithPrev
/// [isBuiltin] 是否内置规则（UI 不可删除，仅可开关）
/// [isRegex] 是否正则规则
class SegmentRuleItem {
  final String id;
  final String pattern;
  final int action; // 0=ForceBreakAfter, 1=ForceBreakBefore, 2=KeepIndependent, 3=MergeWithPrev
  final bool enabled;
  final bool isBuiltin;
  final bool isRegex;

  const SegmentRuleItem({
    required this.id,
    this.pattern = '',
    required this.action,
    required this.enabled,
    this.isBuiltin = false,
    this.isRegex = false,
  });

  /// 动作类型索引（用于 FFI 传递）
  int get actionIndex => action;

  // ── 动作类型常量（与 Rust SegmentAction 对齐）──
  static const int actionForceBreakAfter = 0;
  static const int actionForceBreakBefore = 1;
  static const int actionKeepIndependent = 2;
  static const int actionMergeWithPrev = 3;

  /// 动作显示名
  static String actionLabel(int action) {
    switch (action) {
      case actionForceBreakAfter:
        return '行后分段';
      case actionForceBreakBefore:
        return '行前分段';
      case actionKeepIndependent:
        return '独立成段';
      case actionMergeWithPrev:
        return '强制合并';
      default:
        return '未知';
    }
  }

  /// 内置规则显示名（id → 中文名）
  static String builtinLabel(String id) {
    switch (id) {
      case 'builtin:quote_unclosed':
        return '引号吸附';
      case 'builtin:chapter_title':
        return '章节标题独立';
      case 'builtin:scene_separator':
        return '场景分隔符独立';
      case 'builtin:short_line_poem':
        return '诗词短行独立';
      default:
        return id;
    }
  }

  /// 内置规则默认集（Rust 侧缺省兜底同表；quote 吸附为算法核心）
  /// 语义：
  /// - quote_unclosed：引号未闭合时永不切分，跨行对话自动合并（吸附）
  /// - chapter_title：第X章/回/卷 等标题行独立成段
  /// - scene_separator：*** / --- 分隔行独立成段
  /// - short_line_poem：短行（<20字）独立成段（诗词书用，默认关）
  static const List<SegmentRuleItem> builtins = [
    SegmentRuleItem(
      id: 'builtin:quote_unclosed',
      action: actionMergeWithPrev,
      enabled: true,
      isBuiltin: true,
    ),
    SegmentRuleItem(
      id: 'builtin:chapter_title',
      action: actionKeepIndependent,
      enabled: true,
      isBuiltin: true,
    ),
    SegmentRuleItem(
      id: 'builtin:scene_separator',
      action: actionKeepIndependent,
      enabled: true,
      isBuiltin: true,
    ),
    SegmentRuleItem(
      id: 'builtin:short_line_poem',
      action: actionKeepIndependent,
      enabled: false,
      isBuiltin: true,
    ),
  ];

  SegmentRuleItem copyWith({
    String? id,
    String? pattern,
    int? action,
    bool? enabled,
    bool? isBuiltin,
    bool? isRegex,
  }) {
    return SegmentRuleItem(
      id: id ?? this.id,
      pattern: pattern ?? this.pattern,
      action: action ?? this.action,
      enabled: enabled ?? this.enabled,
      isBuiltin: isBuiltin ?? this.isBuiltin,
      isRegex: isRegex ?? this.isRegex,
    );
  }
}
