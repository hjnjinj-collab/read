import 'package:flutter/material.dart';

import 'settings_chrome.dart';

/// 阅读默认（骨架）：全局排版与翻页偏好；字段与阅读菜单 sheet 对齐后启用
class ReadingSettingsPage extends StatelessWidget {
  const ReadingSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: '阅读默认',
      slivers: [
        SliverToBoxAdapter(
          child: SettingsGroup(
            header: '排版',
            children: const [
              SettingLabel(title: '字体', subtitle: '骨架占位 — 思源宋（内置）'),
              SettingLabel(title: '字号', subtitle: '当前 18pt'),
              SettingLabel(title: '行距', subtitle: '当前 1.6'),
              SettingLabel(title: '边距', subtitle: '当前 16'),
              SettingLabel(title: '段落', subtitle: '首行缩进 / 段距'),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: SettingsGroup(
            header: '翻页',
            children: const [
              SettingLabel(title: '默认翻页模式', subtitle: '仿真 / 平滑 / 无'),
              SettingLabel(title: '默认速度', subtitle: '快 / 中 / 慢'),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: SettingsGroup(
            header: '夜间',
            children: const [
              SettingLabel(title: '纸色与墨色', subtitle: '跟随主题派生（当前）'),
            ],
          ),
        ),
      ],
    );
  }
}
