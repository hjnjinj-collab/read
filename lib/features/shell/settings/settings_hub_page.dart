import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/app_version_service.dart';
import '../../../core/theme/app_icons.dart';
import '../providers/shell_settings.dart';
import 'settings_chrome.dart';

/// 设置根页：分区标题 + **悬浮霜面大卡**（一区一卡）。
/// 外轮廓圆角由卡片 Clip 承担，**中间行直角**（参考 Legado 规则页）。
/// 液态仍只出现在子页滑轨/开关。
class SettingsHubPage extends ConsumerWidget {
  const SettingsHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shell = ref.watch(shellSettingsProvider);
    final versionAsync = ref.watch(appVersionStringProvider);
    final version = versionAsync.when(
      data: (v) => v,
      loading: () => '…',
      error: (_, _) => '未知',
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SettingsBackdrop(
        child: SettingsGlassScroll(
          child: CustomScrollView(
            slivers: [
              const SliverAppBar(
                title: Text('设置'),
                pinned: false,
                floating: false,
                backgroundColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
              ),
              SliverList.list(
                children: [
                  SettingsGroup(
                    float: true,
                    header: '个性化',
                    children: [
                      SettingNavRow(
                        icon: AppIcons.grid,
                        title: '外观',
                        summary: _appearanceSummary(shell),
                        padV: shell.frostRowPadV,
                        onTap: () => context.push('/settings/appearance'),
                      ),
                      SettingNavRow(
                        icon: Icons.auto_awesome_rounded,
                        title: '材质与玻璃',
                        summary: _glassSummary(shell),
                        padV: shell.frostRowPadV,
                        onTap: () => context.push('/settings/glass'),
                      ),
                      SettingNavRow(
                        icon: Icons.waves_rounded,
                        title: '动效',
                        summary: '标准 · 仿真翻页',
                        padV: shell.frostRowPadV,
                        onTap: () => context.push('/settings/motion'),
                      ),
                      SettingNavRow(
                        icon: Icons.language_rounded,
                        title: '语言',
                        summary: '简体中文',
                        padV: shell.frostRowPadV,
                        onTap: () {},
                      ),
                    ],
                  ),
                  SettingsGroup(
                    float: true,
                    header: '阅读与数据',
                    children: [
                      SettingNavRow(
                        icon: AppIcons.bookshelf,
                        title: '阅读默认',
                        summary: '全局排版与翻页偏好',
                        padV: shell.frostRowPadV,
                        onTap: () => context.push('/settings/reading'),
                      ),
                      SettingNavRow(
                        icon: Icons.folder_rounded,
                        title: '存储',
                        summary: '缓存与预热',
                        padV: shell.frostRowPadV,
                        onTap: () => context.push('/settings/storage'),
                      ),
                      SettingNavRow(
                        icon: Icons.sync_rounded,
                        title: '同步',
                        summary: '未配置',
                        padV: shell.frostRowPadV,
                        onTap: () {},
                      ),
                      SettingNavRow(
                        icon: Icons.notifications_rounded,
                        title: '通知',
                        summary: '关闭',
                        padV: shell.frostRowPadV,
                        onTap: () {},
                      ),
                    ],
                  ),
                  SettingsGroup(
                    float: true,
                    header: '隐私与关于',
                    children: [
                      SettingNavRow(
                        icon: Icons.lock_rounded,
                        title: '隐私',
                        summary: '本地优先',
                        padV: shell.frostRowPadV,
                        onTap: () {},
                      ),
                      SettingNavRow(
                        icon: Icons.science_rounded,
                        title: '实验性',
                        summary: '开发者选项',
                        padV: shell.frostRowPadV,
                        onTap: () {},
                      ),
                      SettingNavRow(
                        icon: AppIcons.about,
                        title: '关于',
                        summary: '版本 $version',
                        padV: shell.frostRowPadV,
                        onTap: () => context.push('/about'),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _appearanceSummary(ShellSettings shell) {
  final mode = switch (shell.themeMode) {
    'light' => '浅色',
    'dark' => '深色',
    _ => '跟随系统',
  };
  return '$mode${shell.dynamicColor ? ' · 动态取色' : ''}';
}

String _glassSummary(ShellSettings shell) {
  final m = shell.glassMode == 'lite' ? '毛玻璃' : '液态';
  final blur =
      shell.navBlurSigma < 1 ? '关模糊' : 'blur ${shell.navBlurSigma.round()}';
  return '$m · $blur';
}
