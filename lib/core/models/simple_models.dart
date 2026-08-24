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
  });

  bool get isImage => resourceHref != null;
}

/// 行内样式分段：`[start, end)` 字符区间的覆盖样式
/// （null 字段继承行级默认）
class EntrySegment {
  final int start;
  final int end;
  final String? color;
  final double? fontScale;

  /// 字形样式（绘制端按用户开关决定粗/斜是否应用；下划线恒应用）
  final bool bold;
  final bool italic;
  final bool underline;

  const EntrySegment({
    required this.start,
    required this.end,
    this.color,
    this.fontScale,
    this.bold = false,
    this.italic = false,
    this.underline = false,
  });
}

class PageInfo {
  final int pageIndex;
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

  const PageInfo({
    required this.pageIndex,
    this.entries = const [],
    this.backgroundHref,
    this.backgroundSize,
    this.backgroundPosition,
    required this.startCharIndex,
    required this.endCharIndex,
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
