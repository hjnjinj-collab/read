import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../../core/models/simple_models.dart';
import '../../diagnostics/reader_trace.dart';
import '../reader_page_widget.dart';
import 'page_turn_types.dart';

/// 水波纹翻页绘制器
///
/// 2026-09-03 v15: gap=0 + 方块重叠，彻底消除间隙穿透
///
/// **v14 失败原因**（用户截图反馈）：
/// 1. v14 gap=3px 仍有间隙穿透（用户能看穿到下方旧内容）
/// 2. 用户原话："我们本身就是要用这个方块动画来修饰这个分割线"
/// 3. 必须确保方块之间**零间隙**或**互相重叠**
///
/// **v15 核心方案**：
/// 1. **gap=0**：方块之间无间隙（v14 的 3px → 0）
/// 2. **方块大小 28px > 步长 26px**：方块**互相重叠 2px**，完全遮盖
/// 3. **多列密铺**：12 列 × ~30 行 = 360 个方块（v14 的 250 → 360）
/// 4. **全屏覆盖**：行数动态计算，铺满整个屏幕高度
/// 5. **3 种灰度**随机分布
class RipplePainter extends CustomPainter {
  final PageInfo? foldingPage;
  final PageInfo? revealPage;
  final double progress;
  final PageDirection direction;

  const RipplePainter({
    required this.foldingPage,
    required this.revealPage,
    required this.progress,
    required this.direction,
  });

  // 方块大小（像素）—— 比步长大 2px（让方块互相重叠 2px）
  static const double _blockSize = 28.0;

  // 方块步长（方块中心间距）—— 26px < 方块大小 28px → 互相重叠 2px
  // 关键：步长 < 方块大小 → 零间隙穿透
  static const double _blockStep = 26.0;

  // 沿推进方向的方块数（列数）—— 增加密度
  static const int _blockCols = 12;

  // 沿 y 方向的方块数（行数）—— **根据屏幕高度动态计算**（每行间距固定）
  // 实际行数 = (size.height + _blockStep) / _blockStep + 1

  // 方块"下落"最大距离
  static const double _fallDistance = 60.0;

  // 方块浮动幅度
  static const double _floatAmplitude = 6.0;

  // 方块旋转幅度（弧度，约 34°）
  static const double _rotationAmplitude = 0.6;

