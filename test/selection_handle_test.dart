import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/models/simple_models.dart';
import 'package:legado_flutter/features/reader/presentation/providers/reader_provider.dart';

PageInfo _twoLinePage() {
  // 两行文本：行0 [0,10)，行1 [10,20)
  return PageInfo(
    pageIndex: 0,
    chapterIndex: 0,
    startCharIndex: 0,
    endCharIndex: 20,
    entries: [
      PageEntry(
        text: '0123456789',
        x: 20,
        y: 100,
        width: 200,
        height: 24,
        startCharIndex: 0,
        endCharIndex: 10,
      ),
      PageEntry(
        text: 'abcdefghij',
        x: 20,
        y: 140,
        width: 200,
        height: 24,
        startCharIndex: 10,
        endCharIndex: 20,
      ),
    ],
  );
}

void main() {
  group('resolveSelectionStartDrag', () {
    test('拖 start 不重置 end', () {
      final (s, e) = resolveSelectionStartDrag(
        currentEnd: 12,
        charOffset: 3,
        pageEnd: 20,
      );
      expect(s, 3);
      expect(e, 12);
    });

    test('越过 end 时区间翻转且 end 随手指', () {
      final (s, e) = resolveSelectionStartDrag(
        currentEnd: 10,
        charOffset: 15,
        pageEnd: 20,
      );
      expect(s, 10);
      expect(e, 16);
    });

    test('charOffset 钳到页尾', () {
      final (s, e) = resolveSelectionStartDrag(
        currentEnd: 18,
        charOffset: 99,
        pageEnd: 20,
      );
      expect(s, 18);
      expect(e, 20);
    });
  });

  group('findEntryForHitTest', () {
    test('盒内命中本行', () {
      final page = _twoLinePage();
      final entry = findEntryForHitTest(const Offset(30, 110), page.entries);
      expect(entry, isNotNull);
      expect(entry!.startCharIndex, 0);
    });

    test('行间隙落到纵向更近的下一行', () {
      final page = _twoLinePage();
      // y=135 在行间隙且更靠近行1（行1 midY=152，行0 midY=112）
      final entry = findEntryForHitTest(const Offset(30, 135), page.entries);
      expect(entry, isNotNull);
      expect(entry!.startCharIndex, 10);
    });

    test('横向过远返回 null', () {
      final page = _twoLinePage();
      final entry = findEntryForHitTest(const Offset(400, 110), page.entries);
      expect(entry, isNull);
    });
  });
}
