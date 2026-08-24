import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../../core/models/simple_models.dart';
import '../../../../core/services/reader_font.dart';
import '../services/book_image_store.dart';

class ReaderPageWidget extends StatefulWidget {
  final PageInfo pageInfo;
  /// 字形开关（纯绘制期过滤：粗/斜按用户设置应用，下划线恒应用）
  final bool applyBold;
  final bool applyItalic;
  /// TXT 章节标题加粗（粗体开关 && 非 EPUB；EPUB 章首行不加粗）
  final bool applyTitleBold;
  /// 排版基准（M7 与 Rust 同源：替换硬编码 18/1.5，保证绘制与断行一致）
  final double baseFontSize;
  final double baseLineHeight;

  const ReaderPageWidget({
    Key? key,
    required this.pageInfo,
    this.applyBold = true,
    this.applyItalic = true,
    this.applyTitleBold = false,
    this.baseFontSize = 18.0,
    this.baseLineHeight = 1.5,
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
        applyBold: widget.applyBold,
        applyItalic: widget.applyItalic,
        applyTitleBold: widget.applyTitleBold,
        baseFontSize: widget.baseFontSize,
        baseLineHeight: widget.baseLineHeight,
      ),
      size: Size.infinite,
    );
  }
}

/// 页面绘制器：先画整页背景（EPUB 装饰页），再按 entries 绘制文本/图片
class PagePainter extends CustomPainter {
  final PageInfo pageInfo;
  final VoidCallback onImageNeeded;
  final bool applyBold;
  final bool applyItalic;
  final bool applyTitleBold;
  final double baseFontSize;
  final double baseLineHeight;

  static const Color _paperColor = Color(0xFFF5F1E8);

  PagePainter(
    this.pageInfo, {
    required ValueNotifier<int> repaint,
    required this.onImageNeeded,
    this.applyBold = true,
    this.applyItalic = true,
    this.applyTitleBold = false,
    this.baseFontSize = 18.0,
    this.baseLineHeight = 1.5,
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

      // 表格单元格线框：细灰描边（不填充；几何由布局引擎折算）
      if (entry.isTableFrame) {
        canvas.drawRect(
          Rect.fromLTWH(entry.x, entry.y, entry.width, entry.height),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.0
            ..color = const Color(0xFF999999),
        );
        continue;
      }

      final text = entry.text;
      if (text == null || text.isEmpty) continue;
      final baseColor = entry.isComment
          ? const Color(0xFF888888)
          : (_parseHexColor(entry.color) ?? Colors.black);
      final baseScale = entry.fontScale ?? 1.0;
      // TXT 章节标题加粗（与 EPUB 行内粗体同一开关；TextSpan 子段
      // 未显式设置时继承父级，segments 分支无需重复判断）
      final baseStyle = TextStyle(
        color: baseColor,
        fontSize: baseFontSize * baseScale,
        height: baseLineHeight,
        fontFamily: ReaderFont.family,
        fontWeight:
            (applyTitleBold && entry.isChapterStart) ? FontWeight.w700 : null,
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
                fontSize: baseFontSize * (seg.fontScale ?? baseScale),
                height: baseLineHeight,
                fontFamily: ReaderFont.family,
                // 合成粗/斜体（绘制期，不参与 Rust 断行测量）；
                // null 时继承行级默认
                fontWeight:
                    (seg.bold && applyBold) ? FontWeight.w700 : null,
                fontStyle:
                    (seg.italic && applyItalic) ? FontStyle.italic : null,
                decoration:
                    seg.underline ? TextDecoration.underline : null,
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

      // M7：恒定无约束排版——消灭「Rust 测窄 → TextPainter 二次换行 →
      // 与下一行重叠/页尾截断」（内容跨页丢失重复的直接来源）
      textPainter.layout(minWidth: 0, maxWidth: double.infinity);
      final naturalWidth = textPainter.maxIntrinsicWidth;

      if (naturalWidth <= entry.width * 1.02 || entry.width <= 0) {
        // 正常或轻微超宽（≤2%，epsilon 已把概率压到极低）：原样绘制，
        // 几 px 渗入右 padding 无感知，保字形保真
        textPainter.paint(canvas, Offset(entry.x, entry.y));
      } else {
        // 显著超宽（粗体合成/窄列等残余场景）：该行整体等比缩放，
        // 宁可字形略小也不丢字
        final s = entry.width / naturalWidth;
        canvas.save();
        canvas.translate(entry.x, entry.y);
        canvas.scale(s);
        textPainter.paint(canvas, Offset.zero);
        canvas.restore();
      }
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
    return oldDelegate.pageInfo != pageInfo ||
        oldDelegate.applyBold != applyBold ||
        oldDelegate.applyItalic != applyItalic ||
        oldDelegate.applyTitleBold != applyTitleBold ||
        oldDelegate.baseFontSize != baseFontSize ||
        oldDelegate.baseLineHeight != baseLineHeight;
  }
}
