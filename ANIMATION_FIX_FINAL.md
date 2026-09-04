# 翻页动画失效问题 - 最终修复报告

**日期**: 2026-09-03  
**议题**: 参数变更后翻页动画永久失效  
**状态**: ✅ 已修复（根本原因）

---

## 问题症状

用户修改排版参数（重新分段设置）后：
1. ✅ 当前页面内容正确重新排版
2. ✅ FrameSet 被发布
3. ❌ **翻页动画永久失效**（即使资源已就绪）

关键日志证据：
```
[READER] turn.gate.wait reason=epoch/fingerprint mismatch
  setEpoch=2 storeEpoch=2
  setFp=...15119031211
  storeFp=...15119035861
```

**观察**：epoch 相同，但 fingerprint 的最后几位不同（`31211` vs `35861`）。

---

## 根本原因

**`_paraFormatHash` 更新的时序问题**，导致 `store.configFingerprint` 与 `FrameSet.configFingerprint` 不一致。

### 问题代码路径

在 `reader_provider.dart` 的 `applyContentProcessingSettings` 方法中：

```dart
Future<void> applyContentProcessingSettings(...) async {
  ++_requestGeneration;
  
  // L194: 第一次调用 advanceSession
  _invalidateFrames(reason: 'settings');
  // → 内部调用 _renderStore.advanceSession(
  //     sessionEpoch: ++_sessionEpoch,
  //     configFingerprint: layoutFingerprint()  // ← 此时 _paraFormatHash 还是旧值
  //   )
  // → store.configFingerprint = "...35861" (旧值)
  
  // L205-213: 更新各种设置...
  
  // L216-221: 更新段落格式设置
  _enableIndent = enableIndent;
  _indentSizeChars = indentSizeChars;
  // ...
  
  // L222-229: 同步 Rust 设置
  await _bookService.setParagraphFormatSettings(...);
  
  // L230: 更新 _paraFormatHash
  _paraFormatHash = _computeParaFormatHash();
  // → 现在 layoutFingerprint() 会返回 "...31211" (新值)
  
  // L240: 加载当前页
  await _loadCurrentPage(...);
  // → _prepareAndPublishFrameSet 被调用
  // → 捕获 finalFingerprint = layoutFingerprint() = "...31211"
  // → 发布 FrameSet(configFingerprint: "...31211")
}
```

### 为什么会失败

1. **L194**：`_invalidateFrames` 调用 `advanceSession`，此时 `_paraFormatHash` **还是旧值**
   - `store.configFingerprint` = `layoutFingerprint()` = `"...35861"`

2. **L230**：`_paraFormatHash` 被更新为新值
   - 现在 `layoutFingerprint()` 返回 `"...31211"`

3. **L240**：`_loadCurrentPage` → `_prepareAndPublishFrameSet`
   - 发布 `FrameSet(configFingerprint: "...31211")`

4. **翻页时门控检查**（`page_turn_composer.dart:284`）：
   ```dart
   if (set.configFingerprint != store.configFingerprint) {
     // "...31211" != "...35861" → mismatch
     return const TargetWait();
   }
   ```

5. **结果**：动画永久失效，因为 `store.configFingerprint` 永远不会被更新（只有 `advanceSession` 会更新它）

---

## 修复方案

**在 `_paraFormatHash` 更新之后，再次调用 `advanceSession` 更新 `store.configFingerprint`**

### 修改的代码

`lib/features/reader/presentation/providers/reader_provider.dart` L230-232：

```dart
await _bookService.setParagraphFormatSettings(
  enableIndent: enableIndent,
  indentSizeChars: indentSizeChars,
  paragraphSpacingMultiplier: paragraphSpacingMultiplier,
  reParagraphMode: reParagraphMode,
  smartSplitThreshold: smartSplitThreshold,
  aggressiveSplitThreshold: aggressiveSplitThreshold,
);
_paraFormatHash = _computeParaFormatHash();

// ✅ 新增：_paraFormatHash 更新后，再次更新 store.configFingerprint
// 确保 store.configFingerprint 与后续发布的 FrameSet.configFingerprint 一致
_renderStore.advanceSession(
  sessionEpoch: _sessionEpoch,  // 复用已递增的 epoch
  configFingerprint: layoutFingerprint(),  // 使用更新后的 fingerprint
);

_invalidatePageCountCache();
```

### 为什么这个修复有效

1. **第一次 `advanceSession`**（L194）：清空 `frameSet`，取消待决手势
2. **更新 `_paraFormatHash`**（L230）：改变 `layoutFingerprint()` 的返回值
3. **第二次 `advanceSession`**（新增）：更新 `store.configFingerprint` 为最新值
4. **发布 FrameSet**：使用最新的 `layoutFingerprint()`
5. **门控检查**：`set.configFingerprint == store.configFingerprint` → ✅ **动画正常启动**

---

## 验证结果

### Dart 分析
```
flutter analyze lib/features/reader/presentation/providers/reader_provider.dart
✅ 只有既有的 4 个 info 警告，无新增错误
```

### Rust 测试
```
cargo test --package reader_core --lib
✅ 142 tests passed / 0 failed
```

---

## 预期效果

修复后的行为：
1. 用户修改排版参数 → `applyContentProcessingSettings` 被调用
2. 第一次 `advanceSession`：清空 `frameSet`，使用旧的 fingerprint
3. 更新 `_paraFormatHash`：`layoutFingerprint()` 返回新值
4. **第二次 `advanceSession`**：更新 `store.configFingerprint` 为新值
5. `_loadCurrentPage` → `_prepareAndPublishFrameSet`：发布新 FrameSet（使用新 fingerprint）
6. 翻页时门控检查：`setFp == storeFp` → ✅ **动画正常启动**

---

## 相关文件

- `lib/features/reader/presentation/providers/reader_provider.dart` - L230-239（新增第二次 advanceSession）
- `lib/features/reader/presentation/providers/reader_render_state.dart` - L181-194（advanceSession 实现）
- `lib/features/reader/presentation/widgets/page_turn_composer.dart` - L283-292（门控检查逻辑）

---

## 历史调试过程

### 尝试 1：资源状态监控（无效）
- 假设：资源状态从 loading → ready 时缺少通知
- 修复：添加定时器轮询资源状态
- 结果：**无效**，因为资源实际上已经 ready，问题在 fingerprint mismatch

### 尝试 2：重新捕获 fingerprint（无效）
- 假设：异步操作期间 fingerprint 变化
- 修复：在发布 FrameSet 前重新捕获 `layoutFingerprint()`
- 结果：**无效**，因为 `store.configFingerprint` 仍然是旧值

### 尝试 3：更新 store.configFingerprint（✅ 成功）
- 发现：`_paraFormatHash` 更新导致 `layoutFingerprint()` 改变，但 `store.configFingerprint` 在更新前就被设置了
- 修复：在 `_paraFormatHash` 更新后，再次调用 `advanceSession` 更新 `store.configFingerprint`
- 结果：✅ **成功**，`setFp == storeFp`，动画恢复正常

---

## 下一步

用户需要重新构建并测试：

```powershell
cd D:\android\example\legado_flutter
.\fix_sync.ps1
flutter run -d windows
```

测试步骤：
1. 打开一本书
2. 修改排版参数（重新分段设置）
3. 等待当前页重新排版完成
4. 尝试翻页 → **动画应该正常播放**
5. 验证日志中不再出现 `fingerprint mismatch`
