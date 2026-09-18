import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
// ignore: implementation_imports
import 'package:liquid_glass_easy/src/widgets/components/liquid_glass_segmented.dart';

import '../../../core/theme/app_theme.dart';
import '../providers/shell_settings.dart';
import '../widgets/circular_reveal.dart';
import '../widgets/expandable_glass_nav.dart' show AnimatedNavGlyph;
import '../widgets/shell_ambient.dart';
import 'settings_chrome.dart';

/// 外观：主题色 / 明暗 / 动态取色 / 书架布局
class AppearanceSettingsPage extends ConsumerStatefulWidget {
  const AppearanceSettingsPage({super.key});

  @override
  ConsumerState<AppearanceSettingsPage> createState() =>
      _AppearanceSettingsPageState();
}

class _AppearanceSettingsPageState
    extends ConsumerState<AppearanceSettingsPage> {
  /// 本地明暗索引：先驱动动画，动画完成后再同步主题
  int? _pendingThemeIndex;

  /// 最近一次点击的全局坐标（圆形遮罩圆心）
  Offset? _lastTapPosition;

  @override
  Widget build(BuildContext context) {
    final shell = ref.watch(shellSettingsProvider);
    final n = ref.read(shellSettingsProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    // 优先用本地待定索引（动画中），否则用 shell 当前值
    final themeIndex = _pendingThemeIndex ??
        switch (shell.themeMode) {
          'light' => 1,
          'dark' => 2,
          _ => 0,
        };
    // 与根设置页同一套霜层接口
    final frostDir = AmbientDir.parse(shell.frostDir);
    final frostA = shell.frostGradA != null
        ? Color(shell.frostGradA!)
        : null;
    final frostB = shell.frostGradB != null
        ? Color(shell.frostGradB!)
        : null;
    final frostDepth = shell.frostGradDepth;

    return SettingsScaffold(
      title: '外观',
      slivers: [
        // ── 主题色 + 动态取色 ──
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
                  child: Text(
                    '主题',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                        ),
                  ),
                ),
                SettingsFrostShell(
                  dir: frostDir,
                  colorA: frostA,
                  colorB: frostB,
                  gradDepth: frostDepth,
                  showShadow: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SettingLabel(title: '主题色'),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final p in AppTheme.seedPresets)
                                _SeedChip(
                                  label: p.label,
                                  color: p.color,
                                  selected: shell.seedArgb == null
                                      ? p.color.toARGB32() ==
                                          AppTheme.seed.toARGB32()
                                      : shell.seedArgb ==
                                          p.color.toARGB32(),
                                  onTap: () => n.setSeed(p.color),
                                ),
                            ],
                          ),
                        ),
                        // 调色面板
                        _ColorPalette(
                          current: shell.seedArgb != null
                              ? Color(shell.seedArgb!)
                              : null,
                          onPick: (c) => n.setSeed(c),
                        ),
                        SettingSwitchRow(
                          title: '动态取色',
                          subtitle: 'Android 12+ 跟随壁纸（开启时覆盖主题色）',
                          value: shell.dynamicColor,
                          onChanged: n.setDynamicColor,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // ── 明暗切换 ──
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
                  child: Text(
                    '明暗',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                        ),
                  ),
                ),
                SettingsFrostShell(
                  dir: frostDir,
                  colorA: frostA,
                  colorB: frostB,
                  gradDepth: frostDepth,
                  showShadow: false,
                  child: Listener(
                    onPointerDown: (e) => _lastTapPosition = e.position,
                    child: LiquidGlassSegmented(
                      segments: const ['跟随系统', '浅色', '深色'],
                      selectedIndex: themeIndex,
                      onChanged: (i) {
                        final mode = switch (i) {
                          1 => 'light',
                          2 => 'dark',
                          _ => 'system',
                        };

                        // 判断有效主题是否实际变化
                        final systemBrightness =
                            MediaQuery.platformBrightnessOf(context);
                        final currentEffective = switch (shell.themeMode) {
                          'light' => Brightness.light,
                          'dark' => Brightness.dark,
                          _ => systemBrightness,
                        };
                        final newEffective = switch (mode) {
                          'light' => Brightness.light,
                          'dark' => Brightness.dark,
                          _ => systemBrightness,
                        };

                        // 主题实际不变：跳过过渡动画，直接切换
                        if (currentEffective == newEffective) {
                          n.setThemeMode(mode);
                          setState(() => _pendingThemeIndex = null);
                          return;
                        }

                        setState(() => _pendingThemeIndex = i);

                        final tapPos = _lastTapPosition ??
                            Offset(
                              MediaQuery.sizeOf(context).width / 2,
                              MediaQuery.sizeOf(context).height / 2,
                            );

                        // 快照吞噬：截旧画面 → 重绘 → 圆形吃掉快照露出新主题
                        CircularRevealTheme.reveal(
                          context: context,
                          globalPosition: tapPos,
                          onThemeChange: () {
                            n.setThemeMode(mode);
                          },
                        ).then((_) {
                          if (mounted) {
                            setState(() => _pendingThemeIndex = null);
                          }
                        });
                      },
                    width: double.infinity,
                    // 与网格布局行高对齐
                    height: 48,
                    segmentBuilder: (context, i, selected, color) {
                      // 切换前后使用不同图标：outlined ↔ filled
                      final unselectedIcons = [
                        Icons.brightness_auto_outlined,
                        Icons.wb_sunny_outlined,
                        Icons.nights_stay_outlined,
                      ];
                      final selectedIcons = [
                        Icons.brightness_auto_rounded,
                        Icons.wb_sunny_rounded,
                        Icons.nights_stay_rounded,
                      ];
                      final labels = ['跟随系统', '浅色', '深色'];
                      return AnimatedNavGlyph(
                        icon: selected
                            ? selectedIcons[i]
                            : unselectedIcons[i],
                        label: labels[i],
                        color: color,
                        selectedColor: scheme.primary,
                        unselectedColor: scheme.onSurfaceVariant,
                        selected: selected,
                        accentColor: scheme.tertiary,
                        iconSize: 14,
                        fontSize: 12,
                        horizontal: true,
                      );
                    },
                    style: LiquidGlassStyle(
                      shape: LiquidGlassShape.continuousRoundedRectangle(
                        // 与外层 SettingsFrostShell radius 完全一致
                        cornerRadius: 16,
                        borderWidth: 0,
                        borderColor: Colors.transparent,
                        lightIntensity: 0,
                        borderType: const OpticalBorder(
                          borderSolidity: 0,
                          ambientIntensity: 0,
                        ),
                      ),
                      appearance: LiquidGlassAppearance(
                        // 完全透明：让容器霜层渐变直接透过来
                        color: Colors.transparent,
                        blur: LiquidGlassBlur(
                          sigmaX: shell.navBlurSigma.clamp(0, 20),
                          sigmaY: shell.navBlurSigma.clamp(0, 20),
                        ),
                        shadow: LiquidGlassShadow(
                          blur: 0,
                          opacity: 0,
                          cornerRadius: 16,
                        ),
                      ),
                      refraction: const LiquidGlassRefraction(
                        distortion: 0.06,
                        distortionWidth: 16,
                        chromaticAberration: 0.001,
                      ),
                    ),
                    pillStyle: LiquidGlassSegmentedPillStyle(
                      glass: shell.lgMotionOn,
                      animated: true,
                      growHeight: shell.lgMotionOn ? 10 : 0,
                      glassStyle: LiquidGlassStyle(
                        appearance: LiquidGlassAppearance(
                          color: scheme.primary.withValues(alpha: 0.28),
                          blur: const LiquidGlassBlur(
                            sigmaX: 1.5,
                            sigmaY: 1.5,
                          ),
                          shadow: LiquidGlassShadow(
                            blur: 8,
                            opacity: 0.20,
                            inset: 0,
                            cornerRadius: 14,
                          ),
                        ),
                        refraction: const LiquidGlassRefraction(
                          distortion: 0.08,
                          distortionWidth: 12,
                        ),
                      ),
                    ),
                    labelStyle: LiquidGlassSegmentedLabelStyle(
                      selectedColor: scheme.primary,
                      unselectedColor: scheme.onSurfaceVariant,
                      fontSize: 12,
                      selectedFontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              ],
            ),
          ),
        ),
        // ── 书架布局 ──
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
                  child: Text(
                    '书架',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                        ),
                  ),
                ),
                SettingsFrostShell(
                  dir: frostDir,
                  colorA: frostA,
                  colorB: frostB,
                  gradDepth: frostDepth,
                  showShadow: false,
                  child: SettingSwitchRow(
                    title: '网格布局',
                    subtitle: '关闭则使用列表模式',
                    value: shell.bookshelfGrid,
                    onChanged: n.setBookshelfGrid,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SeedChip extends StatelessWidget {
  const _SeedChip({
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.35),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(label, style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}

/// 调色面板：扩展色板，允许自定义主题色
class _ColorPalette extends StatelessWidget {
  const _ColorPalette({
    required this.current,
    required this.onPick,
  });

  final Color? current;
  final ValueChanged<Color> onPick;

  static const List<Color> _palette = [
    Color(0xFFE57373), // 红
    Color(0xFFF06292), // 粉
    Color(0xFFBA68C8), // 紫
    Color(0xFF9575CD), // 淡紫
    Color(0xFF7986CB), // 靛
    Color(0xFF64B5F6), // 蓝
    Color(0xFF4FC3F7), // 浅蓝
    Color(0xFF4DD0E1), // 青
    Color(0xFF4DB6AC), // 蓝绿
    Color(0xFF81C784), // 绿
    Color(0xFFAED581), // 浅绿
    Color(0xFFFFD54F), // 黄
    Color(0xFFFFB74D), // 橙
    Color(0xFFA1887F), // 棕
    Color(0xFF90A4AE), // 蓝灰
    Color(0xFF607D8B), // 石板
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '调色板',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in _palette)
                _PaletteSwatch(
                  color: c,
                  selected: current?.toARGB32() == c.toARGB32(),
                  onTap: () => onPick(c),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PaletteSwatch extends StatelessWidget {
  const _PaletteSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? scheme.onSurface
                : Colors.white.withValues(alpha: 0.4),
            width: selected ? 2.5 : 1,
          ),
        ),
        child: selected
            ? Icon(Icons.check, size: 14, color: scheme.onSurface)
            : null,
      ),
    );
  }
}


