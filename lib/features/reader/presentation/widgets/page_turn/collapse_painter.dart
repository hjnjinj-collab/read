import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../../core/models/simple_models.dart';
import '../../diagnostics/reader_trace.dart';
import '../reader_page_widget.dart';

/// 方块坍塌溶解翻页绘制器（collapse dissolve）
///
/// 2026-09-04 M2: 以点击位置为引力中心的径向坍塌方案（近→远波前扩散）
///
/// 两层架构（与 RipplePainterV16 v16.10 同源，全部踩坑教训已内置）：
/// ```
/// 层1: 新页整页（实时矢量直绘，纸色底 + 渲染参数同源 → 完成瞬间零色差）
/// 层2: 旧页方块层（shader 全屏，径向波前时序缩放坍解 → 恒不透明零重叠）
/// ```
class CollapsePainter extends CustomPainter {
  final PageInfo? foldingPage;
  final PageInfo? revealPage;
  final double progress;

  /// 坍塌中心（点击点 / 拖拽松手点，屏幕逻辑坐标）
  final Offset center;

  /// 每页随机种子（波次抖动不规则化，与水波纹同机制）
  final double waveSeed;

  // === 渲染参数（与 PagePainter/CurlPainter/RipplePainterV16 同源）===
  // 动画中实时直绘的新页必须与完成后正式渲染参数一致，否则完成瞬间内容跳变
  final bool applyBold;
  final bool applyItalic;
  final bool applyTitleBold;
  final double baseFontSize;
  final double baseLineHeight;

  /// 方块阴影颜色（对齐 v16.10，可配置）
  final Color shadowColor;

  /// 方块边长（px，2026-09-04 P1 设置化：24~64，默认 36）
  final double blockSize;

  /// 向心滑移距离（px，2026-09-04 P1 设置化：0~80，默认 45）
  final double slideDistance;

  /// 折叠页（旧页）的预生成纹理（shader 采样用）
  final ui.Image? foldingPageImage;

  final ui.FragmentShader? collapseShader;

  const CollapsePainter({
    required this.foldingPage,
    required this.revealPage,
    required this.progress,
    required this.center,
    this.waveSeed = 0.0,
    this.applyBold = true,
    this.applyItalic = true,
    this.applyTitleBold = false,
    this.baseFontSize = 18.0,
    this.baseLineHeight = 1.5,
    this.shadowColor = const Color(0xFF333630),
    this.blockSize = 36.0,
    this.slideDistance = 45.0,
    this.foldingPageImage,
    this.collapseShader,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final sw = Stopwatch()..start();

    readerTrace('collapse.paint.frame', {
      'progress': progress.toStringAsFixed(3),
      'center': '${center.dx.toStringAsFixed(0)}_${center.dy.toStringAsFixed(0)}',
      'hasFoldingImg': foldingPageImage != null,
    });

    if (revealPage == null && foldingPage == null) return;

    if (progress <= 0.001) {
      _paintPage(canvas, foldingPage, size);
      return;
    }
    if (progress >= 0.999) {
      _paintPage(canvas, revealPage, size);
      return;
    }

    if (revealPage == null || foldingPage == null) {
      _paintPage(canvas, revealPage ?? foldingPage, size);
      return;
    }

    // === 层1: 新页整页（实时矢量直绘 + 渲染参数同源）===
    _paintPage(canvas, revealPage, size);

    // === 层2: 旧页方块层（shader 全屏绘制，径向坍塌）===
    if (collapseShader != null && foldingPageImage != null) {
      _drawCollapseBlocksWithShader(canvas, size);
    } else {
      // Fallback: shader/纹理未就绪 → 直接画旧页整页（无动画过渡）
      readerTrace('collapse.shader.missing', {
        'hasShader': collapseShader != null,
        'hasFoldingImg': foldingPageImage != null,
      });
      if (foldingPageImage != null) {
        canvas.drawImageRect(
          foldingPageImage!,
          Rect.fromLTWH(0, 0, foldingPageImage!.width.toDouble(),
                        foldingPageImage!.height.toDouble()),
          Rect.fromLTWH(0, 0, size.width, size.height),
          Paint()..filterQuality = FilterQuality.medium,
        );
      } else {
        _paintPage(canvas, foldingPage, size);
      }
    }

    sw.stop();
    if (sw.elapsedMilliseconds > 8) {
      readerTrace('collapse.paint.slow', {
        'elapsedMs': sw.elapsedMilliseconds,
        'progress': progress.toStringAsFixed(3),
      });
    }
  }

  /// 用 Shader 全屏绘制旧页方块层（径向坍塌）
  void _drawCollapseBlocksWithShader(Canvas canvas, Size size) {
    if (collapseShader == null || foldingPageImage == null) return;

    // shader 参数（uniform 布局：11 个 float + 1 sampler，索引按声明顺序）
    collapseShader!.setFloat(0, size.width);   // uResolution.x
    collapseShader!.setFloat(1, size.height);  // uResolution.y
    collapseShader!.setFloat(2, progress);     // uProgress
    collapseShader!.setFloat(3, blockSize);    // uBlockSize（用户可调）
    collapseShader!.setFloat(4, center.dx);    // uCenter.x
    collapseShader!.setFloat(5, center.dy);    // uCenter.y
    collapseShader!.setFloat(6, waveSeed);     // uSeed（每页随机）
    // uShadowColor（vec3 → 索引 7/8/9）
    collapseShader!.setFloat(7, shadowColor.r);
    collapseShader!.setFloat(8, shadowColor.g);
    collapseShader!.setFloat(9, shadowColor.b);
    collapseShader!.setFloat(10, slideDistance); // uSlideDistance（用户可调）

    // 单纹理：旧页
    collapseShader!.setImageSampler(0, foldingPageImage!);

    // shader 全屏绘制旧页方块层
    final paint = Paint()..shader = collapseShader;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      paint,
    );
  }

  /// 实时直绘一页（统一模板：先纸色底再 paintPage，与 RipplePainterV16 同源）
  /// paint 的 progress 短路路径 / fallback 全部经由此方法 → 自动带纸色底
  /// 与用户渲染参数，trailing 帧与正式渲染逐像素一致
  void _paintPage(Canvas canvas, PageInfo? page, Size size) {
    if (page == null) return;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = PageContentRenderer.paperColor,
    );
    PageContentRenderer.paintPage(
      canvas,
      page,
      size: size,
      onImageNeeded: () {},
      applyBold: applyBold,
      applyItalic: applyItalic,
      applyTitleBold: applyTitleBold,
      baseFontSize: baseFontSize,
      baseLineHeight: baseLineHeight,
    );
  }

  @override
  bool shouldRepaint(CollapsePainter oldDelegate) {
    return (progress - oldDelegate.progress).abs() > 0.005 ||
           center != oldDelegate.center ||
           blockSize != oldDelegate.blockSize ||
           slideDistance != oldDelegate.slideDistance ||
           shadowColor != oldDelegate.shadowColor ||
           foldingPage != oldDelegate.foldingPage ||
           revealPage != oldDelegate.revealPage ||
           foldingPageImage != oldDelegate.foldingPageImage ||
           collapseShader != oldDelegate.collapseShader;
  }
}
