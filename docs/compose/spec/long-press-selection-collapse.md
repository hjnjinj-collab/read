---
feature: long-press-selection-collapse
status: abandoned
updated: 2026-09-11
branch: master
commits: 2d559a8（已由 e279f22 revert）
---

# 长按选区按住期间抖动塌缩为单字

> **⚠ 已回滚（e279f22）**：真机验证锚定门控导致选择光标不跟手，且摘录仍为
> 1 字——证明微抖塌缩并非首字问题的根因。真根因指向 `expandToWordBoundary`
> 以单条 entry 为界扩展（若 entry 为逐字粒度则恒返回 1 字），待另行修复。
> 本文档保留作死因记录。

## Report

**What was built** — 锚定门控修复：长按 `beginSelection` 整词选中后，手指按住期间的 PointerMove（电容屏微抖，raw Listener 无 touch-slop 过滤）不再调用 `updateSelection` 重设尾端——只有当手指命中点移出锚定选区区间 `[start, end)` 时才更新，扩展/收缩行为保留；pointer-up 清锚，下次手势对当前选区 lazy 重锚。仅改 `reader_page.dart` body 手势路径，overlay 手柄拖拽（依赖 `updateSelection` 自由收缩语义）不受影响。

**Verification** — `flutter analyze`：34 条均为既有基线告警，无本 diff 新增（PASS）。独立审查 subagent：Spec 合规 PASS、正确性 PASS（长按→抖→存笔记、拖出扩展、第二次触摸重锚、翻页清选区、扩展后二次触摸五场景推演全部通过）、代码一致性 PASS，无 critical。

**Journey log** — ① 本项目 raw Listener 无 touch-slop 过滤，任何"按住期间位置敏感"的逻辑都需自行防抖；后续新增按住状态的手势模式应检查是否暴露于 PointerMove 微抖。② 门控采用"半开区间 + 手势级 lazy 快照"：跳过 updateSelection 永不破坏 provider 状态，stale anchor 天然良性。③ 审查者建议的"updateSelection 后前移锚端"缓解经推演反而加重回缩限制（回拖命中必落扩大锚内被跳过），未采纳——同手势内扩展后无法缩回词内属可接受取舍（抬手重锚/手柄可绕开）。④ `onPointerCancel` 缺失为既有缺口（来电/手势导航时锚与 _isDragging 残留），锚残留经推演良性，登记备忘未修。

## [S1] Problem

上一轮修复 beginSelection 词边界后，真机新建笔记摘录仍只有 1 个字。根因：长按触发 beginSelection（整词）后手指仍按在屏上，电容屏微抖产生的 PointerMove 进入 `_onPointerMove` 选区分支，`updateSelection(hitOffset)` 把 `_selectionEnd` 无条件重设为手指下字符（clamp 下限 start+1），整词塌缩为单字。raw Listener 无 touch-slop 过滤，塌缩几乎必然发生。

## [S2] Design

锚定门控，仅改 reader_page.dart 的 body 手势路径（不动 provider：overlay 手柄拖拽依赖 updateSelection 的自由收缩语义）：

- `_selectionAnchorStart/End` 记录当前选区（长按建立后显式锚定；pointer-up 清锚后对当前选区 lazy 快照）；
- PointerMove 选区分支：hitOffset 落在锚定区间内 → 跳过 updateSelection；区间外 → 正常更新；
- pointer-up 清锚；下次手势对当前选区 lazy 重锚。

行为：长按后保持不动/微抖 → 选区保持整词；拖出选区 → 正常扩展/收缩；手柄拖拽不受影响。

## [S3] Out of Scope

- body 左拖移动 start 手柄（现仅改 end，维持既有行为）
- 同一次手势内"扩展后回缩进原词区间"的精细收缩（锚不随扩展前移，抬手重锚或 overlay 手柄可绕开）
- `onPointerCancel` 处理（既有缺口，锚残留经推演良性）
- 选区状态机加固（页尾空选区退化，见 epub-batch-locate-deadlock.md）

## Tasks

- [x] T1: 锚定门控实现 — acceptance: 按住选区内微抖不改变选区，移出后正常扩展 (covers: S2)
- [x] T2: flutter analyze 无新增告警 — acceptance: analyze 通过 (covers: S2)
