---
feature: reader-menu-chrome-ia
status: designed
updated: 2026-09-20
branch: master
commits: 2b187d0..HEAD
---

# 阅读菜单 Chrome · 双套布局（草稿）

> **本轮只出草稿**，不实现。对标：`D:\android\example\legado-with-MD3`
> （`ReadBookMenuBar*` / `SystemMenuPage` / `ReadMenuConfig`）。
> 真机截图对照：传统 MD3 底栏设置（字号/翻页方式/速度 + 工具图标排）。

## Report

## [S1] Problem

我方阅读菜单目前只有**一套** MD3 底栏（`reader_menu.dart`：标题条 + 进度/字号/翻页 + 固定工具排）。对标应用提供**两套 chrome**：

1. **传统底栏**（`readMenuFloatingBottomBar=false`）— 整宽设置面：进度、字号、翻页方式/速度、工具图标网格；顶栏/底栏可选 Haze / Solid / Progressive 模糊。
2. **悬浮图标**（`true`）— 与我方液态玻璃同语言：圆形/胶囊图标行（可液态玻璃按钮），设置进 sheet；顶栏可合并按钮 / 标题胶囊。

需要把「双套 + 图标可配」的**布局契约**定死，再实现。

## [S2] Design（草稿契约）

### [S2.1] 双套 Chrome 总览

| | A. 传统底栏 | B. 悬浮图标 |
|--|-------------|-------------|
| 形态 | 底部整宽面板（贴底或圆角浮起） | 一排（可多行）独立圆键/胶囊，悬浮在正文上 |
| 设置内容 | **内嵌**在面板内（滑杆/步进/chip） | **外置** sheet（对标 `ReadStyleSheet` / `TypographyPage`） |
| 工具入口 | 面板底部图标网格/排 | 同一排上的图标；溢出进「更多」 |
| 模糊 | 面板整体 Haze/Solid/Progressive | 每键可选 LiquidGlass（对标 `readMenuFloatingIconLiquidGlass`） |
| 默认 | 我方现状对齐此套 | 对标默认 `true`；我方草稿默认 **A**，B 为可选 |

切换开关：阅读设置「菜单形态：传统底栏 | 悬浮图标」（对标 `FloatingBottomBar`）。

### [S2.2] 图标布局 — 重点

#### 动作字典（两套共用 id，对标 `readMenuButtonInfos` / `ReadBookButtonIds`）

| id | 中文 | 我方现状 | 备注 |
|----|------|----------|------|
| catalog | 目录 | ✓ Chapters | |
| search | 搜索 | ✓ | |
| addBookmark | 书签 | ✓ Bookmarks | |
| note / highlight | 笔记 | ✓ | |
| setting | 设置 | ✓ | 传统=内嵌区；悬浮=进 sheet |
| theme | 日夜 | 顶栏 ✓ | 悬浮可进排 |
| prev/next_chapter | 上/下章 | 对标有 | 草稿可进「更多」 |
| auto_page | 自动翻页 | 对标有 | 后续 |
| read_aloud | 朗读 | 对标有 | 后续 |
| more | 更多 | 溢出收纳 | |

#### A. 传统底栏 — 工具图标排

```text
┌──────────────────────────────────────────┐
│ 章名 ························  [moon] [×] │  ← 顶条（可渐变模糊）
├──────────────────────────────────────────┤
│  [book]  ──────●────────────   1/123     │  ← 进度
│  字号  −   15   +                        │
│  翻页方式  [卷曲] [水波纹] [坍塌]         │
│  翻页速度  [快] [中] [慢]                 │
├──────────────────────────────────────────┤
│  (i)  (i)  (i)  (i)  (i)                 │  ← 工具图标排
│  目录  搜索  书签  笔记  设置             │
└──────────────────────────────────────────┘
```

