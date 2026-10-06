import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:liquid_glass_easy/src/widgets/components/liquid_glass_segmented.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/shell_glass_style.dart';
import '../../reader/presentation/services/bg_image_store.dart';
import '../../reader/presentation/widgets/reader_page_widget.dart' show PageContentRenderer;
import '../providers/shell_settings.dart';
import '../widgets/shell_ambient.dart';
import 'settings_chrome.dart';

/// 打开壳层液态取色对话框（外观页主题色）。
Future<Color?> showShellColorPicker(
  BuildContext context, {
  required Color initialColor,
  required ValueChanged<Color> onPick,
}) {
  return showDialog<Color>(
    context: context,
    builder: (context) => ShellColorPickerDialog(
      initialColor: initialColor,
      onPick: onPick,
    ),
  );
}

/// 阅读背景取色：液态壳（同 sheet）+ 单色 + 背景/文字预览。
Future<Color?> showPaperColorPicker(
  BuildContext context, {
  required Color initialColor,
  required Color textColor,
  Color? previewBg,
  required ValueChanged<Color> onPick,
}) {
  return showDialog<Color>(
    context: context,
    builder: (context) => PaperColorPickerDialog(
      initialColor: initialColor,
      textColor: textColor,
      previewBg: previewBg ?? initialColor,
      onPick: onPick,
    ),
  );
}

/// 背景取色对话框：液态玻璃壳 + 单色取色 + 背景/文字预览。
class PaperColorPickerDialog extends ConsumerStatefulWidget {
  const PaperColorPickerDialog({
    super.key,
    required this.initialColor,
    required this.textColor,
    this.previewBg,
    required this.onPick,
  });

  final Color initialColor;

  /// 预览文字色（挑背景时=正文色；挑文字时=当前文字色）
  final Color textColor;

  /// 预览底色（挑背景时=所选背景；挑文字时=对应纸色）
  final Color? previewBg;
  final ValueChanged<Color> onPick;

  @override
  ConsumerState<PaperColorPickerDialog> createState() =>
      _PaperColorPickerDialogState();
}

class _PaperColorPickerDialogState
    extends ConsumerState<PaperColorPickerDialog> {
  late Color _color;

  @override
  void initState() {
    super.initState();
    _color = widget.initialColor;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shell = ref.watch(shellSettingsProvider);
    final blur =
        shell.readerSheetBlurOn ? shell.readerSheetBlurSigma : 0.0;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: LiquidGlassSheet(
          anchor: LiquidGlassSheetAnchor.attached,
          grabber: true,
          // 与阅读设置 sheet 同源液态壳
          style: shellFrostLiquidStyle(
            scheme,
            navBlur: blur,
            navTint: shell.navTintStrength,
            radius: 28,
            strength: 1,
          ),
          foregroundColor: scheme.onSurface,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '背景取色',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${ColorTools.nameThatColor(_color)} · ${colorNameZh(_color)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                // 预览：真实阅读底（风景图+蒙版）或纯色 + 正文观感
                Builder(builder: (context) {
                  final bgImg = BgImageStore.instance.image;
                  final base = widget.previewBg ?? _color;
                  final scrim = base.withValues(
                    alpha: bgImg != null
                        ? BgImageStore.scrimAlpha(
                            BgImageStore.scrimStrength,
                            PageContentRenderer.paperOpacity,
                          )
                        : 1.0,
                  );
                  return Container(
                    width: double.infinity,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: base,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.22),
                      ),
                    ),
                    child: Stack(
                      children: [
                        if (bgImg != null)
                          Positioned.fill(
                            child: RawImage(
                              image: bgImg,
                              fit: BoxFit.cover,
                              filterQuality: FilterQuality.medium,
                            ),
                          ),
                        if (bgImg != null)
                          Positioned.fill(child: ColoredBox(color: scrim)),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '字有时是会骗人的',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                  // 挑背景：字=正文色；挑文字：字=当前选中色
                                  color: widget.previewBg == null
                                      ? widget.textColor
                                      : _color,
                                  height: 1.5,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '预览 · 背景与正文色搭配',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: (widget.previewBg == null
                                          ? widget.textColor
                                          : _color)
                                      .withValues(alpha: 0.72),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Center(
                      child: ColorPicker(
                        color: _color,
                        onColorChanged: (c) => setState(() => _color = c),
                        pickersEnabled: const {
                          ColorPickerType.primary: false,
                          ColorPickerType.accent: false,
                          ColorPickerType.wheel: true,
                        },
                        width: 40,
                        height: 40,
                        showColorName: false,
                        showColorCode: false,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
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
                        Navigator.pop(context, _color);
                      },
                      child: const Text('确定'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 取色对话框：flex_color_picker + 液态玻璃壳（外观主题色）。
class ShellColorPickerDialog extends ConsumerStatefulWidget {
  const ShellColorPickerDialog({
    super.key,
    required this.initialColor,
    required this.onPick,
  });

  final Color initialColor;
  final ValueChanged<Color> onPick;

  @override
  ConsumerState<ShellColorPickerDialog> createState() =>
      _ShellColorPickerDialogState();
}

class _ShellColorPickerDialogState
    extends ConsumerState<ShellColorPickerDialog> {
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
                      ' · ${colorNameZh(_color)}',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ),
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
                              blur: const LiquidGlassBlur(
                                  sigmaX: 1.5, sigmaY: 1.5),
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
                            child: Center(
                              child: ColorPicker(
                                color: _color,
                                onColorChanged: (Color c) =>
                                    setState(() => _color = c),
                                pickersEnabled: enabled,
                                width: 40,
                                height: 40,
                                showColorName: false,
                                showColorCode: false,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    child: Align(
                      alignment: Alignment.center,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          final hex = hexArgb(_color);
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
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                AppIcons.colorPicker,
                                size: 16,
                                color: scheme.onPrimaryContainer,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                hexArgb(_color),
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
                            Navigator.pop(context, _color);
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
}

/// 按色相/饱和度/明度给任意颜色取中文名：12 段色相 + 深/浅/灰修饰
String colorNameZh(Color c) {
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
  final idx = ((hsv.hue + 7.5) % 360) ~/ 30;
  final base = names[idx.clamp(0, 11)];
  if (v < 0.4) return '深$base';
  if (v > 0.82 && s < 0.45) return '浅$base';
  return base;
}

/// 8 位 hex（含 alpha）
String hexArgb(Color c) =>
    '#${c.toARGB32().toRadixString(16).toUpperCase().padLeft(8, '0')}';
