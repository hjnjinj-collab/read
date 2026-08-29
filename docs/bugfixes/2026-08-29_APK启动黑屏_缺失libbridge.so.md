# Bug 修复报告：APK 启动白/黑屏——缺失 `libbridge.so`（Rust 未为 Android 编译）

## 修复日期
2026-08-29

## 问题概述

`flutter build apk` 成功（产出 56 MB `app-release.apk`），但 Android 上**安装后启动白/黑屏卡死**，UI 永远不出现。

**前置上下文**：8-29 早上的 3 个修复（sqlite3 hook 走 source 模式、AGP 9 compileSdk=36、file_picker 12.x）让 APK 编译通过。

## 根本原因

`lib/main.dart:14-15` 在 `runApp` 之前同步 await Rust 初始化：

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BookService.init();   // ← 抛异常
  await _loadSystemFont();
  runApp(const ProviderScope(child: MyApp()));  // ← 永远不执行
}
```

`BookService.init()` → `RustLib.init()` 内部调 `ExternalLibrary.open('libbridge.so')`（`flutter_rust_bridge 2.x` codegen 出的 stem = `'bridge'`，源在 `lib/core/ffi/rust_bridge.dart/frb_generated.dart:67`）。

**APK 里根本没有 `libbridge.so`**——直接证据是 ZIP 列表：

```
lib/arm64-v8a/libapp.so        6016 KB  ← Flutter 引擎占位 so，不是 bridge
lib/arm64-v8a/libdartjni.so     128 KB
lib/arm64-v8a/libflutter.so   11472 KB
lib/arm64-v8a/libsqlite3.so    1685 KB
lib/armeabi-v7a/libapp.so      6609 KB
lib/armeabi-v7a/libdartjni.so    80 KB
lib/armeabi-v7a/libflutter.so   8414 KB
lib/armeabi-v7a/libsqlite3.so   1641 KB
lib/x86_64/libapp.so            6209 KB
lib/x86_64/libdartjni.so        114 KB
lib/x86_64/libflutter.so       12745 KB
lib/x86_64/libsqlite3.so        1694 KB
```

`libapp.so` 是 Flutter Android Engine 的占位 so（6 MB，含 Flutter 引擎绑定），**不是**用户的 Rust bridge 库。

`ExternalLibrary.open('libbridge.so')` 抛 `ArgumentError: Failed to load dynamic library 'libbridge.so'` → `main()` 异常 → `runApp` 从未执行 → Android 显示 MainActivity 的默认背景（白屏或黑屏，看主题）。

## 缺失原因（链式）

| # | 缺失环节 | 证据 |
|---|---------|------|
| 1 | `build_apk.ps1` **没有 Rust 编译步骤** | 脚本全文只跑 `flutter clean / pub get / 修补 pub cache / flutter build apk`，无 `cargo build` |
| 2 | 之前 `fix_sync.ps1` 只为 Windows 服务 | 步骤 6 = `cargo build --release`（默认 `x86_64-pc-windows-msvc`），无 Android target |
| 3 | `rust/target/aarch64-linux-android/release/` 不存在 | `ls rust/target/aarch64-linux-android/` 只有 `debug/`，无 `release/`（debug 是之前手动调试的产物） |
| 4 | Flutter Gradle Plugin **不编译 Rust** | `D:\android\flutter\packages\flutter_tools\gradle\src\main\kotlin\*.kt` 全无 `cdylib` / `cargo` 字符串——Rust 编译对 AGP 完全透明 |
| 5 | `flutter_rust_bridge` 2.x 没自动 cargo 调用 | 文档要求手动 `cargo build --target <android-abi>` 后复制到 `jniLibs/` |

## 解决方案

**给 `build_apk.ps1` 加 Rust Android 4 ABI 编译 + jniLibs 拷贝**：

1. **安装 `cargo-ndk`**（一次性）：`cargo install cargo-ndk`
2. **4 ABI 编译**：`cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -o android/app/src/main/jniLibs/ build --release`
3. **`build_apk.ps1` 流程**（`flutter build apk` 自动把 `jniLibs/<abi>/libbridge.so` 打进 APK `lib/<abi>/`）

### `build_apk.ps1` 新流程（5 步）

```
[1/5] 设置环境变量（JAVA_HOME / NDK / pub 镜像）
[2/5] flutter_rust_bridge_codegen generate（重生成 FFI 绑定以防 API 漂移）
[3/5] cargo ndk -t <4 ABIs> -o android/app/src/main/jniLibs/ build --release
      （用 NDK 27 toolchain 编 libbridge.so，输出 4 个 ABI 到 jniLibs/）
