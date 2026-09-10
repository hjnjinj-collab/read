---
feature: selection-handle-tracking
status: delivered
updated: 2026-09-10
branch: master
commits: pending
---

# 选区手柄跟手与双端独立拖拽

## Report

**What was built** — 修复阅读页选区手柄两个体验缺陷：(1) 拖拽不跟手/光标停在上一行；(2) 拖 start 时 end 被 `beginSelection` 重置。手柄改为全屏 `Listener` + `globalPosition` 经 overlay 根换算页面坐标；`hitTestCharOffset` 盒外回退纵向最近行；新增 `updateSelectionStart` / `resolveSelectionStartDrag` 保证双端独立。

**Verification** — `flutter test test/selection_handle_test.dart test/note_highlight_test.dart` → 13 passed；`flutter analyze` 对改动文件无 error（仅既有 info/warning）。独立 review 确认 4 项 AC；已按 review 补指针 id 校验、抽出 `findEntryForHitTest` 供生产与测试共用。

**Journey log**
- `git worktree add` 被会话策略拦截，改动落在 master 工作区（与既有未提交笔记管线修复同树）。
- 旧实现 `details.localPosition + handlePosition` 坐标系错误 + 每 tick 重建 GestureDetector → 手势 arena 重置，表现为“隔几行仍停在上一行”。
- `beginSelection` 语义是“新开单字符选区”，误用于拖 start 手柄导致 end 被抹掉。

## [S1] Problem

阅读页长按选区后拖拽手柄：

1. **不跟手**：手指已移到下一行，光标/选区端点仍停在上一行。
2. **拖头尾重置**：拖 start 手柄时 end 被抹掉。

## [S2] Design

### 坐标与命中

- 手柄拖拽：全屏 `Listener` + `globalPosition` → overlay 根 `globalToLocal` → 阅读区局部坐标。
- `findEntryForHitTest`：盒内优先；否则纵向最近行（横向 48px 容差）。
- 拖拽开始 `prepareDragCache`，全程复用 TextPainter。

### 双端独立

- `updateSelectionStart` → `resolveSelectionStartDrag`：只动 start；越过 end 时区间翻转为 `[end, finger+1)`。
- end 手柄仍走 `updateSelection`。

### 手势稳定性

- 稳定 `ValueKey('sel-handle-start'/'end')`；指针 id 锁定当前手柄。
- 拖拽中 overlay `HitTestBehavior.opaque` 挡住翻页手势；`up`/`cancel` 校验 pointer id。

## [S3] Out of Scope

- 复制到剪贴板 TODO
- 跨页/跨章选区
- 笔记 enrich / frame set 管线

## Tasks

- [x] T1: `updateSelectionStart` + 命中回退最近 entry — acceptance: 单测覆盖“拖 start 不重置 end”与“盒外点命中最近行” (covers: S2)
- [x] T2: 手柄拖拽改 globalPosition/Listener，稳定 key + 指针锁定 — acceptance: 代码审查坐标链路完整；analyze 无 error (covers: S2; depends: T1)
- [x] T3: 回归测试与 analyze — acceptance: `flutter test test/note_highlight_test.dart test/selection_handle_test.dart` 全绿 (covers: S1 S2; depends: T1 T2)
