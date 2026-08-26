import 'dart:math' as math;
import 'dart:ui' as ui;

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
  /// 当前页快照（拖拽开始捕获；null 时回退到 [paintContent] 直绘）
  final ui.Image? currentImage;

  /// 当前页数据（快照未就绪时的直绘回退源）
  final PageInfo currentPage;

  /// 底层目标页数据（每帧经 [paintContent] 绘制到露出区）
  final PageInfo targetPage;

  /// 页面内容渲染回调（复用 PageContentRenderer，由 composer 注入绘制参数）
  final void Function(Canvas canvas, PageInfo page) paintContent;

  /// 触点/动画插值触点（本地坐标）
  final Offset touch;

  /// 翻页方向（决定固定折角）
  final PageDirection direction;

  /// 自动播放阶段进度；拖拽阶段传 null。
  /// 仅用于收尾淡入层门控（≥0.7 渐显目标页），触点插值由 composer 完成
  final double? autoProgress;

  static const Color _paperColor = Color(0xFFF5F1E8);

  /// 纸背底色（正面纸色加深 ~8%，legado backgroundMeanColor 等价物：
  /// 背面先铺不透明底再画镜像，读感为独立实心纸张）
  static const Color _paperBackColor = Color(0xFFE9E3D5);

  CurlPainter({
    required this.currentImage,
    required this.currentPage,
    required this.targetPage,
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

    // ① 正面剩余区
    final frontVisible =
        Path.combine(PathOperation.difference, pageRectPath, path0);
    canvas.save();
    canvas.clipPath(frontVisible);
    _drawCurrent(canvas, page);
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
    paintContent(canvas, targetPage);
    // 折缝投影带：沿 crease 方向的渐变，宽度 dis/4
    _drawCreaseShadow(canvas, p, page);
    canvas.restore();

    // ③ 背面折叠区：path1 = vertex→vertex2→end2→T→end1；clip = path0∩path1
    //    legado 配方（drawCurrentBackArea L273-335）：
    //    不透明纸背底色 → 镜像当前页 → 折缝渐变阴影条
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
      // ② 沿折痕线（start1→start2）的纯反射镜像出纸背：
      //    单位法向量保证正交（无拉伸），轴取折痕保证镜像位置正确
      final m = reflectionAboutCrease(p.start1, p.start2);
      canvas.translate(p.start1.dx, p.start1.dy);
      canvas.transform(m.storage);
      canvas.translate(-p.start1.dx, -p.start1.dy);
      _drawCurrent(canvas, page);
      canvas.restore();
      // ③ 折缝阴影条：0x33→0xB0 黑（legado L110 配色），贴折缝最深
      canvas.save();
      canvas.clipPath(backFace);
      _drawBackFoldShadow(canvas, p, page);
      canvas.restore();
    }

    // ④ 正面边缘软阴影：沿折边两条二次曲线描边 + 高斯模糊，
    //    裁到正面剩余区使模糊只向正面渗透
    final edgeShadow = Path()
      ..moveTo(p.start1.dx, p.start1.dy)
      ..quadraticBezierTo(p.ctrl1.dx, p.ctrl1.dy, p.end1.dx, p.end1.dy)
      ..lineTo(p.end2.dx, p.end2.dy)
      ..quadraticBezierTo(p.ctrl2.dx, p.ctrl2.dy, p.start2.dx, p.start2.dy);
    canvas.save();
    canvas.clipPath(frontVisible);
    canvas.drawPath(
      edgeShadow,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.30)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
    canvas.restore();

    // 触点附近的小暗斑（手指按压感）
    canvas.drawCircle(
      p.touch,
      18,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.08)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );

    // ⑤ 收尾淡入层：自动扫过末段（≥70%）以渐增不透明度铺满目标页。
    //    保证 progress=1.0 末帧 = 100% 干净目标页 = 定格帧——无论折叠
    //    几何残留多少当前页切片都被盖住，从机制上消灭「末帧闪回当前页」。
    //    （对齐 legado 末帧与换页后像素一致的性质）
    final ap = autoProgress;
    if (ap != null && ap >= 0.7) {
      final opacity = ((ap - 0.7) / 0.3).clamp(0.0, 1.0);
      if (opacity > 0) {
        canvas.saveLayer(
          Offset.zero & page,
          Paint()..color = Colors.white.withValues(alpha: opacity),
        );
        canvas.drawRect(Offset.zero & page, Paint()..color = _paperColor);
        paintContent(canvas, targetPage);
        canvas.restore();
      }
    }
  }

  /// 当前页绘制：优先用快照位图，未就绪则直绘回退
  void _drawCurrent(Canvas canvas, Size page) {
    final img = currentImage;
    if (img != null) {
      final src = Rect.fromLTWH(
          0, 0, img.width.toDouble(), img.height.toDouble());
      canvas.drawImageRect(img, src, Offset.zero & page, Paint());
    } else {
      paintContent(canvas, currentPage);
    }
  }

  /// 折缝投影带：canvas 平移到 start1、旋转 crease 方向角、
  /// 画宽 dis/4 的线性渐变（黑@0.5 → 透明），指向目标区内部
  void _drawCreaseShadow(Canvas canvas, CurlPoints p, Size page) {
    final angle = math.atan2(
      p.ctrl1.dx - p.corner.dx,
      p.ctrl2.dy - p.corner.dy,
    );
    final stripW = (p.dis / 4).clamp(8.0, 120.0);
    final maxLen = page.longestSide * 1.5;
    canvas.save();
    canvas.translate(p.start1.dx, p.start1.dy);
    canvas.rotate(angle);
    canvas.drawRect(
      Rect.fromLTWH(-stripW, 0, stripW, maxLen),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerRight,
          end: Alignment.centerLeft,
          colors: [
            Colors.black.withValues(alpha: 0.45),
            Colors.transparent,
          ],
        ).createShader(Rect.fromLTWH(-stripW, 0, stripW, maxLen)),
    );
    canvas.restore();
  }

  /// 背面折缝阴影条（legado folder-shadow，L278-333）：
  /// 宽 f3 = min(|avg(start1.x,ctrl1.x)−ctrl1.x|, |avg(start2.y,ctrl2.y)−ctrl2.y|)，
  /// 色 0x33→0xB0 黑，贴折缝处最深、向纸背内部渐浅
  void _drawBackFoldShadow(Canvas canvas, CurlPoints p, Size page) {
    final angle = math.atan2(
      p.ctrl1.dx - p.corner.dx,
      p.ctrl2.dy - p.corner.dy,
    );
    final f3 = math.min(
      ((p.start1.dx + p.ctrl1.dx) / 2 - p.ctrl1.dx).abs(),
      ((p.start2.dy + p.ctrl2.dy) / 2 - p.ctrl2.dy).abs(),
    );
    final stripW = (f3 <= 0 ? p.dis / 4 : f3).clamp(8.0, 160.0);
    final maxLen = page.longestSide * 1.5;
    canvas.save();
    canvas.translate(p.start1.dx, p.start1.dy);
    canvas.rotate(angle);
    // 旋转坐标系中折缝为 x=0，纸背内部在 +x 侧：
    // 折缝处最深（0xB0），向内渐浅（0x33）
    canvas.drawRect(
      Rect.fromLTWH(0, 0, stripW, maxLen),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: const [Color(0xB0333333), Color(0x33333333)],
        ).createShader(Rect.fromLTWH(0, 0, stripW, maxLen)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(CurlPainter oldDelegate) {
    return oldDelegate.currentImage != currentImage ||
        oldDelegate.currentPage != currentPage ||
        oldDelegate.targetPage != targetPage ||
        oldDelegate.touch != touch ||
        oldDelegate.autoProgress != autoProgress ||
        oldDelegate.direction != direction;
  }
}
