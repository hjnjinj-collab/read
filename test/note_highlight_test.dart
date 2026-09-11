import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/database/app_database.dart';
import 'package:legado_flutter/core/models/simple_models.dart' hide ReadingState;
import 'package:legado_flutter/features/reader/presentation/providers/reader_provider.dart';
import 'package:legado_flutter/features/reader/presentation/widgets/reader_page_widget.dart';

Note _note({
  int id = 1,
  int chapterIndex = 0,
  required int start,
  required int end,
  int colorIndex = 0,
}) {
  return Note(
    id: id,
    bookPath: '/book.txt',
    chapterIndex: chapterIndex,
    startCharOffset: start,
    endCharOffset: end,
    excerpt: 'excerpt',
    colorIndex: colorIndex,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );
}

PageInfo _pageWithEntry({
  int chapter = 0,
  int start = 0,
  int end = 20,
  String text = '他走进房间，看见桌上的信。',
  List<EntrySegment> segments = const [],
}) {
  return PageInfo(
    pageIndex: 0,
    chapterIndex: chapter,
    startCharIndex: start,
    endCharIndex: end,
    entries: [
      PageEntry(
        text: text,
        x: 0,
        y: 0,
        width: 200,
        height: 24,
        startCharIndex: start,
        endCharIndex: end,
        segments: segments,
      ),
    ],
  );
}

void main() {
  group('ReadingState.copyWith', () {
    test('保留 currentChapterNotes', () {
      final notes = [_note(start: 0, end: 5)];
      const base = ReadingState(currentChapterNotes: []);
      final next = base.copyWith(currentChapterNotes: notes);
      expect(next.currentChapterNotes, same(notes));
    });

    test('未传时沿用旧 notes', () {
      final notes = [_note(start: 0, end: 5)];
      final base = ReadingState(currentChapterNotes: notes);
      final next = base.copyWith(isLoading: true);
      expect(next.currentChapterNotes, same(notes));
    });
  });

  group('enrichPageWithNotes', () {
    test('按笔记区间注入 backgroundColor segments', () {
      final page = _pageWithEntry();
      final notes = [_note(start: 6, end: 12)];
      final enriched = enrichPageWithNotes(page, notes);
      final segs = enriched.entries.single.segments;
      expect(segs, isNotEmpty);
      final covered = segs.where((s) => s.backgroundColor != null).toList();
      expect(covered, isNotEmpty);
      expect(covered.first.backgroundColor, noteColorHex(0));
    });

    test('colorIndex=4 注入 underline 而非背景', () {
      final page = _pageWithEntry();
      final notes = [_note(start: 0, end: 4, colorIndex: 4)];
      final enriched = enrichPageWithNotes(page, notes);
      final segs = enriched.entries.single.segments;
      final underlineSegs = segs.where((s) => s.underline).toList();
      expect(underlineSegs, isNotEmpty);
      expect(underlineSegs.every((s) => s.backgroundColor == null), isTrue);
    });

    test('合并 EPUB 原有 segments 的粗体/颜色', () {
      final page = _pageWithEntry(segments: const [
        EntrySegment(start: 0, end: 20, bold: true, color: '#FF0000'),
      ]);
      final notes = [_note(start: 5, end: 8)];
      final enriched = enrichPageWithNotes(page, notes);
      final segs = enriched.entries.single.segments;
      expect(segs.every((s) => s.bold), isTrue);
      expect(segs.every((s) => s.color == '#FF0000'), isTrue);
      expect(segs.any((s) => s.backgroundColor != null), isTrue);
    });

    test('无重叠笔记时原样返回', () {
      final page = _pageWithEntry(chapter: 0, start: 0, end: 20);
      final notes = [_note(start: 100, end: 110)];
      final enriched = enrichPageWithNotes(page, notes);
      expect(identical(enriched, page), isTrue);
    });
  });

  group('PageContentRenderer hex 色', () {
    test('6 位与 8 位 AARRGGBB 均可解析', () {
      final six = PageContentRenderer.parseHexColorForTest('#FFD54F');
      final eight = PageContentRenderer.parseHexColorForTest('#66FFD54F');
      expect(six, const Color(0xFFFFD54F));
      expect(eight, const Color(0x66FFD54F));
    });
  });

  group('groupNotesByChapter', () {
    test('按章分组且保持组内顺序', () {
      final notes = [
        _note(id: 1, chapterIndex: 2, start: 10, end: 12),
        _note(id: 2, chapterIndex: 0, start: 1, end: 3),
        _note(id: 3, chapterIndex: 2, start: 40, end: 42),
      ];
      final g = groupNotesByChapter(notes);
      expect(g.keys.toSet(), {0, 2});
      expect(g[2]!.map((n) => n.id), [1, 3]);
      expect(g[0]!.single.id, 2);
    });
  });
}