| 契约 | 取值 |
|------|------|
| 图标几何 | 单元 **≥56×56** 命中；glyph 22–24；label 11–12（可开关 `iconShowText`） |
| 每行个数 | 默认 **5**；可配 4–6（对标 `iconItemsPerRow`） |
| 行数 | 默认 **1**；可配 1–2（对标 `iconRowCount`），超出进「更多」 |
| 对齐 | 整排水平均分（`spaceEvenly`）；两行时 5+ 溢出 |
| 选中/激活 | 主色 glyph + 可选轻底（tonal）；非激活 `onSurfaceVariant` |
| 图标风格 | **三档**（对标 `iconStyle` 0/1/2）：0 线性 / 1 面性（默认）/ 2 双色；与壳层 Iconsax 族对齐，不混 Material |
| 自定义图标 | 后续；草稿预留 id 映射 |

#### B. 悬浮图标 — 圆键行

```text
        正文… 正文… 正文…

   (i)   (i)   (i)   (i)   (i)     ← 悬浮圆键排（居中/可配左|右）
   目录  搜索  书签  笔记  设置
```

| 契约 | 取值 |
|------|------|
| 键形态 | 圆键 **44–48** 直径（自定义图 36 内容 + 外圈）；对标 `ReadMenuGlassButtonSurface` |
| 间距 | 横向 **8**（对标 padding horizontal 4×2） |
| 排 | 默认 1 行；与 A 共用 `iconItemsPerRow` / `iconRowCount` |
| 对齐 | 默认 **居中**；可配 Start / End（对标 `FloatingIconRow.alignment`） |
| 液态玻璃 | 每键可选 LiquidGlass（我方 `LiquidGlassTabBarAction` / segmented 圆键同源）；关闭则 tonal 圆键 |
| 溢出 | 第 6 个起进「更多」圆键（`…`）→ `RoundDropdownMenu` |
| 不与正文抢手势 | 外层 opaque Listener（壳底栏同款） |

### [S2.3] 顶栏（两套共用，草稿只定契约）

| 项 | 契约 |
|----|------|
| 默认 | 返回 · 书名居中 · 页码/章号 · 日夜 · 关闭 |
| 模糊 | None / 渐变模糊（我方 `TopScrollBlurChrome` 语言） |
| 可选 | 标题胶囊；顶栏按钮液态；「合并按钮」进一个胶囊 |

### [S2.4] 设置面（菜单「外观」草稿结构）

对标 `SystemMenuPage` 三 Tab：**全局 | 底栏 | 顶栏**。我方草稿收敛为两页：

1. **形态与图标** — 传统/悬浮；图标风格三档；每行个数；行数；显示文字；图标排序（可拖）；恢复默认
2. **材质与顶栏** — 面板圆角/模糊档；悬浮键液态开关；顶栏模糊/合并

本轮不实现任何控件，只冻结信息架构。

### [S2.5] 与既有约束对齐

- 玻璃只属 chrome；**正文永不玻璃化**
- Impeller：单 Lens；液态与 BackdropFilter 禁止叠挂
- 减弱动态：无液态、无模糊动画；A/B 均实底；布局瞬时切换
- 尺寸与壳底栏同语言：触达 ≥44，字面 11–12

## [S3] Out of Scope

- 本轮**零实现**（仅草稿）
- 自定义图标上传 / 云同步
- 朗读、自动翻页、AI 等动作接线
- 顶栏合并按钮的最终视觉
- 点击分区/手势设置（另稿）

## Tasks（下轮实现时启用）

- [ ] T1: 菜单形态开关 + A 传统底栏工具排（5 均分、字面可关） — acceptance: 切换形态布局即时变；A 排可进 5 动作 (covers: S2.1,S2.2A)
- [ ] T2: B 悬浮圆键排 + 液态开关 + 溢出更多 — acceptance: 与 A 动作 id 对齐；液态/tonal 可切；≥6 收纳 (covers: S2.2B; depends: T1)
- [ ] T3: 图标风格三档 / 每行·行数 — acceptance: 设置改后两套同步生效 (covers: S2.2)
- [ ] T4: 设置面两页 IA 落地 — acceptance: 形态/图标/材质可改且持久化 (covers: S2.4; depends: T1,T2)
- [ ] T5: 验证 + 真机 — acceptance: analyze 无新增；减弱动态/Impeller 约束不破 (covers: S2.5)
