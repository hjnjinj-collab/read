import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../../core/models/simple_models.dart';
import 'page_turn_types.dart';

// ══════════════════════════════════════════════════════════════
// 卷曲几何（纯函数，可单测）
//
// 移植自 legado Android `SimulationPageDelegate.calcPoints`
// （L520-597）与 `getCross`（L602-612）。
// 坐标系：y 向下，与 Android/Flutter 一致。
// ══════════════════════════════════════════════════════════════

/// calcPoints 的全部结果点
class CurlPoints {
  final Offset touch; // T（出界回拉后）
  final Offset corner; // C
  final Offset ctrl1;
  final Offset ctrl2;
  final Offset start1;
  final Offset start2;
  final Offset end1;
  final Offset end2;
  final Offset vertex1; // 贝塞尔顶点近似 (S+2·Ctrl+E)/4
  final Offset vertex2;
  final double dis; // touchToCornerDis

  const CurlPoints({
    required this.touch,
    required this.corner,
    required this.ctrl1,
    required this.ctrl2,
    required this.start1,
    required this.start2,
    required this.end1,
    required this.end2,
    required this.vertex1,
    required this.vertex2,
    required this.dis,
  });
}

/// 折角选择：与触点同侧的页角（legado calcCornerXY 语义——
/// 从哪个角落起手就掀起哪个角）
Offset calcCornerByTouch(Offset touch, Size page) {
  final cx = touch.dx <= page.width / 2 ? 0.0 : page.width;
  final cy = touch.dy <= page.height / 2 ? 0.0 : page.height;
  return Offset(cx, cy);
}

/// 按翻页方向固定折角：next=右下角（抓右下往左翻），prev=左下角
Offset cornerForDirection(PageDirection direction, Size page) {
  if (direction == PageDirection.prev) return Offset(0, page.height);
  return Offset(page.width, page.height);
}

/// 两直线交点（参数式，垂直线安全；近平行返回 null）
Offset? lineIntersect(Offset p1, Offset p2, Offset p3, Offset p4) {
  final d1 = p2 - p1;
  final d2 = p4 - p3;
  final denom = d1.dx * d2.dy - d1.dy * d2.dx;
  if (denom.abs() < 1e-9) return null;
  final t = ((p3.dx - p1.dx) * d2.dy - (p3.dy - p1.dy) * d2.dx) / denom;
  return p1 + d1 * t;
}

/// 二次贝塞尔顶点近似：(S + 2·Ctrl + E)/4
Offset bezierVertex(Offset s, Offset ctrl, Offset e) => Offset(
      (s.dx + 2 * ctrl.dx + e.dx) / 4,
      (s.dy + 2 * ctrl.dy + e.dy) / 4,
    );

/// 过点 [a]、沿 [a]→[b] 方向直线的平面反射矩阵
///
/// R = I − 2n̂n̂ᵀ，n̂ 为直线的**单位**法向量（方向向量旋转 90°）。
/// 正交矩阵（纯镜像、零缩放），det = −1，直线上的点为不动点。
/// 用于把当前页内容沿折痕线镜像出纸张背面。
Matrix4 reflectionAboutCrease(Offset a, Offset b) {
  final d = b - a;
  final len = d.distance == 0 ? 0.001 : d.distance;
  final nx = -d.dy / len;
  final ny = d.dx / len;
  return Matrix4.fromList([
    1 - 2 * nx * nx, -2 * nx * ny, 0, 0, //
    -2 * nx * ny, 1 - 2 * ny * ny, 0, 0, //
    0, 0, 1, 0, //
    0, 0, 0, 1,
  ]);
}

/// 真实折叠轴镜像矩阵（含枢轴平移，纯函数可单测）
///
/// 轴 = 触点-角点垂直平分线：ctrl1 到角点/触点等距
/// （|ctrl1−corner|² = |ctrl1−touch|² 可证），故「过 ctrl1 且垂直于
/// corner−touch」的直线即垂直平分线。对齐 legado drawCurrentBackArea
/// 的 mMatrixArray(f8,f9) + pre/postTranslate(ctrl1)——折缝为轴上
/// 不动点，正/背面内容在折缝处像素连续（用 start1→start2 做轴会
/// 横向偏移 (corner.x−ctrl1.x)/2，镜面内容与折缝不衔接）。
/// 方向取 ⊥(corner−touch) 而非 ctrl1→mid：横扫终点 (-w,h) 处
/// ctrl1 与中点重合，后者零向量退化。
Matrix4 foldMirrorMatrix(CurlPoints p) {
  final dx = p.corner.dx - p.touch.dx;
  final dy = p.corner.dy - p.touch.dy;
  final axisEnd = Offset(p.ctrl1.dx - dy, p.ctrl1.dy + dx);
  final r = reflectionAboutCrease(p.ctrl1, axisEnd);
  return Matrix4.identity()
    ..translateByDouble(p.ctrl1.dx, p.ctrl1.dy, 0, 1)
    ..multiply(r)
    ..translateByDouble(-p.ctrl1.dx, -p.ctrl1.dy, 0, 1);
}

