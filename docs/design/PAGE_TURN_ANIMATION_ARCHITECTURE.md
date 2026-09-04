# 翻页动画架构（Page Turn Animation Architecture）

> 日期: 2026-09-04
> 地位: 翻页动画域的**权威描述**，以代码实际状态为准。
> 范围: 四种翻页模式的手势管线、启动门控、控制器、渲染层、缓存体系、排队与互斥、提交定格、诊断 trace。
> 上游文档: 全流程总架构见 [ARCHITECTURE.md](./ARCHITECTURE.md)（阶段五）；历史方案演进见 [PAGE_TURN_ANIMATION_PLAN.md](./PAGE_TURN_ANIMATION_PLAN.md) 与 `docs/bugfixes/` 翻页系列报告。

---

## 1. 模式家族总览

| 模式 | PageTurnMode | 控制器 | 渲染器 | 视觉模型 | 纹理需求 |
|------|--------------|--------|--------|----------|----------|
| 卷曲 | `simulation` | `SimulationTurnController` | `CurlPainter` | 弹簧物理折页（legado 仿真） | **无快照**——纯矢量直绘 + `onImageNeeded` 实时重绘 |
| 滚动 | `verticalScroll` | `ScrollTurnController` | `_buildScrollTransition`（平移） | Y 轴滑页 | 无快照 |
| 水波纹 | `ripple` | `RippleTurnController` | `RipplePainterV16` + `ripple_shredder.frag` | 双波分界线横向扫过，方块原位缩放崩解+滑移旋转 | 旧页快照 1 张 |
| 坍塌 | `collapse` | `CollapseTurnController` | `CollapsePainter` + `block_collapse.frag` | 点击位置为引力中心，方块径向波前（近→远）向心坍塌溶解 | 旧页快照 1 张 |

**核心不对称**：curl 是矢量直绘（天然 immune 到纹理时序问题）；ripple/collapse 依赖 `ui.Image` 快照，由此派生出本架构最重要的子系统——**快照缓存与启动门控**（§7）。

**速度三档**（`PageTurnSpeed`）：快=400 / 中=600 / 慢=800ms（`rippleDurationMs`）；collapse 控制器内部 ×1.4（560/840/1120，径向多波次密度更高）。档位定义不动，只调 multiplier。回弹动画恒 300ms 不随档位。

---

## 2. 分层架构

```
┌─ ReaderPage（手势捕获层）─────────────────────────────────────────┐
│ Listener pointer down/move/up → 8px 启动阈值 → 渐进式阻尼          │
│ resolveGesture 四态判定（tap/turnPage/snapBack/verticalIntent）    │
│ 点击分区：collapse 用 2D 中心矩形（_collapseTapZone）              │
│   中心 30%~70%×30%~70% → 菜单；其余左半 prev / 右半 next           │
└──────────────┬───────────────────────────────────────────────────┘
               ▼ _PageTurnComposerBridge（GlobalKey 方法桥）
┌─ PageTurnComposer（唯一编排者）───────────────────────────────────┐
│ ① 门控层   _targetFrameFor → Ready/OutOfRange/Wait 三态           │
│ ② 启动层   _startTurnAnimated（见 §4）                            │
│ ③ 排队层   _queuedTapTurn（覆盖式单槽）+ 挂起 pending 三态重试     │
│ ④ 动画层   PageTurnAnimationController 家族（见 §5）              │
│ ⑤ 渲染层   Painter 家族（见 §6）                                  │
│ ⑥ 缓存层   页面快照 LRU + BookImageStore（见 §7）                 │
│ ⑦ 提交层   _commitPageTurn → 定格 → release（见 §9）              │
└───────────────────────────────────────────────────────────────────┘
               ▼
┌─ ReaderRenderStateStore（FrameSet 权威发布）───────────────────────┐
│ 三槽 FrameSlot(current/previous/next) 四态                         │
│ ready/outOfRange/failed/pending；pendingTurn 登记-消费-取消        │
│ sessionEpoch/configFingerprint 会话失效（不变量 6）                │
└───────────────────────────────────────────────────────────────────┘
```

---

## 3. 手势管线（ReaderPage → Composer）

### 3.1 三条触发路径

