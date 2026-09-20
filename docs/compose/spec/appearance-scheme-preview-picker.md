---
feature: appearance-scheme-preview-picker
status: delivered
updated: 2026-09-19
branch: master
commits: cdf94df..782b925
---

# 明暗/书架容器对齐导航栏尺寸 + 派生色预览 + FlexColorPicker

## Report

**What was built** — 外观页三类容器最终统一 60px 高（明暗分段贴壳边、
pill 增长 6 不溢出；开关行 36+24=60）。自定义取色对话框：FrostShell
玻璃壳（radius 24、霜向/渐变跟随用户自定义），标题下中英双语色名行，
液态玻璃三段切换器（主题色/强调色/色轮；height 36 + padding 4 →
pill 28 饱满、grow 6 恢复液态鼓动（峰值 34<36 不溢出）、底衬
SettingsRowShell 派生色 surfaceContainerLow α0.45 内衬 4、总高 44）+ IndexedStack 三个单类型 ColorPicker（pickersEnabled
显式关闭其余类型——包内未传的 accent 键 `?? true` 默认开启是双切换器
重复的根因；面板外包 Center，内容居中主要由包内 Column
crossAlignment 支撑）；自绘 primaryContainer 色码行（条收缩贴内容整体居中、点按复制）；「选择颜色」按钮为标签行 trailing 与文字
同行。玻璃描边明暗分档（浅 0.5px α0.32 / 深 0.8px α0.28，
AppGlass.rimWidth 单点）且提为前景层修复深色圆角缺角（内容层非定位
子节点保 child-sizing）。派生色系 8 角色预览卡实时跟随主题来源。
目标台账 `docs/compose/appearance-goals-log.md` 落库；明暗分段 pill
40/60（padding 10）按钮感明确，两处切换器选中态
primaryContainer α0.9 / onPrimaryContainer——**glassStyle（玻璃动画态）
与 restStyle（动画回落静止态）双层同色**，shadow cornerRadius
按 pillH/2 派生（20/14）。

**Verification** — `flutter analyze`：25 issue 全部 PRE-EXISTING，
改动文件零新增；`flutter test` 主题冒烟 2 PASS；各轮独立审查均三项
PASS、无 critical（包源码层核对：pickersEnabled `?? true` 陷阱、
SelectPicker 亮度取字、BackdropFilter 采样链、Stack biggest 陷阱、
rim 层序、Segmented padding/pill 数学、ColorPicker Column 对齐）。
已知边界：色板末行靠左为包 WrapAlignment.start（Center 不修正，
自绘可解暂未做）；色板在色轮取任意色时回退首个 swatch 高亮（包行为）；
色块对号为包内按亮度自适应黑白；IndexedStack 三面板同时 build；
ExcludeSemantics 使取色对话框对读屏不可见。

**Journey log** —
- **第三方包 map 参数的 `?? 默认值`陷阱**：flex_color_picker 的
  `pickersEnabled[X] ?? true`（primary/accent 默认开）——传单键 map
  时其余类型仍启用。对 map 型参数必须显式关闭无关键。
- Stack 分层壳体：内容层必须非定位子节点（child-sizing），覆盖层
  （rim/遮罩）才用 Positioned.fill——全定位子节点取
  constraints.biggest，Column 无界高度下崩溃。
- frost 描边是明暗双档 + 层序问题：深色需更高对比且 rim 必须画在
  模糊层之上（前景层），否则圆角弧线被裁切边缘半透明带吃掉。
- 视觉观感三教训：「臃肿」常源于组件自身体量；瘦身过头失去鼓动观感
  ——液态组件静态比例与动态动效一起定；「居中」分清 Column 对齐 /
  Wrap 行内 / 容器收缩后再居中。**液态组件多态样式要逐态核对**：
  LiquidGlassSegmentedPillStyle 的 glassStyle 只管玻璃动画态，静止
  回落态走 restStyle（未设即组件默认白）；且包字段文档称
  「glass=true 时 restStyle unused」与实现矛盾——**以实现为准**，
  涉及第三方组件多态样式时读渲染路径而非字段注释。
- flex_color_scheme v9 迁移 material_ui 是作者有意设计；本项目借算法
  维持 8.x 锁定（framework 类型分叉不可用）。

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

### 选中 pill 静止态派生色（T16，用户验收反馈九）

- **根因（用户判断正确）**：包内 pill 为双层结构——`glassStyle`
  只作用于玻璃**动画态**；动画回落后的静止选中态渲染 **`restStyle`**
  的 tinted pill（liquid_glass_segmented.dart:70-106 类文档 +
  :327-380 restOpacity/静止停放逻辑 + :533-539 `_tintedPill` 读
  `rest.appearance.color`）。未设 restStyle 时用组件默认 fill——
  白色胶囊，视觉上"透明遮罩取代了派生色"。
- 修复：两处切换器（明暗 + 取色器）pillStyle 均补
  `restStyle: LiquidGlassStyle(appearance: LiquidGlassAppearance(
  color: scheme.primaryContainer.withValues(alpha: 0.9)))`
  ——静止态与玻璃态同为派生色底；shape 不传时包默认
  `(height-padding*2)/2` 胶囊圆角自动。
- 明暗比例再加强：`padding 7→10`（pill 40/60，四周 10px 按钮感明显）；
  grow 6 峰值 46<60 不溢出。

### 目标台账与明暗选中态派生化（T15，用户验收反馈八）

- 目标任务台账：`docs/compose/appearance-goals-log.md`（外观线
  G1–G4 全程目标/交付/commit/约束沉淀）。
- 明暗分段选中 pill 比例：`padding 4→7`（pill 高 46/60 ≈ 0.77，
  与取色器切换器 28/36 比例一致）；grow 6 保持（峰值 52<60）。
