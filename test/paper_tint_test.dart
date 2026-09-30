import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/features/reader/presentation/services/paper_tint.dart';

void main() {
  group('PaperTint.comicTintAmount（漫画边缘留白）', () {
    test('图边纯白 → 接近全量映射', () {
      final t = PaperTint.comicTintAmount(1.0, 0.0, 0.0);
      expect(t, greaterThan(0.9));
    });

    test('图内纯白（edge=0.3）不动 — 防止误伤白底', () {
      final t = PaperTint.comicTintAmount(1.0, 0.0, 0.30);
      expect(t, lessThan(0.05));
    });

    test('图边淡彩/米白（chroma 高）不动', () {
      final t = PaperTint.comicTintAmount(0.96, 0.20, 0.0);
      expect(t, lessThan(0.15));
    });

    test('图边线稿黑不动', () {
      final t = PaperTint.comicTintAmount(0.15, 0.0, 0.0);
      expect(t, lessThan(0.05));
    });

    test('从边缘到内容区平滑衰减', () {
      final edge = PaperTint.comicTintAmount(1.0, 0.0, 0.02);
      final mid = PaperTint.comicTintAmount(1.0, 0.0, 0.10);
      final inside = PaperTint.comicTintAmount(1.0, 0.0, 0.25);
      expect(edge, greaterThan(mid));
      expect(mid, greaterThan(inside));
    });
  });

  group('PaperTint.pdf 文档重映射', () {
    test('低色度文档感高', () {
      expect(PaperTint.pdfDocAmount(0.02), greaterThan(0.9));
    });

    test('彩色插图不映射', () {
      expect(PaperTint.pdfDocAmount(0.35), lessThan(0.1));
    });

    test('纸白映射到 1（纸端），墨黑到 0（墨端），中间抬对比', () {
      expect(PaperTint.pdfMappedLuma(1.0), closeTo(1.0, 0.02));
      expect(PaperTint.pdfMappedLuma(0.0), closeTo(0.0, 0.02));
      // 0.5 仍在中点；略偏亮的灰经对比提升会略变亮
      expect(PaperTint.pdfMappedLuma(0.6), greaterThan(0.6));
      expect(PaperTint.pdfMappedLuma(0.4), lessThan(0.4));
    });
  });

  group('门控', () {
    test('active 受开关与书籍类型共同控制', () {
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