| 路径 | 入口 | 语义 |
|------|------|------|
| 点击 | `onTapTurn(direction, tapPosition)` | 空闲态点击：坍塌中心=真实点击点；其他模式合成边缘触点 |
| 拖拽 | `onDragStart/Update/End` | 跟手（dragTo 1:1）+ 松手 `animateTurn/animateSnapBack` |
| 挂起重试 | pending 机制（timer + FrameSet 发布 listener 双驱动） | 帧未就绪的手势延后执行 |

### 3.2 点击分区（collapse 专属，2026-09-04 v2）

```
┌──────────┬─────────────────┬──────────┐
│          │  顶部中间带→翻页  │          │
│  prev    │ ┌─────────────┐ │  next    │
│  (左半)  │ │ 菜单 2D 矩形 │ │  (右半)  │
│          │ │ x,y∈30%~70% │ │          │
│          │ └─────────────┘ │          │
│          │  底部中间带→翻页  │          │
└──────────┴─────────────────┴──────────┘
```

- `_collapseTapZone(pos, w, h)`：中心矩形 → null（菜单意图）；其余按左右半分翻页。
- **在途点击同语义**：动画/提交窗口期的 pointer-up 走 `_resolveInFlightTapDirection`（与空闲点击同一套判定），带方向转排队——否则同一位置首击能翻、连点不能。

### 3.3 阻尼与判定

- 渐进式阻尼：[0,0.5) 完全跟手 / [0.5,0.8) 线性阻尼 / [0.8,1.0] 强阻尼（映射到 [0.7,0.85]）
- `resolveGesture`：tap(<18px) / turnPage(距离≥15%屏宽 或 速度≥400px/s) / snapBack / verticalIntent(dy 主导 1.5×)

---

## 4. 启动封装 `_startTurnAnimated`（所有路径的唯一入口）

```
_startTurnAnimated(direction, localTouch, {isTap, autoPlay})
  │
  ├─ [同步置位段——先于任何 await]
  │    _isActive=true（isIdle 立即 false → pointer-move 停止重发 startDrag）
  │    _turnDirection / 触点三字段 / _rippleSeed
  │
  ├─ [快照就绪门控]（仅方块类模式）
  │    _ensureCurrentSnapshotReady() —— 500ms 超时
  │    快路径：按页 LRU 缓存命中（常态，零延迟）
  │    慢路径：串行链生成当前页快照（首遇新页 ~30-60ms）
  │
  ├─ [await 后门控重查]（publish 可能使帧失效/推进）
  │    TargetReady    → 用新 frame 启动
  │    TargetWait     → 复位 + 重新挂起走原重试链
  │    TargetOutOfRange → 复位 + 直翻保功能
  │    快照超时        → tap 直翻保功能 / drag 复位由 pointer-move 重试
  │
  ├─ [启动] _targetFrame=frame; _replaceController(); setState
  │
  └─ [收尾]
       deferred drag end（快照窗口内手指已抬起）→ 补 _runAuto(挂起值)
       autoPlay=true（tap 语义）→ 持有 _turnEndInFlight 跑 _runAuto(true)
       autoPlay=false（drag 语义）→ 等待 dragTo 跟手 / 松手 endDrag
```

**为什么同步置位必须先于 await**：isIdle 立即变 false，reader_page 的 pointer-move 不再重发 startDrag（无重入死循环），onTapTurn 命中队列守卫，await 窗口内状态对外一致。

---

## 5. 动画控制器层

```dart
abstract class PageTurnAnimationController {
  Duration get turnDuration => 300ms;      // 可覆写（速度档位来源）
  Future<bool> animateTurn();              // 返回 false=被打断（调用方不得提交）
  Future<bool> animateSnapBack();
  void dragTo(double v);                   // ⚠️ value setter 内部隐式 stop()
  final ValueNotifier<int> repaintNotifier; // 拖拽期绕过 shouldRepaint 直达 paint
}
```

- 实现走 `_controller.animateTo(...).orCancel` + catch `TickerCanceled`——**裸 await 的 TickerFuture 被取消后永不完成**（挂死根因，见 bugfixes/2026-09-04）
- `buildSimulation` 为遗留死代码路径（基类不再消费 Simulation）
- 速度注入：`createTurnController(mode, speed)` → 各控制器 `durationMs`

---

## 6. 渲染层（两层架构）

