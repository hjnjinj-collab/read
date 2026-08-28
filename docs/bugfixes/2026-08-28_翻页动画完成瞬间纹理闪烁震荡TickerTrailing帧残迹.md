# Bug 修复报告：翻页动画完成瞬间纹理闪烁震荡（Ticker trailing 帧残迹）

## 修复日期
2026-08-28

## 问题概述

仿真卷曲翻页动画**完成的瞬间**（commit → release 阶段）屏幕出现一闪而过的「上一帧卷曲残迹」：
- 视觉上看到卷曲几何的折角、对角阴影残迹**停留一帧**才切到干净新页
- 现象在每条翻页**完成时**稳定复现
- **不是**动画中段（动画过程中段折叠完全正常）
- 跨章、纯文字、含图片 EPUB 全部命中

**日志证据模式**（`curl.paint.frame` 序列的"短路-跌回"震荡）：

```
... autoProgress=0.9978 isSettled=false  ← 上升
... autoProgress=1.0    isSettled=true   ← 触顶 1.0，短路命中
... autoProgress=0.9999 isSettled=false  ← 关键！跌回 1.0 以下
... autoProgress=0.9998 isSettled=false  ← 继续衰减
... autoProgress=0.9996 ...
turn.animation.complete
```

**注**：本报告与 `2026-08-28_纹理闪烁震荡问题已解决`（git commit 标记）对应。

## 根本原因

**Flutter Ticker 渐近逼近的尾随帧**。

1. `controller.animateTurn()` 内部逐帧推进 `progress = 0 → 1.0`
2. `progress=1.0` 那一帧：CurlPainter 入口短路 `ap >= 1.0` 命中 → 只画 revealPage 全屏 → **干净新页**上屏
3. **Ticker 完成回调**（`onComplete` 异步触发）在 progress=1.0 触达**之后**还有几帧 trailing paint 调用——这些帧里 controller.progress **回退到 0.9996~0.9999**（高精度浮点的最后几次渐近逼近）
4. `ap=0.9996 < 1.0` → **`isSettled=false`** → **走非短路路径** → CurlPainter 按 p=0.9996 画卷曲几何 → **看到折叠末态残迹帧**上屏 = 闪
5. 之后 turn.animation.complete 触发 commit → widget.update → build 走 CurlPainter 短路 → 再画 revealPage 全屏

`CurlPainter.paint` 入口短路条件硬阈值 `1.0`，浮点尾随帧 `0.9996~0.9999` 不满足 → 走完整卷曲几何路径 → 视觉上是"残迹帧"。

## 解决方案

把短路条件从 `ap >= 1.0` 放宽为 `ap >= 0.9995`：

```dart
// lib/features/reader/presentation/widgets/page_turn/curl_painter.dart
final ap = autoProgress;
final isSettled = (ap != null && ap >= 0.9995) ||
    identical(revealPage, foldingPage);
```

**阈值选择依据**：
- Flutter Ticker 的渐近逼近精度通常是 `1.0 - 1e-4 ~ 1.0 - 1e-6`，阈值 0.9995 完全覆盖 trailing 帧
- 远在动画中段进度（0.5~0.99）之上，**不会误命中**——动画中段继续走卷曲几何
- 缓解期（0.9995 < ap < 1.0）的 trailing 帧全部走短路画 revealPage 全屏

## 验证

- `flutter analyze`：0 错误 0 警告（23 条 info 全既有）
- `flutter test`：90 过 1 挂（基线 widget_test 模板失败）
- 真机验证：所有翻页 commit 之前 `curl.paint.frame` 日志**不再出现"isSettled: true 之后又 false"**——最后几帧全部 `isSettled=true` 一致画 revealPage 全屏，无残迹帧插入

## 预防/工程约束（新增）

**Flutter Ticker 完成回调的 trailing 帧**：硬阈值 `>= 1.0` 在浮点尾随帧（0.9996~0.9999）下不命中。对**任何以 controller 进度做"完成判定"的短路逻辑**，阈值应放宽到 `0.999` 量级以覆盖 trailing 帧。Ticker 完成 callback 自身是异步的——最后几帧 paint 由 `markNeedsPaint` 触发，controller.progress 可能已不再精确为 1.0。

## 相关文件
- `lib/features/reader/presentation/widgets/page_turn/curl_painter.dart` — 短路条件阈值
