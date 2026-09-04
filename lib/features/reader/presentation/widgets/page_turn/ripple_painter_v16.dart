import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../../core/models/simple_models.dart';
import '../../diagnostics/reader_trace.dart';
import '../reader_page_widget.dart';
import 'page_turn_types.dart';

/// 水波纹翻页绘制器 v16.2: 三段式架构 + 双纹理采样内容粉碎
///
/// 2026-09-03 v16.2 修复（用户第二轮截图反馈）：
/// 1. **目标页过早显示** → 三段式架构：左旧页 + 中粉碎带 + 右新页，各自独立绘制
/// 2. **内容叠加** → 取消"新页底层全屏"，改为只在右侧绘制新页区域
/// 3. **粉碎带是分界线** → shader 内方块根据中心位置采样不同纹理（左旧右新）
///
/// **核心架构**：
/// ```
/// ┌─────────────────┬─────────────┬─────────────────┐
/// │  旧页纹理（左）  │  粉碎方块带  │  新页纹理（右）  │
/// │  drawImageRect  │  shader双纹理 │  drawImageRect  │
/// └─────────────────┴─────────────┴─────────────────┘
/// ```
class RipplePainterV16 extends CustomPainter {
  final PageInfo? foldingPage;
  final PageInfo? revealPage;
  final double progress;
  final PageDirection direction;
  
  /// 折叠页（旧页）的预生成纹理
  final ui.Image? foldingPageImage;

  /// 揭示页（新页）的预生成纹理
  /// v16.9.3: 揭示页已改为实时矢量直绘（与完成后渲染同源，消除切换色差），
  /// 本字段仅为兼容 composer 传参保留，paint 不再消费
  final ui.Image? revealPageImage;
  final ui.FragmentShader? shredderShader;

  const RipplePainterV16({
    required this.foldingPage,
    required this.revealPage,
    required this.progress,
    required this.direction,
    this.waveSeed = 0.0,
    this.applyBold = true,
    this.applyItalic = true,
    this.applyTitleBold = false,
    this.baseFontSize = 18.0,
    this.baseLineHeight = 1.5,
    this.shadowColor = const Color(0xFF333630),
    this.foldingPageImage,
    this.revealPageImage,
    this.shredderShader,
  });

  /// v16.9.7: 每页随机种子——双波叠加波形不规则化，每次翻页形状不同
  final double waveSeed;

  /// v16.10: 方块阴影颜色（可配置——立体感由"颜色"塑造而非压暗，
  /// 深浅主题/个性化都可调）
  final Color shadowColor;

  // === v16.9.5 渲染参数（与 PagePainter/CurlPainter 同源）===
  // 动画中实时直绘的新页必须与完成后正式渲染参数一致，
  // 否则完成瞬间内容跳变（字号/行距/加粗设置不同 → 闪烁）
  final bool applyBold;
  final bool applyItalic;
  final bool applyTitleBold;
  final double baseFontSize;
  final double baseLineHeight;

  // 方块大小（像素）（v16.9.3: 28→36，更大更少 → 方块感强、碎渣少）
  static const double _blockSize = 36.0;

  // v16.3: 波浪参数（v16.5: 振幅 30→45 打破整齐感）
  static const double _waveAmp = 45.0;     // 波浪振幅（px）
  static const double _waveLength = 120.0; // 波浪波长（px）

