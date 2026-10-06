---
feature: reader-gesture-single-hand
status: delivered
updated: 2026-10-01
branch: master
commits: 6179068..HEAD
---

# 单手手势优化：卷曲跟手 + 音量键 + 翻页清晰度

## Report

**What was built** — ①**卷曲跟手**：拖拽期 `effTouch` 改用真实 `_lastTouchLocal`（`_isDragDriving` 门控），折角/贝塞尔随手指位置与角度变化；松手后仍走 release→sweep 插值。②**音量键翻页**：Android `dispatchKeyEvent` → `legado/keys` 通道；音量上=上一页、下=下一页；设置「音量键翻页」默认关，仅阅读页开启时拦截。③**翻页清晰度**：ripple/collapse 动画层 `FilterQuality.medium` → `high`；快照已按 dpr 原生生成。

**Verification** —
- `flutter test test/reader_gesture_single_hand_test.dart`：PASS 4/4（拖拽跟手/插值/定格）
- `flutter analyze --no-pub`：无 error
- arm64 APK 构建通过

**Journey log** —
- 拖拽期误走 `_releaseTouch→sweep` 插值是「不跟手」根因
- 音量键须原生 intercept，且默认关避免抢媒体音量
- 动画层 medium 采样在变换下必糊，high 才够

## [S1] Problem

## [S1] Problem

1. **卷曲不跟手角度**：拖拽期 `effTouch` 被 `_releaseTouch→sweepTarget` 插值覆盖，折角固定在起手点附近，只有横向 progress 在变。
2. **无音量键翻页**：单手够不到屏缘时无法翻页。
3. **翻页清晰度下降**：动画期 `FilterQuality.medium` 采样 + 变换，字发糊。

## [S2] Design

### A. 卷曲跟手（拖拽期）

- **拖拽中**（`_isActive && !_autoIsTurn && !_holdingFinalFrame`）：`effTouch = _lastTouchLocal`（真实手指），折角/贝塞尔随手指位置与角度变化。
- **松手自动**（`_autoIsTurn`）：保持现插值 `_releaseTouch → sweepTarget`。
- **回弹**（`!_autoIsTurn` 且在自动收尾）：`_releaseTouch → _dragFirstTouch`。
- 判定：增加 `_isDragDriving`（onDragUpdate 置位、onDragEnd/自动清位），与 `_autoIsTurn` 一起决定触点源。

### B. 音量键翻页

- Android `MainActivity.dispatchKeyEvent`：音量上/下 `ACTION_DOWN` → `legado/keys` 通道 `volumeUp` / `volumeDown`。
- Dart 阅读页监听：上=上一页、下=下一页（与系统阅读器习惯一致：音量下=下一页）。
- 设置开关「音量键翻页」默认**关**（避免抢媒体音量）；仅阅读页且开关开时拦截。
- 通道带 `enabled` 状态由 Dart 下发；关闭时原生放行系统音量。

### C. 翻页清晰度

- 快照已按 `dpr` 原生分辨率生成（保留）。
- `ripple_painter_v16` / `collapse_painter` / curl 镜面 `drawImageRect`：`FilterQuality.medium` → **`FilterQuality.high`**。
- 禁止在动画层对整页纹理再做额外降采样。

### 测试

- 卷曲触点：拖拽期 `effTouch` 等于最后 `localTouch`（纯函数抽 `resolveCurlTouch` 可测）。
- 音量键映射：`volumeUp→prev`、`volumeDown→next`（纯函数）。

## [S3] Out of Scope

- 页内双指捏合（与翻页手势冲突，二期）。
- 音量键调节亮度/音量（仅翻页）。
- 3D 真纸物理仿真。

## Tasks

- [x] T1: 拖拽期卷曲跟手触点 — acceptance: 斜向拖动折角随手指变 (covers: S2)
- [x] T2: 音量键翻页通道 + 设置开关 — acceptance: 开关开时音量下=下一页 (covers: S2)
- [x] T3: 动画层 FilterQuality.high — acceptance: 翻页过程字迹不糊 (covers: S2)
- [x] T4: 测试/构建收口 — acceptance: 测试过；APK 可装 (covers: S2; depends: T1,T2,T3)