- 选中色派生化（可读性，两处切换器统一）：pill 底
  `primary α0.28` → `primaryContainer α0.9`，选中文字
  `primary` → `onPrimaryContainer`——MD3 可读性配对，浅/深色
  主题下对比度均有保障。

### 取色器验收修正四（T14，用户验收反馈七）

- **pill 饱满度与鼓动恢复**：上轮 pill 22（32−5×2）过扁、且
  `growHeight: 0` 误关了液态鼓动——调整为 `height 36`、组件
  `padding 4`（pill 高 28 饱满）、`growHeight: lgMotionOn ? 6 : 0`
  （切换时 pill 峰值 28+6=34 < 36，不溢出壳）；底衬 Padding 4
  保持，总高 44。
- **色码条收缩居中**：全宽条 + 内容居中 → 条两侧空白过大。改为
  `Row(mainAxisSize.min)` 收缩贴合内容 + 外层 `Align(center)`
  ——条自身紧凑，整体在对话框内水平居中。

### 取色器验收修正三（T13，用户验收反馈六）

- **面板居中**：包内 MainColors 的 Wrap 无 alignment 参数（末行
  `WrapAlignment.start` 靠左留白）；每个 ColorPicker 外包 `Center`
  保留（无害）。审查核对：ColorPicker Column 默认 `mainAxisSize.max` +
  `crossAxisAlignment.center`，intrinsic 宽的色板 Wrap 已在包内被居中；
  末行仍偏左是包 Wrap 行为，若真机不接受需自绘色板（包外方案，暂留）。
- **切换器去臃肿**：体量问题在高度与 pill 比例而非溢出——
  `LiquidGlassSegmented height 40→32`、组件 `padding 4→5`
  （pill 高 22，与轨道边距 5，比例纤细），底衬 `Padding 6→4`
  （总高 40）；明暗模式分段（60）不动。
- **色码行居中**：`Row(mainAxisAlignment: center)` 保持默认
  `mainAxisSize.max`——`primaryContainer` 圆角条占满宽度，内部
  icon + hex + 复制图标整组水平居中（hex 定长 10 字符无截断风险）。

### 取色器验收修正二（T12，用户验收反馈五）

- **双切换器重复根因**：包内 `_pickers` 对未传入的 `accent` 键
  `?? true` 默认开启（flex_color_picker-3.8.0 color_picker.dart:1534-1537），
  单类型 map 只传一键时实际 count=2 → 包 selector 仍显示。修复：
  三个面板的 `pickersEnabled` map **显式关闭**其余类型
  （primary/accent/wheel 各只开一个），count=1 后包 selector 隐藏。
- **切换器底衬容器**：液态切换器外包 `SettingsRowShell`
  （非霜壳——无 blur/渐变），`fill: scheme.surfaceContainerLow
  α0.45` 派生色 + 圆角 18 + 既有 0.5px 描边语言，内衬 padding 6。
- **色码行派生色**：包内色码背景写死（colorCodeHasColor ? 当前色 :
  黑/白低透明），不可定制——关闭 `showColorCode`，自绘色码行：
  `primaryContainer` 圆角容器 + `onPrimaryContainer` 文字 + 复制
  图标，点按复制 hex（与派生色卡同一 hex 计算逻辑）。

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
- [x] T10: 明暗分段 60 + 开关行 60 统一 — acceptance: 明暗与网格布局容器精确同高、pill 不溢出壳（落地+审查 PASS：(60−8)+6=58≤60） (covers: S2 T10/T11)
- [x] T11: 取色器液态玻璃切换器 + 派生色细节 — acceptance: 三段切换为 LiquidGlassSegmented；分段/色码均派生色；IndexedStack 切换不丢状态（落地+审查 PASS） (covers: S2 T10/T11)
- [x] T12: 双切换器去重 + 切换器底衬 + 色码行 primaryContainer — acceptance: 对话框仅一个切换器；切换器有派生色底衬（非霜壳）；色码行 primaryContainer（落地+审查 PASS） (covers: S2 取色器验收修正二)
- [x] T13: 面板居中 + 切换器瘦身 + 色码行居中 — acceptance: 色板/色轮面板内容水平居中（包内 Column crossAlignment 支撑；末行靠左为包 Wrap 行为待真机）；切换器总高 40 且 pill 纤细；色码行整组居中（落地+审查 PASS） (covers: S2 取色器验收修正三)
- [x] T14: pill 饱满 + 恢复鼓动 + 色码条收缩居中 — acceptance: pill 28 饱满；切换有液态鼓动且不溢出（峰值 34<36）；色码条紧凑贴内容整体居中（落地+审查 PASS；grow 期接触影可能被壳边轻微裁切待真机） (covers: S2 取色器验收修正四)
- [x] T15: 目标台账 + 明暗 pill 比例/选中色派生化 — acceptance: 台账 docs/compose/appearance-goals-log.md 落库；明暗 pill 46/60 比例与取色器一致；两处切换器选中态 primaryContainer/onPrimaryContainer（落地+审查 PASS；shadow cornerRadius 已按 pillH/2 派生） (covers: S2 目标台账与明暗选中态派生化)
- [x] T16: pill 静止态 restStyle 派生色 + 明暗 padding 10 — acceptance: 动画回落静止选中态为 primaryContainer 派生色（不再被白色 rest pill 取代）；明暗 pill 40/60 按钮感（落地+审查 PASS：双层交接无叠色，lgMotionOn=false 时 restStyle 为唯一指示同样必要） (covers: S2 选中 pill 静止态派生色)
- [ ] T4: analyze + test + 审查 + 真机验收 — acceptance: analyze 无新增告警（已达成）；各轮审查 PASS（已达成）；真机确认（待用户执行） (covers: S1 全部)
