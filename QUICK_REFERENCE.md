# 快速参考：FFI 绑定和内容净化

**最后更新**: 2026-08-20  
**状态**: ✅ FFI 绑定已生成，待 Flutter 端验证

---

## 🚀 快速启动

### ⭐ 方法 1: 手动模式（推荐，最稳定）

```powershell
# Step 1: 设置 PATH（每个新终端都需要）
$env:Path += ";C:\Program Files\Git\usr\bin"

# Step 2: 编译 Rust
cd D:\android\example\legado_flutter\rust
cargo build --release --features js-engine

# Step 3: 复制 DLL 到 Flutter 构建目录
cd ..
New-Item -ItemType Directory -Force -Path "build\windows\x64\runner\Debug" | Out-Null
Copy-Item rust\target\release\bridge.dll build\windows\x64\runner\Debug\bridge.dll -Force

# Step 4: 运行应用
flutter run -d windows
```

### 方法 2: 使用 fix_sync.ps1

```powershell
cd D:\android\example\legado_flutter
.\fix_sync.ps1

# ⚠️ 如果最后一步 "flutter build windows" 失败，手动复制 DLL：
Copy-Item rust\target\release\bridge.dll build\windows\x64\runner\Debug\bridge.dll -Force
flutter run -d windows
```

---

## ⚠️ 已知问题：Native Assets 构建失败

**现象**：
```
Target build_hooks failed : error : Building native assets failed
error MSB8066: 自定义生成已退出，代码为 1
```

**根本原因**（参考 `docs/BUG_FIXES.md` #7）：
1. **DLL 路径问题已解决**：`fix_sync.ps1` 第 7 步已复制 DLL
2. **Flutter Native Assets 自动构建失败**：
   - `flutter build windows` 尝试自动编译 Rust
   - PATH 环境变量未传递给 MSBuild 子进程
   - rquickjs-sys 编译失败（找不到 patch 命令）

**解决方案**：
- ✅ 使用 `flutter run -d windows`（跳过 native assets 构建）
- ✅ 手动复制 DLL 后再运行
- ❌ 不要使用 `flutter build windows`（会触发自动构建）

---

## 📝 在 Flutter 中使用

### 基本用法

```dart
import 'package:legado_flutter/core/ffi/rust_bridge.dart';

// 1. 创建选项
final options = ContentCleaningOptions(
  enableHtmlCleaning: true,          // 清理 HTML 标签
  enableAdRemoval: true,              // 删除广告
  enableSmartParagraphing: true,      // 智能分段
  enableWhitespaceCleanup: true,      // 清理空白
  enableTraditionalToSimplified: false, // 繁简转换（未实现）
);

// 2. 设置全局选项
await setContentCleaningOptions(options: options);

// 3. 读取章节（自动应用净化）
final content = await getChapterContent(
  bookId: bookId,
  chapterIndex: 0,
);

// 4. 清除选项（可选）
await clearContentCleaningOptions();
```

### 在阅读页面集成

**位置**: `lib/features/reader/presentation/providers/reader_provider.dart`

```dart
Future<void> openBook(String filePath, String bookName) async {
  try {
    // 启用内容净化
    final cleaningOptions = ContentCleaningOptions(
      enableHtmlCleaning: true,
      enableAdRemoval: true,
      enableSmartParagraphing: true,
      enableWhitespaceCleanup: true,
      enableTraditionalToSimplified: false,
    );
    await setContentCleaningOptions(options: cleaningOptions);
    
    // ... 原有的 openBook 逻辑 ...
  } catch (e) {
    print('启用内容净化失败: $e');
  }
}
```

---

## 🔧 常见问题

### Q: DLL not found 错误

```powershell
# 检查 DLL 是否存在
Test-Path build\windows\x64\runner\Debug\bridge.dll

# 手动复制
Copy-Item rust\crates\bridge\target\release\bridge.dll build\windows\x64\runner\Debug\bridge.dll -Force
```

### Q: Native Assets 构建失败

**这是已知问题**（参考 `docs/BUG_FIXES.md` #7 和 `docs/NATIVE_ASSETS_WORKAROUND.md`）

**根本原因**：
- `flutter build windows` 尝试自动编译 Rust
- PATH 环境变量未传递给 MSBuild 子进程
- rquickjs-sys 找不到 patch 命令

**解决方案**（已验证有效）：
```powershell
# 不要使用 "flutter build windows"
# 直接使用 "flutter run -d windows"
flutter run -d windows
```

或者手动复制 DLL：
```powershell
Copy-Item rust\target\release\bridge.dll build\windows\x64\runner\Debug\bridge.dll -Force
flutter run -d windows
```

**详细说明**: 参见 `docs/NATIVE_ASSETS_WORKAROUND.md`

### Q: 内容净化没有生效

**检查清单**:
1. ✅ 已调用 `setContentCleaningOptions()`
2. ✅ 在 `getChapterContent()` 之前设置
3. ✅ 测试文件包含需要净化的内容（HTML、广告）

---

## 📊 ContentCleaner 功能

| 功能 | 说明 | 状态 |
|------|------|------|
| HTML 清理 | 移除 `<div>`, `<p>`, `<span>` 等标签 | ✅ |
| 广告删除 | 删除常见广告文字 | ✅ |
| 智能分段 | 根据缩进和空行重新组织 | ✅ |
| 空白清理 | 移除多余空格和换行 | ✅ |
| 繁简转换 | 繁体转简体 | ⏳ 接口预留 |

---

## 📚 详细文档

1. **EXECUTION_SUMMARY.md** - 执行总结（当前状态）
2. **FFI_CODEGEN_SUCCESS.md** - 技术实现报告
3. **NEXT_STEPS_TESTING.md** - 测试指南和验证方案

---

## 🐛 调试命令

```powershell
# 检查 Rust 编译
cd rust
cargo check --package bridge

# 查看生成的 API
grep "ContentCleaningOptions" lib/core/ffi/rust_bridge.dart/api.dart

# 重新生成 FFI 绑定
$env:Path += ";C:\Program Files\Git\usr\bin"
flutter_rust_bridge_codegen generate --no-build-runner

# 查看 DLL 依赖
dumpbin /dependents build\windows\x64\runner\Debug\bridge.dll
```

---

## ⚡ 性能指标

| 指标 | 预期 | 实测 |
|------|------|------|
| Rust 编译时间 | < 2 min | ~1m 15s |
| 小章节净化 (< 10KB) | < 50ms | 待测试 |
| 中等章节 (10-50KB) | < 100ms | 待测试 |
| 大章节 (> 50KB) | < 200ms | 待测试 |

---

## ✅ 验证清单

使用前请确认：

- [ ] Rust DLL 已编译（`rust/crates/bridge/target/release/bridge.dll` 存在）
- [ ] DLL 已复制到 Flutter 构建目录
- [ ] Flutter 应用可以启动
- [ ] 在代码中调用 `setContentCleaningOptions()`
- [ ] 准备了包含 HTML/广告的测试文件

---

## 🎯 下一步

1. **立即**: 在 `reader_provider.dart` 中集成内容净化
2. **测试**: 打开测试文件，验证净化效果
3. **优化**: 根据测试结果调整参数
4. **扩展**: 创建设置页面（可选）

---

**遇到问题？** 查看 `docs/NEXT_STEPS_TESTING.md` 的常见问题排查部分。
