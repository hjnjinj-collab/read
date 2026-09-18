import 'package:flutter/material.dart';

import 'settings_chrome.dart';

/// 动效（骨架）：转场/翻页档位占位；数据源接 AppMotion / 阅读设置后续补
class MotionSettingsPage extends StatelessWidget {
  const MotionSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: '动效',
      slivers: [
        SliverToBoxAdapter(
          child: SettingsGroup(
            header: '转场',
            children: [
              const SettingLabel(
                title: '页面转场',
                subtitle: '阅读页缩放 720ms · easeInOutQuart（当前固定）',
              ),
              const SettingLabel(
                title: '书架重排',
                subtitle: 'FLIP 位移 · 无回弹',
              ),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: SettingsGroup(
            header: '翻页（默认值）',
            children: const [
              SettingLabel(
                title: '翻页模式',
                subtitle: '骨架占位 — 接入阅读默认后启用',
              ),
              SettingLabel(
                title: '翻页速度',
                subtitle: '快 / 中 / 慢（当前「中」）',
              ),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: SettingsGroup(
            header: '系统',
            children: const [
              SettingLabel(
                title: '减弱动态',
                subtitle: '始终跟随系统设置：玻璃退化实底、动画直切',
              ),
            ],
          ),
        ),
      ],
    );
  }
}
