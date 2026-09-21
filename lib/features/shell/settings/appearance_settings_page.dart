import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
// ignore: implementation_imports
import 'package:liquid_glass_easy/src/widgets/components/liquid_glass_segmented.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/shell_settings.dart';
import '../widgets/circular_reveal.dart';
import '../widgets/expandable_glass_nav.dart' show AnimatedNavGlyph;
import '../widgets/shell_ambient.dart';
import 'settings_chrome.dart';

/// 外观：主题色 / 调色板 / 取色器 / 动态取色 / 明暗模式 / 书架布局
class AppearanceSettingsPage extends ConsumerStatefulWidget {
  const AppearanceSettingsPage({super.key});

  @override
  ConsumerState<AppearanceSettingsPage> createState() =>
      _AppearanceSettingsPageState();
}

class _AppearanceSettingsPageState
    extends ConsumerState<AppearanceSettingsPage> {
  int? _pendingThemeIndex;
  Offset? _lastTapPosition;

  @override
  Widget build(BuildContext context) {
    final shell = ref.watch(shellSettingsProvider);
    final n = ref.read(shellSettingsProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    // 当前生效的主题色来源：dynamic | preset | palette | picker
    final activeSource = shell.effectiveSeedSource;
    final themeIndex = _pendingThemeIndex ??
        switch (shell.themeMode) {
          'light' => 1,
          'dark' => 2,
          _ => 0,
        };
    final frostDir = AmbientDir.parse(shell.frostDir);
    final frostA =
        shell.frostGradA != null ? Color(shell.frostGradA!) : null;
    final frostB =
        shell.frostGradB != null ? Color(shell.frostGradB!) : null;
    final frostDepth = shell.frostGradDepth;

    return SettingsScaffold(
      title: '外观',
      slivers: [
        // ── 主题 ──
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SectionHeader(
                  icon: AppIcons.themeColor,
                  label: '主题',
                  scheme: scheme,
                ),
                SettingsFrostGate(
                  dir: frostDir,
                  colorA: frostA,
                  colorB: frostB,
                  gradDepth: frostDepth,
                  blurSigma: 0,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 首行距顶垫高：SettingIconLabel 自带 6px，合计 14px，
                      // 消除贴着壳顶的溢出感
                      const SizedBox(height: 8),
                      // 主题色
                      SettingIconLabel(
                        icon: AppIcons.themeColor,
                        title: '主题色',
                      ),
                      Opacity(
                        // 来源互斥：非「预置」来源时整组降权（MD3 disabled 38%），仍可点击切换
                        opacity: activeSource == 'preset' ? 1 : 0.38,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
                          child: _EvenWrap(
                            children: [
                              for (final p in AppTheme.seedPresets)
                                ChoiceChip(
                                  avatar: Container(
                                    width: 16,
                                    height: 16,
                                    decoration: BoxDecoration(
                                      color: p.color,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white
                                            .withValues(alpha: 0.35),
                                      ),
                                    ),
                                  ),
                                  label: Text(p.label),
                                  labelStyle: Theme.of(context)
                                      .textTheme
                                      .labelMedium,
                                  showCheckmark: true,
                                  selected: activeSource == 'preset' &&
                                      (shell.seedArgb != null
                                              ? Color(shell.seedArgb!)
                                              : AppTheme.seed)
                                          .toARGB32() ==
                                          p.color.toARGB32(),
                                  onSelected: (_) => n
                                      .applySeed(p.color, source: 'preset'),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SettingsDivider(indent: 16),
                      // 调色板
                      SettingIconLabel(
                        icon: AppIcons.palette,
                        title: '调色板',
                      ),
                      Opacity(
                        opacity: activeSource == 'palette' ? 1 : 0.38,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: _ColorPalette(
                            current: activeSource == 'palette' &&
                                    shell.seedArgb != null
                                ? Color(shell.seedArgb!)
                                : null,
                            onPick: (c) =>
                                n.applySeed(c, source: 'palette'),
                          ),
                        ),
                      ),
                      const SettingsDivider(indent: 16),
                      // 自定义取色器：标签与按钮同行（trailing），与左侧
                      // 文字水平对齐；互斥降权只作用于按钮（与其余组一致）
                      SettingIconLabel(
                        icon: AppIcons.colorPicker,
                        title: '自定义取色',
                        subtitle: '手动选择任意主色调',
                        trailing: Opacity(
                          opacity: activeSource == 'picker' ? 1 : 0.38,
                          child: _ColorPickerButton(
                            current: shell.seedArgb != null
                                ? Color(shell.seedArgb!)
                                : AppTheme.seed,
                            active: activeSource == 'picker',
                            onPick: (c) =>
                                n.applySeed(c, source: 'picker'),
                          ),
                        ),
                      ),
                      const SettingsDivider(indent: 16),
                      // 动态取色：纳入来源互斥——非当前来源时整行降权，
                      // 开关仍可点（点开即切到 dynamic 来源）
                      Opacity(
                        opacity: activeSource == 'dynamic' ? 1 : 0.38,
                        child: SizedBox(
                          width: double.infinity,
                          child: SettingSwitchRow(
                            title: '动态取色',
                            subtitle: 'Android 12+ 跟随壁纸（开启时覆盖主题色）',
                            value: shell.dynamicColor,
                            onChanged: n.setDynamicColor,
                          ),
                        ),
                      ),
                      const SettingsDivider(indent: 16),
                      // 派生色系：当前 scheme 的 MD3 角色色实时预览
                      SettingIconLabel(
                        icon: AppIcons.schemeTints,
                        title: '派生色系',
                        subtitle: '当前主题色派生的 MD3 色彩角色',
                      ),
                      Padding(
                        // 底距 14：作为主题容器末分区，与其他容器末行呼吸一致
                        padding: const EdgeInsets.fromLTRB(16, 2, 16, 14),
                        child: _SchemeTintsGrid(scheme: scheme),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        // ── 明暗模式 ──
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SectionHeader(
                  icon: AppIcons.themeMode,
                  label: '明暗模式',
                  scheme: scheme,
                ),
                SettingsFrostGate(
                  dir: frostDir,
                  colorA: frostA,
                  colorB: frostB,
                  gradDepth: frostDepth,
                  blurSigma: 0,
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
                        CircularRevealTheme.reveal(
                          context: context,
                          globalPosition: tapPos,
                          onThemeChange: () => n.setThemeMode(mode),
                        ).then((_) {
                          if (mounted) {
                            setState(() => _pendingThemeIndex = null);
                          }
                        });
                      },
                      width: double.infinity,
                      // 与开关行统一 60；padding 10 → pill 40/60，
                      // 四周 10px 按钮感；grow 6 峰值 46<60 不溢出
                      height: 60,
                      padding: 10,
                      segmentBuilder: (context, i, selected, color) {
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
                          selectedColor: scheme.onPrimaryContainer,
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
                        growHeight: shell.lgMotionOn ? 6 : 0,
                        glassStyle: LiquidGlassStyle(
                          appearance: LiquidGlassAppearance(
                            // 动画透明透底、无阴影；静止 restPillTint
                            color: Colors.transparent,
                            blur: const LiquidGlassBlur(
                              sigmaX: 1.5,
                              sigmaY: 1.5,
                            ),
                            shadow: null,
                          ),
                          refraction: const LiquidGlassRefraction(
                            distortion: 0.08,
                            distortionWidth: 12,
                          ),
                        ),
                        restStyle: LiquidGlassStyle(
                          appearance: LiquidGlassAppearance(
                            color: AppGlass.restPillTint(scheme),
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
                _SectionHeader(
                  icon: AppIcons.bookshelfLayout,
                  label: '书架布局',
                  scheme: scheme,
                ),
                SettingsFrostGate(
                  dir: frostDir,
                  colorA: frostA,
                  colorB: frostB,
                  gradDepth: frostDepth,
                  blurSigma: 0,
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

/// 分区标题：图标 + 文字
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.label,
    required this.scheme,
  });

  final IconData icon;
  final String label;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
      child: Row(
        children: [
          Icon(icon, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
          ),
        ],
      ),
    );
  }
}

/// 均分布局：子元素保持自然宽度，通过调整间距均分可用宽度
class _EvenWrap extends StatelessWidget {
  const _EvenWrap({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    const rowCount = 3;
    return LayoutBuilder(
      builder: (context, constraints) {
        final rows = <Widget>[];
        for (var i = 0; i < children.length; i += rowCount) {
          final rowChildren = <Widget>[];
          for (var j = i; j < i + rowCount && j < children.length; j++) {
            rowChildren.add(children[j]);
          }
          // 用 IntrinsicWidth 测量每个子元素自然宽度
          // 然后用 Spacer 均分剩余空间
          rows.add(
            IntrinsicHeight(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: rowChildren,
              ),
            ),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              rows[i],
            ],
          ],
        );
      },
    );
  }
}

/// 调色板：16 色扩展色板
class _ColorPalette extends StatelessWidget {
  const _ColorPalette({required this.current, required this.onPick});

  final Color? current;
  final ValueChanged<Color> onPick;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final c in AppTheme.palettePresets)
            _PaletteSwatch(
              color: c,
              selected: current?.toARGB32() == c.toARGB32(),
              onTap: () => onPick(c),
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

/// 自定义取色器按钮：点击弹出 flex_color_picker 取色对话框
class _ColorPickerButton extends StatelessWidget {
  const _ColorPickerButton({
    required this.current,
    required this.active,
    required this.onPick,
  });

  final Color current;

  /// 当前来源是否为本取色器：真时用主色描边强调
  final bool active;
  final ValueChanged<Color> onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _showColorPicker(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? scheme.primary : scheme.outlineVariant,
            width: active ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: current,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.4),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text('选择颜色', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(width: 4),
            Icon(AppIcons.chevronRight,
                size: 16, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  void _showColorPicker(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => _ColorPickerDialog(
        initialColor: current,
        onPick: onPick,
      ),
    );
  }
}

/// 取色对话框：flex_color_picker + 液态玻璃壳（与设置容器/底栏同语言）
class _ColorPickerDialog extends ConsumerStatefulWidget {
  const _ColorPickerDialog({
    required this.initialColor,
    required this.onPick,
  });

  final Color initialColor;
  final ValueChanged<Color> onPick;

  @override
  ConsumerState<_ColorPickerDialog> createState() =>
      _ColorPickerDialogState();
}

class _ColorPickerDialogState extends ConsumerState<_ColorPickerDialog> {
  late Color _color;

  /// 当前取色面板：0 主题色 / 1 强调色 / 2 色轮（默认色轮）
  int _pickerIndex = 2;

  @override
  void initState() {
    super.initState();
    _color = widget.initialColor;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shell = ref.watch(shellSettingsProvider);
    return ExcludeSemantics(
      child: Dialog(
        backgroundColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: SettingsFrostGate(
            // 对话框独立卡片感：圆角 24（页面容器保持 16）
            radius: 24,
            blurSigma: 0,
            dir: AmbientDir.parse(shell.frostDir),
            colorA: shell.frostGradA != null
                ? Color(shell.frostGradA!)
                : null,
            colorB: shell.frostGradB != null
                ? Color(shell.frostGradB!)
                : null,
            gradDepth: shell.frostGradDepth,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                    child: Text(
                      '自定义主色调',
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                    child: Text(
                      '${ColorTools.nameThatColor(_color)}'
                      ' · ${_colorNameZh(_color)}',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                  // 液态玻璃切换器：与明暗模式同组件同语言，外包
                  // 派生色底衬容器（SettingsRowShell，非霜壳）。
                  // height 36 + padding 4 → pill 28 饱满；grow 6 恢复
                  // 液态鼓动（峰值 34 < 36 不溢出）；底衬内衬 4 → 总高 44
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                    child: SettingsRowShell(
                      borderRadius: BorderRadius.circular(18),
                      fill: scheme.surfaceContainerLow
                          .withValues(alpha: 0.45),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: LiquidGlassSegmented(
                      segments: const ['主题色', '强调色', '色轮'],
                      selectedIndex: _pickerIndex,
                      onChanged: (i) => setState(() => _pickerIndex = i),
                      width: double.infinity,
                      height: 36,
                      padding: 4,
                      style: LiquidGlassStyle(
                        shape: LiquidGlassShape.continuousRoundedRectangle(
                          cornerRadius: 14,
                          borderWidth: 0,
                          borderColor: Colors.transparent,
                          lightIntensity: 0,
                          borderType: const OpticalBorder(
                            borderSolidity: 0,
                            ambientIntensity: 0,
                          ),
                        ),
                        appearance: LiquidGlassAppearance(
                          color: Colors.transparent,
                          blur: const LiquidGlassBlur(sigmaX: 1.5, sigmaY: 1.5),
                          shadow: LiquidGlassShadow(
                            blur: 0,
                            opacity: 0,
                            cornerRadius: 14,
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
                        // 液态鼓动：与明暗分段一致，峰值不溢出壳
                        growHeight: shell.lgMotionOn ? 6 : 0,
                        glassStyle: LiquidGlassStyle(
                          appearance: LiquidGlassAppearance(
                            color: Colors.transparent,
                            blur: const LiquidGlassBlur(
                              sigmaX: 1.5,
                              sigmaY: 1.5,
                            ),
                            shadow: null,
                          ),
                          refraction: const LiquidGlassRefraction(
                            distortion: 0.08,
                            distortionWidth: 12,
                          ),
                        ),
                        restStyle: LiquidGlassStyle(
                          appearance: LiquidGlassAppearance(
                            color: AppGlass.restPillTint(scheme),
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
                  ),
                  // 三个单类型取色器按选择切换：pickersEnabled 必须
                  // **显式关闭**其余类型——包内未传的 accent 键
                  // `?? true` 默认开启，只传一键时 count=2 会仍显示
                  // 包内 selector（与液态切换器功能重复的根因）
                  Flexible(
                    child: IndexedStack(
                      index: _pickerIndex,
                      children: [
                        for (final enabled
                            in const <Map<ColorPickerType, bool>>[
                          {
                            ColorPickerType.primary: true,
                            ColorPickerType.accent: false,
                            ColorPickerType.wheel: false,
                          },
                          {
                            ColorPickerType.primary: false,
                            ColorPickerType.accent: true,
                            ColorPickerType.wheel: false,
                          },
                          {
                            ColorPickerType.primary: false,
                            ColorPickerType.accent: false,
                            ColorPickerType.wheel: true,
                          },
                        ])
                          SingleChildScrollView(
                            // 包内色板 Wrap 无 alignment 参数（默认靠左），
                            // Center 在外层把面板内容水平居中
                            child: Center(
                              child: ColorPicker(
                                color: _color,
                                onColorChanged: (Color c) =>
                                    setState(() => _color = c),
                                pickersEnabled: enabled,
                                width: 40,
                                height: 40,
                                // 色名/色码均走自绘行（包内背景不可定制）
                                showColorName: false,
                                showColorCode: false,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  // 色码行：包内 fillColor 写死不可定制，自绘
                  // primaryContainer 条——条收缩贴内容，整体居中
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    child: Align(
                      alignment: Alignment.center,
                      child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        final hex = _hexArgb(_color);
                        Clipboard.setData(ClipboardData(text: hex));
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                          SnackBar(
                            content: Text('已复制 $hex'),
                            duration: const Duration(milliseconds: 1200),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          // 条收缩贴内容（min），由外层 Align 整体居中
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              AppIcons.colorPicker,
                              size: 16,
                              color: scheme.onPrimaryContainer,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _hexArgb(_color),
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    color: scheme.onPrimaryContainer,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Icons.copy,
                              size: 14,
                              color: scheme.onPrimaryContainer,
                            ),
                          ],
                        ),
                      ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () {
                            widget.onPick(_color);
                            Navigator.pop(context);
                          },
                          child: const Text('确定'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 按色相/饱和度/明度给任意颜色取中文名：12 段色相 + 深/浅/灰修饰
  String _colorNameZh(Color c) {
    final hsv = HSVColor.fromColor(c);
    final s = hsv.saturation;
    final v = hsv.value;
    if (s < 0.12) {
      if (v < 0.15) return '黑';
      if (v > 0.88) return '白';
      return v < 0.5 ? '深灰' : '浅灰';
    }
    const names = [
      '红', '橙', '黄', '黄绿', '绿', '青绿',
      '青', '蓝', '靛蓝', '紫', '品红', '粉',
    ];
    // 从 -7.5° 起每 30° 一段，红窗 [-7.5°, 22.5°) 跨越 0°
    final idx = ((hsv.hue + 7.5) % 360) ~/ 30;
    final base = names[idx.clamp(0, 11)];
    if (v < 0.4) return '深$base';
    if (v > 0.82 && s < 0.45) return '浅$base';
    return base;
  }
}

/// 8 位 hex（含 alpha），取色器色码行与派生色卡共用
String _hexArgb(Color c) =>
    '#${c.toARGB32().toRadixString(16).toUpperCase().padLeft(8, '0')}';

/// 派生色系预览：当前 ColorScheme 的 8 个 MD3 角色，点击复制 hex。
/// 色值实时取自 Theme——任何主题色来源切换即时反映。
class _SchemeTintsGrid extends StatelessWidget {
  const _SchemeTintsGrid({required this.scheme});

  final ColorScheme scheme;

  List<(String, Color)> get _tints => [
        ('primary', scheme.primary),
        ('primaryContainer', scheme.primaryContainer),
        ('secondary', scheme.secondary),
        ('secondaryContainer', scheme.secondaryContainer),
        ('tertiary', scheme.tertiary),
        ('tertiaryContainer', scheme.tertiaryContainer),
        ('error', scheme.error),
        ('errorContainer', scheme.errorContainer),
      ];

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 4,
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      childAspectRatio: 1.45,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      children: [
        for (final (name, color) in _tints)
          _TintSwatch(name: name, color: color),
      ],
    );
  }
}

class _TintSwatch extends StatelessWidget {
  const _TintSwatch({
    required this.name,
    required this.color,
  });

  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final hex = _hexArgb(color);
    final fg =
        color.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;
    final outline = Theme.of(context).colorScheme.outlineVariant;
    return InkWell(
      onTap: () {
        Clipboard.setData(ClipboardData(text: hex));
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text('已复制 $hex'),
            duration: const Duration(milliseconds: 1200),
            behavior: SnackBarBehavior.floating,
          ),
        );
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: outline.withValues(alpha: 0.4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                name,
                style: TextStyle(fontSize: 9, color: fg),
                maxLines: 2,
              ),
            ),
            const Spacer(),
            Text(
              hex,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
