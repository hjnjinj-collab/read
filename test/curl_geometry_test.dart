import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/features/reader/presentation/widgets/page_turn/curl_painter.dart';
import 'package:legado_flutter/features/reader/presentation/widgets/page_turn/page_turn_types.dart';

void main() {
  const page = Size(400, 800);

  group('calcCornerByTouch', () {
    // legado 语义：折角与触点同侧——从哪个角落起手就掀哪个角
    test('触点在左上区域 → 折角为左上角', () {
      final c = calcCornerByTouch(const Offset(50, 100), page);
      expect(c, const Offset(0, 0));
    });

    test('触点在右下区域 → 折角为右下角', () {
      final c = calcCornerByTouch(const Offset(300, 700), page);
      expect(c, const Offset(400, 800));
    });

    test('触点恰好在中线按左/上处理（≤ 判定）', () {
      final c = calcCornerByTouch(Offset(page.width / 2, 0), page);
      expect(c.dx, 0.0);
      expect(c.dy, 0.0);
    });
  });

  group('cornerForDirection', () {
    test('next → 右下角（抓右下往左翻）', () {
      expect(
        cornerForDirection(PageDirection.next, page),
        const Offset(400, 800),
      );
    });

    test('prev → 左下角', () {
      expect(
        cornerForDirection(PageDirection.prev, page),
        const Offset(0, 800),
      );
    });
  });

  group('lineIntersect', () {
    test('十字相交于 (5,5)', () {
      final p = lineIntersect(
        const Offset(0, 5), const Offset(10, 5), // 水平线 y=5
        const Offset(5, 0), const Offset(5, 10), // 垂直线 x=5
      );
      expect(p, isNotNull);
      expect(p!.dx, closeTo(5, 1e-6));
      expect(p.dy, closeTo(5, 1e-6));
    });

    test('平行线返回 null', () {
      final p = lineIntersect(
        const Offset(0, 0), const Offset(1, 0),
        const Offset(0, 1), const Offset(1, 1),
      );
      expect(p, isNull);
    });
  });

  group('bezierVertex', () {
    test('顶点 = (S + 2C + E)/4', () {
      final v = bezierVertex(
        const Offset(0, 0),
        const Offset(4, 4),
        const Offset(8, 0),
      );
      // x: (0+8+8)/4=4 ; y: (0+8+0)/4=2
      expect(v.dx, closeTo(4, 1e-6));
      expect(v.dy, closeTo(2, 1e-6));
    });
  });

  group('reflectionAboutCrease', () {
    // 取 2x2 线性部分（storage 列主序: [m00,m01,.., m10,m11,..]）
    List<List<double>> linear2x2(Matrix4 m) => [
          [m.storage[0], m.storage[4]],
          [m.storage[1], m.storage[5]],
        ];

    test('正交性 RᵀR = I（纯镜像零缩放——拉伸回归锁）', () {
      final m = linear2x2(reflectionAboutCrease(
        const Offset(100, 800),
        const Offset(400, 650),
      ));
      // 对角元素 ≈ 1
      expect(m[0][0] * m[0][0] + m[1][0] * m[1][0], closeTo(1, 1e-9));
      expect(m[0][1] * m[0][1] + m[1][1] * m[1][1], closeTo(1, 1e-9));
      // 列正交
      expect(m[0][0] * m[0][1] + m[1][0] * m[1][1], closeTo(0, 1e-9));
    });

    test('det = −1（镜像而非旋转）', () {
      final m = linear2x2(reflectionAboutCrease(
        const Offset(0, 0),
        const Offset(1, 1),
      ));
      final det = m[0][0] * m[1][1] - m[0][1] * m[1][0];
      expect(det, closeTo(-1, 1e-9));
    });

    test('折痕线上的点是不动点（方向向量经反射保持不变）', () {
      final a = const Offset(100, 800);
      final b = const Offset(400, 650);
      final m = reflectionAboutCrease(a, b);
      // 折痕方向向量 d 经线性部分变换后保持不变（线上方向是特征值 1 的特征向量）
      final d = b - a;
      final dx = m.storage[0] * d.dx + m.storage[4] * d.dy;
      final dy = m.storage[1] * d.dx + m.storage[5] * d.dy;
      expect(dx, closeTo(d.dx, 1e-9));
      expect(dy, closeTo(d.dy, 1e-9));
    });

    test('法向方向上的点被镜像到另一侧', () {
      // 折痕为 x 轴（a=(0,0), b=(10,0)）→ (3,5) 应映到 (3,−5)
      final m = reflectionAboutCrease(const Offset(0, 0), const Offset(10, 0));
      final x = m.storage[0] * 3 + m.storage[4] * 5;
      final y = m.storage[1] * 3 + m.storage[5] * 5;
      expect(x, closeTo(3, 1e-9));
      expect(y, closeTo(-5, 1e-9));
    });
  });

  group('calcCurlPoints', () {
    // next 翻页：角点固定右下 (400,800)，触点从右缘向左拖
    test('触点靠近右缘时折面几何收敛且有限', () {
      final p = calcCurlPoints(
        const Offset(360, 700),
        const Offset(400, 800),
        page,
      );
      expect(p.dis.isFinite, isTrue);
      for (final o in [
        p.ctrl1, p.ctrl2, p.start1, p.start2,
        p.end1, p.end2, p.vertex1, p.vertex2,
      ]) {
        expect(o.dx.isFinite && o.dy.isFinite, isTrue);
      }
    });

    test('ctrl1 在底边 (y=corner.y)，ctrl2 在右边 (x=corner.x)', () {
      final p = calcCurlPoints(
        const Offset(250, 500),
        const Offset(400, 800),
        page,
      );
      expect(p.ctrl1.dy, closeTo(800, 1e-6));
      expect(p.ctrl2.dx, closeTo(400, 1e-6));
      expect(p.start1.dy, closeTo(800, 1e-6));
      expect(p.start2.dx, closeTo(400, 1e-6));
    });

    test('start1 位于 ctrl1 与角点的中点外侧一半', () {
      final p = calcCurlPoints(
        const Offset(250, 500),
        const Offset(400, 800),
        page,
      );
      // start1.x = ctrl1.x − (corner.x−ctrl1.x)/2
      final expected =
          p.ctrl1.dx - (400 - p.ctrl1.dx) / 2;
      expect(p.start1.dx, closeTo(expected, 1e-6));
    });

    test('dis = 最终触点到角点距离（含回拉后重算的不变量）', () {
      final p = calcCurlPoints(
        const Offset(250, 500),
        const Offset(400, 800),
        page,
      );
      expect(
        p.dis,
        closeTo((p.touch - const Offset(400, 800)).distance, 1e-6),
      );
    });

    test('出界回拉：start1 出屏且触点在页内时收拢使 start1 回屏', () {
      // 极端触点使 start1 冲出左边界
      final p = calcCurlPoints(
        const Offset(30, 780),
        const Offset(400, 800),
        page,
      );
      // 回拉后 start1 应回到页内水平范围
      expect(p.start1.dx, greaterThanOrEqualTo(-0.5));
      expect(p.start1.dx, lessThanOrEqualTo(page.width + 0.5));
      // 全部几何有限
      expect(p.touch.dx.isFinite, isTrue);
      expect(p.touch.dy.isFinite, isTrue);
      expect(p.vertex2.dy.isFinite, isTrue);
    });

    test('分母趋零保护：触点贴近角点水平线不产生 NaN/Infinity', () {
      // my == corner.dy 使 safeDen 生效路径被触发
      final p = calcCurlPoints(
        const Offset(200, 800),
        const Offset(400, 800),
        page,
      );
      expect(p.ctrl1.dx.isFinite, isTrue);
      expect(p.end1.dx.isFinite, isTrue);
    });
  });
}