/// 主几何计算——legado calcPoints 移植
///
/// 含「start1 出屏时按相似三角形把触点拉回屏内再重算」的兜底。
CurlPoints calcCurlPoints(Offset touchIn, Offset corner, Size page) {
  var touch = touchIn;

  CurlPoints compute(Offset t) {
    final mx = (t.dx + corner.dx) / 2;
    final my = (t.dy + corner.dy) / 2;

    // 分母趋零保护：保留符号、钳到 ±0.01（对齐 legado 的 0.1f 最小值思路）
    double safeDen(double d) =>
        d.abs() < 0.01 ? (d < 0 ? -0.01 : 0.01) : d;

    final ctrl1 = Offset(
      mx - (corner.dy - my) * (corner.dy - my) / safeDen(corner.dx - mx),
      corner.dy,
    );
    final ctrl2 = Offset(
      corner.dx,
      my - (corner.dx - mx) * (corner.dx - mx) /
          safeDen(corner.dy - my),
    );

    final start1 = Offset(
      ctrl1.dx - (corner.dx - ctrl1.dx) / 2,
      corner.dy,
    );
    final start2 = Offset(
      corner.dx,
      ctrl2.dy - (corner.dy - ctrl2.dy) / 2,
    );

    final end1 = lineIntersect(t, ctrl1, start1, start2) ?? t;
    final end2 = lineIntersect(t, ctrl2, start1, start2) ?? t;

    final vertex1 = bezierVertex(start1, ctrl1, end1);
    final vertex2 = bezierVertex(start2, ctrl2, end2);

    final dis = (t - corner).distance;

    return CurlPoints(
      touch: t,
      corner: corner,
      ctrl1: ctrl1,
      ctrl2: ctrl2,
      start1: start1,
      start2: start2,
      end1: end1,
      end2: end2,
      vertex1: vertex1,
      vertex2: vertex2,
      dis: dis,
    );
  }

  var pts = compute(touch);

  // 出界回拉（稳健策略）：start1 水平出屏且触点在页内时，
  // 将触点沿触点→角点方向向角点收拢，直到 start1 回到屏内。
  // （legado 原版用相似三角形投影，极端拖距下会把 T 抛到页外远处；
  // 二分收拢保证几何始终有限、折面随拖距单调收敛。）
  final outOfScreen = pts.start1.dx < 0 || pts.start1.dx > page.width;
  if (outOfScreen &&
      touch.dx >= 0 &&
      touch.dx <= page.width &&
      touch.dy >= 0 &&
      touch.dy <= page.height) {
    var lo = 0.0; // s=0 原触点
    var hi = 0.999; // s→1 贴到角点
    for (var i = 0; i < 14; i++) {
      final mid = (lo + hi) / 2;
      final cand = Offset.lerp(touch, corner, mid)!;
      if (compute(cand).start1.dx >= -0.5 &&
          compute(cand).start1.dx <= page.width + 0.5) {
        hi = mid; // 收拢后已回屏 → 可再松一点
      } else {
        lo = mid; // 仍出屏 → 继续收拢
      }
    }
    final fixed = Offset.lerp(touch, corner, hi)!;
    if ((fixed - touch).distance > 0.5) {
      touch = fixed;
      pts = compute(touch);
    }
  }

  return pts;
}

// ══════════════════════════════════════════════════════════════
// CurlPainter — 四层绘制管线
//
// 对齐 legado drawCurrentPageArea / drawNextPageAreaAndShadow /
// drawCurrentBackArea / 阴影带的分层顺序：
//   ① 正面剩余区（pageRect ∖ path0）画当前页
//   ② 目标页露出区（五边形 ∩ path0）画目标页 + 折缝阴影带
//   ③ 背面折叠区（path0 ∩ path1）反射矩阵镜像当前页 + 暗化
//   ④ 正面边缘软阴影沿两条贝塞尔曲线描边
// ══════════════════════════════════════════════════════════════

class CurlPainter extends CustomPainter {
  /// 被折走的页数据（正面剩余区 + 背面镜像同源，每帧直绘）
  final PageInfo foldingPage;

  /// 露出的页数据（每帧直绘）
  final PageInfo revealPage;

