import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'settings_chrome.dart';

/// 存储（骨架）：缓存占用展示；清理动作接 CoverStore / 热分页后续补
class StorageSettingsPage extends ConsumerWidget {
  const StorageSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsScaffold(
      title: '存储',
      slivers: [
        SliverToBoxAdapter(
          child: SettingsGroup(
            header: '缓存',
            children: const [
              SettingLabel(title: '封面缓存', subtitle: '骨架占位 — 待接 CoverStore 统计'),
              SettingLabel(title: '热分页缓存', subtitle: '最近书籍 ±1 章预写（mtime 淘汰 400）'),
              SettingLabel(title: '解析会话', subtitle: 'LRU 10 本，随进程'),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: SettingsGroup(
            header: '策略',
            children: const [
              SettingLabel(title: '仅 Wi-Fi 预热', subtitle: '骨架占位'),
            ],
          ),
        ),
      ],
    );
  }
}
