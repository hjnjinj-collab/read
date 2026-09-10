import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/simple_models.dart';
import '../../../../core/services/reader_font.dart';
import '../providers/reader_provider.dart';

/// A31-v4: 选区高亮独立覆盖层
///
/// **关键架构改进**：选区高亮不再放在整页 CustomPaint 内部，
/// 而是独立的 CustomPainter，只监听 _selectionTick。
/// 拖拽选区时只重绘高亮矩形（几个 Rect），不触发整页 TextPainter 重建。
///
/// 旧架构问题：updateSelection → selectionTick++ → 整页重绘
///   → 所有 TextPainter 重新 layout → 拖拽卡顿不跟手
/// 新架构：updateSelection → selectionTick++ → 只重绘高亮层（<1ms）
class SelectionHighlightPainter extends CustomPainter {
  final PageInfo page;
  final int? start;
  final int? end;
  final double baseFontSize;
  final double baseLineHeight;

  SelectionHighlightPainter({
    required this.page,
    required this.start,
    required this.end,
    required this.baseFontSize,
    required this.baseLineHeight,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (start == null || end == null) return;
    final paint = Paint()..color = Colors.blue.withValues(alpha: 0.3);

    for (final entry in page.entries) {
      final text = entry.text;
      if (text == null || !entry.hasCharRange) continue;
      final overlapStart = start!.clamp(entry.startCharIndex!, entry.endCharIndex!);
      final overlapEnd = end!.clamp(entry.startCharIndex!, entry.endCharIndex!);
      if (overlapStart >= overlapEnd) continue;

      final baseStyle = TextStyle(
        fontSize: baseFontSize * (entry.fontScale ?? 1.0),
        height: baseLineHeight,
        fontFamily: ReaderFont.family,
        letterSpacing: entry.letterGap,
      );
      final textPainter = TextPainter(
        text: TextSpan(text: text, style: baseStyle),
        textDirection: TextDirection.ltr,
      )..layout(minWidth: 0, maxWidth: double.infinity);

      final localStart = overlapStart - entry.startCharIndex!;
      final localEnd = overlapEnd - entry.startCharIndex!;
      final boxes = textPainter.getBoxesForSelection(
        TextSelection(
          baseOffset: localStart.clamp(0, text.length),
          extentOffset: localEnd.clamp(0, text.length),
        ),
      );
      textPainter.dispose();

      for (final box in boxes) {
        canvas.drawRect(
          Rect.fromLTRB(
            entry.x + box.left,
            entry.y + box.top,
            entry.x + box.right,
            entry.y + box.bottom,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(SelectionHighlightPainter oldDelegate) {
    return oldDelegate.start != start ||
        oldDelegate.end != end ||
        oldDelegate.page != page;
  }
}

/// A31-v4: 选区高亮覆盖层 Widget
///
/// Positioned.fill 放在阅读区域 Stack 中，只画高亮矩形。
/// 工具条和手柄在 ReaderSelectionOverlay 中（层级更高）。
class SelectionHighlightLayer extends ConsumerWidget {
  final PageInfo page;

  const SelectionHighlightLayer({super.key, required this.page});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(readerProvider.notifier);
    final fontSize = notifier.fontSize;
    final lineHeight = notifier.lineHeight;

    return ValueListenableBuilder<int>(
      valueListenable: notifier.selectionTick,
      builder: (context, _, __) {
        if (!notifier.hasSelection) return const SizedBox.shrink();
        return Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: SelectionHighlightPainter(
                page: page,
                start: notifier.selectionStart,
                end: notifier.selectionEnd,
                baseFontSize: fontSize,
                baseLineHeight: lineHeight,
                repaint: notifier.selectionTick,
              ),
            ),
          ),
        );
      },
    );
  }
}
