import 'package:flutter/painting.dart';
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

  group('fitContent 内容框适配', () {
    test('内容框贴合宽度时缩放大于 contain', () {
      const dest = Rect.fromLTWH(0, 0, 1080, 2400);
      const content = Rect.fromLTWH(157, 0, 1570 * 0.8, 2480.0);
      final f = PaperTint.fitContent(dest, 1570, 2480, content);
      final containS = 1080 / (1570 * 0.8);
      final s = f.width / 1570;
      expect(s, greaterThan(1080 / 1570)); // 大于整图 contain
      expect(s, greaterThanOrEqualTo(containS * 0.55)); // 有抬升
    });

    test('fillBoost=0 时内容框宽度贴合 dest（整图框更大）', () {
      const dest = Rect.fromLTWH(0, 0, 1080, 2400);
      const content = Rect.fromLTWH(157, 0, 1570 * 0.8, 2480.0);
      final f = PaperTint.fitContent(dest, 1570, 2480, content, 0);
      final contentW = f.width * (content.width / 1570);
      expect(contentW, closeTo(1080, 1.0));
    });

    test('横竖缩放比一致', () {
      const dest = Rect.fromLTWH(0, 0, 1080, 2400);
      const content = Rect.fromLTWH(157, 0, 1570 * 0.8, 2480.0);
      final f = PaperTint.fitContent(dest, 1570, 2480, content);
      expect(f.width / 1570, closeTo(f.height / 2480, 0.001));
    });

    test('无内容框时退化为限幅 cover', () {
      const dest = Rect.fromLTWH(0, 0, 1080, 2400);
      final f = PaperTint.fitContent(dest, 1570, 2480, null);
      expect(f.width, lessThanOrEqualTo(1080 * 1.12 + 0.5));
      expect(f.width / 1570, closeTo(f.height / 2480, 0.001));
    });
  });

  group('effectivePaperColor 明亮模式可见', () {
    test('近白纸色会加深（日间默认纸）', () {
      final p = PaperTint.effectivePaperColor(const Color(0xFFF5F1E8));
      expect(p.r, lessThan(0.92));
    });

    test('有色纸（护眼绿/夜色）原样', () {
      final green = const Color(0xFFC8DCC0);
      expect(PaperTint.effectivePaperColor(green), green);
      final dark = const Color(0xFF1E1E1E);
      expect(PaperTint.effectivePaperColor(dark), dark);
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
