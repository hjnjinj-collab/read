import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/services/app_version_service.dart';
import '../../core/theme/app_icons.dart';
import '../../core/theme/app_theme.dart' show AppTheme;
import 'providers/shell_settings.dart';

/// 设置 Tab：外观（主题色/明暗/动态取色/布局）/ 关于
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shell = ref.watch(shellSettingsProvider);
    final shellNotifier = ref.read(shellSettingsProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final versionAsync = ref.watch(appVersionStringProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CustomScrollView(
        slivers: [
          const SliverAppBar.large(
            title: Text('设置'),
          ),
          SliverList.list(
            children: [
              _SectionHeader(label: '外观'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  '主题色',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final p in AppTheme.seedPresets)
                      _SeedChip(
                        label: p.label,
                        color: p.color,
                        selected: shell.seedArgb == null
                            ? p.color.toARGB32() == AppTheme.seed.toARGB32()
                            : shell.seedArgb == p.color.toARGB32(),
                        onTap: () => shellNotifier.setSeed(p.color),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'system', label: Text('跟随系统')),
                    ButtonSegment(value: 'light', label: Text('浅色')),
                    ButtonSegment(value: 'dark', label: Text('深色')),
                  ],
                  selected: {shell.themeMode},
                  onSelectionChanged: (s) =>
                      shellNotifier.setThemeMode(s.first),
                ),
              ),
              ListTile(
                title: const Text('底栏玻璃'),
                subtitle: Text(
                  shell.glassMode == 'lite' || Platform.isWindows
                      ? '毛玻璃霜面（Windows 强制；无 shader）'
                      : '液态折射（Impeller 实时）',
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SegmentedButton<String>(
                  key: ValueKey('glass-mode-${shell.glassMode}'),
                  segments: const [
                    ButtonSegment(value: 'liquid', label: Text('液态玻璃')),
                    ButtonSegment(value: 'lite', label: Text('毛玻璃')),
                  ],
                  selected: {shell.glassMode},
                  onSelectionChanged: (s) {
                    // 先写 Engine，再持久化；AppShell 以 glassMode 为 Key 重建 Lens
                    shellNotifier.setGlassMode(s.first);
                  },
                ),
              ),
              ListTile(
                title: const Text('底栏模糊'),
                subtitle: Text(
                  shell.navBlurSigma < 1
                      ? '关闭（仅着色）'
                      : '强度 ${shell.navBlurSigma.round()}',
                ),
              ),
              // ClipRect：滑轨 Lens 的 blur/refraction 会画出边界，不裁会糊到整页
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: ClipRect(
                  child: LiquidGlassSlider(
                    key: const ValueKey('nav-blur-slider'),
                    value: shell.navBlurSigma.clamp(0, 48),
                    onChanged: shellNotifier.setNavBlurSigma,
                    minimumValue: 0,
                    maximumValue: 48,
                    activeColor: scheme.primary,
                    width: MediaQuery.sizeOf(context).width - 32,
                    height: 56,
                    style: LiquidGlassSlider.defaultStyle.copyWith(
                      appearance: LiquidGlassSlider.defaultStyle.appearance
                          .copyWith(
                        blur: const LiquidGlassBlur(sigmaX: 1, sigmaY: 1),
                      ),
                      refraction: const LiquidGlassRefraction(
                        distortion: 0.04,
                        distortionWidth: 12,
                      ),
                    ),
                  ),
                ),
              ),
              ListTile(
                title: const Text('底栏色渗'),
                subtitle: Text(
                  '主色强度 ${(shell.navTintStrength * 100).round()}%',
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: ClipRect(
                  child: LiquidGlassSlider(
                    key: const ValueKey('nav-tint-slider'),
                    value: shell.navTintStrength.clamp(0, 1),
                    onChanged: shellNotifier.setNavTintStrength,
                    minimumValue: 0,
                    maximumValue: 1,
                    activeColor: scheme.primary,
                    width: MediaQuery.sizeOf(context).width - 32,
                    height: 56,
                    style: LiquidGlassSlider.defaultStyle.copyWith(
                      appearance: LiquidGlassSlider.defaultStyle.appearance
                          .copyWith(
                        blur: const LiquidGlassBlur(sigmaX: 1, sigmaY: 1),
                      ),
                      refraction: const LiquidGlassRefraction(
                        distortion: 0.04,
                        distortionWidth: 12,
                      ),
                    ),
                  ),
                ),
              ),
              SwitchListTile(
                title: const Text('动态取色'),
                subtitle: const Text('Android 12+ 跟随壁纸（开启时覆盖主题色）'),
                value: shell.dynamicColor,
                onChanged: shellNotifier.setDynamicColor,
              ),
              SwitchListTile(
                title: const Text('书架网格布局'),
                subtitle: const Text('关闭则使用列表模式'),
                value: shell.bookshelfGrid,
                onChanged: shellNotifier.setBookshelfGrid,
              ),
              const Divider(height: 24),
              _SectionHeader(label: '关于'),
              ListTile(
                leading: Icon(AppIcons.about, color: scheme.onSurfaceVariant),
                title: const Text('关于'),
                subtitle: versionAsync.when(
                  data: (v) => Text('版本 $v'),
                  loading: () => const Text('读取中…'),
                  error: (_, _) => const Text('版本未知'),
                ),
                trailing: const Icon(AppIcons.chevronRight),
                onTap: () => context.push('/about'),
              ),
              const SizedBox(height: 120),
            ],
          ),
        ],
      ),
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
