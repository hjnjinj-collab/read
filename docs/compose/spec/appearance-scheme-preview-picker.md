---
feature: appearance-scheme-preview-picker
status: in-progress
updated: 2026-09-19
branch: master
commits: cdf94df..0829b87
---

# 明暗/书架容器对齐导航栏尺寸 + 派生色预览 + FlexColorPicker

## Report

**What was built** — 外观页三类容器尺寸统一到液态玻璃导航栏高度 64px：
明暗分段撤销误加的垫高（贴壳边）且 48→64；`SettingSwitchRow` 垂直
8→14（行高 64，6 处统一）。主题容器末尾「派生色系」分区：8 个 MD3
角色 4 列网格实时跟随主题来源，点击复制 8 位 hex，底距 14px 不贴底。
自定义取色迁移 flex_color_picker 3.8 并包进 `SettingsFrostShell`
液态玻璃壳（霜向/渐变经 Consumer 跟随用户外观自定义），标题下显示
「英文色名 · 中文名」（HSV 12 段色相映射），顶部冗余复制按钮移除；
applySeed 来源互斥流程不变。

**Verification** — `flutter analyze`：25 issue 全部 PRE-EXISTING，
改动文件零新增；两轮独立审查三项 PASS、无 critical（滚动兜底范式、
透明 Dialog 上 BackdropFilter 采样链、_colorNameZh 边界数学、
无死导入均核对）；真机反馈四项（贴底/色名中文/玻璃壳/冗余按钮）
全部落地。转场动画瞬间霜面可能闪一下（BackdropFilter 采样转场
saveLayer，瞬时项）与 ExcludeSemantics 使对话框按钮对 TalkBack
不可见（压制取色器巨量语义树的取舍）两项已记录，真机观察。

**Journey log** —
- flex_color_scheme v9 迁移 material_ui 是作者有意设计（用户确认）；
  本项目借用其色彩体系与算法，8.x 锁定维持。
- 明暗模式容器的语义是「复刻导航栏尺寸」——对液态玻璃容器加通用
  padding 前先确认设计意图，上轮 vertical:10 垫高即误判。
- ColorPicker 在 AlertDialog/Dialog 内自适应内容宽；wheel 切换改变
  对话框尺寸，矮屏需 Flexible+SingleChildScrollView 兜底。
- Dialog 透明底 + FrostShell 组合成立：BackdropFilter 采样同合成树
  先行内容（下层页面 + barrier），透明底是必要条件而非障碍。
- 审查子代理 bash 受限时「终点文件状态 + 全库交叉 grep」模式连续
  三轮可用，结论经主代理抽验成立。

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

### 真机验收修正（T5/T6，同 feature 打磨）

- 派生色系作为主题容器末分区，网格底距 2 → 14px，消除贴底。
- 对话框改用 `SettingsFrostShell` 液态玻璃壳（与设置容器/底栏同语言），
  Dialog 透明底 + maxWidth 380；内部 Column：标题行 / 中英色名行 /
  Flexible 滚动 ColorPicker / 底部操作行。
- 色名双语：关闭包内 `showColorName`，自定义行显示
  `ColorTools.nameThatColor` 英文名 + `_colorNameZh` 中文
  （HSV 色相 12 段 + 深/浅/灰修饰，覆盖任意色）。
- 删除 `copyPasteBehavior(copyButton)`——色码行自带复制，顶部工具栏
  复制按钮冗余。

### 收尾打磨（T7，用户验收反馈）

- 取色器分段选择器派生色：`selectedPickerTypeColor: scheme.primary`
  （包内 SelectPicker 按 thumb 亮度自动取黑白文字）；分段标签中文化
  （主题色/强调色/色轮）；`pickerTypeTextStyle` 用 bodySmall +
  onSurfaceVariant。
- `SettingsFrostShell` 描边细腻化（全局）：rim width 1→0.5，浅色
  α0.48→0.32、深色 α0.10→0.08；对话框壳 `radius: 24`（页面容器
  保持 16，独立卡片感）。
- 「选择颜色」按钮右移贴容器右缘（16px 网格），与开关行布局语言一致。

## [S3] Out of Scope

- flex_color_scheme v9 迁移（用户确认借鉴算法即可，8.x 锁定维持）。
- 明暗分段圆角/形状与导航栏胶囊的形状统一（仅对齐高度）。
- glass 设置页布局的其他问题（仅被动接受行高 64）。

## Tasks

- [x] T1: 撤明暗垫高 + 分段 64 + SettingSwitchRow vertical 14 — acceptance: 明暗与书架容器均 64px，与导航栏同高；分段贴壳边（代码落地+审查核对，视觉待真机） (covers: S2 尺寸)
- [x] T2: 派生色系预览卡（8 角色网格 + tap 复制 hex） — acceptance: 切主题色/动态取色时色卡即时刷新；点击复制 hex（落地+审查核对） (covers: S2 预览)
- [x] T3: FlexColorPicker 替换自写 HSV 对话框 — acceptance: 色轮/色板/色码可用，确定后来源切到 picker 且其余组置灰（落地+审查核对） (covers: S2 取色器)
- [x] T5: 派生色系网格底距 14px — acceptance: 主题容器末分区不再贴底（真机反馈修正） (covers: S2 真机修正)
- [x] T6: 取色器 FrostShell 玻璃壳 + 中英色名 + 删顶部复制按钮 — acceptance: 对话框呈液态玻璃材质；色名显示「英文 · 中文」；顶部无孤立复制按钮 (covers: S2 真机修正)
- [ ] T7: 分段派生色 + 霜层描边/圆角细腻化 + 取色按钮右移 — acceptance: 分段选中态用 scheme.primary；rim 0.5px 更细腻；按钮贴右 (covers: S2 收尾打磨)
- [ ] T4: analyze + test + 审查 + 真机验收 — acceptance: analyze 无新增告警（已达成）；审查 PASS（待 T7 后复审）；真机确认（待用户执行） (covers: S1 全部)
