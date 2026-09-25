---
feature: reader-menu-chrome-ia
status: in-progress
updated: 2026-09-23
branch: master
commits: c84cfa2..uncommitted
---

# 阅读菜单 Chrome · 双套布局（草稿）

> **本轮只出草稿**，不实现。对标：`D:\android\example\legado-with-MD3`
> （`ReadBookMenuBar*` / `SystemMenuPage` / `ReadMenuConfig`）。
> 真机截图对照：传统 MD3 底栏设置（字号/翻页方式/速度 + 工具图标排）。

## Report

**Journey log 补** — 真机模糊泄露：阅读 chrome 多枚 `LiquidGlassTabBarAction` 叠 BF 必漏；圆键改无 Lens 玻璃观感，模糊只留上下 `ReaderBlurVeil` 各一层。

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

**材质总则（真机对标）**：顶栏圆键、悬浮圆键、底栏工具键、进度两侧箭头键 —— **全部液态玻璃**（浅色玻璃球 + 内高光 + 轻描边，叠在正文/毛玻璃上）。打开的 sheet/面板也带玻璃感（毛玻璃底 + 玻璃控件），不是纯白 MD 卡。关闭「液态」时才落 tonal 实底。正文仍永不玻璃化。

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
| 液态玻璃 | **默认开**：每键玻璃球（对标截图浮在正文上的圆键）；关则 tonal 圆键 |
| 溢出 | 第 6 个起进「更多」圆键（`…`）→ `RoundDropdownMenu` |
| 不与正文抢手势 | 外层 opaque Listener（壳底栏同款） |

### [S2.3] 顶栏（两套共用，草稿只定契约）

| 项 | 契约 |
|----|------|
| 默认 | 返回 · 书名居中 · 页码/章号 · 翻译 · 更多 `…` ·（日夜可并入更多） |
| 按钮材质 | **液态玻璃圆键**（对标顶栏 ← / 翻译 / ⋯） |
| 模糊 | None / 渐变模糊（我方 `TopScrollBlurChrome` 语言） |
| 可选 | 标题胶囊；「合并按钮」进一个胶囊 |

### [S2.4] 设置面（菜单「外观」草稿结构）

对标 `SystemMenuPage` + `TypographyPage`（Typography / Information / Padding）。我方草稿收敛为**三页**。**打开层**毛玻璃 + 玻璃控件。

1. **形态与图标** — 传统/悬浮；图标风格三档；每行个数；行数；显示文字；图标排序（可拖）；恢复默认
2. **排版布局**（对标 Typography）— 子页签：
   - **正文**：字体、字号、行距、段距、字距、文字色/强调色
   - **标题**：标题字体、标题上边距、标题上下留白、标题色
   - **页眉/页脚**：显隐、字体、分隔线、颜色（信息条）
   - **边距**：正文/页眉/页脚 上·下·左·右 padding（对标 `TypographyMarginTab`）
3. **背景主题**（对标 `BgTextConfigSheet` / `GlobalThemePage`）— 样式名与动作（重命名/删除/恢复/导入/导出）；深色状态栏图标；**背景色**（日间/夜间双色）；**背景图**（日间/夜间，可清）+ **内置背景图网格**（羊皮纸/亚麻/宣纸/夜空等预览格 + 自定义图片）；**背景透明度**；预设主题卡
4. **材质与顶栏** — 面板圆角/模糊档；悬浮键液态开关（默认开）；合并顶栏按钮；标题胶囊

**字体选择 sheet**（对标 `FontSelectSheet` / `FontSelectGrid`）— 从「排版布局 · 正文/标题/页眉/页脚 · 字体」进入二级层：系统字体菜单；打开字体文件夹；字体文件**网格**（名/大小/时间排序）；当前选中高亮；空态提示选文件夹。

本轮不实现任何控件，只冻结信息架构。

### [S2.5] 功能流（预置，点击入口）

| 入口 | 打开物 | 契约 |
|------|--------|------|
| **目录** | 章节列表 sheet（左或底） | 当前章高亮；点章关闭并跳转；搜索章名过滤 |
| **搜索** | 正文搜索 sheet | 输入 → 结果列表（章·片段）；点结果跳转并高亮 |
| **书签** | 书签列表 sheet | 列表 + 本章添加/删除 |
| **笔记** | 笔记/高亮列表 sheet | 筛选本章/全书；点条目跳转 |
| **设置** | 双页设置 sheet | ①形态与图标 ②材质与顶栏（见 S2.4） |
| 更多 `…` | 溢出动作菜单 | 上/下章、自动翻页、朗读…（后续接线） |

传统底栏 A：上述入口在工具排；设置也可从面板内「外观」进入同一 sheet。  
悬浮 B：圆键直接进 sheet；菜单形态开关在设置①。

可视化：`docs/design/reader-menu-chrome-proto.html` 可点 HTML 原型（双套切换 + 目录/搜索/设置流），作设计沟通用，非产品代码。

### [S2.6] 与既有约束对齐

- 玻璃只属 chrome；**正文永不玻璃化**
- Impeller：单 Lens；液态与 BackdropFilter 禁止叠挂
- 减弱动态：无液态、无模糊动画；A/B 均实底；布局瞬时切换
- 尺寸与壳底栏同语言：触达 ≥44，字面 11–12

### [S2.7] 模糊垫与防泄露（真机反馈）