  @override
  void paint(Canvas canvas, Size size) {
    final sw = Stopwatch()..start();

    readerTrace('ripple.paint.frame', {
      'progress': progress.toStringAsFixed(3),
      'direction': direction.toString(),
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

    final isNext = direction == PageDirection.next;

    final boundaryX = isNext
        ? progress * size.width
        : (1 - progress) * size.width;

    // === 1. 新页（已推进区域）===
    if (isNext) {
      if (boundaryX > 0) {
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(0, 0, boundaryX, size.height));
        _paintPage(canvas, revealPage, size);
        canvas.restore();
      }
    } else {
      if (boundaryX < size.width) {
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(boundaryX, 0, size.width - boundaryX, size.height));
        _paintPage(canvas, revealPage, size);
        canvas.restore();
      }
    }

    // === 2. 旧页主区域（粉碎方块带外）===
    final blockBandWidth = _blockCols * _blockStep + _blockStep;
    if (isNext) {
      final mainLeft = math.min(boundaryX + blockBandWidth, size.width);
      if (mainLeft < size.width) {
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(mainLeft, 0, size.width - mainLeft, size.height));
        _paintPage(canvas, foldingPage, size);
        canvas.restore();
      }
    } else {
      final mainRight = math.max(boundaryX - blockBandWidth, 0.0);
      if (mainRight > 0) {
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(0, 0, mainRight, size.height));
        _paintPage(canvas, foldingPage, size);
        canvas.restore();
      }
    }

    // === 3. 粉碎方块带（全屏高度覆盖，修饰分割线）===
    if (isNext) {
      _drawShredderBlocks(
        canvas,
        size,
        bandLeft: boundaryX,
        bandRight: math.min(boundaryX + blockBandWidth, size.width),
        isNext: true,
      );
    } else {
      _drawShredderBlocks(
        canvas,
        size,
        bandLeft: math.max(boundaryX - blockBandWidth, 0.0),
        bandRight: boundaryX,
        isNext: false,
      );
    }

    sw.stop();
    if (sw.elapsedMilliseconds > 8) {
      readerTrace('ripple.paint.slow', {
        'elapsedMs': sw.elapsedMilliseconds,
        'progress': progress.toStringAsFixed(3),
      });
    }
  }

  /// 绘制粉碎机式方块流：
  /// - 方块沿 y 方向**铺满整个屏幕高度**（关键修复）
  /// - 每个方块独立动画：下落 + 浮动 + 旋转 + 缩放
  /// - 旋转幅度加大，让方块边缘"侵入"邻居间隙
  void _drawShredderBlocks(
    Canvas canvas,
    Size size, {
    required double bandLeft,
    required double bandRight,
    required bool isNext,
  }) {
    final bandWidth = bandRight - bandLeft;
    if (bandWidth <= 0) return;

    // 步骤 1：先在粉碎带内画旧页（作为底层）
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(bandLeft, 0, bandRight, size.height));
    _paintPage(canvas, foldingPage, size);
    canvas.restore();

    // 步骤 2：画 N×M 个方块
    // 关键：行数动态计算，确保铺满整个屏幕高度
    final colStep = _blockStep;
    final rowStep = _blockStep;
    final blockRows = ((size.height + _blockStep) / rowStep).ceil() + 1;

    final totalWidth = _blockCols * colStep + _blockStep;
    final startX = bandLeft + (bandWidth - totalWidth) / 2; // 居中
    // y 方向从 -rowStep 开始（让顶部也有方块可下落）
    final startY = -rowStep;

    // 3 种灰度（深/中/浅）
    final colors = [
      const Color(0xFF777777), // 深灰
      const Color(0xFF999999), // 中灰
      const Color(0xFFBBBBBB), // 浅灰
    ];

    for (int col = 0; col < _blockCols; col++) {
      for (int row = 0; row < blockRows; row++) {
        final blockX = startX + col * colStep;
        final blockY = startY + row * rowStep;

        // 该方块的"瀑布位置" = 距 bandLeft 的归一化距离
        final blockCenterX = blockX + _blockSize / 2;
        final distFromBoundary = ((blockCenterX - bandLeft) / bandWidth).clamp(0.0, 1.0);
        // 翻转进度
        final colProgress = isNext
            ? (progress - distFromBoundary)
            : ((1 - progress) - (1 - distFromBoundary));

        // 下落进度
        final fallProgress = (colProgress / 0.5).clamp(0.0, 1.0);
        if (fallProgress <= 0) continue;

        // === 持续动态（粉碎机感）===
        // 用 row 而非 col 计算 hash → 不同行不同步
        final blockHash = ((col * 73 + row * 131) % 1000) / 1000.0;
        final timePhase = progress * math.pi * 4;

        // 浮动（基于 hash 错开）
        final dy = fallProgress * _fallDistance
            + math.sin(timePhase + blockHash * math.pi * 2) * _floatAmplitude;

        // 旋转（幅度加大，让方块边缘侵入间隙）
        final rotation = fallProgress * _rotationAmplitude * 2
            + math.sin(timePhase * 1.5 + blockHash * math.pi) * 0.3;

        // 缩放脉动
        final scale = (1.0 - 0.25 * fallProgress)
            + math.sin(timePhase * 2 + blockHash * math.pi * 3) * 0.08;

        final color = colors[(col * 3 + row) % colors.length];

        // 绘制方块（带变换）—— **不透明**
        canvas.save();
        canvas.translate(
          blockX + _blockSize / 2,
          blockY + _blockSize / 2 + dy,
        );
        canvas.rotate(rotation);
        canvas.scale(scale);

        // 实心填充（不透明）
        final fillPaint = Paint()..color = color;
        canvas.drawRect(
          Rect.fromLTWH(
            -_blockSize / 2,
            -_blockSize / 2,
            _blockSize,
            _blockSize,
          ),
          fillPaint,
        );

        // 深色边框（增强"方块"感）
        final borderPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = const Color(0xFF444444);
        canvas.drawRect(
          Rect.fromLTWH(
            -_blockSize / 2,
            -_blockSize / 2,
            _blockSize,
            _blockSize,
          ),
          borderPaint,
        );

        canvas.restore();
      }
    }
  }

  void _paintPage(Canvas canvas, PageInfo? page, Size size) {
    if (page == null) return;
    PageContentRenderer.paintPage(canvas, page, size: size, onImageNeeded: () {});
  }

  @override
  bool shouldRepaint(RipplePainter oldDelegate) {
    return (progress - oldDelegate.progress).abs() > 0.005 ||
           direction != oldDelegate.direction ||
           foldingPage != oldDelegate.foldingPage ||
           revealPage != oldDelegate.revealPage;
  }
}
