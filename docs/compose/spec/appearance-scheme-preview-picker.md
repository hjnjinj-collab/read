---
feature: appearance-scheme-preview-picker
status: delivered
updated: 2026-09-19
branch: master
commits: cdf94df..82cac1f
---

# 明暗/书架容器对齐导航栏尺寸 + 派生色预览 + FlexColorPicker

## Report

**What was built** — 外观页三类容器尺寸统一到液态玻璃导航栏高度 64px
（明暗分段贴壳边 64、开关行 6×64）。主题容器末尾「派生色系」分区：
8 个 MD3 角色 4 列网格实时跟随主题来源，点击复制 hex，底距 14px。
自定义取色迁移 flex_color_picker 3.8，外包 SettingsFrostShell 玻璃壳
（radius 24、霜向/渐变经 Consumer 跟随用户自定义），标题下「英文色名 ·
中文名」双语行（HSV 12 段映射），分段选择器 thumb 用 scheme.primary
且标签中文化，顶部冗余复制按钮移除。「选择颜色」按钮为标签行
`SettingIconLabel.trailing` 控件，与左侧文字水平同行。玻璃描边按
明暗分档：浅色 0.5px α0.32-0.35 细腻，深色 0.8px α0.26-0.28 保证
轮廓与圆角可辨——FrostShell / floatRowRim / RowShell 三处经
`AppGlass.rimWidth` 统一宽度语言。

**Verification** — `flutter analyze`：25 issue 全部 PRE-EXISTING，
改动文件零新增；`flutter test` 主题冒烟 2 PASS；四轮独立审查均三项
PASS、无 critical（包源码层核对：SelectPicker 按 thumb 亮度自动黑白
文字、透明 Dialog 上 BackdropFilter 采样链、_colorNameZh 边界数学、
trailing 垂直居中与无双重 padding、分档变量消费）。已知边界：中等
亮度自定义 seed 时分段文字对比度临界（包设计）、ExcludeSemantics 使
取色对话框对读屏不可见（压制语义树噪声的取舍）、深色 rim 若仍嫌淡
可在 AppGlass.rimWidth / rim 调值。

**Journey log** —
- flex_color_scheme v9 迁移 material_ui 是作者有意设计（用户确认）；
  本项目借用其色彩体系与算法，8.x 锁定维持。
- 液态玻璃容器的 padding/尺寸/描边语义先问设计意图再动手（明暗分段
  「复刻导航栏」的垫高误判教训）；描边是明暗双档视觉语言，调一处需
  同步全部壳体并提取 AppGlass.rimWidth 单点维护。
- Dialog 透明底 + FrostShell 组合成立：BackdropFilter 采样同合成树
  先行内容，透明底是必要条件；对话框独立感靠 radius 24 与页面 16 区分。
- frost 描边是全局视觉语言：FrostShell rim 调细时同步 SettingsRowShell
  等兄弟壳体，避免外壳 0.5 / 子行 1 的不统一。
- **Stack 全定位子节点会取 constraints.biggest**：Column 无界高度下
  触发框架断言、Dialog 松弛高度下壳体膨胀全高。分层壳体的内容层必须
  保持非定位子节点（child-sizing），仅覆盖层（rim/遮罩）用
  Positioned.fill——参照 SettingsFrostGroup 的既有可行结构。
- 审查子代理 bash 受限时「终点文件状态 + 全库交叉 grep + 包源码」
  模式连续多轮可用，结论经主代理抽验成立。

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

### 深色描边分档与同行布局（T8，用户验收反馈二）

- 描边按明暗模式分档（T7 的 0.5px/α0.08 在深色下轮廓不可读、圆角
  可视性丧失）：
  - `SettingsFrostShell` rim：浅色 0.5px α0.32（维持细腻）；
    深色 0.8px α0.28（轮廓可读，圆角边界可辨）。
  - `AppGlass.floatRowRim` 深色 α0.10→0.26；`SettingsRowShell`
    宽度浅 0.5 / 深 0.8，与 FrostShell 同语言。
