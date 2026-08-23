import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/services/book_source_service.dart';

void main() {
  group('SearchBookItem', () {
    test('should parse from JSON', () {
      final json = {
        'name': '测试书名',
        'author': '测试作者',
        'kind': '玄幻',
        'last_chapter': '第100章',
        'intro': '这是一本测试书',
        'cover_url': 'https://example.com/cover.jpg',
        'book_url': 'https://example.com/book/1',
        'source_url': 'https://example.com',
      };

      final item = SearchBookItem.fromJson(json);

      expect(item.name, '测试书名');
      expect(item.author, '测试作者');
      expect(item.kind, '玄幻');
      expect(item.lastChapter, '第100章');
      expect(item.intro, '这是一本测试书');
      expect(item.coverUrl, 'https://example.com/cover.jpg');
      expect(item.bookUrl, 'https://example.com/book/1');
      expect(item.sourceUrl, 'https://example.com');
    });

    test('should serialize and deserialize correctly', () {
      final item = SearchBookItem(
        name: '测试书名',
        author: '测试作者',
        kind: '玄幻',
        lastChapter: '第100章',
        intro: '这是一本测试书',
        coverUrl: 'https://example.com/cover.jpg',
        bookUrl: 'https://example.com/book/1',
        sourceUrl: 'https://example.com',
      );

      final json = item.toJson();
      final item2 = SearchBookItem.fromJson(json);

      expect(item.name, item2.name);
      expect(item.author, item2.author);
      expect(item.bookUrl, item2.bookUrl);
    });

    test('should handle empty strings', () {
      final json = {
        'name': '',
        'author': '',
        'kind': '',
        'last_chapter': '',
        'intro': '',
        'cover_url': '',
        'book_url': '',
        'source_url': '',
      };

      final item = SearchBookItem.fromJson(json);

      expect(item.name, '');
      expect(item.author, '');
      expect(item.bookUrl, '');
    });
  });

  group('BookInfo', () {
    test('should parse from JSON', () {
      final json = {
        'name': '测试书名',
        'author': '测试作者',
        'kind': '玄幻',
        'last_chapter': '第100章',
        'intro': '这是一本测试书',
        'cover_url': 'https://example.com/cover.jpg',
        'toc_url': 'https://example.com/toc',
        'word_count': '100000',
      };

      final info = BookInfo.fromJson(json);

      expect(info.name, '测试书名');
      expect(info.author, '测试作者');
      expect(info.tocUrl, 'https://example.com/toc');
      expect(info.wordCount, '100000');
    });

    test('should serialize and deserialize correctly', () {
      final info = BookInfo(
        name: '测试书名',
        author: '测试作者',
        kind: '玄幻',
        lastChapter: '第100章',
        intro: '这是一本测试书',
        coverUrl: 'https://example.com/cover.jpg',
        tocUrl: 'https://example.com/toc',
        wordCount: '100000',
      );

      final json = info.toJson();
      final info2 = BookInfo.fromJson(json);

      expect(info.name, info2.name);
      expect(info.author, info2.author);
      expect(info.tocUrl, info2.tocUrl);
      expect(info.wordCount, info2.wordCount);
    });
  });

  group('ChapterInfoItem', () {
    test('should parse from JSON', () {
      final json = {
        'name': '第1章 测试',
        'url': 'https://example.com/chapter/1',
        'is_vip': false,
        'update_time': '2024-01-01',
        'is_volume': false,
        'index': 0,
      };

      final chapter = ChapterInfoItem.fromJson(json);

      expect(chapter.name, '第1章 测试');
      expect(chapter.url, 'https://example.com/chapter/1');
      expect(chapter.isVip, false);
      expect(chapter.updateTime, '2024-01-01');
      expect(chapter.isVolume, false);
      expect(chapter.index, 0);
    });

    test('should handle VIP chapters', () {
      final json = {
        'name': 'VIP章节',
        'url': 'https://example.com/chapter/vip',
        'is_vip': true,
        'update_time': '2024-01-01',
        'is_volume': false,
        'index': 5,
      };

      final chapter = ChapterInfoItem.fromJson(json);

      expect(chapter.isVip, true);
      expect(chapter.index, 5);
    });

    test('should handle volume markers', () {
      final json = {
        'name': '第一卷',
        'url': '',
        'is_vip': false,
        'update_time': '',
        'is_volume': true,
        'index': 0,
      };

      final chapter = ChapterInfoItem.fromJson(json);

      expect(chapter.isVolume, true);
      expect(chapter.url, '');
    });
  });

  group('ChapterContent', () {
    test('should parse from JSON', () {
      final json = {
        'content': '这是章节正文内容',
        'next_url': 'https://example.com/chapter/2',
      };

      final content = ChapterContent.fromJson(json);

      expect(content.content, '这是章节正文内容');
      expect(content.nextUrl, 'https://example.com/chapter/2');
    });

    test('should handle null nextUrl', () {
      final json = {
        'content': '这是章节正文内容',
        'next_url': null,
      };

      final content = ChapterContent.fromJson(json);

      expect(content.content, '这是章节正文内容');
      expect(content.nextUrl, isNull);
    });

    test('should handle missing fields', () {
      final json = <String, dynamic>{
        'content': '测试内容',
      };

      final content = ChapterContent.fromJson(json);

      expect(content.content, '测试内容');
      expect(content.nextUrl, isNull);
    });

    test('should serialize correctly', () {
      final content = ChapterContent(
        content: '测试内容',
        nextUrl: 'https://example.com/next',
      );

      final json = content.toJson();

      expect(json['content'], '测试内容');
      expect(json['next_url'], 'https://example.com/next');
    });

    test('should serialize null nextUrl', () {
      final content = ChapterContent(
        content: '测试内容',
      );

      final json = content.toJson();

      expect(json['next_url'], isNull);
    });
  });

  group('BookSourceService', () {
    test('should have all required methods', () {
      // 验证所有静态方法都存在
      expect(BookSourceService.loadBookSource, isNotNull);
      expect(BookSourceService.loadBookSourceFfi, isNotNull);
      expect(BookSourceService.getBookSourceJson, isNotNull);
      expect(BookSourceService.searchBook, isNotNull);
      expect(BookSourceService.searchBookByJson, isNotNull);
      expect(BookSourceService.searchBookParsed, isNotNull);
      expect(BookSourceService.getBookInfo, isNotNull);
      expect(BookSourceService.getBookInfoByJson, isNotNull);
      expect(BookSourceService.getBookInfoParsed, isNotNull);
      expect(BookSourceService.getToc, isNotNull);
      expect(BookSourceService.getTocByJson, isNotNull);
      expect(BookSourceService.getTocParsed, isNotNull);
      expect(BookSourceService.getChapterContent, isNotNull);
      expect(BookSourceService.getChapterContentByJson, isNotNull);
      expect(BookSourceService.getChapterContentParsed, isNotNull);
      expect(BookSourceService.listBookSourcesJson, isNotNull);
      expect(BookSourceService.deleteBookSource, isNotNull);
      expect(BookSourceService.setBookSourceEnabled, isNotNull);
    });
  });
}
