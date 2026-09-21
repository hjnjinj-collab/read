import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
// 分段控件尚未进公开 barrel，与外观页一致从 src 引用
// ignore: implementation_imports
import 'package:liquid_glass_easy/src/widgets/components/liquid_glass_segmented.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart' show AppGlass;
import '../providers/shell_settings.dart';
import '../widgets/shell_ambient.dart';
import 'settings_chrome.dart';

/// 材质与玻璃：全页统一「霜壳 + 液态切换/滑杆」
class GlassSettingsPage extends ConsumerWidget {
  const GlassSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shell = ref.watch(shellSettingsProvider);
    final n = ref.read(shellSettingsProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final forced = Platform.isWindows;
    final motion = shell.lgMotionOn
        ? const LiquidGlassLensMotionSpec()
        : const LiquidGlassLensMotionSpec(maxDeformation: 0);
    final frostDir = AmbientDir.parse(shell.frostDir);
    final frostA =
        shell.frostGradA != null ? Color(shell.frostGradA!) : null;
    final frostB =
        shell.frostGradB != null ? Color(shell.frostGradB!) : null;
    final frostDepth = shell.frostGradDepth;
    // 霜壳内滑杆宽：页边距 16×2 + 壳内 padding 12×2
    final sliderW = width - 32 - 24;

    Widget frostSection({
      required String header,
      required List<Widget> children,
    }) {
      // 与设置根页 float 组同语义：frostOn 关闭时不做主/第三色渐变渗色
      return SliverToBoxAdapter(
        child: _FrostSection(
          header: header,
          frostOn: shell.frostOn,
          dir: frostDir,
          colorA: frostA,
          colorB: frostB,
          depth: frostDepth,
          children: children,
        ),
      );
    }

    Widget slider({
      required Key key,
      required double value,
      required double min,
      required double max,
      required ValueChanged<double> onChanged,
    }) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: ClipRRect(
          // 滑杆液态 thumb 同样可能外泄，按壳内圆角裁切
          borderRadius: BorderRadius.circular(16),
          child: LiquidGlassSlider(
            key: key,
            value: value.clamp(min, max),
            onChanged: onChanged,
            minimumValue: min,
            maximumValue: max,
            activeColor: scheme.primary,
            width: sliderW,
            height: 56,
            motion: motion,
            style: _sliderStyle(),
          ),
        ),
      );
    }

    Widget valueSeg({
      required List<String> segments,
      required List<String> values,
      required String selected,
      required ValueChanged<String> onPick,
      List<IconData>? icons,
      List<double>? iconAngles,
      double bottomPad = 14,
    }) {
      return Padding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, bottomPad),
        child: _LiquidValueSegmented(
          segments: segments,
          values: values,
          selected: selected,
          lgMotionOn: shell.lgMotionOn,
          navBlurSigma: shell.navBlurSigma,
          icons: icons,
          iconAngles: iconAngles,
          onPick: onPick,
        ),
      );
    }

    // 方向枚举：Iconsax 轴向箭头；对角用 axis + 旋转（与壳层图标体系一致）
    const dirValues = ['tlbr', 'trbl', 'top', 'left'];

    return SettingsScaffold(
      title: '材质与玻璃',
      slivers: [
        frostSection(
          header: '模式',
          children: [
            SettingLabel(
              title: '渲染材质',
              subtitle: forced
                  ? 'Windows 强制毛玻璃霜面（无 shader）'
                  : shell.glassMode == 'lite'
                      ? '毛玻璃霜面：无 shader、省电'
                      : '液态折射：Impeller 实时',
            ),
            valueSeg(
              segments: const ['液态玻璃', '毛玻璃'],
              values: const ['liquid', 'lite'],
              selected: shell.glassMode,
              onPick: n.setGlassMode,
            ),
          ],
        ),
        frostSection(
          header: '底栏',
          children: [
            SettingLabel(
              title: '模糊',
              subtitle: shell.navBlurSigma < 1
                  ? '关闭（仅着色）'
                  : '强度 ${shell.navBlurSigma.round()}',
            ),
            slider(
              key: const ValueKey('nav-blur-slider'),
              value: shell.navBlurSigma,
              min: 0,
              max: 48,
              onChanged: n.setNavBlurSigma,
            ),
            SettingLabel(
              title: '色渗滤镜',
              subtitle: '主色强度 ${(shell.navTintStrength * 100).round()}%',
            ),
            slider(
              key: const ValueKey('nav-tint-slider'),
              value: shell.navTintStrength,
              min: 0,
              max: 1,
              onChanged: n.setNavTintStrength,
            ),
          ],
        ),
        frostSection(
          header: '页面色渗',
          children: [
            SettingSwitchRow(
              title: '均匀渗入',
              subtitle: '整页纸色混入主色（与渐变叠加）',
              value: shell.pageTintOn,
              onChanged: n.setPageTintOn,
            ),
            SettingLabel(
              title: '浅色底',
              subtitle:
                  '主色 ${(shell.pageTintLight * 100).round()}% · 默认 35%',
            ),
            slider(
              key: const ValueKey('page-tint-light'),
              value: shell.pageTintLight,
              min: 0,
              max: 0.60,
              onChanged: n.setPageTintLight,
            ),
            SettingLabel(
              title: '深色底',
              subtitle:
                  '主色 ${(shell.pageTintDark * 100).round()}% · 默认 0（纯夜底）',
            ),
            slider(
              key: const ValueKey('page-tint-dark'),
              value: shell.pageTintDark,
              min: 0,
              max: 0.40,
              onChanged: n.setPageTintDark,
            ),
          ],
        ),
        frostSection(
          header: '页底渐变',
          children: [
            SettingSwitchRow(
              title: '氛围渐变',
              subtitle: 'primary + tertiary 对角/轴向光晕（叠在色渗上）',
              value: shell.ambientOn,
              onChanged: n.setAmbientOn,
            ),
            SettingLabel(
              title: '方向',
              subtitle: AmbientDir.parse(shell.ambientDir).label,
            ),
            valueSeg(
              segments: const ['', '', '', ''],
              values: dirValues,
              selected: shell.ambientDir,
              icons: const [
                AppIcons.dirAxis,
                AppIcons.dirAxis,
                AppIcons.dirDown,
                AppIcons.dirAxis,
              ],
              iconAngles: const [math.pi / 4, 3 * math.pi / 4, 0, 0],
              onPick: n.setAmbientDir,
              bottomPad: 8,
            ),
          ],
        ),
        frostSection(
          header: '设置页霜层',
          children: [
            SettingSwitchRow(
              title: '垫底霜层',
              subtitle: '关闭后子栏无下层渐变，仅轻透填色 + 阴影',
              value: shell.frostOn,
              onChanged: n.setFrostOn,
            ),
            SettingLabel(
              title: '方案',
              subtitle: shell.frostStyle == 'slice'
                  ? '切片：每栏一段渐变'
                  : '统一：整组一条连续渐变',
            ),
            valueSeg(
              segments: const ['统一连续', '分栏切片'],
              values: const ['unified', 'slice'],
              selected: shell.frostStyle,
              onPick: n.setFrostStyle,
              bottomPad: 8,
            ),
            SettingLabel(
              title: '方向',
              subtitle: AmbientDir.parse(shell.frostDir).label,
            ),
            valueSeg(
              segments: const ['', '', '', ''],
              values: dirValues,
              selected: shell.frostDir,
              icons: const [
                AppIcons.dirAxis,
                AppIcons.dirAxis,
                AppIcons.dirDown,
                AppIcons.dirAxis,
              ],
              iconAngles: const [math.pi / 4, 3 * math.pi / 4, 0, 0],
              onPick: n.setFrostDir,
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '行缝遮住霜层，渐变只从子栏下透出；子栏带悬浮阴影。',
                style: TextStyle(height: 1.4),
              ),
            ),
            SettingLabel(
              title: '子栏高度',
              subtitle: '上下 padding ${shell.frostRowPadV.round()} · 默认 20',
            ),
            slider(
              key: const ValueKey('frost-row-pad'),
              value: shell.frostRowPadV,
              min: 8,
              max: 36,
              onChanged: n.setFrostRowPadV,
            ),
            SettingLabel(
              title: '渐变深浅',
              subtitle: shell.frostGradDepth <= 0.95
                  ? '偏淡 ${(shell.frostGradDepth * 100).round()}%'
                  : shell.frostGradDepth >= 1.05
                      ? '偏浓 ${(shell.frostGradDepth * 100).round()}%'
                      : '标准 100%',
            ),
            slider(
              key: const ValueKey('frost-grad-depth'),
              value: shell.frostGradDepth,
              min: 0.3,
              max: 1.8,
              onChanged: n.setFrostGradDepth,
            ),
            SettingLabel(
              title: '渐变起点色',
              subtitle: shell.frostGradA == null
                  ? '跟随主题 primary'
                  : '自定义',
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _FrostColorChip(
                    label: '主题',
                    color: scheme.primary,
                    selected: shell.frostGradA == null,
                    onTap: () => n.setFrostGradA(null),
                  ),
                  for (final c in _frostColorPresets(scheme))
                    _FrostColorChip(
                      label: c.label,
                      color: c.color,
                      selected: shell.frostGradA == c.color.toARGB32(),
                      onTap: () => n.setFrostGradA(c.color),
                    ),
                ],
              ),
            ),
            SettingLabel(
              title: '渐变终点色',
              subtitle: shell.frostGradB == null
                  ? '跟随主题 tertiary'
                  : '自定义',
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _FrostColorChip(
                    label: '主题',
                    color: scheme.tertiary,
                    selected: shell.frostGradB == null,
                    onTap: () => n.setFrostGradB(null),
                  ),
                  for (final c in _frostColorPresets(scheme))
                    _FrostColorChip(
                      label: c.label,
                      color: c.color,
                      selected: shell.frostGradB == c.color.toARGB32(),
                      onTap: () => n.setFrostGradB(c.color),
                    ),
                ],
              ),
            ),
          ],
        ),
        frostSection(
          header: '说明',
          children: [
            SettingSwitchRow(
              title: '果冻效应',
              subtitle: '关闭后滑杆/开关/分段无形变鼓动，模糊不溢出',
              value: shell.lgMotionOn,
              onChanged: n.setLgMotionOn,
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Text(
                '色渗 = 整页均匀主色；页底渐变 / 设置霜层方向可分别配置。'
                '液态折射依赖 Impeller；Skia 平台自动退化为霜面。',
                style: TextStyle(height: 1.5),
              ),
            ),
          ],
        ),
      ],
    );
  }

  LiquidGlassStyle _sliderStyle() => LiquidGlassSlider.defaultStyle.copyWith(
        appearance: LiquidGlassSlider.defaultStyle.appearance.copyWith(
          blur: const LiquidGlassBlur(sigmaX: 1, sigmaY: 1),
        ),
        refraction: const LiquidGlassRefraction(
          distortion: 0.04,
          distortionWidth: 12,
        ),
      );
}

