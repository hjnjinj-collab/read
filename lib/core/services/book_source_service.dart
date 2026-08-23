import 'dart:convert';
import '../ffi/rust_bridge.dart/api.dart' as api;
import '../ffi/rust_bridge.dart/lib.dart' show FfiBookSource;

/// 书源服务 - 封装 Rust 书源解析引擎的 FFI 调用
class BookSourceService {
  /// 从 JSON 加载书源
  /// 返回书源 URL 作为标识符
  static Future<String> loadBookSource(String sourceJson) async {
    return await api.loadBookSource(sourceJson: sourceJson);
  }

  /// 从 FfiBookSource 对象加载书源
  static Future<String> loadBookSourceFfi(FfiBookSource source) async {
    return await api.loadBookSourceFfi(source: source);
  }

  /// 获取书源 JSON
  static Future<String> getBookSourceJson(String sourceUrl) async {
    return await api.getBookSourceJson(sourceUrl: sourceUrl);
  }

  /// 搜索书籍
  /// 返回 JSON 数组字符串，需要手动解析
  static Future<String> searchBook(FfiBookSource source, String keyword) async {
    return await api.searchBook(source: source, keyword: keyword);
  }

  /// 搜索书籍（JSON 字符串版本）
  static Future<String> searchBookByJson(String sourceJson, String keyword) async {
    return await api.searchBookByJson(sourceJson: sourceJson, keyword: keyword);
  }

  /// 搜索书籍并解析为列表
  static Future<List<SearchBookItem>> searchBookParsed(
    FfiBookSource source,
    String keyword,
  ) async {
    final jsonStr = await searchBook(source, keyword);
    final List<dynamic> list = jsonDecode(jsonStr);
    return list.map((e) => SearchBookItem.fromJson(e)).toList();
  }

  /// 获取书籍信息
  static Future<String> getBookInfo(FfiBookSource source, String bookUrl) async {
    return await api.getBookInfo(source: source, bookUrl: bookUrl);
  }

  /// 获取书籍信息（JSON 字符串版本）
  static Future<String> getBookInfoByJson(String sourceJson, String bookUrl) async {
    return await api.getBookInfoByJson(sourceJson: sourceJson, bookUrl: bookUrl);
  }

  /// 获取书籍信息并解析
  static Future<BookInfo> getBookInfoParsed(
    FfiBookSource source,
    String bookUrl,
  ) async {
    final jsonStr = await getBookInfo(source, bookUrl);
    return BookInfo.fromJson(jsonDecode(jsonStr));
  }

  /// 获取章节目录
  static Future<String> getToc(FfiBookSource source, String tocUrl) async {
    return await api.getToc(source: source, tocUrl: tocUrl);
  }

  /// 获取章节目录（JSON 字符串版本）
  static Future<String> getTocByJson(String sourceJson, String tocUrl) async {
    return await api.getTocByJson(sourceJson: sourceJson, tocUrl: tocUrl);
  }

  /// 获取章节目录并解析
  static Future<List<ChapterInfoItem>> getTocParsed(
    FfiBookSource source,
    String tocUrl,
  ) async {
    final jsonStr = await getToc(source, tocUrl);
    final List<dynamic> list = jsonDecode(jsonStr);
    return list.map((e) => ChapterInfoItem.fromJson(e)).toList();
  }

  /// 获取章节正文
  static Future<String> getChapterContent(
    FfiBookSource source,
    String chapterUrl,
  ) async {
    return await api.getChapterContentFromSource(
      source: source,
      chapterUrl: chapterUrl,
    );
  }

  /// 获取章节正文（JSON 字符串版本）
  static Future<String> getChapterContentByJson(
    String sourceJson,
    String chapterUrl,
  ) async {
    return await api.getChapterContentFromSourceJson(
      sourceJson: sourceJson,
      chapterUrl: chapterUrl,
    );
  }

  /// 获取章节正文并解析
  static Future<ChapterContent> getChapterContentParsed(
    FfiBookSource source,
    String chapterUrl,
  ) async {
    final jsonStr = await getChapterContent(source, chapterUrl);
    return ChapterContent.fromJson(jsonDecode(jsonStr));
  }

