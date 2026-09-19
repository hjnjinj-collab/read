---
feature: appearance-seed-source
status: delivered
updated: 2026-09-19
branch: master
commits: 6c977f1..27f1500
---

# 外观页主题色来源互斥与视觉精修

## Report

**What was built** — 外观页「主题」容器建立主题色来源互斥模型：`ShellSettings`
新增 `seedSource`（preset/palette/picker）持久化字段，旧数据按色值命中调色板
推断迁移；`effectiveSeedSource` 在动态取色开启时无条件返回 `dynamic`。
预置 chips / 调色板 / 自定义取色按钮三组按来源互斥降权（Opacity 0.38），
置灰组保持可点击，点击即经 `applySeed` 单次持久化完成「关动态取色 + 设色 +
记来源」。预置色改官方 MD3 `ChoiceChip`（色点 + checkmark）；分隔线改
1dp + primary α0.18；主题容器首行距顶垫至 14px。

**Verification** — `flutter analyze`：0 error，25 issue 全部为 reader/test
目录既有问题（PRE-EXISTING），本次四个改动文件零告警；独立审查（子代理）
三项结论 Spec compliance / Correctness / Codebase consistency 全 PASS，
无 critical。真机视觉验收由用户执行中（T5 未勾）。

**Journey log** —
- reserveSwellRoom 布局占位陷阱已沉淀为工程约束第 10 条（见
  docs/bugfixes/2026-09-19 报告），本轮开关对齐是同一排查脉络的收尾。
- `applySeed` 去重以「值相等」为准：动态取色关闭 + seedArgb 为 null 时
  首点默认松绿会触发一次无害显式写入（视觉无变化），不做 null 特判。
- SettingsDivider 当前仅外观页 3 处使用；组件在共享库 settings_chrome.dart，
  其他设置页后续采用即继承新样式。

## [S1] Problem

外观页「主题」容器存在四类问题：

1. 容器首行「主题色」标签距壳体顶部仅 ~4px，视觉上有溢出感。
2. 分隔线用中性色（outlineVariant α0.60 / 0.8dp），不符合 MD3「分隔线用强调色
   或其派生色」的方向，厚度也非标准 1dp。
3. 预置主题色用自绘 `_SeedChip`，选中态缺少 MD3 标准语言（checkmark、状态层）。
4. 预置色 / 调色板 / 自定义取色 / 动态取色四种来源可同时"看起来生效"——
   chips、色板高亮、取色按钮各自为政，用户无法分辨当前主题色来自哪里。

## [S2] Design

### 主题色来源模型（provider）

- `ShellSettings` 新增 `seedSource: String` 字段，取值
  `preset | palette | picker`，默认 `preset`，随 `encode()`/`tryParse()` 持久化。
- 旧数据迁移推断（`tryParse`，无 `seedSource` 键时）：
  `seedArgb == null` → `preset`；`seedArgb` 命中 16 色调色板 → `palette`；
  否则 → `picker`。调色板色表从 `_ColorPalette._palette` 提取为
  `AppTheme.palettePresets`（core/theme/app_theme.dart），UI 与迁移共用。
- `effectiveSeedSource` getter：`dynamicColor ? 'dynamic' : seedSource`。
  动态取色开启时无条件覆盖其余来源。
- `ShellSettingsNotifier.applySeed(Color color, {required String source})`：
  单次 `_persist` 内同时「关闭 dynamicColor（若开）+ 写 seedArgb + 写
  seedSource」。替换原 `setSeed` 在外观页的三处调用；`setSeed` 删除
  （全仓仅外观页使用）。点击任何置灰项 = 直接 `applySeed`，自动让位，
  单步切换（用户已确认）。

### 互斥置灰（UI）

同一时刻恰有一组处于「生效」视觉态，其余三组以 **Opacity 0.38**
（MD3 disabled 标准）降权显示，**保持可点击**：

| 生效来源 | 预置 chips | 调色板 | 自定义取色按钮 | 动态取色开关 |
|---|---|---|---|---|
| dynamic | 0.38 | 0.38 | 0.38 | 开 |
| preset | 正常+选中 | 0.38 | 0.38 | 关 |
| palette | 0.38 | 正常+选中 | 0.38 | 关 |
| picker | 0.38 | 0.38 | 正常+强调边框 | 关 |

- chips 选中判定：`activeSource == 'preset' && (seedArgb ?? AppTheme.seed) == p.color`。
- 色板选中判定：`activeSource == 'palette' && seedArgb == c.toARGB32()`。
- 取色按钮选中：`activeSource == 'picker'`，边框改 `scheme.primary`。
- 动态取色开关行永远可交互，不参与降权。

### MD3 ChoiceChip

`_SeedChip` 删除，预置色改用官方 `ChoiceChip`：`avatar` 色点（16px 圆 +
细白描边）+ `label` 文字，`showCheckmark: true`（MD3 标准选中语言），
形状 `StadiumBorder`，选中态用 MD3 默认配色。`_EvenWrap` 的
`rowCount` 参数删除（调用处从不传，分析器 warning），固定 3 列 spaceBetween。

### 分隔线（全局组件）

`SettingsDivider`：`thickness 0.8 → 1`，颜色
`scheme.outlineVariant.withValues(alpha: 0.60)` →
`scheme.primary.withValues(alpha: 0.18)`（强调色派生，玻璃壳上呈淡品牌色
发丝线）。组件位于共享库 settings_chrome.dart，当前仅外观页 3 处使用，
其他设置页后续采用即继承。

### 主题容器顶部间距

外观页「主题」容器 Column 首插入 `SizedBox(height: 10)`：
首行标签实际距顶 4(SettingIconLabel) + 10 = 14px，消除贴顶溢出感。
其余容器不动。

## [S3] Out of Scope

- 动态取色副标题换行挤压开关的问题（后续单独处理）。
- 明暗模式 / 书架布局容器的内边距（用户未反馈问题）。
- `SettingIconLabel` 组件本体的 padding（多处共用，避免波及）。
- Windows 动态取色行为本身（API 不可用，仅开关状态展示）。

## Tasks

- [x] T1: provider 加 seedSource 字段 + 迁移推断 + applySeed + 删 setSeed；palette 表提取到 AppTheme — acceptance: analyze 无新增告警；旧持久化 JSON 可正常解析出合理来源 (covers: S2 来源模型)
- [x] T2: 主题容器顶部间距 + 预置色改 ChoiceChip + _EvenWrap 清理 rowCount — acceptance: 首行距顶 ~14px；chips 呈现 MD3 选中 checkmark；warning 消除 (covers: S2 ChoiceChip / 顶部间距)
- [x] T3: 四来源互斥置灰接入（Opacity 0.38 + 选中判定矩阵 + applySeed 调用） — acceptance: 任一时刻仅一组全亮；点击置灰组立即切换来源并关闭动态取色 (covers: S2 互斥置灰)
- [x] T4: SettingsDivider 1dp + primary α0.18 — acceptance: 外观页与其他设置页分隔线统一为淡强调色 1dp (covers: S2 分隔线)
- [ ] T5: flutter analyze + 全页真机验收 — acceptance: analyze 无 error、无新增 warning（已达成）；用户真机确认四项视觉与交互（待执行） (covers: S1 全部)
