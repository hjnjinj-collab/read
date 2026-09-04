# 翻页动画卡死：TickerFuture 裸 await 挂死 + 拖拽驱动劫持动画（三档速度引入后必现）

> 日期: 2026-09-04
> 影响: 水波纹翻页在「中档速度」（600ms）下动画随机卡死在途中某帧（如 progress=0.750），此后**所有翻页手势永久失效**，界面冻结在溶解中间态，只能重启恢复。快档（400ms）偶发、旧默认 300ms 几乎不复现——不是速度档位的 bug，而是**潜伏竞态被更长的动画窗口放大到必现**。
> 状态: ✅ 已解决（2026-09-04，用户实测通过）

---

## 症状

1. 切换到中档速度后，翻页动画播放到一半冻结（截图：方块溶解进行到 ~75% 处静止）
2. 日志特征：连续多条**相同 progress** 的 `ripple.paint.frame`（如 7 条 0.750），之后进度不再推进
3. 冻结后点击/滑动均无反应——翻页手势管线整体失灵

## 真正根因（双缺陷叠加）

### 根因 1（触发器）：`onDragUpdate` 不检查 `isAnimating` → 拖拽驱动劫持动画

`page_turn_composer.dart` 的拖拽更新入口只挡了 `_isActive`：

```dart
void onDragUpdate(double progress, Offset localTouch) {
  if (!_isActive || _turnController == null) return;  // 动画播放中 _isActive==true，放行！
  _turnController!.dragTo(progress.clamp(0.0, 1.0));
}
```

而 reader_page 的 `_onPointerMove` 只要 `isIdle == false` 就发 `updateDrag`——
**自动动画播放期间 `isIdle` 也是 false**（`!_isActive` 即 idle 的判定把"动画中"算进去了）。
于是：动画播放中用户第二次触摸的移动事件 → `dragTo` →
`AnimationController.value setter` → **setter 内部会 `stop()` 打断正在播放的收尾动画**（Flutter 语义）。

### 根因 2（放大器）：裸 `await animateTo` 在动画被打断时**永不完成**

`page_turn_controller.dart`：

```dart
await _controller.animateTo(to, duration: duration, curve: Curves.easeOutCubic);
```

Flutter 经典陷阱：`animateTo`/`forward` 返回的 `TickerFuture`，若动画被
`stop()` / value setter / dispose 打断，**这个 Future 永远不 complete**
（只有 `.orCancel` 变体才会以 `TickerCanceled` 异常终结）。

两者叠加的完整链路：

```
600ms 动画播放中
  → 第二次触摸 pointer-move → updateDrag → dragTo
  → AnimationController.value setter 内部 stop() → 动画被取消
  → _runAuto 的 await controller.animateTurn() 永不返回（挂死）
  → onDragEnd 的 finally 不执行 → _turnEndInFlight 永久 true
  → _isActive 永久 true
  → 后续所有手势被守卫吞掉（onDragStart/onTapTurn 的 _isActive/isAnimating 守卫）
  → 界面永久冻结在中途溶解帧
```

日志中 7 条相同的 `progress=0.750` 正是动画被劫持/打断的现场。

### 为什么 300ms 不卡、600ms 必卡

触发条件 = **第二次触摸落在动画播放窗口内**。300ms 窗口太短，人手几乎不可能
在收尾动画的 300ms 内再触摸；600ms 把窗口拉长一倍 → 必现。
**"调慢动画后暴露竞态"是此类时序 bug 的指纹**——新动画/新时长上线后，
所有假设"动画窗口很短不会被重入"的隐式约定都要重新审视。

## 修复方案（两层防御）

### 修复 1（根因）：动画中拒绝拖拽驱动

```dart
// page_turn_composer.dart onDragUpdate：
if (_turnController!.isAnimating) return;  // 自动动画播放中不接受 dragTo
```

### 修复 2（兜底）：`_animateTo` 用 `.orCancel` + 捕获 `TickerCanceled`，await 恒可完成

```dart
// page_turn_controller.dart _animateTo：
try {
  await _controller
      .animateTo(to, duration: duration, curve: Curves.easeOutCubic)
      .orCancel;
  return true;
} on TickerCanceled {
  return false;
}
```

- `animateTurn`/`animateSnapBack` 返回 `bool`（true=完整播完）
- `_runAuto` 收到 false 时：trace `turn.aborted` + `_resetState()` 复位回空闲，
  **不提交翻页**——杜绝"挂死"与"半途误提交"两种坏结局
- 即使未来出现新的动画打断源（新功能/新守卫缺口），管线也不会再死锁

## 教训（工程约束级）

1. **裸 `await controller.animateTo()/forward()` 是挂死陷阱**：被 stop()/value setter/
   dispose 取消后 TickerFuture 永不 complete。任何"await 动画完成后再提交"的管线
   必须 `.orCancel` + catch，并把"动画是否完整播完"显式传给调用方决策。
2. **`AnimationController.value` 赋值 = 隐式 `stop()`**：任何在动画期间可能被调用的
   拖拽驱动入口，必须显式挡住 `isAnimating`，否则拖拽会静默杀死动画。
3. **`isIdle == false` ≠ "可以驱动拖拽"**：合成器的非空闲态包含"拖拽中"和"动画中"
   两种相位，只有前者接受 dragTo。
4. 调慢动画时长是复现时序竞态的有效手段（等价于免费的时间放大镜）。

## 涉及文件

- `lib/features/reader/presentation/widgets/page_turn_composer.dart`
  （`onDragUpdate` 加 `isAnimating` 守卫；`_runAuto` 处理被打断的动画）
- `lib/features/reader/presentation/widgets/page_turn/page_turn_controller.dart`
  （`_animateTo` 改 `.orCancel` + `TickerCanceled` → 返回 bool；
  `animateTurn`/`animateSnapBack` 返回 `Future<bool>`）
- 关联功能：快/中/慢三档翻页速度（`PageTurnSpeed`，`page_turn_types.dart` /
  `ripple_turn_controller.dart` / `reader_menu.dart`）——本 bug 由该功能拉长动画窗口暴露

## 附：顺带清理的死代码发现

排查中发现 `RippleTurnController` 构造参数里的 `super(duration: 600ms)` 与
`_LinearSimulation`/`buildSimulation` 是**从未被调用的死代码**——基类早已改走
`animateTo` 路径（所有模式的实际动画时长都是其中的硬编码值）。已清理：
ripple 时长经覆写 `turnDuration` getter 生效；`buildSimulation` 保留抽象成员但
实现注明死代码。**此前 ripple 实际动画时长是 300ms 而非注释宣称的 600ms**。