```
层1: 新页整页 —— 实时矢量直绘（PageContentRenderer.paintPage）
     统一模板：先 drawRect(paperColor) 再 paintPage（渲染参数与正式渲染同源）
     → 动画中/完成瞬间逐像素一致，无切换色差、无 trailing 帧闪烁
层2: 旧页方块层 —— FragmentShader 全屏绘制（采样旧页快照）
```

### 6.1 坍塌 shader（block_collapse.frag）参数速查

| 参数 | 值 | 说明 |
|---|---|---|
| COLLAPSE_FRAC | 0.45 | 波前扫 55% + 单块坍塌 45% |
| SLIDE_DISTANCE | 45px | 向心滑移（uCenter=点击点） |
| JITTER_DELAY | 0.12 | **恒减法**（只推迟不提前） |
| 旋转 | 1.2~3.2 rad 每块随机 | rotDir × rotAmp |
| 阴影 | 8px 渐变带 ×0.55，底重顶轻(1.8/0.5) | uShadowColor 可配置 |
| 消隐 | scale ≤0.02 → 透明 | 恒不透明缩放崩解，无半透明混合 |
| 采样 | 半纹素对齐 `(floor(src)+0.5)/uResolution` | 消除双线性发虚 |
| 时序 | `startAt = dNorm × (1-COLLAPSE_FRAC)` | dNorm 按中心到四角最大距离归一化，四角同刻收尾 |

### 6.2 水波纹 shader（ripple_shredder.frag）参数速查

blockSize 36 / waveAmp 45 / waveLength 120（双波叠加 0.53×反向）/ SWEEP_RANGE 3.0 / 两段式阈值 0.6 / jitter −h0×0.15 / uSeed 每翻页随机 / uniform 12 float + 1 sampler（改布局必须同步 Dart setFloat 索引）。

### 6.3 短路纪律

`progress<=0.001 / >=0.999` 短路与 fallback 路径**必须**经由统一 `_paintPage` 模板（纸色底+渲染参数）——与 8-28 Ticker trailing 帧报告同源约束。

---

## 7. 缓存体系（动画域）

### 7.1 全局缓存拓扑（动画相关层）

```
┌─ S1 页面快照 LRU（2026-09-04 v2）─────────────────────────────┐
│ PageTurnComposer._snapshotCache                               │
│ LRU(8) LinkedHashMap，touch 刷新访问序（动画在用恒最新）       │
│ 键 = readerPageId(实例哈希)|chapter/page|视口尺寸|dpr|         │
│      fontSize|lineHeight|bold|italic|titleBold                │
│ 值 = ui.Image（dpr 高分辨率快照，canvas.scale(dpr) 绘制）      │
│ 淘汰：超容量移除最旧并 dispose（在用纹理每次 build touch，     │
│       恒为最新，不会被淘汰）                                   │
└───────────────────────────────────────────────────────────────┘

┌─ S2 书内图片解码缓存（BookImageStore）────────────────────────┐
│ LRU(64) + _pinned（存活 FrameSet 引用防淘汰）                  │
│ 键 = "$bookId|$resourceHref"；ensureLoaded 异步取字节→解码    │
│ 失败 3 次退避重试（500ms/2s/8s）后稳定 failed（恒画占位）      │
│ 解码并发闸门 _Semaphore(2)                                     │
└───────────────────────────────────────────────────────────────┘

┌─ S3 上游分页缓存（Rust，见 ARCHITECTURE.md §5.2）──────────────┐
│ PAGINATION_CACHE / STRUCTURED_PAGINATION_CACHE (LRU 10)        │
│ GlyphCache / MEASURE_CACHE / 净化落盘缓存                      │
└───────────────────────────────────────────────────────────────┘
```

### 7.2 快照键设计原则

**键 = 内容的真实依赖**，不是生命周期概念：

| 键分量 | 防御的过时场景 |
|---|---|
| `readerPageId`（实例哈希） | 重排后 PageInfo 实例重建（行断变化） |
| `chapter/pageIndex` | 实例哈希碰撞兜底 + 诊断可读性 |
| 视口尺寸 + dpr | 窗口缩放 / 跨屏拖动 |
| fontSize/lineHeight/bold/italic/titleBold | 阅读设置变更（实例未变内容渲染变） |

> 历史教训：v1 键 = `setRevision`（生命周期概念）→ 每次翻页提交三张纹理全作废重生成 → 紧接的点击/拖拽必然撞上 toImage 窗口 = 「动画启动延迟、拖拽不跟手」根因。**revision 是门控概念不是内容概念。**

