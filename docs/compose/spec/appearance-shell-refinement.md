---
feature: appearance-shell-refinement
status: delivered
updated: 2026-09-19
branch: master
commits: d4560f2..cdf94df
---

# 外观页壳体间距统一 + flex_color_scheme 全局主题引擎

## Report

**What was built** — 全局主题引擎替换：`AppTheme.light/dark` 改由
`FlexColorScheme` 生成 `ColorScheme`（`FlexKeyColors()` 单 seed 派生，
默认 `FlexTones.material` 与 `ColorScheme.fromSeed` 同源，补全
surfaceContainer 系列角色；dark 传 `primaryLightRef` 消除 fixed 色
警告），`_base` 全部玻璃自定义与 pageTint 色渗保留。依赖锁
`flex_color_scheme ^8.2.0`（8.4.0）。外观页四边间距统一：标签行水平
16px、开关行垂直 8px、明暗分段垫 10px、首行保持距顶 14px；动态取色行
纳入来源互斥（Opacity 0.38，可点）。

**Verification** — `flutter analyze`：25 issue 全部 PRE-EXISTING
（reader/test 目录），改动文件零新增；`flutter test
test/app_theme_flex_scheme_test.dart`：2 PASS、无 flex 警告；独立审查
三项 PASS、无 critical（fromSeed 等价性经包文档逐层核对，
Opacity 不阻断命中测试，glass 页 4 处开关行无间距叠加问题）。
真机视觉验收由用户执行中（T4 部分）。

**Journey log** —
- **flex_color_scheme v9 不可用于 framework 项目**：v9 整体迁移到作者
  自研 material_ui 包，`toScheme` 返回 material_ui.ColorScheme 与
  framework 同名类型分叉（仅留 deprecated 的 widget 桥，需
  flutter_localizations）。锁 8.x + pubspec 注释 + 冒烟测试三重防护。
  选型大版本升级前先查类型体系是否仍指向 flutter/material。
- **dart format 全文件重排会污染最小 diff**：本轮先 format 后 diff 达
  347+/325-，checkout 后按语义重做收敛到 32+/15-。本仓库无全量 format
  惯例，后续改动保持各文件既有缩进风格，不做顺手 format。
- 审查子代理 bash 被权限拦截时，以终点文件状态逐条核对并如实声明
  "diff 未过目"——该报告仍逐层核实了 flex_seed_scheme 的 fromSeed
  等价性链路，主代理抽验行号成立，采信结论。
- reserveSwellRoom 布局占位陷阱已沉淀为 BUGFIX_INDEX 工程约束第 10 条
  （上一轮），本轮互斥矩阵新增第四区块（动态取色行）即在其上叠加。

## [S1] Problem

1. 外观页三个霜壳容器的四边间距不成节奏：「主题色」等标签行水平仅 4px
   （内容为 16px 网格）直接贴边；动态取色副标题两行后距壳底仅 4px；
   明暗模式分段上下无垫高——整体不精致。
2. 主题色生成用 `ColorScheme.fromSeed`，MD3 色彩角色派生不完整
   （surfaceContainer 系列等），用户要求引入 flex_color_scheme 作为
   全局主题引擎（用户已确认仅替换引擎，不接包内取色器/预览组件）。
3. 动态取色行未参与互斥置灰：其他来源生效时它仍全亮，违反
   「任何时候只有一种主题色生效，其他方式置灰」（上一轮 spec 有意排除，
   用户本轮明确要求纳入）。

## [S2] Design

### flex_color_scheme 全局主题引擎（T1）

- `pubspec.yaml` 增加 `flex_color_scheme`（最新 stable）。
- `AppTheme.light/dark` 内部改为 `FlexColorScheme` 生成 `ColorScheme`：
  `seedColor = dynamicSeed ?? seedOverride ?? AppTheme.seed`，
  tonal 蓝图用包内 M3 标准（FlexTone material 路径，与 `ColorScheme.fromSeed`
  行为同源但角色派生更完整），`useMaterial3` 保持 true。
- `_base(scheme, pageTint)` 的全部自定义（pageSurface 色渗、InkSparkle、
  appBar/系统 UI 样式等）原样保留——引擎替换只发生在 scheme 生成层，
  组件主题层不动，玻璃风格零波及。
- `main.dart` 调用签名不变（dynamicSeed/seedOverride/pageTint 透传）。

### 壳体间距节奏（T2）

统一规则：水平内容网格 16px；垂直呼吸 8/10/14 按内容自带空隙微调，
不追求像素等值、追求贴边感消除：

- `SettingIconLabel`：`fromLTRB(4,4,4,4)` → `fromLTRB(16,6,16,6)`
  （组件仅外观页 3 处使用，直接改本体；标签与内容左对齐）。
- `SettingSwitchRow`：`vertical 4 → 8`（外观页 2 处 + glass 设置页 4 处
  统一生效；动态取色两行副标题后底部约 8+ 行高空隙，书架布局行同步获得
  呼吸感）。
- 主题容器首行垫高 `SizedBox(height: 10)` → `8`（8 + label 6 = 14 距顶，
  维持上轮确定的 14）。
- 明暗模式容器：`LiquidGlassSegmented` 外包 `Padding(vertical: 10)`，
  上下垫高与开关行节奏一致。

### 动态取色行纳入互斥（T3)

外观页动态取色 `SettingSwitchRow` 包 `Opacity(activeSource == 'dynamic' ? 1 : 0.38)`：
关闭且其他来源生效时整行降权，开关保持可点（点开即切到 dynamic 来源）。
开启时全亮。与上一轮矩阵合并后：四个区块（chips/色板/取色按钮/动态取色行）
任意时刻恰有一个全亮。

## [S3] Out of Scope

- FlexColorPicker / 派生色预览卡（用户明确不接入）。
- 动态取色副标题文案（用户确认保留两行原文案）。
- glass_settings_page 的其他布局问题（仅被动接受 SettingSwitchRow 的
  垂直间距统一）。
- FlexColorScheme 的 subThemes（组件主题层维持项目自定义）。

## Tasks

- [x] T1: 引入 flex_color_scheme，AppTheme.light/dark 改由 FlexColorScheme 生成 scheme — acceptance: analyze 通过；全应用色彩由新引擎派生，深浅色均正常（analyze PASS + 冒烟测试 2 PASS；视觉待真机） (covers: S2 引擎)
- [x] T2: 间距统一（SettingIconLabel/SettingSwitchRow/首垫/明暗垫高） — acceptance: 外观页三容器四边无贴边感，标签与内容左对齐 16px（代码落地+审查核对，视觉待真机） (covers: S2 间距)
- [x] T3: 动态取色行纳入互斥置灰 — acceptance: 非当前来源时整行 0.38 且开关可点（落地+审查核对） (covers: S2 互斥)
- [ ] T4: flutter analyze + 独立审查 + 用户真机验收 — acceptance: analyze 无新增告警（已达成）；审查 PASS（已达成）；真机确认（待用户执行） (covers: S1 全部)
