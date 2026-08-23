import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../../core/models/simple_models.dart';
import '../services/book_image_store.dart';

class ReaderPageWidget extends StatefulWidget {
  final PageInfo pageInfo;

  const ReaderPageWidget({
    Key? key,
    required this.pageInfo,
  }) : super(key: key);

  @override
  State<ReaderPageWidget> createState() => _ReaderPageWidgetState();
}

class _ReaderPageWidgetState extends State<ReaderPageWidget> {
  /// 图片异步解码完成后的重绘信号（传给 CustomPainter.repaint）
  final ValueNotifier<int> _repaintTick = ValueNotifier<int>(0);

  @override
  void dispose() {
    _repaintTick.dispose();
    super.dispose();
  }

  void _onImageReady() {
    _repaintTick.value++;
    // 帧末重绘，避免在回调栈内直接标记
    SchedulerBinding.instance.scheduleFrame();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: PagePainter(
        widget.pageInfo,
        repaint: _repaintTick,
        onImageNeeded: _onImageReady,
      ),
      size: Size.infinite,
    );
  }
}

/// 页面绘制器：先画整页背景（EPUB 装饰页），再按 entries 绘制文本/图片
class PagePainter extends CustomPainter {
  final PageInfo pageInfo;
  final VoidCallback onImageNeeded;

  static const Color _paperColor = Color(0xFFF5F1E8);

  PagePainter(
    this.pageInfo, {
    required ValueNotifier<int> repaint,
    required this.onImageNeeded,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _paperColor);

    // 整页背景：严格按 CSS background-size 语义绘制——
    // - cover/缺省：等比铺满窗口、溢出部分按 background-position 锚点裁切
    // - contain：完整显示
    // - stretch（100% 100%）：拉伸铺满
    // 不做任何桌面端替代策略（用户定论：样式表怎么写就怎么显示）
    final bgHref = pageInfo.backgroundHref;
    if (bgHref != null) {
      final bg = BookImageStore.instance.get(bgHref);
      if (bg != null) {
        _paintBackground(canvas, bg, Offset.zero & size);
      } else {
        BookImageStore.instance.ensureLoaded(bgHref, onImageNeeded);
      }
    }

    for (final entry in pageInfo.entries) {
      final href = entry.resourceHref;
      if (href != null) {
        final image = BookImageStore.instance.get(href);
        if (image != null) {
          // paintImage 按目标矩形拉伸——布局引擎已折算好等比尺寸
          paintImage(
            canvas: canvas,
            rect: Rect.fromLTWH(entry.x, entry.y, entry.width, entry.height),
            image: image,
            fit: BoxFit.fill,
          );
        } else {
          // 解码中占位：浅灰圆角块 + 边框
          final rect = Rect.fromLTWH(
              entry.x, entry.y, entry.width, entry.height);
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(6)),
            Paint()..color = const Color(0xFFDDDDDD),
          );
          BookImageStore.instance.ensureLoaded(href, onImageNeeded);
        }
        continue;
      }

      final text = entry.text;
      if (text == null || text.isEmpty) continue;
      final baseColor = _parseHexColor(entry.color) ?? Colors.black;
      final baseScale = entry.fontScale ?? 1.0;
      final baseStyle = TextStyle(
        color: baseColor,
        fontSize: 18 * baseScale,
        height: 1.5,
        fontFamily: 'sans-serif',
      );

      final TextSpan textSpan;
      if (entry.segments.isEmpty) {
        textSpan = TextSpan(text: text, style: baseStyle);
      } else {
        // 行内富文本：分段覆盖样式，间隙回填默认样式
        final children = <InlineSpan>[];
        var cursor = 0;
        for (final seg in entry.segments) {
          final s = seg.start.clamp(0, text.length);
          final e = seg.end.clamp(s, text.length);
          if (s > cursor) {
            children.add(TextSpan(text: text.substring(cursor, s)));
          }
          if (e > s) {
            children.add(TextSpan(
              text: text.substring(s, e),
              style: TextStyle(
                color: _parseHexColor(seg.color) ?? baseColor,
                fontSize: 18 * (seg.fontScale ?? baseScale),
                height: 1.5,
                fontFamily: 'sans-serif',
              ),
            ));
            cursor = e;
          }
        }
        if (cursor < text.length) {
          children.add(TextSpan(text: text.substring(cursor)));
        }
        textSpan = TextSpan(style: baseStyle, children: children);
      }

      final textPainter = TextPainter(
        text: textSpan,
        textAlign: TextAlign.left,
        textDirection: TextDirection.ltr,
      );

      textPainter.layout(
        minWidth: 0,
        maxWidth: entry.width,
      );

      textPainter.paint(canvas, Offset(entry.x, entry.y));
    }
  }

  /// `#rgb`/`#rrggbb` 十六进制色解析（非法形态返回 null 回落主题色）
  static Color? _parseHexColor(String? hex) {
    if (hex == null) return null;
    var h = hex.replaceFirst('#', '');
    if (h.length == 3) {
      h = h.split('').map((c) => c + c).join();
    }
    if (h.length != 6) return null;
    final v = int.tryParse('ff$h', radix: 16);
    return v == null ? null : Color(v);
  }

  /// 背景铺放：严格 CSS background-size 语义 + position 锚点
  void _paintBackground(Canvas canvas, ui.Image image, Rect rect) {
    final mode = pageInfo.backgroundSize;

    // stretch：拉伸铺满（允许变形，对应 background-size:100% 100%）
    if (mode == 'stretch') {
      paintImage(
        canvas: canvas,
        rect: rect,
        image: image,
        fit: BoxFit.fill,
      );
      return;
    }

    // cover/contain 共用：fit 由模式决定，锚点由 position 关键字决定
    // （"bottom center" → 底边对齐；"left top" → 左上对齐；缺省居中）
    final pos = pageInfo.backgroundPosition ?? '';
    final x = pos.contains('left') ? -1.0 : (pos.contains('right') ? 1.0 : 0.0);
    final y = pos.contains('top') ? -1.0 : (pos.contains('bottom') ? 1.0 : 0.0);
    paintImage(
      canvas: canvas,
      rect: rect,
      image: image,
      fit: mode == 'contain' ? BoxFit.contain : BoxFit.cover,
      alignment: Alignment(x, y),
      filterQuality: FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(PagePainter oldDelegate) {
    return oldDelegate.pageInfo != pageInfo;
  }
}