### 7.3 生成串行链 `_serializeSnapshot`

所有 `_pageToImage` 调用经 `Future` 链排队执行——publish 预热与翻页启动的即时生成并发时，消除「并发写同一缓存字段 / 先 dispose 后赋值」窗口。链任务内部**禁止再入链**（A 等 B、B 等 A 死锁）。dispose 时序恒为「先赋值新、再 dispose 旧」。

### 7.4 预热时机矩阵

| 时机 | 动作 | 目的 |
|---|---|---|
| FrameSet 发布（publish） | `_prewarmAllPageImages`：仅预热 current 页快照 | 用户交互前纹理已在缓存 |
| 翻页提交（_commitPageTurn） | `BookImageStore.prewarmManifest(target.hrefs)` | 目标页图片全部终态后才 release 定格 |
| shader 加载完成 | 预热 current | 启动即热 |

> 邻居页（next/prev）快照预热已**废除**：collapse 不消费 reveal 纹理（层1 矢量直绘）；ripple revealPageImage 自 v16.9.3 亦不被 paint 消费。翻页提交后旧目标页实例成为新当前页——按页键控天然命中，无需显式预热。

---

## 8. 排队与互斥体系

### 8.1 互斥旗标

| 旗标 | 持有者 | 防御 |
|---|---|---|
| `_turnEndInFlight` | onDragEnd 自身 / tap autoPlay / deferred 补跑 | 动画在途时飘来的 drag-end 穿透 → animateSnapBack 内部 stop() 打断在途动画 = 「动画消失」（2026-09-04 根因） |
| `_isActive` | _startTurnAnimated 同步置位至 _resetState | 手势重入守卫（startDrag/onTapTurn） |
| `_commitInFlight` / `_holdingFinalFrame` | 提交链路 | 提交窗口期新手势/点击 |
| `onDragUpdate.isAnimating` 守卫 | 拖拽驱动入口 | `AnimationController.value setter = 隐式 stop()`——拖拽位移静默杀死动画 |

### 8.2 点击排队 `_queuedTapTurn`（覆盖式单槽）

- 入队：onTapTurn 被守卫拒绝 / 在途 drag-end 带翻页意图
- 消费：`_releaseSettled`（release）/ snapback / aborted 三个复位点 → `_maybeRunQueuedTurn`（postFrame）→ 完整门控重放
- 只保留最后一次意图：快速连点 ≈ 每个动画周期至多补一翻

### 8.3 挂起 pending 三态（帧未就绪）

- timer 超时（动态：tap 400 / drag 600 + 复杂度加成，上限 2000ms）回调三态：
  - busy（新手势在途）→ 安全丢弃
  - 门控 Ready → `_startTurnAnimated` 补跑**完整动画**（坍塌中心用挂起时登记的真实点击坐标）
  - 仍 Wait → 重挂；OutOfRange → 直翻
- tap 轮次上限 `_tapWaitRounds`（3 轮 ~1.2s 后直翻；**独立计数**——`_clearPending` 每轮重置 `_pendingRetryCount`，轮次无法用它累计）
- drag 上限 `_pendingRetryLimit`（5 次 register）
- 快照门控窗口（controller null）内手指抬起：`_pendingDragEndShouldTurn` 挂起，启动后补跑（否则冻结在 0 进度）

---

## 9. 提交与定格

```
_runAuto(true)
  └ animateTurn()（false=被打断 → turn.aborted + _resetState，不提交）
  └ _commitPageTurn
      ├ _settledFrame = 目标帧（定格：动画末帧内容 == 目标帧）
      ├ _holdingFinalFrame=true; _commitInFlight=true
      ├ notifier.nextPage/previousPage(preloaded: 目标)   ← 带预载页免 FFI
      ├ BookImageStore.prewarmManifest(目标 hrefs)        ← 图片全终态才 release
      └ finally: turn.commit trace（state 是否同步到目标）
didUpdateWidget → _settledMatchesCurrentPage（identity/三元等价）
  → _scheduleFinalFrameRelease → _releaseSettled → _resetState → _maybeRunQueuedTurn
兜底：_settledSafetyTimer 1500ms 强制释放
```

---