| 契约 | 取值 |
|------|------|
| 圆键材质 | **保持液态玻璃**（`LiquidGlassTabBarAction`）；禁止改成纯观感假玻璃 |
| 防泄露 | **ClipOval 裁切** Lens/模糊到圆内；不是去掉液态 |
| 顶栏垫 | 菜单态：顶→底渐变模糊；阅读中：轻量无 BF 渐变（防常驻 BF 拖死开书） |
| 底栏垫 | 菜单态：**底→顶**渐变模糊（壳滤镜镜像） |
| BF 数量 | 垫各一层；圆键 Lens 由 ClipOval 收束 |

### [S2.8] 图标三档 + 液态果冻动效（本轮细化）

**图标**（`ReaderMenuIcons` / `ReaderMenuGlyph`，Iconsax 族，不混 Material）：

| 档 | `readerIconStyle` | 渲染 |
|----|-------------------|------|
| 线性 | 0 | outline 字形 |
| 面性（默认） | 1 | `_copy` 填充字形 |
| 双色 | 2 | 填充垫 primary@0.38 + 线性主字叠色 |

覆盖：顶栏返回/更多、工具排目录/搜索/书签/笔记/设置/更多、字号 ±、悬浮圆键。设置①「图标风格」三档切换即时生效（持久化 `readerIconStyle`）。

**动效（液态果冻风）**：

| 交互 | 契约 |
|------|------|
| 菜单开合 | 顶 `AnimatedSlide` 上/下 260ms、底 280ms；`easeOutBack` 回弹；**禁止 Fade/Opacity 包 LiquidGlass** |
| A/B 形态切换 | `AnimatedSwitcher` 240ms；仅 `ScaleTransition`+`SlideTransition`（Transform） |
| 按压果冻 | `lgMotionOn` → `LiquidGlassFlex.pronounced()`；关 → `subtle()` |
| 减弱动态 | duration=0、无液态形变；布局瞬时（S2.6） |
| 图标色 | 与壳层液态圆键同源：选中 `primary` / 未选 `onSurfaceVariant`；双色垫 `tertiary` |
| 开合雾垫 | `ReaderMenuFog` **固定贴边**、不随 slide 平移（防弹出时顶/底空白） |
| 工具排 | **5 项**（目录/搜索/书签/笔记/设置）；设置齿轮即更多，无第 6 溢出键 |

## [S3] Out of Scope

- 本轮**零实现**（仅草稿）
- 自定义图标上传 / 云同步
- 朗读、自动翻页、AI 等动作接线
- 顶栏合并按钮的最终视觉
- 点击分区/手势设置（另稿）

## Tasks（三阶段实施计划）

### Phase 1：菜单完善

- [x] T0: 外层壳子 — 顶栏液态圆键 + A 传统底板 + B 悬浮工具球排 (covers: S2.1,S2.2)
- [x] T1.1: 形态持久化：`_chromeMode` 写入 ShellSettings，重进阅读记住上次形态 — acceptance: 切换→退出→重进，形态不变 (covers: S2.1)
- [x] T1.2: 传统底栏工具排对齐 IA：5 均分、glyph 22–24、label 11–12 — acceptance: 与设置页图标排视觉一致 (covers: S2.2A)
- [ ] T1.3: 悬浮模式圆键排完善：间距 8、居中对齐、第 6 个进「更多」 — acceptance: ≥6 动作收纳进溢出菜单 (covers: S2.2B)

### Phase 2：设置四页

- [x] T2.1: 形态与图标页：传统/悬浮切换、图标风格三档、每行个数、行数 — acceptance: 改后两套 chrome 同步生效 (covers: S2.4; depends: T1.1)
- [x] T2.1a: Iconsax 图标三档（线性/面性/双色）+ `readerIconStyle` 持久化 — acceptance: 设置①切换后工具排/圆键/顶栏字形同步 (covers: S2.8)
- [x] T2.1b: 液态果冻动效：菜单 Slide 开合 + A/B Scale 切换 + pronounced 按压 — acceptance: 开合有回弹；无 Fade 包玻璃；减弱动态瞬时 (covers: S2.8)
- [x] T2.2: 排版布局页：字体/字号/行距/段距/字距 + 标题 + 页眉页脚 + 边距 — acceptance: 参数持久化，正文实时刷新 (covers: S2.4)
- [x] T2.3: 背景主题页：日夜背景色/图/透明度 + 内置背景图网格 + 预设主题卡 — acceptance: 背景切换即时生效 (covers: S2.4)
- [x] T2.4: 材质与顶栏页：面板圆角/模糊档、悬浮键液态开关、合并顶栏按钮 — acceptance: 材质参数与设置页同源 (covers: S2.4)
- [ ] T2.5: 字体选择 sheet：系统字体 + 字体文件夹 + 文件网格 + 选中高亮 — acceptance: 选字体后正文实时刷新 (covers: S2.4)

### Phase 3：验证与收尾

- [ ] T3.1: 全量 flutter analyze — acceptance: 零新增 error (covers: S2.6)
- [ ] T3.2: Windows + 手机真机验证 — acceptance: 无缩放、无阴影、交互流畅 (covers: S2.6,S2.7)
- [ ] T3.3: 更新 progress-summary + spec 收口 + 提交推送 — acceptance: 文档与代码同步 (covers: S2)