  /// 页面内容渲染回调（复用 PageContentRenderer，由 composer 注入绘制参数）
  final void Function(Canvas canvas, PageInfo page) paintContent;

  /// 触点/动画插值触点（本地坐标）
  final Offset touch;

  /// 翻页方向（决定固定折角）
  final PageDirection direction;

  /// 自动播放阶段进度；拖拽阶段传 null。
  final double? autoProgress;

  static const Color _paperColor = Color(0xFFF5F1E8);

  /// 纸背底色（正面纸色加深 ~8%，legado backgroundMeanColor 等价物：
  /// 背面先铺不透明底再画镜像，读感为独立实心纸张）
  static const Color _paperBackColor = Color(0xFFE9E3D5);

  CurlPainter({
    required this.foldingPage,
    required this.revealPage,
    required this.paintContent,
    required this.touch,
    required this.direction,
    required this.autoProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final page = size;
    canvas.drawRect(Offset.zero & page, Paint()..color = _paperColor);

    final corner = cornerForDirection(direction, page);

    // 触点已由 composer 完成插值（拖拽=实时手指；自动=起止锚点映射）
    final p = calcCurlPoints(touch, corner, page);

    // ── path0：被折走的区域（从正面剪掉）──
    final path0 = Path()
      ..moveTo(p.start1.dx, p.start1.dy)
      ..quadraticBezierTo(p.ctrl1.dx, p.ctrl1.dy, p.end1.dx, p.end1.dy)
      ..lineTo(p.touch.dx, p.touch.dy)
      ..lineTo(p.end2.dx, p.end2.dy)
      ..quadraticBezierTo(p.ctrl2.dx, p.ctrl2.dy, p.start2.dx, p.start2.dy)
      ..lineTo(p.corner.dx, p.corner.dy)
      ..close();

    final pageRectPath = Path()..addRect(Offset.zero & page);

    // 主折缝曲线（贝塞尔1：start1→ctrl1→end1）——铰链阴影/正面软阴影/折痕高光共用。
    // 注意：绝不能把 end1→end2 直线连进描边路径——那是弦线而非真实折边
    // （真实边界经触点 T：end1→T→end2），沿弦线描边会在翻面内部画出
    // 一条与折缝不平行的直线黑影
    final foldCurve = Path()
      ..moveTo(p.start1.dx, p.start1.dy)
      ..quadraticBezierTo(p.ctrl1.dx, p.ctrl1.dy, p.end1.dx, p.end1.dy);
    // 第二折缝曲线（贝塞尔2：end2→ctrl2→start2）——仅正面侧软阴影
    final frontFoldCurves = Path()
      ..moveTo(p.start1.dx, p.start1.dy)
      ..quadraticBezierTo(p.ctrl1.dx, p.ctrl1.dy, p.end1.dx, p.end1.dy)
      ..moveTo(p.end2.dx, p.end2.dy)
      ..quadraticBezierTo(p.ctrl2.dx, p.ctrl2.dy, p.start2.dx, p.start2.dy);

    // ① 正面剩余区：被折走的页（与空闲帧同一渲染函数，像素一致）
    final frontVisible =
        Path.combine(PathOperation.difference, pageRectPath, path0);
    canvas.save();
    canvas.clipPath(frontVisible);
    paintContent(canvas, foldingPage);
    canvas.restore();

    // ② 目标页露出区：五边形 start1→v1→v2→start2→corner ∩ path0
    final pentagon = Path()
      ..moveTo(p.start1.dx, p.start1.dy)
      ..lineTo(p.vertex1.dx, p.vertex1.dy)
      ..lineTo(p.vertex2.dx, p.vertex2.dy)
      ..lineTo(p.start2.dx, p.start2.dy)
      ..lineTo(p.corner.dx, p.corner.dy)
      ..close();
    final revealArea = Path.combine(PathOperation.intersect, pentagon, path0);
    canvas.save();
    canvas.clipPath(revealArea);
    canvas.drawRect(Offset.zero & page, Paint()..color = _paperColor);
    paintContent(canvas, revealPage);
    // 折缝宽域投影（向露出区衰减）
    _drawFoldWash(
      canvas,
      p,
      page,
      revealArea,
      intoFlap: false,
    );
    canvas.restore();

    // ③ 背面折叠区：path1 = vertex→vertex2→end2→T→end1；clip = path0∩path1
    //    legado 配方（drawCurrentBackArea L273-335）：
    //    不透明纸背底色 → 镜像被折走的页（与正面同源同帧）→ 折缝渐变阴影条
    final path1 = Path()
      ..moveTo(p.vertex1.dx, p.vertex1.dy)
      ..lineTo(p.vertex2.dx, p.vertex2.dy)
      ..lineTo(p.end2.dx, p.end2.dy)
      ..lineTo(p.touch.dx, p.touch.dy)
      ..lineTo(p.end1.dx, p.end1.dy)
      ..close();
    final backFace =
        Path.combine(PathOperation.intersect, path0, path1);
    if (!backFace.getBounds().isEmpty) {
      canvas.save();
      canvas.clipPath(backFace);
      // ① 不透明纸背底色：实心纸质感，不透下层内容
      canvas.drawRect(Offset.zero & page, Paint()..color = _paperBackColor);
      // ② 镜像被折走的页：内层 save/transform/restore 保证变换只作用于
      //    内容绘制，外层 clip 始终有效；与正面同一帧同一函数绘同一页，
      //    镜像轴（过 ctrl1 的触点-角点垂直平分线）为不动点 → 折缝处
      //    正/背面内容像素连续（legado f8/f9 矩阵等价实现）
      canvas.save();
      canvas.transform(foldMirrorMatrix(p).storage);
      paintContent(canvas, foldingPage);
      canvas.restore();
      // 折缝宽域曲面明暗（向翻面内部衰减至触点）
      _drawFoldWash(
        canvas,
        p,
        page,
        backFace,
        intoFlap: true,
      );
      canvas.restore();
    }

    // ④ 正面边缘软阴影：沿两条折缝曲线描边 + 高斯模糊，
    //    裁到正面剩余区使模糊只向正面渗透
    canvas.save();
    canvas.clipPath(frontVisible);
    canvas.drawPath(
      frontFoldCurves,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.30)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
    canvas.restore();

    // ⑤ 折痕高光：折缝处细白线（纸张弯折的受光面，参考卷曲实现的
    //    fold-highlight——暗铰链 + 细高光使折缝读作真实物理折痕）
    canvas.drawPath(
      foldCurve,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.40)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // 触点附近的小暗斑（手指按压感）
    canvas.drawCircle(
      p.touch,
      18,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.08)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );
  }