## 10. 诊断 trace 清单

| trace | 语义 |
|---|---|
| `turn.gate.wait/outOfRange/ready` | 门控判定与原因 |
| `turn.snapshot {ok,waitMs,page}` | 快照门控耗时（常态 fast-path 不打；waitMs>60 需关注） |
| `turn.wait {waitMs}` | 挂起登记到真正启动 |
| `turn.pending.timeout/retry` / `turn.drop {reason}` | 挂起重试与保功能直翻（retry-limit/tap-wait-rounds-limit/timeout-busy/end-during-pending） |
| `turn.queued` / `turn.queued.run` / `turn.end.swallowed` | 排队与互斥吞掉 |
| `turn.drag-end.pending/deferred` | 快照窗口内抬手的挂起补跑 |
| `turn.aborted {reason: ticker-canceled}` | 动画被打断（出现即异常，必有 cancel 源） |
| `turn.commit {state, matchesState}` | 提交落地真值 |
| `collapse.paint.frame/slow` / `ripple.paint.frame/slow` | 渲染帧与慢帧（>8ms） |

---

## 11. 工程硬约束（动画域，违反即出 Bug）

1. **裸 `await animateTo()/forward()` 是挂死陷阱**——被 stop()/value 赋值/dispose 取消后 TickerFuture 永不完成；必须 `.orCancel` + catch，并把「是否完整播完」显式传回调用方决策
2. **`AnimationController.value` 赋值 = 隐式 `stop()`**——一切可能发生在动画期间的 dragTo 入口必须挡 `isAnimating`
3. **「非空闲」≠「可拖拽」**——非空闲含拖拽中与动画中两种相位，只有前者接受 dragTo
4. **tap 自动播放与 drag 收尾同等持有 `_turnEndInFlight`**——否则在途动画被飘来 drag-end 杀死
5. **短路/fallback 直绘必须与正式渲染逐像素同源**（纸色底 + notifier 渲染参数）
6. **快照缓存键 = 内容的真实依赖**（实例身份+参数+尺寸），生命周期概念（revision）不得作内容键
7. **快照生成必经串行链**，dispose 恒「先赋值新再释放旧」；链内禁止再入链
8. **jitter/时序偏移恒减法**（只推迟不提前），防止旧页侧抢跑
9. **shader uniform 布局由声明顺序决定**，GLSL 改动必须同步 Dart setFloat 索引
10. **shader 改动必须完整构建**（不能热重载）；纯 Dart 可热重启
11. **调慢动画时长 = 时序竞态的时间放大镜**——新动画/新时长上线后重审所有「窗口很短不会被重入」的隐式假设

---

## 12. 已知边界与下一步候选

| # | 候选 | 说明 |
|---|---|---|
| 1 | ~~设置持久化~~ | ✅ P1 落地（drift AppSettings 表，翻页模式/速度/坍塌参数/主题重启恢复） |
| 2 | ~~坍塌参数设置化~~ | ✅ P1 落地（CollapseStyle block/slide/shadow 设置面板即时生效） |
| 3 | ~~暗黑主题~~ | ✅ P1 落地（ReaderTheme light/dark 色板 + 缓存键主题分量） |
| 4 | ~~ripple 遗留清理~~ | ✅ A23 删除：revealPageImage / buildSimulation 家族 / RipplePainter v15（shader 失败降级改 curl 直绘）；PageFlipSession 与 viewport 只写链一并清退 |
| 5 | Android 真机验证 | 手势坐标系/dpr/toImage 性能（本体系全部在 Windows 验证） |
| 6 | 拖拽坍塌中心插值 | 拖拽中坍塌中心恒为松手点/起手点，可做实时触点跟随 |
| 7 | 速度档位平滑 | easeOutCubic 全档共用；慢档可考虑线性尾段避免「结尾拖沓感」 |

> **A23 清理记录（2026-09-05）**：动画域死代码清退 ~1120 行——buildSimulation
> 家族（基类已走 animateTo+easeOutCubic）、revealPageImage（paint 零消费）、
> PageFlipSession（M9.5 未接线早期方案，互斥旗标即现状权威）、RipplePainter
> v15（无纸色底/无渲染参数，违反硬约束 5；shader 失败降级改 curl 直绘）、
> ReaderRenderViewport 只写链（零订阅者）。硬约束 1-11 不受影响。
