---
feature: glass-settings-progressive-disclosure
status: delivered
updated: 2026-09-19
branch: master
commits: 515d8fb..HEAD
---

# 材质与玻璃：条件展开（Progressive Disclosure）

## Report

**What was built** — 「材质与玻璃」页改为条件展开：新增 `SettingDependents`（widgets 库 `Expansible` + `ExpansibleController`），header 常显、body 随父开关/档位自动 expand/collapse。页面色渗（`pageTintOn`）、页底渐变（`ambientOn`）、设置页霜层（`frostOn`）三组细调项仅在对应开关打开时展开；果冻效应迁入「模式」组，门控为 `!Platform.isWindows && glassMode == 'liquid'`（与 `applyGlassEngine` 的 forceLite 对齐）。持久化字段与 setter 未改。关闭态 header subtitle 显示「已关闭」摘要。

**Verification** — `flutter analyze`：25 issues，全部 PRE-EXISTING（reader/test）；两变更文件 No issues；`flutter test test/app_theme_flex_scheme_test.dart`：2 PASS。评审 Spec/Consistency PASS；Critical（Windows 果冻门控未并入 forced）已修并复审 CRITICAL resolved。

**Journey log** —
- Flutter 新 API 记忆点：`Expansible`/`ExpansibleController`（widgets），非 `ExpansionTile` 整壳
- 引擎 `forceLite = liteGlass || Platform.isWindows` 与 UI 门控必须同语义，否则 Windows 默认 liquid 会误展开果冻
- Expansible 折叠靠 ClipRect heightFactor + Offstage，液态控件仍依赖自身 ClipRRect+bevel 层序
- S2 门控表权威优先于 ASCII 示意（示意曾漏 Windows 条件）
- hub 页 glassMode 摘要未反映 Windows 强制（展示层瑕疵，本轮 Out of Scope）

## [S1] Problem

「材质与玻璃」页把 **主模式开关** 与 **依赖该模式的细调项** 全部平铺：

- 渲染材质（liquid / lite）只有档位选择，却与后续所有视觉项无层级关系；
- 设置页霜层：`frostOn` 关闭时，方案 / 方向 / 子栏高度 / 渐变深浅 / 起终点色仍全部可见；
- 页面色渗：`pageTintOn` 关闭时，浅色底 / 深色底滑杆仍占位；
- 页底渐变：`ambientOn` 关闭时，方向分段仍占位。

结果是滚动很长、有效项密度低，用户难以判断「当前哪些设置真的在生效」。

## [S2] Design

### 组件契约（Flutter 新 API）

用户记忆中的「新组件特性」对应 Flutter widgets 库：

| API | 用途 |
|-----|------|
| `Expansible` | header 常显 + body 折叠/展开（高度动画） |
| `ExpansibleController` | `expand` / `collapse` / `isExpanded` / `toggle` |
| `ExpansibleController.of/maybeOf` | 从 context 取控制器 |

**不用** Material `ExpansionTile` 整壳：自带 ListTile + 箭头，会破坏液态设置语言。

本项目落地封装 `SettingDependents`（`settings_chrome.dart`）：

- `enabled`：true → expand；false → collapse
- `header`：始终渲染（开关/分段 + subtitle 摘要）
- `children`：依赖项列表
- `maintainState: true`（默认）：折叠后保留 body 状态
- `initState` / `didUpdateWidget` 同步 controller（勿在 build 内 expand/collapse）

行为：

1. `didUpdateWidget`：`enabled` true → `controller.expand()`；false → `controller.collapse()`。
2. 初始：按当前 `enabled` 设 `ExpansibleController` 状态。
3. 动画：高度 clip；禁止 BoxShadow；子项沿用 Liquid 滑杆/分段/开关。
4. 关闭态：header subtitle 写明「已关闭」或当前档位摘要。

### 页面布局蓝图（交付态）

```
材质与玻璃
│
├─ [模式]
│  渲染材质  [液态玻璃 | 毛玻璃]          ← 始终可见
│  └─ SettingDependents(enabled: !Windows && glassMode=='liquid')
│     果冻效应 switch                     ← 与引擎 forceLite 对齐
│
├─ [底栏]
│  模糊 slider / 色渗滤镜 slider          ← 始终可见（无二级门控）
│
├─ [页面色渗]
│  均匀渗入 switch                       ← header
│  └─ SettingDependents(enabled: pageTintOn)
│     浅色底 slider / 深色底 slider
│
├─ [页底渐变]
│  氛围渐变 switch                       ← header
│  └─ SettingDependents(enabled: ambientOn)
│     方向 [四向 glyph 分段]
│
├─ [设置页霜层]
│  垫底霜层 switch                       ← header
│  └─ SettingDependents(enabled: frostOn)
│     方案 / 方向 / 行缝 / 子栏高度 / 渐变深浅 / 起终点色
│
└─ [说明]
   帮助文案（果冻指向「模式 · 液态玻璃」且非 Windows 强制）
```

### 门控语义（与状态字段对齐）— 权威表

| 门控字段 | 展开内容 | 折叠时 header subtitle |
|----------|----------|------------------------|
| `!Platform.isWindows && shell.glassMode == 'liquid'`（与 `applyGlassEngine` forceLite 对齐） | 果冻效应 `lgMotionOn` | 档位说明；lite / Windows 强制不展示果冻 |
| `shell.pageTintOn` | 浅色底 / 深色底滑杆 | 「已关闭」 |
| `shell.ambientOn` | 方向分段 | 「已关闭」 |
| `shell.frostOn` | 方案/方向/行缝/高度/深浅/双色 | 「已关闭：子栏仅轻透填色 + 阴影」 |

持久化字段与 setter **不变**；仅 UI 可见性变化。

### 视觉与工程约束

- `_FrostSection` + `SettingsFrostGate` 分组壳体语义不变
- 展开区控件仍走 `_LiquidValueSegmented` / `LiquidGlassSlider` / `SettingSwitchRow`
- 禁止：BoxShadow 黑影、ExpansionTile 默认箭头皮

## [S3] Out of Scope

- 外观页 / 设置根页 / 底栏本体参数重构
- `shell_settings.dart` 持久化 schema、新设置字段
- lite 时隐藏整个「设置页霜层」（霜层与 Lens 模式正交，独立门控 `frostOn`）
- 非本页设置页的 disclosure 接入
- settings hub 页 glassMode 摘要显示 Windows 强制

## Tasks

- [x] T1: `SettingDependents` 封装（Expansible + Controller 自动门控）— acceptance: 开关 true/false 时 body 展开/折叠；折叠不占高；build 内不调 controller (covers: S2)
- [x] T2: 页面色渗 / 页底渐变 / 设置页霜层 三组接入门控 — acceptance: switch 关闭后细调项不占高；打开后完整可调 (covers: S2; depends: T1)
- [x] T3: 果冻效应 liquid+非 Windows 门控 — acceptance: 非 Windows 且 liquid 可见；lite/Windows 折叠；说明组不重复 (covers: S2; depends: T1)
- [x] T4: 关闭态 subtitle 摘要与文案 — acceptance: 与 S2 门控表一致 (covers: S2; depends: T2)
- [x] T5: 验证 — acceptance: analyze 相对基线无新增；主题测试 PASS (covers: S2; depends: T2, T3)
