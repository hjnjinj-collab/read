import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
// 与书架顶栏同源：分段控件尚未进公开 barrel
// ignore: implementation_imports
import 'package:liquid_glass_easy/src/widgets/components/liquid_glass_segmented.dart';

import '../../../core/theme/app_icons.dart';

/// 可扩展液态底栏。
///
/// 默认：左 `[书架|书源]` 胶囊 + 右「更多」圆键。
/// 点更多：左收成书架圆键，右展开为同构玻璃胶囊 `[设置|添加书籍]`。
/// 设置/添加不收起；仅左圆键收起。
class ExpandableGlassNav extends StatelessWidget {
  const ExpandableGlassNav({
    super.key,
    required this.selectedIndex,
    required this.onChanged,
    required this.expanded,
    required this.onToggleExpand,
    required this.onCollapse,
    required this.onSettings,
    required this.onImport,
    required this.barStyle,
    required this.circleStyle,
    required this.selectedColor,
    required this.unselectedColor,
    this.height = 64,
  });

  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final bool expanded;
  final VoidCallback onToggleExpand;
  final VoidCallback onCollapse;
  final VoidCallback onSettings;
  final VoidCallback onImport;
  final LiquidGlassStyle barStyle;
  final LiquidGlassStyle circleStyle;
  final Color selectedColor;
  final Color unselectedColor;
  final double height;

  static const double _barW = 196;

  LiquidGlassSegmentedPillStyle _pill(double grow) =>
      LiquidGlassSegmentedPillStyle(
        glass: true,
        animated: true,
        growHeight: grow,
        glassStyle: LiquidGlassStyle(
          appearance: LiquidGlassAppearance(
            color: selectedColor.withValues(alpha: 0.22),
            blur: const LiquidGlassBlur(sigmaX: 1.2, sigmaY: 1.2),
            shadow: LiquidGlassShadow(
              blur: 12,
              opacity: 0.28,
              inset: 0,
              cornerRadius: (height - 4) / 2,
            ),
          ),
          refraction: const LiquidGlassRefraction(
            distortion: 0.07,
            distortionWidth: 14,
          ),
        ),
      );

  LiquidGlassSegmentedLabelStyle _labels() => LiquidGlassSegmentedLabelStyle(
        selectedColor: selectedColor,
        unselectedColor: unselectedColor,
        fontSize: 11,
        selectedFontWeight: FontWeight.w600,
        unselectedFontWeight: FontWeight.w500,
      );

  Widget _glyph(IconData icon, String label, Color color, {bool bold = false}) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: bold ? FontWeight.w600 : FontWeight.w500,
            color: color,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final circle = height;
    // 父级已 pad 16；展开时右侧吃满剩余宽，与左圆键只留 8px
    final total = (MediaQuery.sizeOf(context).width - 32).clamp(280.0, 480.0);
    const tightGap = 8.0;
    final panelW = (total - circle - tightGap).clamp(_barW, total);

    final mainBar = LiquidGlassSegmented(
      segments: const ['书架', '书源'],
      selectedIndex: selectedIndex.clamp(0, 1),
      onChanged: onChanged,
      width: _barW,
      height: height - 4,
      style: barStyle,
      pillStyle: _pill(12),
      labelStyle: _labels(),
      segmentBuilder: (context, i, selected, color) {
        final icons = [AppIcons.bookshelf, AppIcons.sources];
        return _glyph(
          icons[i],
          ['书架', '书源'][i],
          color,
          bold: selected,
        );
      },
    );

    // 展开：与主胶囊同构；宽度吃满，两键均分
    final morePanel = LiquidGlassSegmented(
      segments: const ['设置', '添加书籍'],
      selectedIndex: 0,
      onChanged: (_) {},
      width: panelW,
      height: height - 4,
      style: barStyle,
      pillStyle: const LiquidGlassSegmentedPillStyle(
        glass: false,
        animated: false,
      ),
      labelStyle: _labels(),
      segmentBuilder: (context, i, selected, color) {
        final icons = [AppIcons.settings, AppIcons.importFile];
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (i == 0) {
              onSettings();
            } else {
              onImport();
            }
          },
          child: _glyph(
            icons[i],
            ['设置', '添加书籍'][i],
            unselectedColor,
          ),
        );
      },
    );

    final homeCircle = LiquidGlassTabBarAction(
      icon: AppIcons.bookshelf,
      size: circle,
      foregroundColor: selectedColor,
      style: circleStyle,
      touch: const LiquidGlassTouch(flex: LiquidGlassFlex()),
      onTap: () {
        onChanged(0);
        onCollapse();
      },
    );

    final moreCircle = LiquidGlassTabBarAction(
      icon: Icons.more_horiz_rounded,
      size: circle,
      foregroundColor: unselectedColor,
      style: circleStyle,
      touch: const LiquidGlassTouch(flex: LiquidGlassFlex()),
      onTap: onToggleExpand,
    );

    return SizedBox(
      height: height,
      // 吃掉命中，避免按压玻璃时把事件漏给下层书架滚动
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) {},
        onPointerMove: (_) {},
        onPointerUp: (_) {},
        child: Row(
          // 默认：左右分贴两端；展开：左圆键 + 紧邻的满宽面板
          mainAxisAlignment: expanded
              ? MainAxisAlignment.start
              : MainAxisAlignment.spaceBetween,
          children: [
            // 左槽
            AnimatedContainer(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              alignment: Alignment.centerLeft,
              width: expanded ? circle : _barW,
              height: height,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: expanded
                    ? KeyedSubtree(
                        key: const ValueKey('home'),
                        child: homeCircle,
                      )
                    : KeyedSubtree(
                        key: const ValueKey('main'),
                        child: mainBar,
                      ),
              ),
            ),
            if (expanded) const SizedBox(width: tightGap),
            // 右槽：展开吃满剩余宽；默认仅圆键贴右
            AnimatedContainer(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              alignment: expanded ? Alignment.center : Alignment.centerRight,
              width: expanded ? panelW : circle,
              height: height,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: expanded
                    ? KeyedSubtree(
                        key: const ValueKey('panel'),
                        child: morePanel,
                      )
                    : KeyedSubtree(
                        key: const ValueKey('more'),
                        child: moreCircle,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
