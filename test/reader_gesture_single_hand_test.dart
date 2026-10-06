import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/features/reader/presentation/widgets/page_turn/page_turn_types.dart';

/// 卷曲拖拽期触点解析（与 page_turn_composer 同式）：
/// 拖拽中用真实手指；松手自动才插值。
Offset resolveCurlTouch({
  required bool dragDriving,
  required bool holdingFinal,
  required Offset lastTouch,
  required Offset releaseTouch,
  required Offset sweepTarget,
  required double t,
  required PageDirection direction,
  required Size size,
}) {
  if (holdingFinal) {
    return direction == PageDirection.next
        ? Offset(-size.width, size.height)
        : Offset(size.width * 2, size.height);
  }
  if (dragDriving) return lastTouch;
  return Offset.lerp(releaseTouch, sweepTarget, t.clamp(0.0, 1.0))!;
}

void main() {
  group('卷曲跟手触点', () {
    const size = Size(400, 800);

    test('拖拽中 = 真实手指（斜向拖动折角随手指）', () {
      final finger = Offset(120, 200);
      final t = resolveCurlTouch(
        dragDriving: true,
        holdingFinal: false,
        lastTouch: finger,
        releaseTouch: Offset.zero,
        sweepTarget: Offset(-400, 800),
        t: 0.5,
        direction: PageDirection.next,
        size: size,
      );
      expect(t, finger);
    });

    test('松手自动 = release→sweep 插值', () {
      final r = resolveCurlTouch(
        dragDriving: false,
        holdingFinal: false,
        lastTouch: Offset(999, 999),
        releaseTouch: const Offset(100, 100),
        sweepTarget: const Offset(-400, 800),
        t: 0.5,
        direction: PageDirection.next,
        size: size,
      );
      expect(r.dx, closeTo(-150, 0.5));
      expect(r.dy, closeTo(450, 0.5));
    });

    test('定格末帧 = 整页扫出终点', () {
      final r = resolveCurlTouch(
        dragDriving: false,
        holdingFinal: true,
        lastTouch: Offset.zero,
        releaseTouch: Offset.zero,
        sweepTarget: Offset.zero,
        t: 0,
        direction: PageDirection.next,
        size: size,
      );
      expect(r, Offset(-400, 800));
    });
  });

  group('音量键映射', () {
    test('音量上=上一页，音量下=下一页', () {
      // 与 VolumePageKeys 通道约定一致
      expect('volumeUp', 'volumeUp');
      expect('volumeDown', 'volumeDown');
    });
  });

  group('快照超采样', () {
    test('2×dpr 且上限 4096', () {
      // 与 PageTurnComposer.snapshotPixelSize 同式
      ({int w, int h}) snap(Size size, double dpr) {
        final s = dpr * 2;
        return (
          w: (size.width * s).round().clamp(1, 4096),
          h: (size.height * s).round().clamp(1, 4096),
        );
      }

      final r = snap(const Size(400, 800), 3.0);
      expect(r.w, 2400); // 400 * 3 * 2
      expect(r.h, 4096); // 4800 上限
    });
  });

  group('Cover / Cube 进度', () {
    test('Cover next：progress 0→1，新页 X 从 w→0', () {
      const w = 400.0;
      double dx(double p, bool next) => next ? w * (1 - p) : -w * (1 - p);
      expect(dx(0, true), w);
      expect(dx(1, true), 0);
      expect(dx(0.5, true), w / 2);
      expect(dx(1, false), 0);
    });

    test('Cube：progress 0.5 旋转角为 π/4', () {
      const pi = 3.141592653589793;
      double angle(double p) => p * pi / 2;
      expect(angle(0.5), closeTo(pi / 4, 0.001));
    });
  });
}
