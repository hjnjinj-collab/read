import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:liquid_glass_easy/src/widgets/components/liquid_glass_segmented.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/shell_settings.dart';
import '../widgets/shell_ambient.dart';
import 'settings_chrome.dart';

/// 打开壳层液态取色对话框（外观页 / 阅读背景等共用）。
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

/// 取色对话框：flex_color_picker + 液态玻璃壳（与设置容器/底栏同语言）。
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
