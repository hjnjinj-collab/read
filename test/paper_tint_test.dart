import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/features/reader/presentation/services/paper_tint.dart';

void main() {
  group('PaperTint.paperTintAmount', () {
    test('纯白几乎全量映射到纸色', () {
      final t = PaperTint.paperTintAmount(1.0, thr: 0.90, str: 1.0);
      expect(t, greaterThan(0.95));
    });

    test('暗色/线稿不映射', () {
      final t = PaperTint.paperTintAmount(0.2, thr: 0.90, str: 1.0);
      expect(t, lessThan(0.05));
    });

    test('阈值附近平滑过渡', () {
      final below = PaperTint.paperTintAmount(0.82, thr: 0.90, str: 1.0);
      final mid = PaperTint.paperTintAmount(0.88, thr: 0.90, str: 1.0);
      final above = PaperTint.paperTintAmount(0.95, thr: 0.90, str: 1.0);
      expect(below, lessThan(mid));
      expect(mid, lessThan(above));
    });

    test('strength=0 不映射', () {
      final t = PaperTint.paperTintAmount(1.0, thr: 0.90, str: 0.0);
      expect(t, 0.0);
    });

    test('默认 active 受开关与书籍类型共同控制', () {
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