[4/5] 修补 pub cache plugin build.gradle（compileSdk 36）
[5/5] flutter build apk
```

### 关键配置

**`android/app/build.gradle.kts` 已硬编 `compileSdk = 36`**（之前 8-29 修过）—— 满足 plugin AAR metadata 校验。

**`pubspec.yaml` 锁定 `flutter_rust_bridge: 2.12.0`**—— 不同小版本 `stem` 命名可能不同。

### Rust 依赖对 NDK 编译的兼容性

`rust/Cargo.toml` 依赖里有 C 系统库：`rusqlite 0.31 features=["bundled"]`（自带 sqlite3）、`rquickjs`（quickjs C）、`ab_glyph`、`openssl-sys`、`bzip2-sys`、`zstd-sys`。**`cargo-ndk` 自动用 NDK clang + 交叉编译工具链**链接 C 库，**不需要手动配置**——但首次 `cargo build` 会下载 NDK 工具链内的 C 库源（quickjs ~3 MB，bzip2/zstd 小），**总首次编译时间 ~25 分钟**（4 ABI 并行编译），二次增量 ~2 分钟。

### 与 `sqlite3_flutter_libs` 的关系

`pubspec.yaml` 里 `sqlite3_flutter_libs: ^0.6.0+eol`（end of life，**不再打包 .so**）+ `hooks.user_defines.sqlite3: source: source`（让 sqlite3 Dart 包走 NDK 编译 4 ABI 的 `libsqlite3.so`）。

`libsqlite3.so`（NDK 编译的 sqlite C 3.53.0）和 `libbridge.so`（NDK 编译的 Rust bridge）是**两个独立 so**，互不冲突——前者给 Dart 端 `sqlite3` 包用，后者给 `flutter_rust_bridge` 用。

## 验证

修复后预期：
- `flutter build apk` 耗时增加 ~25 分钟（首次 Rust 4 ABI 编译）
- APK 大小从 56 MB → 预计 **80-100 MB**（4 ABI × ~12 MB `libbridge.so`）
- APK `lib/<abi>/libbridge.so` 出现
- Android 启动后**主 Activity 显示书架页**（不再是白/黑屏）
- 书架为空时显示 "书架为空" 占位（main.dart:222-240 现有逻辑）

## 备选方案（未采用）

### 方案 B：升级到 `flutter_rust_bridge` v2.13+ 看是否有自动 cargo 集成

未采用：v2.13+ 没有自动 cargo 集成，依然要手动 `cargo ndk` 或 `flutter_rust_bridge_cargo` 工具。

### 方案 C：把 `libbridge.so` 改名成 `libapp.so` 让 `libapp.so` 加载它

未采用：硬编码后 Flutter Engine 的 `libapp.so` 占位会被覆盖，可能引发符号冲突；且 `libbridge.so` 命名是 `flutter_rust_bridge` 的 contract，改名必须改 `stem: 'bridge'` → `stem: 'app'`，本质是同一个事。

### 方案 D：让 `RustLib.init()` 显式传 `externalLibrary: ExternalLibrary.open('libapp.so')`

未采用：`libapp.so` 是 Flutter 引擎 so，**不含 Rust bridge 符号**——`dlsym` 会失败。

## 相关文件

- `lib/main.dart:11-21`：`main()` 启动序列（不需要改——结构正确，问题是 bridge so 不在）
- `lib/core/ffi/book_service.dart:12-14`：`BookService.init()`（不需要改——只是 wrap）
- `lib/core/ffi/rust_bridge.dart/frb_generated.dart:66-71`：`kDefaultExternalLibraryLoaderConfig` 写死 `stem: 'bridge'`（**不要改**——这是 FRB contract）
- `flutter_rust_bridge 2.12.0/lib/src/loader/_io.dart:56`：`ExternalLibrary.open('lib$stem.so')` Android 路径
- `build_apk.ps1`：**新流程加 Rust 编译 + jniLibs 拷贝**
- `rust/crates/bridge/Cargo.toml`：`name = "bridge"` → `cdylib` → NDK 编译后输出 `libbridge.so`

## 预防/工程约束

**Flutter + Rust + Android 必备步骤**：
1. 安装 `cargo-ndk`：`cargo install cargo-ndk`（一次性）
2. `android/app/build.gradle.kts` 不需要 cargo 集成（FRB 不走 Gradle 编译 Rust）
3. `pubspec.yaml` 锁定 `flutter_rust_bridge` 主版本（不同主版本 `stem` 命名可能改）
4. `build_apk` 前必须有 `cargo ndk -t <4 ABIs> -o jniLibs/ build --release` 步骤
5. `jniLibs/<abi>/libbridge.so` 由 Flutter Gradle Plugin 自动打包到 APK `lib/<abi>/libbridge.so`

**调试技巧**：APK 黑/白屏第一时间 `adb logcat | grep -E "AndroidRuntime|flutter"`，**100% 是 `await init` 抛异常**。Windows 上能 build ≠ Android 上能跑——Rust ABI 不一样，**必须为每个 Android ABI 单独编译**。