  /// 折缝宽域明暗：旋转坐标系（原点 vertex1、x 轴沿镜像轴法向）内
  /// 绘制垂直于折缝的线性渐变。
  ///
  /// 翻面侧（intoFlap）：折缝黑@0.28 → dis/5 处 0.10 → 触点全透明——
  /// 垂直平分线性质保证触点（翻面最远点）到镜像轴距离恰为 dis/2，
  /// 渐变终点天然落在翻面最远端：恢复曲面光影且尖端无叠帧堆黑
  /// （替代同心描边：描边在窄楔形尖端全部叠加，组合透明度 ≈0.9 必然
  /// 堆成黑斑）。x<0（折缝曲线两端偏离轴的月牙）钳位取折缝值。
  ///
  /// 露出区侧：折缝黑@0.20 → dis/2 全透明（折起页在下方页上的投影）。
  void _drawFoldWash(
    Canvas canvas,
    CurlPoints p,
    Size page,
    Path clipArea, {
    required bool intoFlap,
  }) {
    final angle = math.atan2(
      p.ctrl1.dx - p.corner.dx,
      p.ctrl2.dy - p.corner.dy,
    );
    final maxLen = page.longestSide * 1.5;
    canvas.save();
    canvas.clipPath(clipArea);
    canvas.translate(p.vertex1.dx, p.vertex1.dy);
    canvas.rotate(angle);
    final Rect rect;
    final LinearGradient gradient;
    if (intoFlap) {
      rect = Rect.fromLTWH(-p.dis / 2, 0, p.dis, maxLen);
      gradient = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        stops: const [0.0, 0.5, 0.7, 1.0],
        colors: [
          Colors.black.withValues(alpha: 0.28),
          Colors.black.withValues(alpha: 0.28),
          Colors.black.withValues(alpha: 0.10),
          Colors.transparent,
        ],
      );
    } else {
      rect = Rect.fromLTWH(-p.dis / 2, 0, p.dis / 2, maxLen);
      gradient = LinearGradient(
        begin: Alignment.centerRight,
        end: Alignment.centerLeft,
        colors: [
          Colors.black.withValues(alpha: 0.20),
          Colors.transparent,
        ],
      );
    }
    canvas.drawRect(rect, Paint()..shader = gradient.createShader(rect));
    canvas.restore();
  }

  @override
  bool shouldRepaint(CurlPainter oldDelegate) {
    return oldDelegate.foldingPage != foldingPage ||
        oldDelegate.revealPage != revealPage ||
        oldDelegate.touch != touch ||
        oldDelegate.autoProgress != autoProgress ||
        oldDelegate.direction != direction;
  }
}
