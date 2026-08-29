import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../../core/models/simple_models.dart';
import '../../services/book_image_store.dart';
import '../../diagnostics/reader_trace.dart';
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

  /// 折缝光影缩放（0~1）：自动翻完收尾时线性淡出，末帧光影归零，
  /// 与干净定格页无缝衔接（否则收尾瞬间光影「啪」地消失）
  final double washScale;

  static const Color _paperColor = Color(0xFFF5F1E8);

  /// 纸背底色（正面纸色加深 ~8%，legado backgroundMeanColor 等价物：
  /// 背面先铺不透明底再画镜像，读感为独立实心纸张）
  static const Color _paperBackColor = Color(0xFFE9E3D5);
  // 旧版曲线高光保留作对照，但当前光影完全采用 MD3 渐变条。
  static const bool _legacyCurveHighlightsEnabled = false;

  CurlPainter({
    required this.foldingPage,
    required this.revealPage,
    required this.paintContent,
    required this.touch,
    required this.direction,
    required this.autoProgress,
    required this.washScale,
    // 图片就绪重绘通道：与空闲页 PagePainter(repaint: _repaintTick) 同机制。
    // must 不走 shouldRepaint 字段比对——动画中 touch 不变时新 painter
    // 字段全同，字段比对会抑制重绘，占位将永久冻结（纹理不变化根因）。
    required Listenable repaint,
  }) : super(repaint: repaint);

  /// 资源就绪诊断辅助：背景图就绪状态字符串（ready / missing / null）
  String _bgReady(PageInfo page) {
    final href = page.backgroundHref;
    if (href == null || href.isEmpty) return 'null';
    return BookImageStore.instance.get(href) != null ? 'ready' : 'missing';
  }

  /// 资源就绪诊断辅助：图片 entry 就绪摘要（ready/total）
  String _imgReadySummary(PageInfo page) {
    var total = 0;
    var ready = 0;
    for (final entry in page.entries) {
      final href = entry.resourceHref;
      if (href == null || href.isEmpty) continue;
      total++;
      if (BookImageStore.instance.get(href) != null) ready++;
    }
    return '$ready/$total';
  }

  // ── 帧诊断节流 ──
  // composer 每次 build 都新建 painter 实例，实例字段无法跨帧记忆，故用静态。
  // 需求：仅"前后纹理变化"时输出（每翻页 1~2 次），动画过程中间帧静默。
  // 判定：foldingPage 或 revealPage 身份任一变化即输出。isSettled 翻转从 fold/reveal
  // 变化中可推断（同帧页面身份不变不会跨越 settled 边界）。
  static String? _lastTracedPages;

  void _shouldTraceThisFrame() {
    final foldingId =
        '${foldingPage.chapterIndex}/${foldingPage.pageIndex}#${readerPageId(foldingPage)}';
    final revealId =
        '${revealPage.chapterIndex}/${revealPage.pageIndex}#${readerPageId(revealPage)}';
    final pages = '$foldingId->$revealId';
    if (_lastTracedPages == pages) return;
    _lastTracedPages = pages;
    final isSettled = identical(revealPage, foldingPage);
    readerTrace('curl.paint.frame', {
      'folding': foldingId,
      'reveal': revealId,
      'isSettled': isSettled,
      'revealBg': _bgReady(revealPage),
      'revealImages': _imgReadySummary(revealPage),
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 末帧短路：动画收尾（autoProgress >= 0.9995 视为已触顶；或 reveal=folding）
    // 直接铺 reveal 全屏。绕过 path0/path1/backFace 极限退化下的灰色纸背色残迹。
    // 阈值放宽到 0.9995：Flutter Ticker 在 animateTurn 触达 1.0 那一刻触发
    // 短路帧后，后续 markNeedsPaint 触发的 paint 调用里 controller.progress
    // 可能已回退到 ~0.9996（完成回调与最后帧时序竞争），硬阈值 1.0 会让这些
    // trailing 帧走非短路路径 → 短暂"残迹帧"上屏 = 闪。
    final ap = autoProgress;
    final isSettled = (ap != null && ap >= 0.9995) ||
        identical(revealPage, foldingPage);
    // 翻页纹理诊断：仅页面身份变化时输出（每翻页 1~2 条），见 _shouldTraceThisFrame。
    _shouldTraceThisFrame();
    if (isSettled) {
      canvas.drawRect(Offset.zero & size, Paint()..color = _paperColor);
      paintContent(canvas, revealPage);
      return;
    }
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
    final path1 = Path()
      ..moveTo(p.vertex1.dx, p.vertex1.dy)
      ..lineTo(p.vertex2.dx, p.vertex2.dy)
      ..lineTo(p.end2.dx, p.end2.dy)
      ..lineTo(p.touch.dx, p.touch.dy)
      ..lineTo(p.end1.dx, p.end1.dy)
      ..close();
    final mirrorEdge = Path()
      ..moveTo(p.end1.dx, p.end1.dy)
      ..lineTo(p.touch.dx, p.touch.dy)
      ..lineTo(p.end2.dx, p.end2.dy);
    final backFace = Path.combine(
      PathOperation.intersect,
      path0,
      path1,
    );


    // 主折缝曲线（贝塞尔1：start1→ctrl1→end1）——背面描边+露出区投影共用。
    // 注意：绝不能把 end1→end2 直线连进描边路径——那是弦线而非真实折边
    // （真实边界经触点 T：end1→T→end2），沿弦线描边会在翻面内部画出
    // 一条与折缝不平行的直线黑影
    // 折面脊线（end1→T→end2）——参考图里这是翻起页**最亮的高光带**
    // （纸张弯曲受光最强的脊），轮 2 沿此画白色高光层。
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
    // 投影只属于下一页，不应覆盖卷起页的镜像背面。
    // backFace 是 path0 ∩ path1；从 revealArea 中扣除后，阴影会停留
    // 在卷页下方的下一页平面，而不会映射到卷曲镜面上。
    final revealShadowArea = Path.combine(
      PathOperation.difference,
      revealArea,
      backFace,
    );
    canvas.save();
    canvas.clipPath(revealArea);
    canvas.drawRect(Offset.zero & page, Paint()..color = _paperColor);
    paintContent(canvas, revealPage);
    // MD3 drawNextPageAreaAndShadow：下一页的投影只画在
    // path0 ∩ path1（即 revealArea）内，以 start1 为旋转锚点，宽度为
    // dis / 4。这个矩形渐变正是卷页下方的投影，不是卷页边缘描边。
    _drawMd3ShadowRect(
      canvas,
      p,
      revealShadowArea,
      anchor: p.start1,
      width: (p.dis / 4).clamp(16.0, 96.0).toDouble(),
      length: page.longestSide * 1.5,
      alpha: 0.62 * washScale,
      darkStop: 0.52,
      darkFactor: 0.92,
      midFactor: 0.52,
      reverse: direction == PageDirection.next,
      angle: math.atan2(
        p.ctrl1.dx - p.corner.dx,
        p.ctrl2.dy - p.corner.dy,
      ),
    );
    canvas.restore();

    // ③ 背面折叠区：path1 = vertex→vertex2→end2→T→end1；clip = path0∩path1
    //    legado 配方（drawCurrentBackArea L273-335）：
    //    不透明纸背底色 → 镜像被折走的页（与正面同源同帧）→ 折缝渐变阴影条
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
      // 卷曲镜面暂不绘制 MD3 folder shadow。
      // 该阴影属于翻起页背面自身的光影，而不是下一页上的投影；
      // 当前阶段需要把两者彻底分离，镜面后续单独加入光影。

      // 镜像边缘光影：参考图中卷页边缘不是黑色轮廓，而是由纸边
      // 向镜面内部散开的暖白反光。所有层都限制在 backFace，绝不影响
      // 下一页投影；低 alpha + 大 blur 保持边缘轻盈。
      for (final (width, alpha, blur) in <(double, double, double)>[
        (2.0, 0.18, 1.2), // 纸边细光
        (7.0, 0.09, 4.0), // 贴边过渡
        (18.0, 0.035, 11.0), // 向镜面内部的羽化
      ]) {
        canvas.drawPath(
          mirrorEdge,
          Paint()
            ..color = const Color(0xFFFFF8E8)
                .withValues(alpha: alpha * washScale)
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeWidth = width
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
        );
      }
      canvas.restore();
    }

    // 被卷起页脚的边缘光影：这条 end1→touch→end2 才是提起的纸边，
    // 不属于镜像内容的整体纹理。它位于 backFace 的边界上，因此必须
    // 在 backFace restore 后绘制，并裁到 path0，避免影响下一页平面。
    canvas.save();
    canvas.clipPath(path0);
    for (final (width, alpha, blur) in <(double, double, double)>[
      (2.5, 0.30, 1.5), // 纸边暗部核心
      (7.0, 0.10, 3.5), // 很窄的边缘过渡
    ]) {
      canvas.drawPath(
        mirrorEdge,
        Paint()
          ..color = const Color(0xFF39444F).withValues(alpha: alpha * washScale)
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
      );
    }
    canvas.restore();

    // 被卷起页脚投向上一页的阴影：与 path0 内的纸边光影分离。
    // 这里必须裁到 frontVisible，阴影才会落在上一页，而不是停在卷页内部；
    // 多层递增模糊模拟参考图中从边缘向外发散的遮挡投影。
    canvas.save();
    canvas.clipPath(frontVisible);
    final footerShadowDirection = p.touch - p.corner;
    final footerLength = footerShadowDirection.distance == 0
        ? 1.0
        : footerShadowDirection.distance;
    final footerUnit = Offset(
      footerShadowDirection.dx / footerLength,
      footerShadowDirection.dy / footerLength,
    );
    for (final (distance, width, alpha, blur) in <(double, double, double, double)>[
      (3, 20, 0.52, 6),
      (18, 36, 0.38, 12),
      (42, 58, 0.20, 22),
      (78, 78, 0.065, 40),
    ]) {
      final offset = footerUnit * distance;
      final shadowPath = Path()
        // 完整的被卷起页脚边缘：两段贝塞尔 + 触点脊线。
        // 之前只画 end1→touch→end2，因此影子只覆盖页脚中段。
        ..moveTo(p.start1.dx + offset.dx, p.start1.dy + offset.dy)
        ..quadraticBezierTo(
          p.ctrl1.dx + offset.dx,
          p.ctrl1.dy + offset.dy,
          p.end1.dx + offset.dx,
          p.end1.dy + offset.dy,
        )
        ..lineTo(p.touch.dx + offset.dx, p.touch.dy + offset.dy)
        ..lineTo(p.end2.dx + offset.dx, p.end2.dy + offset.dy)
        ..quadraticBezierTo(
          p.ctrl2.dx + offset.dx,
          p.ctrl2.dy + offset.dy,
          p.start2.dx + offset.dx,
          p.start2.dy + offset.dy,
        );
      canvas.drawPath(
        shadowPath,
        Paint()
          ..color = const Color(0xFF39444F).withValues(alpha: alpha * washScale)
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
      );
    }
    canvas.restore();

    // MD3 drawCurrentPageShadow：当前页的两条 front shadow 都是
    // 控制点附近的 25px 渐变带，并且只绘制在 path0 外部。
    _drawMd3FrontShadow(canvas, p, page, path0, washScale, first: true);
    _drawMd3FrontShadow(canvas, p, page, path0, washScale, first: false);

    /*
    // 底页投影：阴影不是卷页外缘的描边，而是卷页遮挡光线后落在
    // 下一页上的投影。沿 corner→touch 方向把折痕向底页内部错开几档，
    // 每档同时增大模糊、降低 alpha，形成「折痕附近稍深，向外羽化」的
    // 方向性阴影。clip 到 frontVisible，确保阴影只落在当前可见底页。
    canvas.save();
    canvas.clipPath(frontVisible);
    // 折痕的投影方向应是折痕法向，而不是 corner→touch 方向。
    // 后者通常仍然位于 path0（卷页自身）内，会被 frontVisible 全部裁掉。
    // 取 foldSpine 中段切线的两个法向候选，选择真正落在底页的一侧。
    final spineMid = Offset(
      (p.end1.dx + p.touch.dx + p.end2.dx) / 3,
      (p.end1.dy + p.touch.dy + p.end2.dy) / 3,
    );
    final tangent = p.end2 - p.end1;
    final tangentLength = tangent.distance == 0 ? 1.0 : tangent.distance;
    final normal = Offset(
      -tangent.dy / tangentLength,
      tangent.dx / tangentLength,
    );
    final normalDistance = math.max(12.0, math.min(48.0, p.dis * 0.08));
    final candidateA = spineMid + normal * normalDistance;
    final shadowUnit = !path0.contains(candidateA) &&
            (candidateA.dx >= 0 &&
                candidateA.dx <= page.width &&
                candidateA.dy >= 0 &&
                candidateA.dy <= page.height)
        ? normal
        : -normal;
    final shadowLayers = <(double, double, double, double)>[
      (6.0, 10.0, 0.095, 7.0), // 接触处：略深但不画实边
      (18.0, 24.0, 0.060, 14.0), // 近处投影
      (36.0, 38.0, 0.032, 23.0), // 远处羽化
      (60.0, 50.0, 0.015, 34.0), // 最外层散射
    ];
    for (final (offset, width, alpha, blur) in shadowLayers) {
      final shadowOffset = Offset(
        shadowUnit.dx * offset,
        shadowUnit.dy * offset,
      );
      final shadowPath = Path()
        ..moveTo(p.end1.dx + shadowOffset.dx, p.end1.dy + shadowOffset.dy)
        ..lineTo(p.touch.dx + shadowOffset.dx, p.touch.dy + shadowOffset.dy)
        ..lineTo(p.end2.dx + shadowOffset.dx, p.end2.dy + shadowOffset.dy);
      canvas.drawPath(
        shadowPath,
        Paint()
          ..color = const Color(0xFF303238).withValues(alpha: alpha * washScale)
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = width
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
      );
    }

    // 纸页边缘必须在 backFace 恢复后绘制；如果在 backFace 内描边，
    // 路径恰好落在裁剪边界上会被裁成不可见。这里仅画窄而柔和的纸边，
    // 不承担底页投影职责。
    final backEdge = Path()
      ..moveTo(p.start1.dx, p.start1.dy)
      ..quadraticBezierTo(p.ctrl1.dx, p.ctrl1.dy, p.end1.dx, p.end1.dy)
      ..lineTo(p.touch.dx, p.touch.dy)
      ..lineTo(p.end2.dx, p.end2.dy)
      ..quadraticBezierTo(p.ctrl2.dx, p.ctrl2.dy, p.start2.dx, p.start2.dy);
    canvas.save();
    canvas.clipPath(path0);
    canvas.drawPath(
      backEdge,
      Paint()
        ..color = const Color(0xFF3C3B37).withValues(alpha: 0.30 * washScale)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.0),
    );
    canvas.restore();
    canvas.restore();

    // 尖端触点附近沿贝塞尔边缘展开的暗影（v7 修正 v5 定位错误）：
    // 裁剪窗必须以 p.touch 为中心——touch 正是原「圆形斑点」的中心
    // （翻起页尖端），暗纹应贴着经 T 的折叠边界（cornerFoldEdges 两段
    // 贝塞尔在 end1/end2 处逼近触点）沿边扩散。此前误用固定角点
    // p.corner 定位：窗口挪到页面另一端且叠在镜像文字上，几乎不可见。
    // 必须在 backFace 块外面画、clip 到 path0：尖端三角区属于被折走的
    // path0 而 backFace = path0 ∩ path1，自身块内裁剪覆盖不到。
    final tipFoldEdges = Path()
      ..moveTo(p.start1.dx, p.start1.dy)
      ..quadraticBezierTo(p.ctrl1.dx, p.ctrl1.dy, p.end1.dx, p.end1.dy)
      ..moveTo(p.end2.dx, p.end2.dy)
      ..quadraticBezierTo(p.ctrl2.dx, p.ctrl2.dy, p.start2.dx, p.start2.dy);
    canvas.save();
    canvas.clipPath(path0);
    canvas.clipRect(Rect.fromCenter(
      center: p.touch, width: 160, height: 160,
    ));
    for (final (w, a, blur) in <(double, double, double)>[
      (5, 0.055, 9.0),
      (16, 0.022, 18.0),
    ]) {
      canvas.drawPath(
        tipFoldEdges,
        Paint()
          ..color = const Color(0xFF1F1F22).withValues(alpha: a * washScale)
          ..style = PaintingStyle.stroke
          ..strokeWidth = w
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
      );
    }
    canvas.restore();

    */
    // ④ 正面折缝阴影 + ⑤ 高光：参考图要求明暗对比强烈——
    //    暗线（阴影）在折缝中心 + 亮线（高光）在折缝上方，形成立体渐变带。
    if (_legacyCurveHighlightsEnabled && washScale > 0.01) {
      // 两段 Bezier 曲线路径
      final frontFoldCurves = Path()
        ..moveTo(p.start1.dx, p.start1.dy)
        ..quadraticBezierTo(p.ctrl1.dx, p.ctrl1.dy, p.end1.dx, p.end1.dy)
        ..moveTo(p.end2.dx, p.end2.dy)
        ..quadraticBezierTo(p.ctrl2.dx, p.ctrl2.dy, p.start2.dx, p.start2.dy);

      canvas.save();
      canvas.clipPath(frontVisible);

      // ⑥ 正面折缝投影带（用户红框反馈 2026-08-27）：折面悬空压在底页
      //    上方产生的软投影——参考图折缝正面侧有 40-80px 渐变暗带，而
      //    ④/③ 描边层经 frontVisible 裁剪后可见宽度仅 ~15px，形态性不足。
      // ④ 折缝暗线（阴影）：只保留贴缝的低对比度暗线。
      // 不再填充一整块平移 band：那会产生清晰的直线边界，读起来像
      // 黑色矩形压在页面上，而不是卷页遮住底页后的环境遮蔽。
      const shadowColor = Color(0xFF1F1F22);
      const shadowStops = <(double, double, double)>[
        (2.0, 0.12, 2.2), // 只给折缝一个很轻的核心
        (8, 0.055, 4.5),  // 连续过渡
        (18, 0.022, 10.0), // 轻微羽化，避免硬边
      ];
      for (final (w, a, blur) in shadowStops) {
        canvas.drawPath(
          frontFoldCurves,
          Paint()
            ..color = shadowColor.withValues(alpha: a * washScale)
            ..style = PaintingStyle.stroke
            ..strokeWidth = w
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
        );
      }

      // ⑤ 折缝亮线（高光）：锐利、明亮，2-3px 宽
      // 三层：核心极亮 + 中层过渡 + 外层光晕
      canvas.drawPath(
        frontFoldCurves,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.22 * washScale) // 极亮核心
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
      canvas.drawPath(
        frontFoldCurves,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.12 * washScale) // 中层过渡
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
      );
      canvas.drawPath(
        frontFoldCurves,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.05 * washScale) // 外层光晕
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );

      canvas.restore();

    }
  }

  /// MD3 GradientDrawable 的 Flutter 等价实现：以指定锚点旋转一个
  /// 线性渐变矩形。阴影的位置由调用方的 clipArea 决定，避免用描边
  /// 把卷页外缘错误地画成一圈实线。
  void _drawMd3ShadowRect(
    Canvas canvas,
    CurlPoints p,
    Path clipArea, {
    required Offset anchor,
    required double width,
    required double length,
    required double alpha,
    required bool reverse,
    double? angle,
    double darkStop = 0.30,
    double darkFactor = 0.72,
    double midFactor = 0.26,
  }) {
    if (alpha <= 0.001 || width <= 0 || length <= 0) return;
    final rotation = angle ?? math.atan2(
      p.touch.dx - p.ctrl1.dx,
      p.ctrl1.dy - p.touch.dy,
    );
    final rect = Rect.fromLTWH(
      reverse ? -width : 0,
      0,
      width,
      length,
    );
    // MD3 的 RIGHT_LEFT/LR 方向取决于折角：next（右下角）时，
    // 矩形右端贴近 start1/折痕，必须是最深的一端；向左扩散后变透明。
    // 之前固定从 left→right 放深色，导致投影内外侧反转。
    final shader = ui.Gradient.linear(
      Offset(rect.left, rect.top),
      Offset(rect.right, rect.top),
      reverse
          ? [
              const Color(0x00111111),
              const Color(0xFF111111).withValues(alpha: alpha * 0.26),
              const Color(0xFF111111).withValues(alpha: alpha * 0.72),
            ]
          : [
        const Color(0xFF39444F).withValues(alpha: alpha * darkFactor),
        const Color(0xFF39444F).withValues(alpha: alpha * midFactor),
        const Color(0x0039444F),
            ],
      [0.0, darkStop, 1.0],
    );
    canvas.save();
    canvas.clipPath(clipArea);
    canvas.translate(anchor.dx, anchor.dy);
    canvas.rotate(rotation);
    canvas.drawRect(rect, Paint()..shader = shader);
    canvas.restore();
  }

  void _drawMd3FrontShadow(
    Canvas canvas,
    CurlPoints p,
    Size page,
    Path path0,
    double washScale, {
    required bool first,
  }) {
    if (washScale <= 0.01) return;
    final shadowPath = Path();
    final dx = p.touch.dx - p.ctrl1.dx;
    final dy = p.touch.dy - p.ctrl1.dy;
    final length = math.sqrt(dx * dx + dy * dy);
    final nx = length == 0 ? 0.0 : -dy / length;
    final ny = length == 0 ? 0.0 : dx / length;
    final x = p.touch.dx + nx * 35;
    final y = p.touch.dy + ny * 35;
    if (first) {
      shadowPath
        ..moveTo(x, y)
        ..lineTo(p.touch.dx, p.touch.dy)
        ..lineTo(p.ctrl1.dx, p.ctrl1.dy)
        ..lineTo(p.start1.dx, p.start1.dy)
        ..close();
      _drawMd3ShadowRect(
        canvas, p, Path.combine(PathOperation.difference, shadowPath, path0),
        anchor: p.ctrl1, width: 25, length: page.longestSide * 1.5,
        alpha: 0.22 * washScale, reverse: direction == PageDirection.next,
      );
    } else {
      shadowPath
        ..moveTo(x, y)
        ..lineTo(p.touch.dx, p.touch.dy)
        ..lineTo(p.ctrl2.dx, p.ctrl2.dy)
        ..lineTo(p.start2.dx, p.start2.dy)
        ..close();
      _drawMd3ShadowRect(
        canvas, p, Path.combine(PathOperation.difference, shadowPath, path0),
        anchor: p.ctrl2, width: 25, length: page.longestSide * 1.5,
        alpha: 0.22 * washScale, reverse: direction == PageDirection.next,
      );
    }
  }

  @override
  bool shouldRepaint(CurlPainter oldDelegate) {
    return oldDelegate.foldingPage != foldingPage ||
        oldDelegate.revealPage != revealPage ||
        oldDelegate.touch != touch ||
        oldDelegate.autoProgress != autoProgress ||
        oldDelegate.washScale != washScale ||
        oldDelegate.direction != direction;
  }
}
