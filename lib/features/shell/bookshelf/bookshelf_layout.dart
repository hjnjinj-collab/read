import 'package:flutter/material.dart';

/// 书架网格几何：与 BookshelfPage GridView 同源，供 FLIP / 阅读转场共用
class BookshelfLayout {
  BookshelfLayout._();

  static const double padH = 12;
  static const double gap = 12;
  static const double childAspectRatio = 0.68;

  static int columnsForWidth(double width) {
    if (width < 360) return 2;
    if (width < 700) return 3;
    if (width < 1000) return 4;
    return 5;
  }

  static double cellWidth(double width, int cols) =>
      (width - padH * 2 - gap * (cols - 1)) / cols;

  static double cellHeight(double cellW) => cellW / childAspectRatio;

  /// 网格槽位左上角（相对 GridView 内容区）
  static Offset cellOrigin(
    int index, {
    required int cols,
    required double cellW,
    required double cellH,
  }) {
    final col = index % cols;
    final row = index ~/ cols;
    return Offset(col * (cellW + gap), row * (cellH + gap));
  }

  /// 第 index 本封面中心在屏幕上的 Alignment（供 ScaleTransition 落点）
  ///
  /// [topContent] 为网格第一个 cell 顶边相对屏幕顶的 y
  ///（书架 = MediaQuery.padding.top + 顶栏玻璃 96 + 4）。
  static Alignment slotAlignment(
    BuildContext context, {
    required int index,
    required double topContent,
  }) {
    final size = MediaQuery.sizeOf(context);
    final cols = columnsForWidth(size.width);
    final cellW = cellWidth(size.width, cols);
    final cellH = cellHeight(cellW);
    final origin = cellOrigin(index, cols: cols, cellW: cellW, cellH: cellH);
    final cx = padH + origin.dx + cellW / 2;
    final cy = topContent + origin.dy + cellH / 2;
    return Alignment(
      (cx / size.width) * 2 - 1,
      (cy / size.height) * 2 - 1,
    );
  }
}