/// 统一分组：分区头 + 霜壳/中性壳（跟随设置页「垫底霜层」开关）
class _FrostSection extends StatelessWidget {
  const _FrostSection({
    required this.header,
    required this.frostOn,
    required this.dir,
    required this.colorA,
    required this.colorB,
    required this.depth,
    required this.children,
  });

  final String header;
  final bool frostOn;
  final AmbientDir dir;
  final Color? colorA;
  final Color? colorB;
  final double depth;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
            child: Text(
              header,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
            ),
          ),
          SettingsFrostGate(
            dir: dir,
            colorA: colorA,
            colorB: colorB,
            gradDepth: depth,
            blurSigma: 0,
            child: body,
          ),
        ],
      ),
    );
  }
}

/// 液态枚举切换：半透明派生色 pill。
///
/// 层序：内容 `ClipRRect` 锁住 Lens/pill 模糊（防外泄）→ 前景 rim
/// （T9：画在 Clip 之外，整圈圆角完整）。
/// 圆角：外轨 outerR 与内 pill 嵌套；描边走细腻档。
class _LiquidValueSegmented extends StatelessWidget {
  const _LiquidValueSegmented({
    required this.segments,
    required this.values,
    required this.selected,
    required this.lgMotionOn,
    required this.navBlurSigma,
    required this.onPick,
    this.icons,
    this.iconAngles,
  });