- 「选择颜色」按钮与左侧标签文字同行：`SettingIconLabel` 增加可选
  `trailing` 参数（组件仅外观页使用），自定义取色区改为单行
  `SettingIconLabel(..., trailing: 按钮)`，删除下方独占一行的
  Align 右对齐布局——按钮与「自定义取色」文字水平居中同行，
  右缘仍距壳 16px。

### 明暗/网格统一 60 与取色器液态切换器（T10/T11，用户验收反馈四）

- 明暗分段 `height 64→60`、`growHeight 10→6`（pill 选中态 60=壳高，
  不再溢出壳外——上轮的臃肿感来源），开关行 `vertical 14→12`
  （行高 60）：两容器精确同高、视觉减重；导航栏 64 不变。
- 取色器切换器换**液态玻璃分段**（与明暗模式同组件、同风格语言，
  不包霜壳）：包内 Cupertino 灰底 selector 整体废弃——改为外部
  `LiquidGlassSegmented`（主题色/强调色/色轮三段，labelStyle 派生色）
  + `IndexedStack` 三个单类型 `ColorPicker` 实例
  （`pickersEnabled` 各只开一类，单类型时包内 selector 自动隐藏），
  共享 `_color` 状态，切换不丢选中状态。
- 删除包 selector 相关参数（selectedPickerTypeColor /
  pickerTypeTextStyle / pickerTypeLabels——随包 selector 一起消失）；
  `colorCodeTextStyle` 用 `onSurface` 派生。
- 色块选中对号保留包内自适应黑白（按色块亮度，正确设计不动）。

### 圆角缺角修复（T9，用户验收反馈三）

- 根因是**层序**而非描边宽度：`BackdropFilter` 的模糊采样在 ClipRRect
  裁切边缘有一圈半透明带，描边原先画在渐变层内（模糊层之上但被
  该带透出），圆角弧线处 rim 被吃掉，深色下视觉「缺一角」。
- 修复：`SettingsFrostShell` 内部改 Stack 结构——模糊/渐变层与
  **前景描边层**（`Positioned.fill` + `IgnorePointer` +
  `DecoratedBox(border)`）分离，rim 画在全部层之上，整圈完整可见；
  分档数值不变（浅 0.5px α0.32 / 深 0.8px α0.28）。
- 影响面：全部 FrostShell 容器（外观页三容器、取色对话框、其他设置页），
  浅色同样受益（圆角弧线更连续）。

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
- [x] T7: 分段派生色 + 霜层描边/圆角细腻化 + 取色按钮右移 — acceptance: 分段选中态用 scheme.primary；rim 0.5px 更细腻；按钮贴右（落地+审查 PASS） (covers: S2 收尾打磨)
- [x] T8: 描边明暗分档 + 取色按钮与文字同行 — acceptance: 深色轮廓/圆角可辨；按钮与标签文字同一水平行（落地+审查 PASS） (covers: S2 深色分档与同行)
- [x] T9: FrostShell 描边提为前景层 — acceptance: 深色下圆角处描边不断裂、无缺角感（落地+复审 PASS：内容层非定位子节点保 child-sizing，rim 前置） (covers: S2 圆角缺角修复)
- [ ] T10: 明暗分段 60 + 开关行 60 统一 — acceptance: 明暗与网格布局容器精确同高、pill 不溢出壳（covers: S2 T10/T11）
- [ ] T11: 取色器液态玻璃切换器 + 派生色细节 — acceptance: 三段切换为 LiquidGlassSegmented；分段/色码均派生色；IndexedStack 切换不丢状态 (covers: S2 T10/T11)
- [ ] T4: analyze + test + 审查 + 真机验收 — acceptance: analyze 无新增告警（已达成）；审查 PASS（待 T10/T11 复审）；真机确认（待用户执行） (covers: S1 全部)
