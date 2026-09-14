---
feature: app-shell-bookshelf-ui
status: in-progress
updated: 2026-09-13
branch: master
commits: 
---

# 应用壳 + 书架 UI 重做

## Report

## [S1] Problem

当前应用只有 `main.dart` 内嵌的 `BookshelfPage`（ListView + FAB）和阅读页、关于页。默认 `Colors.blue` M3 毛坯，无导航壳、无书源入口、书架无网格/布局切换。`go_router` 已在 pubspec 却未接入。图标全是老旧 `Icons.*`。需要从零立设计系统：毛玻璃壳、岛屿书封、现代 Flutter 组件、艺术图标。

## [S2] Design

### 设计定位

| 维度 | 决策 |
|------|------|
| 模式 | 书架 expressive-lite；书源/设置 convention |
| 主体 | 中文书阅读器；材料 = 纸、墨、书脊、玻璃 |
| 一句话 | 「纸色底 + 毛玻璃导航 + 岛屿书封 + Iconsax 图标」 |

### 设计原则

1. **阅读优先**：外壳克制，不与阅读页纸色/夜间抢戏
2. **全量 ColorScheme 派生**：禁止 `Colors.blue/.grey` 散落
3. **签名只在书架**：毛玻璃只用于壳层导航，不铺正文
4. **现代 Flutter API 优先**：`go_router` / `NavigationBar` / `SegmentedButton` / `WidgetState` / `Hero` / `MediaQuery.sizeOf`
5. **动效可关**：尊重 `disableAnimations`

### 色彩

| Token | 用途 |
|-------|------|
| seed `#5B6C5A` | 松绿灰，书脊布色 |
| light surface | 近纸白（scheme 派生） |
| dark surface | 近墨黑（scheme 派生） |
| primary | 导航指示、FAB、进度 |
| surfaceContainerHighest | 封面占位、岛底 |
| outlineVariant | 分割 |

- `ThemeMode.system`；动态取色设置项默认 **关**
- 阅读页配色 **不动**

### 字体

- UI：系统字体
- 阅读：既有 ReaderSerif
- 书名：`titleMedium`；进度数字可用 `tabularFigures`

### 布局系统

**间距标度**：4 / 8 / 12 / 16 / 24 / 32（全 UI 只允许这些与 1.5 倍组合）

```
┌─────────────────────────────────────┐
│  大标题区 SliverAppBar.large          │  「书架」/「书源」/「设置」
│  actions: 布局切换 · 更多             │
├─────────────────────────────────────┤
│  内容滚动区（extendBody: true）        │
│  网格: 2/3/4 列 · 封面 2:3 · gap 12  │
│  或列表: 44×66 封面 + 两行文字         │
│  底预留 NavigationBar 高 + 24         │
├─────────────────────────────────────┤
│  毛玻璃 NavigationBar（悬浮）          │  书架 | 书源 | 设置
└─────────────────────────────────────┘
FAB: 导入（书架 Tab），位于 Bar 上方右侧
```

**响应式列数**（宽度）：`<600 → 2`，`600–900 → 3`，`>900 → 4`（平板/桌面）

**岛屿书封卡**（仅网格）：

```
┌──────────────┐
│   封面 2:3    │  ← ClipRRect 顶圆角；缺省渐变+书图标
│   (Hero)     │
├──────────────┤
│ 书名 1–2 行   │  高度固定 40
│ ▓▓▓░░ 进度    │  有进度才显示，高 3
└──────────────┘
elevation: 1 · 底色 surfaceContainerLow · 圆角 12
```

列表模式：常规 ListTile，不做岛。

### 毛玻璃（壳层签名）

| 位置 | 做法 |
|------|------|
| NavigationBar | `ClipRRect` + `BackdropFilter(sigma: 24)` + 半透明 `primaryContainer.withValues(alpha:0.72)` 底；`Scaffold(extendBody: true)` 让网格从 Bar 下穿过 |
| 书架 AppBar | 实底（大标题用 surface），**不**模糊——滚动文字穿过模糊层会糊 |
| 阅读页 | 无玻璃 |

性能：只对导航条做一次 blur；列表滚动不触发额外 filter。`disableAnimations` 或低端可退化为不透明 Bar（`MediaQuery.disableAnimationsOf` 或简单实底回退）。

### 图标（焕新）

引入 **`iconsax_flutter`**（Iconsax，现代多笔画、有艺术感），替换壳层关键图标：

