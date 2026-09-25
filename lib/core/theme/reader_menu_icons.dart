import 'package:flutter/material.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

/// 阅读菜单图标集（Iconsax 族，与壳层 [AppIcons] 同源，不混 Material）。
///
/// 三档风格（对标 `iconStyle`）：
/// - `0` 线性：outline 字形
/// - `1` 面性（默认）：`_copy` 填充字形
/// - `2` 双色：填充底字 + 线性主字叠色
class ReaderMenuIcons {
  ReaderMenuIcons._();

  // ── 顶栏 ──
  static const lineBack = Iconsax.arrow_left;
  static const fillBack = Iconsax.arrow_left_copy;
  static const lineMore = Iconsax.more;
  static const fillMore = Iconsax.more_copy;

  // ── 工具排 / 悬浮圆键 ──
  static const lineCatalog = Iconsax.book_1;
  static const fillCatalog = Iconsax.book_1_copy;
  static const lineSearch = Iconsax.search_normal;
  static const fillSearch = Iconsax.search_normal_copy;
  static const lineBookmark = Iconsax.bookmark;
  static const fillBookmark = Iconsax.bookmark_copy;
  static const lineNotes = Iconsax.edit_2;
  static const fillNotes = Iconsax.edit_2_copy;
  static const lineSettings = Iconsax.setting_2;
  static const fillSettings = Iconsax.setting_2_copy;
  static const lineMinus = Iconsax.minus;
  static const fillMinus = Iconsax.minus_copy;
  static const linePlus = Iconsax.add;
  static const fillPlus = Iconsax.add_copy;
  static const lineClose = Iconsax.close_circle;
  static const fillClose = Iconsax.close_circle_copy;

  // ── 设置 sheet 四页 ──
  static const lineForm = Iconsax.category_2;
  static const fillForm = Iconsax.category_2_copy;
  static const lineType = Iconsax.document_text;
  static const fillType = Iconsax.document_text_copy;
  static const lineBg = Iconsax.colorfilter;
  static const fillBg = Iconsax.colorfilter_copy;
  static const lineMaterial = Iconsax.glass_1;
  static const fillMaterial = Iconsax.glass_1_copy;

  // ── 形态与图标（栏目/分段）──
  static const lineModeTraditional = Iconsax.row_horizontal;
  static const fillModeTraditional = Iconsax.row_horizontal_copy;
  static const lineModeFloating = Iconsax.airdrop;
  static const fillModeFloating = Iconsax.airdrop_copy;
  static const lineIconStyle = Iconsax.brush_1;
  static const fillIconStyle = Iconsax.brush_1_copy;
  static const lineGrid = Iconsax.element_3;
  static const fillGrid = Iconsax.element_3_copy;
  static const lineRows = Iconsax.row_vertical;
  static const fillRows = Iconsax.row_vertical_copy;
  static const lineShowText = Iconsax.text;
  static const fillShowText = Iconsax.text_copy;

  // ── 排版补充 ──
  static const lineTitle = Iconsax.text_bold;
  static const fillTitle = Iconsax.text_bold_copy;
  static const lineLetter = Iconsax.textalign_center;
  static const fillLetter = Iconsax.textalign_center_copy;
  static const lineHeader = Iconsax.arrow_up;
  static const fillHeader = Iconsax.arrow_up_copy;
  static const lineFooter = Iconsax.arrow_down;
  static const fillFooter = Iconsax.arrow_down_copy;

  // ── 背景 / 材质补充 ──
  static const lineDay = Iconsax.sun_1;
  static const fillDay = Iconsax.sun_1_copy;
  static const lineNight = Iconsax.moon;
  static const fillNight = Iconsax.moon_copy;
  static const lineOpacity = Iconsax.drop;
  static const fillOpacity = Iconsax.glass;
  static const linePreset = Iconsax.gallery;
  static const fillPreset = Iconsax.gallery_copy;
  static const lineTheme = Iconsax.magicpen;
  static const fillTheme = Iconsax.magicpen_copy;
  static const lineBlur = Iconsax.blur;
  static const fillBlur = Iconsax.blur_copy;
  static const lineMerge = Iconsax.hierarchy_2;
  static const fillMerge = Iconsax.hierarchy_2_copy;
  static const linePill = Iconsax.toggle_on;
  static const fillPill = Iconsax.toggle_on_copy;
  static const lineSize = Iconsax.size;
  static const fillSize = Iconsax.size_copy;
  static const lineRank = Iconsax.ranking;
  static const fillRank = Iconsax.ranking_copy;

  /// 按风格解析成最终字形（线性/面性；双色由 [ReaderMenuGlyph] 叠色）。
  static IconData resolve({
    required IconData line,
    required IconData fill,
    required int style,
  }) =>
      style == 0 ? line : fill;
}

/// 三档图标渲染：线性 / 面性 / 双色。
///
/// 双色 = 填充字形垫 primary 低透明 + 线性主字，不引入第二套字体。
class ReaderMenuGlyph extends StatelessWidget {
  const ReaderMenuGlyph({
    super.key,
    required this.line,
    required this.fill,
    required this.style,
    required this.size,
    required this.color,
    this.duotoneAccent,
  });

  final IconData line;
  final IconData fill;

  /// 0 线性 / 1 面性 / 2 双色
  final int style;
  final double size;
  final Color color;

  /// 双色垫色；默认 primary @0.38
  final Color? duotoneAccent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (style) {
      case 0:
        return Icon(line, size: size, color: color);
      case 2:
        return SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                fill,
                size: size,
                color: duotoneAccent ??
                    scheme.primary.withValues(alpha: 0.38),
              ),
              Icon(line, size: size, color: color),
            ],
          ),
        );
      default:
        return Icon(fill, size: size, color: color);
    }
  }
}