  final List<String> segments;
  final List<String> values;
  final String selected;
  final bool lgMotionOn;

  /// 保留参数以兼容调用方；设置页轨道**不使用**（见类注释）
  final double navBlurSigma;
  final ValueChanged<String> onPick;

  /// 非空时用图标代替文字（方向等短标签，防溢出 pill）
  final List<IconData>? icons;

  /// 与 [icons] 等长；对角方向用弧度旋转 Iconsax 轴向箭头
  final List<double>? iconAngles;

  /// 细腻外轨：略小于 20，描边更贴霜壳语言
  static const double _outerR = 16;
  static const double _pad = 10;
  static const double _height = 60;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final light = scheme.brightness == Brightness.light;
    final pillBase = AppGlass.restPillTint(scheme);
    final idx = values.indexOf(selected);

    return SizedBox(
      height: _height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 内容层：与外观页明暗切换器同构（包内默认胶囊 morph 鼓动）
          // ClipRRect 仅拦外泄；pill **不要**写死 shape，否则包 morph 不显
          ClipRRect(
            borderRadius: BorderRadius.circular(_outerR),
            child: LiquidGlassSegmented(
              segments: segments,
              selectedIndex: idx < 0 ? 0 : idx,
              onChanged: (i) {
                if (i >= 0 && i < values.length) onPick(values[i]);
              },
              width: double.infinity,
              height: _height,
              padding: _pad,
              style: LiquidGlassStyle(
                shape: LiquidGlassShape.continuousRoundedRectangle(
                  cornerRadius: _outerR,
                  // A：对齐底栏光学边（立体倒角），Lens 内高光
                  borderWidth: 1.0,
                  borderColor: Colors.white.withValues(
                    alpha: light ? 0.42 : 0.24,
                  ),
                  lightIntensity: 1.0,
                ),
                appearance: LiquidGlassAppearance(
                  color: Colors.transparent,
                  blur: const LiquidGlassBlur(sigmaX: 0, sigmaY: 0),
                  shadow: null,
                ),
                refraction: const LiquidGlassRefraction(
                  distortion: 0.05,
                  distortionWidth: 14,
                  chromaticAberration: 0.001,
                ),
              ),
              pillStyle: LiquidGlassSegmentedPillStyle(
                glass: lgMotionOn,
                animated: true,
                growHeight: lgMotionOn ? 6 : 0,
                // 与外观页一致：不传 shape，走包默认胶囊，保证 morph 鼓动
                glassStyle: LiquidGlassStyle(
                  appearance: LiquidGlassAppearance(
                    color: Colors.transparent,
                    blur: const LiquidGlassBlur(sigmaX: 1.5, sigmaY: 1.5),
                    shadow: null,
                  ),
                  refraction: const LiquidGlassRefraction(
                    distortion: 0.08,
                    distortionWidth: 12,
                    chromaticAberration: 0.001,
                  ),
                ),
                restStyle: LiquidGlassStyle(
                  appearance: LiquidGlassAppearance(
                    color: pillBase,
                    blur: const LiquidGlassBlur(sigmaX: 0, sigmaY: 0),
                  ),
                ),
              ),
              labelStyle: LiquidGlassSegmentedLabelStyle(
                selectedColor: scheme.primary,
                unselectedColor: scheme.onSurfaceVariant,
                fontSize: 12,
                selectedFontWeight: FontWeight.w600,
              ),
              segmentBuilder: icons == null
                  ? null
                  : (context, i, selectedSeg, color) {
                      final data = icons![i.clamp(0, icons!.length - 1)];
                      final angle = (iconAngles != null &&
                              i < iconAngles!.length)
                          ? iconAngles![i]
                          : 0.0;
                      final icon = Icon(
                        data,
                        size: 22,
                        color: color,
                      );
                      return Center(
                        child: angle == 0
                            ? icon
                            : Transform.rotate(angle: angle, child: icon),
                      );
                    },
            ),
          ),
          // B：前景 bevel（Clip 外）。注意：BoxDecoration 圆角不能配
          // 非均匀 BorderSide 颜色 → 必须用 CustomPaint 画渐变描边
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _BevelRimPainter(
                  radius: _outerR,
                  light: light,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 圆角 bevel 描边：上亮侧中下暗（BoxDecoration 无法非均匀色+圆角）
class _BevelRimPainter extends CustomPainter {
  _BevelRimPainter({required this.radius, required this.light});

  final double radius;
  final bool light;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = light ? 0.9 : 1.1;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: light ? 0.55 : 0.40),
          Colors.white.withValues(alpha: light ? 0.28 : 0.20),
          Colors.black.withValues(alpha: light ? 0.10 : 0.22),
        ],
        stops: const [0, 0.45, 1],
      ).createShader(rrect.outerRect);
    canvas.drawRRect(rrect.deflate(stroke / 2), paint);
  }

  @override
  bool shouldRepaint(covariant _BevelRimPainter oldDelegate) =>
      oldDelegate.light != light || oldDelegate.radius != radius;
}

/// 霜层渐变颜色预设（轻量 swatch，跟随 scheme 取色）
List<({String label, Color color})> _frostColorPresets(ColorScheme scheme) => [
      (label: '蓝', color: const Color(0xFF5B8DEF)),
      (label: '紫', color: const Color(0xFF9B72CF)),
      (label: '粉', color: const Color(0xFFE07AB5)),
      (label: '橙', color: const Color(0xFFE8945A)),
      (label: '青', color: const Color(0xFF4DB6AC)),
      (label: '金', color: const Color(0xFFD4A843)),
    ];

class _FrostColorChip extends StatelessWidget {
  const _FrostColorChip({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: selected ? 0.28 : 0.14),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? scheme.primary
                : scheme.outlineVariant.withValues(alpha: 0.5),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
