# 项目进度总结（progress summary）

> 更新：2026-09-20 ｜ 仓库：`D:\android\example\legado_flutter` ｜ 分支：`master`
> 用途：重开会话时先读本文件 +「进度文件清单」。

---

## 一、最近主线（按时间）

| 阶段 | 内容 | 状态 |
|------|------|------|
| 壳层 UI | 首页 Dashboard、书架续读、横幅轮换、上滑渐变模糊、底栏 IA | **已 push** |
| 壳层路由 | 同 Tab 策略、回首页解耦、面板选中态、三段放大、Solid/玻璃 IA 同构 | **已 push** `2b187d0` |
| 阅读菜单设计 | 对标 `legado-with-MD3`，双套 chrome + HTML 可点原型 | **设计完成**（多轮 present commit） |
| 阅读 UI 外壳 | `reader_chrome.dart` T0：顶栏/A/B 底栏/工具球 | **已实现，待真机**（未 commit） |
| 防泄露修正 | 恢复液态玻璃 + ClipOval 裁切；BF 渐变垫仅菜单态 | **已改**（ClipOval 实为液态杀手，已换 Batch/Clip.none） |
| 状态栏沉浸 + 液态修复 | 纸色铺满；圆键同源 shellFrost；键 52；顶距收紧；底栏 60/208；底部雾加浓 | **已实现**（待 push） |

远端：`origin/master` @ `2b187d0`（及之前的 present commit）。  
工作区未提交：`reader_chrome.dart`（新）、`reader_page.dart`、`reader-menu-chrome-ia.md`、本文件。

---

## 二、已交付（可重会话直接引用）

### 壳层（已推送）
- 首页 Dashboard + Hero 推挤轮换 + 今日目标首帧
- 书架横幅多本轮换（6s）+ `HeroSlideSwitcher` 真 index
- 共用 `TopScrollBlurChrome`（书架/首页上滑渐变模糊）
- 切页 **仅 slide**（去 Fade，修液态变暗）
- 同 Tab：仅设置子页 `initialLocation` 回 hub；`homeIntroTick` 仅跨 Tab
- 底栏左 `[首页|书架|书源]` + 更多；Solid 与玻璃 IA 同构；三段 72/248

### 阅读菜单（设计 + T0 壳，待真机）
- 设计稿：双套 A 传统底栏 / B 悬浮图标；图标布局、排版细页、背景主题、字体 sheet、背景图网格
- HTML 原型：`docs/design/reader-menu-chrome-proto.html`（可点流程）
- T0 壳：`lib/features/reader/presentation/widgets/reader_chrome.dart`
  - 液态玻璃圆键 + **ClipOval 防模糊泄露**
  - 菜单态：顶→底 / 底→顶 `ReaderBlurVeil`（壳滤镜同语言，各一层 BF）
  - 阅读中：顶栏轻量无 BF 雾（防常驻 BF 拖死 `openBook` → 转圈）
  - 工具：目录/搜索/设置开既有对话框；书签/笔记 stub（有 print 日志）

---

## 三、未完成（下一轮优先）

1. **真机**：键径 52 / 顶距收紧 / 底栏展开不暴涨 / 底部雾可读性
2. 通过后 **commit + push** 工作区阅读 chrome + 沉浸 + 壳层底栏改动
3. 阅读 T1+：形态持久化、设置四页（形态/排版/背景/材质）、字体 sheet、背景图网格接线
4. 状态栏显隐用户开关（后期）
5. 壳层候选：首页数据真实化（时长/折线埋点，统一流程后）

---

## 四、工程约束（速查，勿再踩）

- Impeller：液态圆键**只准**用 `shellFrostLiquidStyle`（与书架同源）；禁止 `ClipOval/saveLayer`、禁止 `LiquidGlassBatch`
- 液态祖先裁切必须 **`Clip.none`**（含 Stack 默认 hardEdge）
- 阅读 chrome：垫层**无 BF** 只做渐变雾；常驻大 BF 会卡开书
- 切页勿对含 LiquidGlass 子树做 Fade/Opacity
- 沉浸：`padTop = paddingVertical + viewPadding.top` 且必须进 fingerprint
- 顶栏玻璃层序：模糊在 ClipRect 内，前景在外
- 自动轮换 Timer 对齐 `disableAnimationsOf`（arm + tick）
- `HeroSlideSwitcher` 只在 index 变化时推挤
- `flutter analyze` 全量基线：**25 PRE-EXISTING**（reader/test）
- 真机验收后再 `push origin master`；master 主 worktree，不建 `.worktrees`
- 回复 **zh-CN**；`/compose-next` 工作流

---

## 五、进度文件清单（重开会话入口）

| 优先级 | 路径 | 用途 |
|--------|------|------|
| **P0** | `docs/compose/progress-summary.md` | 本文件，总入口 |
| **P0** | `docs/compose/spec/reader-statusbar-immersive-glass.md` | 状态栏沉浸 + 液态修复（本轮） |
| **P0** | `docs/compose/spec/reader-menu-chrome-ia.md` | 阅读菜单契约 + T0–T5 |
| **P0** | `docs/design/reader-menu-chrome-proto.html` | 可点布局/流程原型 |
| P1 | `docs/compose/spec/shell-banner-home-blur.md` | 横幅轮换 + 首页模糊 + 切页去 Fade |
| P1 | `docs/compose/spec/shell-tab-reselect-policy.md` | 同 Tab / 回首页 / 选中态 / 三段尺寸 |
| P1 | `docs/compose/spec/shell-solid-glass-ia.md` | Solid/玻璃 IA 同构 |
| P1 | `docs/design/shell-nav-routing-status.md` | 路由现状（历史） |
| P1 | `docs/design/ui-next-roadmap.md` | 路线图 |
| P2 | `docs/compose/spec/settings-top-gradient-blur.md` | 设置顶栏模糊 |
| P2 | `docs/compose/spec/bookshelf-continue-card-ui.md` | 首页/续读 |
| 代码 | `lib/features/reader/presentation/widgets/reader_chrome.dart` | 阅读外壳（未提交） |
| 代码 | `lib/features/reader/presentation/pages/reader_page.dart` | 接线（未提交） |
| 对标 | `D:\android\example\legado-with-MD3` | 阅读菜单对标源 |

**建议重开会话开场**：先读本文件 + `reader-statusbar-immersive-glass.md`，从「真机验收 / T1 设置四页」继续。
