# 动画失效问题调试指南

**日期**: 2026-09-03  
**状态**: 🔍 需要详细日志诊断

---

## 当前情况

根据用户提供的日志，动画仍然失效。关键观察：

```
[READER] turn.start direction=PageDirection.next result=wait
[READER] turn.pending.register direction=PageDirection.next isTap=false epoch=2
[READER] turn.pending.timeout direction=PageDirection.next isTap=true timeoutMs=400
[READER] render.publish revision=12 ... prev=18/0#271561051/ready next=18/2#743625442/ready
```

**关键点**：
- ✅ FrameSet 已发布，资源状态 = `ready`（邻居页都是 ready）
- ❌ 但门控仍然返回 `wait`，导致超时直翻

---

## 已添加详细调试日志

我已经在 `page_turn_composer.dart` 的 `_targetFrameFor()` 方法中添加了详细的门控检查日志，现在每个失败条件都会输出具体原因：

```dart
if (set == null) {
  readerTrace('turn.gate.wait', {'reason': 'frameSet==null'});
  return const TargetWait();
}

if (set.sessionEpoch != store.sessionEpoch || ...) {
  readerTrace('turn.gate.wait', {
    'reason': 'epoch/fingerprint mismatch',
    'setEpoch': set.sessionEpoch,
    'storeEpoch': store.sessionEpoch,
    ...
  });
  return const TargetWait();
}

if (!set.current.identity.matchesPage(widget.currentPage)) {
  readerTrace('turn.gate.wait', {
    'reason': 'current identity mismatch',
    'setPage': '...',
    'widgetPage': '...',
  });
  return const TargetWait();
}

// ... 其他检查
```

---

## 需要重新测试

### 步骤

1. **运行 `fix_sync.ps1`** 重新编译
2. **修改排版参数**（重新分段、字号等）
3. **尝试翻页**（点击或拖拽）
4. **复制完整日志**

### 关键日志标识

请特别关注这些新增的日志：

```
[READER] turn.gate.wait reason=...
[READER] turn.gate.ready direction=...
[READER] turn.gate.outOfRange ...
```

这些日志会告诉我们**具体是哪个门控条件失败了**。

---

## 可能的根因假设

根据之前的日志分析，我有几个假设：

### 假设 1：`widget.currentPage` 与 `set.current.identity` 不匹配

**症状**：
```
turn.gate.wait reason=current identity mismatch
```

**原因**：
- `widget.currentPage` 是 Widget 的属性，从父组件传入
- `set.current.identity` 是 FrameSet 中的页面身份
- 如果两者不同步，门控会拒绝启动动画

**可能触发场景**：
- 参数变更后，页面重新加载
- Widget 重建时 `currentPage` 还是旧值
- FrameSet 已发布新页面，但 Widget 还没收到更新

### 假设 2：`sessionEpoch` 或 `configFingerprint` 不匹配

**症状**：
```
turn.gate.wait reason=epoch/fingerprint mismatch
```

**原因**：
- FrameSet 的 epoch/fingerprint 与 store 的不一致
- 可能是 FrameSet 发布时用的是旧值

### 假设 3：资源状态判定问题

**症状**：
```
turn.gate.wait reason=frame not usable
resourceState=FrameResourceState.pending
```

**原因**：
- 虽然日志显示 `ready`，但实际查询时仍是 `pending`
- 资源监控可能没有正确工作

---

## 下一步行动

取决于新日志的输出：

### 如果看到 `turn.gate.wait reason=current identity mismatch`

**修复方向**：
- 确保 Widget 的 `currentPage` 在 FrameSet 发布后同步更新
- 可能需要在 `_onModelPublished` 中强制刷新 Widget

### 如果看到 `turn.gate.wait reason=epoch/fingerprint mismatch`

**修复方向**：
- 检查 `_publishPinned` 中的 epoch/fingerprint 赋值
- 确保 FrameSet 创建时捕获的是正确的值

### 如果看到 `turn.gate.wait reason=frame not usable`

**修复方向**：
- 资源监控可能没有触发
- 需要检查 `_startResourceMonitoring` 的逻辑
- 可能需要更频繁的检查（50ms 而不是 100ms）

### 如果看到 `turn.gate.ready`

**那说明门控通过了！** 问题可能在动画启动后的其他环节。

---

## 临时建议

在我们获得详细日志之前，有一个**临时解决方案**可以尝试：

### 方案：强制在资源就绪后刷新 Widget

在 `page_turn_composer.dart` 的 `_onModelPublished` 中添加强制刷新：

```dart
void _onModelPublished(ReaderRenderModel model) {
  if (!mounted || _isActive || _pendingDirection == null) return;
  
  // 🔧 临时修复：强制刷新 Widget 状态
  setState(() {});
  
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted || _isActive || _pendingDirection == null) return;
    _retryPendingTurn();
  });
}
```

这会强制 Widget 重建，确保 `currentPage` 是最新的。

---

## 总结

1. ✅ 已添加详细调试日志
2. 🔄 需要重新编译并测试
3. 📋 提供包含 `turn.gate.*` 的完整日志
4. 🎯 根据日志确定具体失败原因
5. 🔧 实施针对性修复

**请运行 `fix_sync.ps1` 并提供新的日志输出。**

---

**调试人**: Kiro AI Agent
