---
feature: appearance-scheme-preview-picker
status: delivered
updated: 2026-09-19
branch: master
commits: cdf94df..61bb105
---

# 明暗/书架容器对齐导航栏尺寸 + 派生色预览 + FlexColorPicker

## Report

**What was built** — 外观页三类容器尺寸统一到液态玻璃导航栏高度 64px：
明暗分段撤销上轮误加的垫高（分段贴壳边）且 48→64；`SettingSwitchRow`
垂直 8→14（行高 64，书架/动态取色/玻璃设置页 6 处统一）。主题容器末尾
新增「派生色系」分区：当前 ColorScheme 的 8 个 MD3 角色 4 列网格，色值
实时跟随主题来源切换，点击复制 8 位 hex。自定义取色对话框迁移到
flex_color_picker 3.8（色板+色轮+色码，外层 SingleChildScrollView
矮屏滚动兜底），自写 HSV 滑杆删除；applySeed 来源互斥流程不变。

**Verification** — `flutter analyze`：25 issue 全部 PRE-EXISTING，
改动文件零新增；独立审查三项 PASS、无 critical（括号平衡、
ColorPicker 对话框宽度按包 README 自适应、Clipboard/maybeOf 空安全、
glass 页 64px 行协调性、grid tile 无溢出均核对）；轻微项已处理：
onColor 死参数删除、色卡角色名允许两行、取色对话框滚动兜底、HSV
过时注释同步。真机视觉验收由用户执行中（T4 部分）。

**Journey log** —
- flex_color_scheme v9 迁移 material_ui 是作者有意设计（用户确认）；
  本项目借用其色彩体系与算法，v9 类型分叉不迁移，8.x 锁定维持。
- 明暗模式容器的设计语义是「复刻导航栏尺寸」——对这类液态玻璃容器
  加通用 padding 前先确认设计意图，上一轮的 vertical:10 垫高即误判。
- ColorPicker 在 AlertDialog 内自适应内容宽（包 README 460-466），但
  wheel 切换会改变对话框尺寸，矮屏需滚动兜底；真机验收时留意横屏。
- 审查子代理 bash 受限时的「终点文件状态核对」模式连续两轮可用且
  结论经主代理抽验成立；抽验重点 = 审查者引用的行号与 diff 摘要。

## [S1] Problem

1. 上一轮给明暗模式分段加的 `Padding(vertical:10)` 是误判：明暗容器的
   设计意图是**复刻液态玻璃导航栏的尺寸**（分段直接贴壳边，无额外
   垫高），垫高后容器 68px 显得臃肿；书架布局行 52px 又偏窄。
   导航栏标准高度为 64px（expandable_glass_nav.dart `height = 64`）。
2. flex_color_scheme 引擎已就位，但外观页还没有派生色展示——用户希望
   直观看到当前主题色的 MD3 色彩角色派生效果。
3. 自定义取色仍是自写 HSV 三滑杆，用户要求接入 flex_color_picker 的
   ColorPicker（色轮 + Material 色板 + 色码）。
4. 认知记录：flex_color_scheme v9 迁移 material_ui 是作者有意设计；
   本项目借用其色彩体系与算法，v9 类型体系与 framework 分叉，维持
   8.x 锁定不变（用户确认）。

## [S2] Design

### 容器尺寸统一到导航栏 64px（T1）

- 明暗模式：撤销 `Padding(vertical:10)`（恢复分段贴壳边），
  `LiquidGlassSegmented height: 48 → 64`——容器与导航栏同高 64，
  液态 pill 溢出效果（growHeight）保留。
- `SettingSwitchRow`：`vertical 8 → 14`，行高 36+28 = 64——书架布局行、
  动态取色行、glass 设置页 4 行全部统一到 64。
- 主题容器首行距顶 14、标签/分隔线节奏不变（上轮成果）。

### 派生色系预览（T2）

- 主题容器末尾（动态取色之后）：`SettingsDivider` +
  `SettingIconLabel('派生色系', AppIcons.schemeTints = Iconsax.category)`
  + `_SchemeTintsGrid`。
- 网格展示 8 个 MD3 角色：primary / primaryContainer / secondary /
  secondaryContainer / tertiary / tertiaryContainer / error /
  errorContainer，`GridView.count(crossAxisCount: 4, aspectRatio 1.45,
  shrinkWrap + NeverScrollable)`。
- 每块显示角色名（9sp，FittedBox scaleDown，最多两行）+ 8 位 hex
  （9sp），文字色按背景
  `computeLuminance() > 0.5 ? black87 : white` 自动取黑白。
- 点击块：`Clipboard.setData` 复制 hex + `ScaffoldMessenger.maybeOf`
  显示「已复制 #XXXXXXXX」（maybeOf 判空，无 Scaffold 环境静默）。
- 色值实时来自 `Theme.of(context).colorScheme`——任何主题色来源切换
  （含动态取色）即时反映。

### FlexColorPicker 取色器（T3）

- 依赖 `flex_color_picker ^3.8.0`（与 flex_color_scheme 同作者、纯
  framework 类型）。
- `_ColorPickerDialog` 重写：内部 `ColorPicker(color, onColorChanged,
  pickersEnabled: {primary, accent, wheel}, width/height 40,
  showColorName: true, showColorCode: true)`，外层
  `SingleChildScrollView` 矮屏滚动兜底，AlertDialog 骨架与
  「确定 → onPick → applySeed(source:'picker')」流程不变。
- 自写 `_SliderRow`、HSV state 全部删除。

## [S3] Out of Scope

- flex_color_scheme v9 迁移（用户确认借鉴算法即可，8.x 锁定维持）。
- 明暗分段圆角/形状与导航栏胶囊的形状统一（仅对齐高度）。
- glass 设置页布局的其他问题（仅被动接受行高 64）。

## Tasks

- [x] T1: 撤明暗垫高 + 分段 64 + SettingSwitchRow vertical 14 — acceptance: 明暗与书架容器均 64px，与导航栏同高；分段贴壳边（代码落地+审查核对，视觉待真机） (covers: S2 尺寸)
- [x] T2: 派生色系预览卡（8 角色网格 + tap 复制 hex） — acceptance: 切主题色/动态取色时色卡即时刷新；点击复制 hex（落地+审查核对） (covers: S2 预览)
- [x] T3: FlexColorPicker 替换自写 HSV 对话框 — acceptance: 色轮/色板/色码可用，确定后来源切到 picker 且其余组置灰（落地+审查核对） (covers: S2 取色器)
- [ ] T4: analyze + test + 审查 + 真机验收 — acceptance: analyze 无新增告警（已达成）；审查 PASS（已达成）；真机确认（待用户执行） (covers: S1 全部)