| 用途 | Iconsax（语义名，以包内实际符号为准） |
|------|--------|
| 书架 Tab | `Iconsax.book` / `book_1` |
| 书源 Tab | `Iconsax.cloud` / `cloud_add` |
| 设置 Tab | `Iconsax.setting_2` |
| 导入 | `Iconsax.add` / `document_upload` |
| 布局网格 | `Iconsax.element_3` / `category` |
| 布局列表 | `Iconsax.textalign_left` / `row_vertical` |
| 关于 | `Iconsax.info_circle` |
| 移出 | `Iconsax.trash` |
| 空态书架 | 大号 `Iconsax.book` 或 `document` |

阅读页内旧 `Icons.*` **本期不强制全换**；壳层 + 书架必须 Iconsax。

### Flutter 现代特性清单

| 特性 | 用途 |
|------|------|
| `go_router` `ShellRoute` | 三 Tab 壳，URL 可 `/bookshelf` `/sources` `/settings`；阅读 `/reader` 全屏 |
| `NavigationBar` + `NavigationDestination` | 底栏；选中 indicator 用 primary |
| `SliverAppBar.large` | 各 Tab 大标题 |
| `SegmentedButton<bool>` | 网格/列表切换（比 IconButton 更明确） |
| `WidgetStateProperty` | 主题组件态 |
| `Hero(tag: book.filePath)` | 网格封面 → 阅读页 |
| `MediaQuery.sizeOf` / `paddingOf` | 响应式，避免全量 MediaQuery |
| `CardThemeData` / `ListTileThemeData` | 全局卡片与列表密度 |
| `FloatingActionButton.extended` 或圆形 | 导入；tooltip 无障碍 |
| `ThemeMode` + 可选 `dynamic_color` 走系统 | 设置开关 |

### 路由结构

```
GoRouter
├─ ShellRoute (AppShell + bottom bar)
│  ├─ /bookshelf  BookshelfPage
│  ├─ /sources    BookSourcesPage
│  └─ /settings   SettingsPage
├─ /reader        ReaderPage (fullscreen, no shell)
└─ /about         AboutPage (fullscreen)
```

`main.dart` 启动仍 `BookService.init` 等；`MaterialApp.router`。

### 空态

- 书架：大 Lucide 书图标 + 「书架是空的」+「从文件导入 TXT 或 EPUB」
- 书源：云图标 +「书源准备中」+ 一句说明，无假按钮
- 设置：常规分组列表

### 文件契约

```
lib/core/theme/app_theme.dart
lib/core/theme/app_icons.dart          # Iconsax 映射
lib/core/router/app_router.dart
lib/features/shell/app_shell.dart
lib/features/shell/book_sources_page.dart
lib/features/shell/settings_page.dart
lib/features/shell/providers/shell_settings.dart
lib/features/shell/bookshelf/bookshelf_page.dart
lib/features/shell/bookshelf/book_cover_card.dart  # 含 BookListTile
```

依赖新增：`iconsax_flutter`、`dynamic_color`。

设置 key `shell`：`{ "bookshelfGrid": bool, "dynamicColor": bool }`。

## [S3] Out of Scope

- 在线书源真实接线
- 阅读设置迁 Tab / 阅读页视觉重做
- 应用内强制浅深色
- 书架分组、拖拽排序、手动换封面
- 全局毛玻璃、正文模糊
- iOS/ Web 专项

## Tasks

- [x] T1: 依赖 iconsax + `app_theme.dart` 全量 scheme 明暗 — acceptance: 无裸 `Colors.blue`；analyze 过 (covers: S2)
- [x] T2: `app_router.dart` ShellRoute 三 Tab + 全屏阅读/关于 — acceptance: 路由可切换；阅读页无底栏 (covers: S2; depends: T1)
- [x] T3: AppShell 毛玻璃 NavigationBar + extendBody — acceptance: 内容从 Bar 下穿过且可读；回退实底可用 (covers: S2; depends: T2)
- [x] T4: 布局偏好落库 + SegmentedButton — acceptance: grid/list 重启保持 (covers: S2)
- [x] T5: 书架岛屿网格（响应式 2/3/4 列）+ 列表模式 — acceptance: 封面岛点开阅读；空态可导入 (covers: S2; depends: T2–T4)
- [x] T6: Hero 封面过渡 — acceptance: 网格打开有过渡，异常不崩 (covers: S2; depends: T5)
- [x] T7: 书源占位 + 设置（版本/关于/动态色/布局）— acceptance: 空态正确；开关落库 (covers: S2; depends: T2–T4)
- [x] T8: analyze 0 error + Windows 可启动 — acceptance: `flutter analyze` 0 error (covers: S2; depends: T1–T7)
