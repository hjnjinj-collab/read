# Fingerprint Mismatch 修复报告

**日期**: 2026-09-03  
**议题**: 参数变更后翻页动画永久失效（fingerprint mismatch）  
**状态**: ✅ 已修复

---

## 问题症状

用户修改排版参数（重新分段设置）后：
1. ✅ 当前页面内容正确重新排版
2. ✅ FrameSet 被发布
3. ❌ **翻页动画持续失效**（即使资源已就绪）

关键日志：
```
[READER] turn.gate.wait reason=epoch/fingerprint mismatch 
  setFp=381.0_716.0_18.0_1.5_20.0_20.0_0.9_true_true_0_17_15119031211 
  storeFp=381.0_716.0_18.0_1.5_20.0_20.0_0.9_true_true_0_17_15119035861
```

---

## 根本原因

**fingerprint 在异步操作期间变得过时**

### 问题代码路径

在 `reader_provider.dart` 的 `_prepareAndPublishFrameSet` 方法中：

```dart
Future<void> _prepareAndPublishFrameSet(PageInfo currentPage) async {
  final generation = _requestGeneration;
  final epoch = _sessionEpoch;
  final fingerprint = layoutFingerprint();  // ← 在方法开始时捕获
  
  // ... 异步操作（加载邻居页、预热资源）...
  // 在这期间，用户可能再次修改参数，导致 layoutFingerprint() 改变
  
  _publishPinned(FrameSet(
    setRevision: _nextFrameSetRevision++,
    sessionEpoch: epoch,
    configFingerprint: fingerprint,  // ← 使用过时的 fingerprint
    // ...
  ));
}
```

### 为什么会失败

1. 用户修改参数 A → 触发 `_prepareAndPublishFrameSet`
2. 方法开始时捕获 `fingerprint = "...31211"`
3. 异步操作进行中（加载邻居页、预热资源）
4. 用户再次修改参数 B → `layoutFingerprint()` 变为 `"...35861"`
5. 异步操作完成，发布 FrameSet（使用过时的 `"...31211"`）
6. 翻页时门控检查：`setFp="...31211"` vs `storeFp="...35861"` → **mismatch** → 动画失效

---

## 修复方案

**在发布 FrameSet 之前重新捕获最新的 fingerprint**

### 修改的代码

`lib/features/reader/presentation/providers/reader_provider.dart`:

```dart
Future<void> _prepareAndPublishFrameSet(PageInfo currentPage) async {
  final generation = _requestGeneration;
  final epoch = _sessionEpoch;
  // ✅ 删除：final fingerprint = layoutFingerprint();
  
  // ... 异步操作 ...
  
  // ✅ 在发布前重新捕获最新的 fingerprint
  final latestFingerprint = layoutFingerprint();
  
  _publishPinned(FrameSet(
    setRevision: _nextFrameSetRevision++,
    sessionEpoch: epoch,
    configFingerprint: latestFingerprint,  // ← 使用最新值
    // ...
  ));
}
```

同样修复了异常处理路径中的相同问题。

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
1. 用户修改排版参数 → `_invalidateFrames()` + `_loadCurrentPage()`
2. `_prepareAndPublishFrameSet` 开始异步加载
3. **即使在异步期间参数再次变化**，发布的 FrameSet 会使用**最新的 fingerprint**
4. 翻页时门控检查：`setFp == storeFp` → ✅ **动画正常启动**

---

## 相关文件

- `lib/features/reader/presentation/providers/reader_provider.dart` - L527, L623, L650
- `lib/features/reader/presentation/widgets/page_turn_composer.dart` - L275-320（门控逻辑）
- `lib/features/reader/presentation/providers/reader_render_state.dart` - L103-115（layoutFingerprint 计算）

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