  @override
  void paint(Canvas canvas, Size size) {
    final sw = Stopwatch()..start();

    readerTrace('ripple.paint.frame', {
      'progress': progress.toStringAsFixed(3),
      'direction': direction.toString(),
      'version': 'v16.9.7-dual-wave-ghost',
      'hasFoldingImg': foldingPageImage != null,
      'hasRevealImg': revealPageImage != null,
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

    // === v16.9 终极简化两层架构 ===
    // 层1: 新页整页（底层）
    // 层2: 旧页方块层（shader 全屏）——方块原位切片，波浪线扫过即淡出
    // 单纹理、单层内容、方块不位移 → 一个像素要么旧页要么新页 → 天然无重叠
    final isNext = direction == PageDirection.next;

    // boundaryX: 波浪线基准位置（屏幕坐标）
    // v16.9.2: 行程加余量 margin——t=0 时线在 width+margin（最右方块完整，
    // 波浪谷不会提前崩解露新页），t=1 时线在 -margin（最左方块全崩解）
    // next: 从右向左推进；prev: 从左向右推进
    final margin = _waveAmp + _blockSize * 3.0;
    final boundaryX = isNext
        ? size.width + margin - progress * (size.width + 2 * margin)
        : -margin + progress * (size.width + 2 * margin);

    // === 层1: 新页整页（v16.9.3 实时矢量直绘 + v16.9.5 参数同源）===
    // 不再用 revealPageImage 快照——实时绘制与动画完成后 overlay 移除时的
    // 矢量渲染完全同源 → 完成瞬间零色差（对齐 CurlPainter 无快照直绘原则；
    // 旧页快照随动画结束消失，不存在残留色差）。
    // 纸色底与渲染参数由 _paintPage 统一处理（v16.9.5）
    _paintPage(canvas, revealPage, size);

    // === 层2: 旧页方块层（shader 全屏绘制，方块原位淡出）===
    if (shredderShader != null && foldingPageImage != null) {
      _drawShredderBlocksWithShader(canvas, size, boundaryX: boundaryX);
    } else {
      // Fallback: shader/纹理未就绪 → 直接画旧页整页（无动画过渡）
      readerTrace('ripple.shader.missing', {
        'hasShader': shredderShader != null,
        'hasFoldingImg': foldingPageImage != null,
        'hasRevealImg': revealPageImage != null,
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
        // 实时直绘旧页（纸色底/参数由 _paintPage 统一处理，v16.9.5）
        _paintPage(canvas, foldingPage, size);
      }
    }

    sw.stop();
    if (sw.elapsedMilliseconds > 8) {
      readerTrace('ripple.paint.slow', {
        'elapsedMs': sw.elapsedMilliseconds,
        'progress': progress.toStringAsFixed(3),
      });
    }
  }

  /// 用 Shader 全屏绘制旧页方块层（v16.9: 单纹理原位淡出）
  void _drawShredderBlocksWithShader(
    Canvas canvas,
    Size size, {
    required double boundaryX,
  }) {
    if (shredderShader == null || foldingPageImage == null) return;

    // 设置 shader 参数（v16.9.7 uniform 布局：9 个 float + 1 sampler）
    shredderShader!.setFloat(0, size.width);   // uResolution.x
    shredderShader!.setFloat(1, size.height);  // uResolution.y
    shredderShader!.setFloat(2, progress);     // uProgress
    shredderShader!.setFloat(3, _blockSize);   // uBlockSize
    shredderShader!.setFloat(4, direction == PageDirection.next ? 1.0 : -1.0);  // uDirection
    shredderShader!.setFloat(5, boundaryX);    // uBoundaryX
    shredderShader!.setFloat(6, _waveAmp);     // uWaveAmp
    shredderShader!.setFloat(7, _waveLength);  // uWaveLength
    shredderShader!.setFloat(8, waveSeed);     // uSeed（每页随机，波形不规则化）
    // uShadowColor（vec3 → 索引 9/10/11）
    shredderShader!.setFloat(9, shadowColor.r);
    shredderShader!.setFloat(10, shadowColor.g);
    shredderShader!.setFloat(11, shadowColor.b);

    // 单纹理：旧页
    shredderShader!.setImageSampler(0, foldingPageImage!);  // uPageTexture

    // shader 全屏绘制旧页方块层
    final paint = Paint()..shader = shredderShader;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      paint,
    );
  }

  /// 实时直绘一页（v16.9.5 统一模板：纸色底 + notifier 同源渲染参数）
  /// paint 的 progress 短路路径 / fallback 全部经由此方法 → 自动带纸色底
  /// 与用户渲染参数，trailing 帧（progress 0.999~0.9999）与正式渲染逐像素一致
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
  bool shouldRepaint(RipplePainterV16 oldDelegate) {
    return (progress - oldDelegate.progress).abs() > 0.005 ||
           direction != oldDelegate.direction ||
           foldingPage != oldDelegate.foldingPage ||
           revealPage != oldDelegate.revealPage ||
           foldingPageImage != oldDelegate.foldingPageImage ||
           revealPageImage != oldDelegate.revealPageImage ||
           shredderShader != oldDelegate.shredderShader;
  }
}
