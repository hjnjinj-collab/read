import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 全局 RepaintBoundary key，用于截取主题切换前的画面快照。
final GlobalKey appRepaintKey = GlobalKey();

/// 快照吞噬式主题过渡。
///
/// 流程（紧凑时序）：
/// 1. 等图标/胶囊动画完成
/// 2. 立刻截图（高 pixelRatio 保持清晰度）
/// 3. 立刻插入全屏 Overlay
/// 4. 立刻触发主题切换 + 吞噬动画
class CircularRevealTheme {
  CircularRevealTheme._();

  /// 触发快照吞噬式主题过渡。
  ///
  /// [captureDelay] 截图前等待时间，需与图标填充动画时长精确对齐（700ms）。
  /// 动画完成 → 立刻截图 → 立刻插入 Overlay → 立刻触发过渡，无额外等待。
  static Future<void> reveal({
    required BuildContext context,
    required Offset globalPosition,
    required VoidCallback onThemeChange,
    Duration duration = const Duration(milliseconds: 700),
    Duration captureDelay = const Duration(milliseconds: 700),
  }) async {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) {
      onThemeChange();
      return;
    }

    final size = MediaQuery.sizeOf(context);
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final maxRadius = _maxDistance(globalPosition, size);
    final completer = Completer<void>();

    // 1. 等待图标填充动画完成（与动画时长精确对齐）
    if (captureDelay > Duration.zero) {
      await Future.delayed(captureDelay);
    }

    // 2. 立刻截图（动画控制器已保证帧渲染完成，无需额外 endOfFrame）
    ui.Image? rawSnapshot;
    try {
      final boundary = appRepaintKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary != null && boundary.attached) {
        rawSnapshot = await boundary.toImage(pixelRatio: pixelRatio);
      }
    } catch (_) {
      rawSnapshot = null;
    }

    if (rawSnapshot == null) {
      onThemeChange();
      if (!completer.isCompleted) completer.complete();
      return completer.future;
    }

    final snapshot = rawSnapshot;
    final progress = ValueNotifier<double>(0.0);

    // 3. 立刻插入全屏 Overlay
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) {
        return SizedBox(
          width: size.width,
          height: size.height,
          child: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (context, t, _) {
              final radius =
                  maxRadius * Curves.easeInOutCubic.transform(t);
              return IgnorePointer(
                child: CustomPaint(
                  painter: _SnapshotSwallowPainter(
                    image: snapshot,
                    center: globalPosition,
                    holeRadius: radius,
                    size: size,
                  ),
                  size: size,
                ),
              );
            },
          ),
        );
      },
    );

    overlay.insert(entry);

    // 4. 立刻触发主题切换 + 吞噬动画
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      onThemeChange();

      const stepMs = 8;
      final steps = (duration.inMilliseconds / stepMs).round();
      for (var i = 1; i <= steps; i++) {
        await Future.delayed(const Duration(milliseconds: stepMs));
        progress.value = i / steps;
      }

      entry.remove();
      snapshot.dispose();
      if (!completer.isCompleted) completer.complete();
    });

    return completer.future;
  }

  static double _maxDistance(Offset center, Size size) {
    final corners = [
      Offset.zero,
      Offset(size.width, 0),
      Offset(0, size.height),
      Offset(size.width, size.height),
    ];
    double max = 0;
    for (final c in corners) {
      final d = (c - center).distance;
      if (d > max) max = d;
    }
    return max;
  }
}

/// 快照吞噬画家：绘制快照，但从 center 挖掉半径为 holeRadius 的圆。
class _SnapshotSwallowPainter extends CustomPainter {
  const _SnapshotSwallowPainter({
    required this.image,
    required this.center,
    required this.holeRadius,
    required this.size,
  });

  final ui.Image image;
  final Offset center;
  final double holeRadius;
  final Size size;

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final dst = Offset.zero & size;

    canvas.save();
    if (holeRadius > 0) {
      final holePath = Path()
        ..addOval(Rect.fromCircle(center: center, radius: holeRadius));
      final clipPath = Path.combine(
        PathOperation.difference,
        Path()..addRect(dst),
        holePath,
      );
      canvas.clipPath(clipPath);
    }
    // 高质量绘制：使用高质量滤镜
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.high,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SnapshotSwallowPainter oldDelegate) =>
      oldDelegate.holeRadius != holeRadius ||
      oldDelegate.center != center;
}
