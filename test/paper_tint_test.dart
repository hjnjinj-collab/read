import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/features/reader/presentation/services/paper_tint.dart';

void main() {
  group('漫画空白边：整行/整列白占比', () {
    test('整行白 → 空白边，改纸色', () {
      expect(PaperTint.blankBandAmount(1.0, 0.2), 1.0);
    });

    test('整列白（左右边）→ 空白边', () {
      expect(PaperTint.blankBandAmount(0.3, 1.0), 1.0);
    });

    test('有内容的行（白占比 0.8）不动 — 即使行里有白块', () {
      expect(PaperTint.blankBandAmount(0.80, 0.40), 0.0);
    });

    test('略低于阈值不整行改（0.95 < 0.97）', () {
      expect(PaperTint.blankBandAmount(0.95, 0.95), 0.0);
    });

    test('达到阈值（0.97）才当空白', () {
      expect(PaperTint.blankBandAmount(0.97, 0.5), 1.0);
    });

    test('近白：高亮度且低色度', () {
      expect(PaperTint.isNearWhite(0.95, 0.02), isTrue);
      expect(PaperTint.isNearWhite(0.85, 0.02), isFalse); // 不够白
      expect(PaperTint.isNearWhite(0.95, 0.25), isFalse); // 米白/淡彩
    });
  });

  group('PDF 文档重映射', () {
    test('低色度文档感高', () {
      expect(PaperTint.pdfDocAmount(0.02), greaterThan(0.9));
    });

    test('彩色插图不映射', () {
      expect(PaperTint.pdfDocAmount(0.35), lessThan(0.1));
    });

    test('纸白→1、墨黑→0、中间抬对比', () {
      expect(PaperTint.pdfMappedLuma(1.0), closeTo(1.0, 0.02));
      expect(PaperTint.pdfMappedLuma(0.0), closeTo(0.0, 0.02));
      expect(PaperTint.pdfMappedLuma(0.6), greaterThan(0.6));
      expect(PaperTint.pdfMappedLuma(0.4), lessThan(0.4));
    });
  });

  group('门控', () {
    test('active = enabled × imagesNeedTint', () {
      PaperTint.enabled = true;
      PaperTint.imagesNeedTint = true;
      expect(PaperTint.active, isTrue);
      PaperTint.enabled = false;
      expect(PaperTint.active, isFalse);
      PaperTint.enabled = true;
      PaperTint.imagesNeedTint = false;
      expect(PaperTint.active, isFalse);
    });
  });
}
