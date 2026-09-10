import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/models/simple_models.dart';
import '../../../../core/services/reader_font.dart';
import '../providers/reader_provider.dart';

/// A31: 文本选区 Overlay（重命名为 ReaderSelectionOverlay 避免与 Flutter 内置 TextSelectionOverlay 冲突）
///
/// 长按文字激活选区后显示：
/// - 选区高亮矩形（半透明蓝色）
/// - 两端拖拽手柄（圆形把手）
/// - 浮动工具条（复制 / 划线 / 备注 / 取消）
///
/// 通过 [readerProvider] 的 selectionTick 驱动重绘。
/// 手势仲裁：选区激活期间，读者页的翻页拖拽应被抑制
/// （由 reader_page 通过 hasSelection 判定）。
class ReaderSelectionOverlay extends ConsumerStatefulWidget {
  final PageInfo page;
  final double baseFontSize;
  final double baseLineHeight;

  const ReaderSelectionOverlay({
    super.key,
    required this.page,
    this.baseFontSize = 18.0,
    this.baseLineHeight = 1.5,
  });

  @override
  ConsumerState<ReaderSelectionOverlay> createState() =>
      _ReaderSelectionOverlayState();
}

class _ReaderSelectionOverlayState extends ConsumerState<ReaderSelectionOverlay> {
  /// 当前正在拖拽哪个手柄（null=无拖拽）
  int? _draggingHandle; // 0=start, 1=end

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(readerProvider.notifier);
    return ValueListenableBuilder<int>(
      valueListenable: notifier.selectionTick,
      builder: (context, tick, _) {
        if (!notifier.hasSelection) return const SizedBox.shrink();
        return _buildOverlay(context, notifier);
      },
    );
  }

  Widget _buildOverlay(BuildContext context, ReaderNotifier notifier) {
    final start = notifier.selectionStart!;
    final end = notifier.selectionEnd!;
    final page = widget.page;

    // 计算选区矩形列表（逐 entry 求交）
    final rects = <Rect>[];
    Offset? firstCharTopLeft;
    Offset? lastCharBottomRight;

    for (final entry in page.entries) {
      final text = entry.text;
      if (text == null || !entry.hasCharRange) continue;
      final overlapStart = start.clamp(entry.startCharIndex!, entry.endCharIndex!);
      final overlapEnd = end.clamp(entry.startCharIndex!, entry.endCharIndex!);
      if (overlapStart >= overlapEnd) continue;

      // 构建 TextPainter 获取选区 boxes
      final baseStyle = TextStyle(
        fontSize: widget.baseFontSize * (entry.fontScale ?? 1.0),
        height: widget.baseLineHeight,
        fontFamily: ReaderFont.family,
        letterSpacing: entry.letterGap,
      );
      final textPainter = TextPainter(
        text: TextSpan(text: text, style: baseStyle),
        textDirection: TextDirection.ltr,
      )..layout(minWidth: 0, maxWidth: double.infinity);

      final localStart = overlapStart - entry.startCharIndex!;
      final localEnd = overlapEnd - entry.startCharIndex!;
      // Flutter TextPainter.getBoxesForSelection 返回选区矩形列表
      final boxes = textPainter.getBoxesForSelection(
        TextSelection(
          baseOffset: localStart.clamp(0, text.length),
          extentOffset: localEnd.clamp(0, text.length),
        ),
      );
      for (final box in boxes) {
        final rect = Rect.fromLTRB(
          entry.x + box.left,
          entry.y + box.top,
          entry.x + box.right,
          entry.y + box.bottom,
        );
        rects.add(rect);
        // 记录首尾字符位置（用于工具条定位）
        firstCharTopLeft ??= rect.topLeft;
        lastCharBottomRight = rect.bottomRight;
      }
      textPainter.dispose();
    }

    if (rects.isEmpty) return const SizedBox.shrink();

    // 工具条位置：选区上方居中（若上方空间不足则放下方）
    final toolbarY = (firstCharTopLeft!.dy - 56).clamp(8.0, double.infinity);
    final toolbarX = ((firstCharTopLeft!.dx + lastCharBottomRight!.dx) / 2 - 120)
        .clamp(8.0, MediaQuery.of(context).size.width - 248);

    return Stack(
      children: [
        // 选区高亮矩形（半透明蓝）
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _SelectionHighlightPainter(rects),
            ),
          ),
        ),
        // 拖拽手柄
        ..._buildHandles(rects, notifier),
        // 浮动工具条
        Positioned(
          left: toolbarX,
          top: toolbarY,
          child: _buildToolbar(context, notifier),
        ),
      ],
    );
  }

  List<Widget> _buildHandles(
    List<Rect> rects,
    ReaderNotifier notifier,
  ) {
    final handles = <Widget>[];
    // start 手柄：选区左上角
    final startRect = rects.first;
    handles.add(
      _buildHandle(
        position: Offset(startRect.left - 1, startRect.bottom),
        isStart: true,
        notifier: notifier,
      ),
    );
    // end 手柄：选区右下角
    final endRect = rects.last;
    handles.add(
      _buildHandle(
        position: Offset(endRect.right - 12, endRect.bottom),
        isStart: false,
        notifier: notifier,
      ),
    );
    return handles;
  }

  Widget _buildHandle({
    required Offset position,
    required bool isStart,
    required ReaderNotifier notifier,
  }) {
    return Positioned(
      left: position.dx,
      top: position.dy - 4,
      child: GestureDetector(
        onPanStart: (_) => _draggingHandle = isStart ? 0 : 1,
        onPanUpdate: (details) {
          final page = widget.page;
          final hitOffset = notifier.hitTestCharOffset(
            details.localPosition + position,
            page,
          );
          if (hitOffset == null) return;
          if (isStart) {
            if (hitOffset < notifier.selectionEnd!) {
              notifier.beginSelection(hitOffset);
            }
          } else {
            notifier.updateSelection(hitOffset);
          }
        },
        onPanEnd: (_) => _draggingHandle = null,
        child: Container(
          width: 16,
          height: 28,
          decoration: BoxDecoration(
            color: Colors.blue.shade600,
            borderRadius: BorderRadius.circular(4),
          ),
          child: CustomPaint(
            painter: _HandlePainter(isStart: isStart),
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar(BuildContext context, ReaderNotifier notifier) {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(8),
      color: Colors.grey.shade800,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _toolbarButton(
            icon: Icons.copy,
            label: '复制',
            onTap: () {
              // TODO: 复制到剪贴板
              notifier.clearSelection();
            },
          ),
          _toolbarButton(
            icon: Icons.highlight,
            label: '划线',
            onTap: () => _addHighlight(notifier),
          ),
          _toolbarButton(
            icon: Icons.edit_note,
            label: '备注',
            onTap: () => _addNoteWithText(context, notifier),
          ),
          _toolbarButton(
            icon: Icons.close,
            label: '取消',
            onTap: () => notifier.clearSelection(),
          ),
        ],
      ),
    );
  }

  Widget _toolbarButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  /// 直接划线（默认黄色高亮，无备注）
  Future<void> _addHighlight(ReaderNotifier notifier) async {
    final excerpt = notifier.selectionText;
    if (excerpt.isEmpty) return;
    await notifier.addNote(
      chapterIndex: widget.page.chapterIndex,
      startCharOffset: notifier.selectionStart!,
      endCharOffset: notifier.selectionEnd!,
      excerpt: excerpt,
      colorIndex: 0, // 黄色
    );
    notifier.clearSelection();
  }

  /// 添加备注（弹出编辑框）
  Future<void> _addNoteWithText(
    BuildContext context,
    ReaderNotifier notifier,
  ) async {
    final excerpt = notifier.selectionText;
    if (excerpt.isEmpty) return;
    final controller = TextEditingController();
    final colorIndex = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加备注'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 摘录预览
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.yellow.shade50,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                excerpt.length > 50 ? '${excerpt.substring(0, 50)}…' : excerpt,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: '输入备注…',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            // 颜色选择
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _colorDot(ctx, 0, Colors.yellow.shade300),
                _colorDot(ctx, 1, Colors.green.shade300),
                _colorDot(ctx, 2, Colors.blue.shade300),
                _colorDot(ctx, 3, Colors.pink.shade300),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 0), // 默认黄色
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (colorIndex == null) return;
    await notifier.addNote(
      chapterIndex: widget.page.chapterIndex,
      startCharOffset: notifier.selectionStart!,
      endCharOffset: notifier.selectionEnd!,
      excerpt: excerpt,
      colorIndex: colorIndex,
      note: controller.text.isNotEmpty ? controller.text : null,
    );
    notifier.clearSelection();
  }

  Widget _colorDot(BuildContext context, int index, Color color) {
    return GestureDetector(
      onTap: () => Navigator.pop(context, index),
      child: Container(
        width: 32,
        height: 32,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.grey.shade400),
        ),
      ),
    );
  }
}

/// 选区高亮矩形绘制器
class _SelectionHighlightPainter extends CustomPainter {
  final List<Rect> rects;

  _SelectionHighlightPainter(this.rects);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.blue.withValues(alpha: 0.3);
    for (final rect in rects) {
      canvas.drawRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(_SelectionHighlightPainter oldDelegate) =>
      oldDelegate.rects != rects;
}

/// 手柄绘制器（三角形指示方向）
class _HandlePainter extends CustomPainter {
  final bool isStart;

  _HandlePainter({required this.isStart});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white;
    final path = Path();
    if (isStart) {
      // 向左的三角
      path.moveTo(size.width * 0.3, size.height * 0.3);
      path.lineTo(size.width * 0.7, size.height * 0.2);
      path.lineTo(size.width * 0.7, size.height * 0.8);
    } else {
      // 向右的三角
      path.moveTo(size.width * 0.7, size.height * 0.3);
      path.lineTo(size.width * 0.3, size.height * 0.2);
      path.lineTo(size.width * 0.3, size.height * 0.8);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_HandlePainter oldDelegate) => oldDelegate.isStart != isStart;
}