  /// 列出所有书源
  /// 注意：FfiBookSource 是从 Rust 生成的类型，不支持 fromJson
  /// 这里返回 JSON 字符串，需要手动解析
  static Future<String> listBookSourcesJson() async {
    return await api.listBookSources();
  }

  /// 删除书源
  static Future<void> deleteBookSource(String sourceUrl) async {
    return await api.deleteBookSource(sourceUrl: sourceUrl);
  }

  /// 设置书源启用状态
  static Future<void> setBookSourceEnabled(String sourceUrl, bool enabled) async {
    return await api.setBookSourceEnabled(sourceUrl: sourceUrl, enabled: enabled);
  }
}

/// 搜索结果项
class SearchBookItem {
  final String name;
  final String author;
  final String kind;
  final String lastChapter;
  final String intro;
  final String coverUrl;
  final String bookUrl;
  final String sourceUrl;

  SearchBookItem({
    required this.name,
    required this.author,
    required this.kind,
    required this.lastChapter,
    required this.intro,
    required this.coverUrl,
    required this.bookUrl,
    required this.sourceUrl,
  });

  factory SearchBookItem.fromJson(Map<String, dynamic> json) {
    return SearchBookItem(
      name: json['name'] ?? '',
      author: json['author'] ?? '',
      kind: json['kind'] ?? '',
      lastChapter: json['last_chapter'] ?? '',
      intro: json['intro'] ?? '',
      coverUrl: json['cover_url'] ?? '',
      bookUrl: json['book_url'] ?? '',
      sourceUrl: json['source_url'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'author': author,
      'kind': kind,
      'last_chapter': lastChapter,
      'intro': intro,
      'cover_url': coverUrl,
      'book_url': bookUrl,
      'source_url': sourceUrl,
    };
  }
}

/// 书籍信息
class BookInfo {
  final String name;
  final String author;
  final String kind;
  final String lastChapter;
  final String intro;
  final String coverUrl;
  final String tocUrl;
  final String wordCount;

  BookInfo({
    required this.name,
    required this.author,
    required this.kind,
    required this.lastChapter,
    required this.intro,
    required this.coverUrl,
    required this.tocUrl,
    required this.wordCount,
  });

  factory BookInfo.fromJson(Map<String, dynamic> json) {
    return BookInfo(
      name: json['name'] ?? '',
      author: json['author'] ?? '',
      kind: json['kind'] ?? '',
      lastChapter: json['last_chapter'] ?? '',
      intro: json['intro'] ?? '',
      coverUrl: json['cover_url'] ?? '',
      tocUrl: json['toc_url'] ?? '',
      wordCount: json['word_count'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'author': author,
      'kind': kind,
      'last_chapter': lastChapter,
      'intro': intro,
      'cover_url': coverUrl,
      'toc_url': tocUrl,
      'word_count': wordCount,
    };
  }
}

/// 章节信息
class ChapterInfoItem {
  final String name;
  final String url;
  final bool isVip;
  final String updateTime;
  final bool isVolume;
  final int index;

  ChapterInfoItem({
    required this.name,
    required this.url,
    required this.isVip,
    required this.updateTime,
    required this.isVolume,
    required this.index,
  });

  factory ChapterInfoItem.fromJson(Map<String, dynamic> json) {
    return ChapterInfoItem(
      name: json['name'] ?? '',
      url: json['url'] ?? '',
      isVip: json['is_vip'] ?? false,
      updateTime: json['update_time'] ?? '',
      isVolume: json['is_volume'] ?? false,
      index: json['index'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'url': url,
      'is_vip': isVip,
      'update_time': updateTime,
      'is_volume': isVolume,
      'index': index,
    };
  }
}

/// 章节正文
class ChapterContent {
  final String content;
  final String? nextUrl;

  ChapterContent({
    required this.content,
    this.nextUrl,
  });

  factory ChapterContent.fromJson(Map<String, dynamic> json) {
    return ChapterContent(
      content: json['content'] ?? '',
      nextUrl: json['next_url'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'content': content,
      'next_url': nextUrl,
    };
  }
}
