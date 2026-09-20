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

  LiquidGlassSegmentedPillStyle _pill(double grow, Color pillBase) =>
      LiquidGlassSegmentedPillStyle(
        glass: true,
        animated: true,
        growHeight: grow,
        glassStyle: LiquidGlassStyle(
          appearance: LiquidGlassAppearance(
            // 派生色选中底（primaryContainer α0.9），与设置页切换器同语言
            color: pillBase,
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
        // 静止选中态走 restStyle 的 tinted pill——
        // 不设则回落组件默认白色（T16 同款根因）
        restStyle: LiquidGlassStyle(
          appearance: LiquidGlassAppearance(color: pillBase),
        ),
      );

  LiquidGlassSegmentedLabelStyle _labels() => LiquidGlassSegmentedLabelStyle(
        selectedColor: selectedColor,
        unselectedColor: unselectedColor,
        fontSize: 11,
        selectedFontWeight: FontWeight.w600,
        unselectedFontWeight: FontWeight.w500,
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 选中 pill 派生色底：glassStyle/restStyle 双层同色（设置页 T16 同语言）
    final pillBase = scheme.primaryContainer.withValues(alpha: 0.9);
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
      pillStyle: _pill(12, pillBase),
      labelStyle: _labels(),
      segmentBuilder: (context, i, selected, color) {
        final icons = [AppIcons.bookshelf, AppIcons.sources];
        return AnimatedNavGlyph(
          icon: icons[i],
          label: ['书架', '书源'][i],
          color: color,
          selectedColor: selectedColor,
          unselectedColor: unselectedColor,
          selected: selected,
          accentColor: scheme.tertiary,
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
      pillStyle: LiquidGlassSegmentedPillStyle(
        glass: false,
        animated: false,
        // glass:false 绘制的就是 rest pill，同样补派生色
        restStyle: LiquidGlassStyle(
          appearance: LiquidGlassAppearance(color: pillBase),
        ),
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
          child: AnimatedNavGlyph(
            icon: icons[i],
            label: ['设置', '添加书籍'][i],
            color: unselectedColor,
            selectedColor: selectedColor,
            unselectedColor: unselectedColor,
            selected: false,
            accentColor: Theme.of(context).colorScheme.tertiary,
            horizontal: true,
            fontSize: 12,
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
            // 左槽：只做宽度过渡。
            // **不要** AnimatedSwitcher——切换瞬间会双挂两个 Lens，
            // Impeller 下双 BackdropFilter 会闪黑/闪边。
            AnimatedContainer(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              alignment: expanded ? Alignment.center : Alignment.centerLeft,
              width: expanded ? circle : _barW,
              height: height,
              child: expanded ? homeCircle : mainBar,
            ),
            if (expanded) const SizedBox(width: tightGap),
            // 右槽：同上，单玻璃子树 + 宽度过渡
            AnimatedContainer(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              alignment: expanded ? Alignment.center : Alignment.centerRight,
              width: expanded ? panelW : circle,
              height: height,
              child: expanded ? morePanel : moreCircle,
            ),
          ],
        ),
      ),
    );
  }
}

/// 底栏图标动画：双层渐进填充 + 方向弹跳。
///
/// 公开供设置页等复用。
class AnimatedNavGlyph extends StatefulWidget {
  const AnimatedNavGlyph({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.selectedColor,
    required this.unselectedColor,
    required this.selected,
    this.accentColor,
    this.iconSize = 20,
    this.fontSize = 11,
    this.horizontal = false,
  });

  final IconData icon;
  final String label;
  final Color color;
  final Color selectedColor;
  final Color unselectedColor;
  final bool selected;

  /// 底层填充强调色（null = selectedColor）
  final Color? accentColor;
  final double iconSize;
  final double fontSize;

  /// true = 图标+文字横排（设置页明暗切换用）
  final bool horizontal;

  @override
  State<AnimatedNavGlyph> createState() => _AnimatedNavGlyphState();
}

class _AnimatedNavGlyphState extends State<AnimatedNavGlyph>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    // 放慢到 700ms，让双层填充更清晰
    duration: const Duration(milliseconds: 700),
  );

  bool _isSelecting = false;

  @override
  void initState() {
    super.initState();
    if (widget.selected) _controller.value = 1;
  }

  @override
  void didUpdateWidget(covariant AnimatedNavGlyph old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) {
      if (widget.selected) {
        _isSelecting = true;
        _controller.forward().whenComplete(() => _isSelecting = false);
      } else {
        _isSelecting = false;
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseColor =
        widget.selected ? widget.selectedColor : widget.unselectedColor;
    // 底层：强调色（accentColor ?? selectedColor）
    final accentColor = widget.accentColor ?? widget.selectedColor;
    // 上层：主色调（selectedColor）
    final primaryColor = widget.selectedColor;

    final iconWidget = SizedBox(
      width: widget.iconSize + 2,
      height: widget.iconSize + 2,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final t = _controller.value;
          final t1 = Curves.easeOutCubic.transform(t);
          final t2 = Curves.easeOutCubic.transform((t - 0.2).clamp(0.0, 1.0));

          // 弹跳：更大幅度，向右上角
          final pulse = _isSelecting ? _pulse(t) : 0.0;
          final scale = 1.0 + 0.28 * pulse;
          final dx = 4.5 * pulse;
          final dy = -4.5 * pulse;

          return Transform.translate(
            offset: Offset(dx, dy),
            child: Transform.scale(
              scale: scale,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 底层：强调色从下往上填充
                  ShaderMask(
                    shaderCallback: (bounds) => LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        accentColor,
                        Color.lerp(baseColor, accentColor,
                            (t1 * 0.7).clamp(0.0, 1.0))!,
                        baseColor,
                      ],
                      stops: [0, t1.clamp(0.01, 0.99), 1],
                    ).createShader(bounds),
                    blendMode: BlendMode.srcIn,
                    child: Icon(widget.icon,
                        size: widget.iconSize, color: Colors.white),
                  ),
                  // 上层：主色调延迟填充（第二波，覆盖强调色）
                  if (t2 > 0.02)
                    Opacity(
                      opacity: t2.clamp(0.0, 1.0),
                      child: ShaderMask(
                        shaderCallback: (bounds) => LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            primaryColor,
                            Color.lerp(accentColor, primaryColor,
                                (t2 * 0.6).clamp(0.0, 1.0))!,
                            Colors.transparent,
                          ],
                          stops: [0, t2.clamp(0.01, 0.99), 1],
                        ).createShader(bounds),
                        blendMode: BlendMode.srcIn,
                        child: Icon(widget.icon,
                            size: widget.iconSize, color: Colors.white),
                      ),
                    ),
                  // 白色倾斜亮线：与弹跳方向一致（左下→右上）
                  if (t2 > 0.02 && t2 < 0.98)
                    ShaderMask(
                      shaderCallback: (bounds) {
                        final edge = t2.clamp(0.02, 0.98);
                        return LinearGradient(
                          // 倾斜方向：左下 → 右上，与弹跳方向一致
                          begin: Alignment.bottomLeft,
                          end: Alignment.topRight,
                          colors: [
                            Colors.transparent,
                            Colors.white.withValues(alpha: 0.85),
                            Colors.white.withValues(alpha: 0.85),
                            Colors.transparent,
                          ],
                          stops: [
                            (edge - 0.10).clamp(0.0, 1.0),
                            (edge - 0.03).clamp(0.0, 1.0),
                            (edge + 0.03).clamp(0.0, 1.0),
                            (edge + 0.10).clamp(0.0, 1.0),
                          ],
                        ).createShader(bounds);
                      },
                      blendMode: BlendMode.srcIn,
                      child: Icon(widget.icon,
                          size: widget.iconSize, color: Colors.white),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );

    final labelWidget = Text(
      widget.label,
      style: TextStyle(
        fontSize: widget.fontSize,
        fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500,
        color: Color.lerp(baseColor, widget.selectedColor,
            Curves.easeOutCubic.transform(_controller.value)),
      ),
    );

    if (widget.horizontal) {
      return AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            iconWidget,
            const SizedBox(width: 4),
            labelWidget,
          ],
        ),
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        iconWidget,
        const SizedBox(height: 2),
        labelWidget,
      ],
    );
  }

  double _pulse(double t) {
    if (t <= 0 || t >= 1) return 0;
    return 1 - (2 * t - 1).abs();
  }
}
