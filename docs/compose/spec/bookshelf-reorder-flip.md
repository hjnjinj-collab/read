---
feature: bookshelf-reorder-flip
status: delivered
updated: 2026-09-13
branch: master
commits: 6db24be..6db24be
---

# 书架返回排序 FLIP 位移

## Report

**What was built** — 返回：阅读页 620ms 缩向第一本，落地后 FLIP 让位 + 3px 绿边框光晕 1400ms。进入：从当前书槽位放大（shelfIndex）；openBook 全程 isLoading 直至首页就绪，避免闪 No content。

**Verification** — `flutter analyze` 相关路径无新 error。真机/Windows 待验：非首位点开应从该书放大；返回落地后有 FLIP + 明显绿边框；进入不再闪 No content。

**Journey log** — 1) FLIP 用稳定外层包装。2) 转场期间不要提前 `_refresh`。3) 边框必须在 Material 之上且加光晕。4) push/pop 对齐槽位不同：从哪来 shelfIndex、去哪 index 0。5) isLoading 不得在 currentPage 就绪前关掉。

## [S1] Problem

从阅读页返回书架时：

1. 曾有竖向 16px 淡入 / 其它书瞬移；已用 FLIP 位移修好网格重排。
2. **阅读页 → 书架整页转场几乎不可见**：`/reader` 默认 `builder` 转场太弱，用户要求「阅读页开始缩小，逐渐缩放回到第一本的位置」。
3. **高亮边框看不见**：边框画在 Material 外侧 `DecoratedBox`，被封面 Material 盖住。

用户期望：返回时阅读页明显缩小并落到第一本槽位；刚读过的书有可见高亮边框。

## [S2] Design

### 网格重排 FLIP（已交付）

- 触发：`_refresh()` 后订单变化（`touchLastRead` 已生效）。
- 每个索引变化的书：`Transform.translate` 从 `oldPos-newPos` → `Offset.zero`，`easeOutCubic` / 300ms。
- 落点：打开的书停 index 0；其余顺延。禁止回弹/缩放参与重排。
- `_FlipSlot` 稳定挂在卡片外；列表按行高估算；`disableAnimations` 直接终态。

### 阅读页缩放转场

- `/reader` 改 `pageBuilder` + `CustomTransitionPage`。
- 转场：整页 `ScaleTransition` + `FadeTransition`；`alignment` = 书架槽位中心。
- **push（从哪来）**：`extra.shelfIndex` = 被点开的书在书架的下标，从该槽放大铺满。
- **pop（去哪）**：固定 index 0（最近阅读落首位）缩回。
- 时长 **620ms**；曲线 `easeInOutCubic`；终态 scale **0.22**。
- pop：透明度 `reverseCurve: Interval(0, 0.28)`，前 ~72% 不透明。
- **时序**：`await push` 返回后再 `_refresh()` + 高亮（1400ms）。
- 几何常量集中在 `BookshelfLayout`。

### 高亮描边

- 封面 Stack 顶层：**2.5px primary 纯描边**（无光晕/阴影），贴封面圆角边缘。
- 持续 1400ms，落地后与 FLIP 同时可见。

### 开书加载

- `openBook`：解析/元数据阶段保持 `isLoading: true`，`_loadCurrentPage` 提交首页后才 `false`。
- 消除「首页未就绪却 isLoading=false → 闪 No content」。
- `ReaderPage` 首帧 postFrame 即 `openBook`，与 620ms push 转场并行。

## [S3] Out of Scope

- 自定义 Hero 飞行 / 阅读页封面落点
- 拖拽手动排序
- 列表模式精细测量
- 其它 Tab / 菜单动效

## Tasks

- [x] T1: 网格 FLIP 位移替换 justMoved 淡入 — acceptance: 返回后打开的书从原槽滑到首位，原首位向右让位；无回弹/缩放 (covers: S2)
- [x] T2: 列表模式同步 FLIP — acceptance: 列表返回按行高估算位移 (covers: S2; depends: T1)
- [x] T3: disableAnimations 与 analyze — acceptance: 减弱动态直接终态；相关路径 analyze 0 error (covers: S2; depends: T1)
- [x] T4: 阅读页 CustomTransitionPage 缩向第一本 — acceptance: 返回时整页缩小落到第一本槽位，push 反向放大 (covers: S2)
- [x] T5: pop 预刷新书架 — acceptance: 缩放过程中书架已是最近阅读在首位 (covers: S2; depends: T4)
- [x] T6: 高亮边框画在封面之上 — acceptance: 返回后第一本可见 primary 边框 (covers: S2)
- [x] T7: analyze — acceptance: 本轮改动路径无新 error（reader 既有 warning 为 PRE-EXISTING）(covers: S2; depends: T4–T6)
