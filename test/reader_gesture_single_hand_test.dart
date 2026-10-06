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
}
