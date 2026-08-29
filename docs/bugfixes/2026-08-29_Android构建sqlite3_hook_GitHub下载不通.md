# Bug 修复报告：Android APK 构建 sqlite3 hook 拉取 GitHub 预编译 .so 失败

## 修复日期
2026-08-29

## 问题概述

`flutter build apk`（release 模式）跑到 `compileFlutterBuildRelease` 任务时，**`sqlite3` Dart 包的 build hook** 试图从 GitHub 下载预编译 SQLite C 库：

```
Building assets for package:sqlite3 failed.
build.dart returned with exit code: 255.

Unhandled exception:
  By default, this package downloads a pre-compiled SQLite library.
  This failed (attepted to download https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.5.1/libsqlite3.arm.android.so).
  For alternatives to downloading SQLite, see https://pub.dev/documentation/sqlite3/latest/topics/hook-topic.html

Original cause: HttpException: 信号灯超时时间已到, uri = https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.5.1/libsqlite3.arm.android.so
```

**触发条件**：在墙内网络环境（GitHub 直连不通）构建 Android release。

**影响**：APK 构建从 17 秒（hook 失败）卡在 native asset build 阶段——前 41 分钟解决了其他依赖，最后才暴露这个 GitHub 网络问题。

## 根本原因

`sqlite3 3.5.1` Dart 包的 `hook/build.dart` 默认走 `PrecompiledFromGithubAssets` 路径，构造下载 URL：

```
https://github.com/simolus3/sqlite3.dart/releases/download/$RELEASE_TAG/$FILENAME
```

`$RELEASE_TAG = sqlite3-3.5.1`，`$FILENAME` 是 `libsqlite3.{arm,arm64,x86_64}.android.so`。`HttpException: 信号灯超时` 是 Windows 套接字层对 GitHub TLS 握手的超时——墙内到 `github.com` 的 443 端口路由被重置或丢包。

**注意**：`sqlite3 3.5.1` 是 **Dart 包版本**，不是 SQLite C 库版本——包内用的是 **SQLite C 3.53.0**（`CHANGELOG.md` 标注）。`RELEASE_TAG` 用 Dart 包版本命名，与 SQLite C 版本无关。

## 解决方案

**改 hook 走 `source` 模式**：用本地源码 + NDK 27 编译 libsqlite3.so（完全离线、镜像无关）。

### 步骤 1：下载 amalgamation 源码

```bash
# 实际 SQLite C 3.53.0 对应 amalgamation
# sqlite.org 直连国内通常可用；不通时用 ghfast 镜像
# file_picker 12.x 解决后，sqlite3 沿用同一镜像策略即可
curl -L -o D:\dowland\sqlite-amalgamation-3530000.zip \
  https://sqlite.org/2026/sqlite-amalgamation-3530000.zip
```

或从 `https://ghfast.top/...` 镜像。

### 步骤 2：解压并放到项目内（.gitignore 忽略）

```bash
# 解压得到 4 个文件（sqlite3.c / sqlite3.h / sqlite3ext.h / shell.c）
tar -xf D:\dowland\sqlite-amalgamation-3530000.zip \
  -C D:\dowland\sqlite-amalgamation-3530000

# 复制到项目内
New-Item -ItemType Directory D:\android\example\legado_flutter\.native_assets\sqlite3 -Force
Copy-Item D:\dowland\sqlite-amalgamation-3530000\sqlite-amalgamation-3530000\sqlite3.* `
  D:\android\example\legado_flutter\.native_assets\sqlite3\

# 加 .gitignore 避免 10 MB 进 git
Add-Content D:\android\example\legado_flutter\.gitignore ".native_assets/"
```

### 步骤 3：pubspec.yaml 用 hooks.user_defines 注入路径

```yaml
# pubspec.yaml
hooks:
  user_defines:
    sqlite3:
      source: source
      path: .native_assets/sqlite3/sqlite3.c
```

**关键坑**：路径必须是**相对路径**（基于 pubspec.yaml 所在目录），不是绝对路径。
- 绝对路径 `D:/dowland/.../sqlite3.c` 会被 `Uri.parse` 解析为 `d` scheme → `Uri.toFilePath()` 抛 `Cannot extract a file path from a d URI`
- 相对路径被 `userDefines.path('key')` 正确解析为 `file:///$projectPath/sqlite3.c`

### 步骤 4：验证

```bash
$env:ANDROID_NDK_HOME = "D:\android\ansdk\ndk\27.0.12077973"
cd D:\android\example\legado_flutter
flutter pub get
flutter build apk
```

hook 走 `CompileSqlite` 模式（`hook/build.dart:54-72`），调 `CBuilder.library(name: 'sqlite3', ...)` 用 NDK 工具链编译 4 个 ABI（armv7/arm64/x86_64）的 `libsqlite3.so`，打包进 APK 的 `lib/<abi>/`。

## 验证

- `flutter analyze`：23 issues（基线 0 错误 0 警告）
- `flutter test`：90 过 1 挂（基线）
- `flutter build apk`：从「hook 失败立即退出」推进到「Rust 编译 4 ABI + APK 打包」

## 备选方案（未采用）

### 方案 B：用 `url_pattern` 走 ghfast 镜像

`sqlite3` hook 的 `userDefines['url_pattern']` 可以覆盖默认 GitHub URL pattern：

```yaml
hooks:
  user_defines:
    sqlite3:
      url_pattern: https://ghfast.top/https://github.com/simolus3/sqlite3.dart/releases/download/$RELEASE_TAG/$FILENAME
```

走 `PrecompiledFromGithubAssets` 路径（不需要 NDK 编译，更快）。但**`ghfast.top` 稳定性未知**——该镜像服务是社区项目，可能变更或限流。**方案 A（本地源码 + NDK）更稳**。

### 方案 C：HTTP 代理

`sqlite3` hook 用 `HttpClient` 不读 `HTTP_PROXY`/`HTTPS_PROXY` 环境变量（dart:io 限制）。需要 patch hook 或写代理转发层，**复杂度高于方案 A**。

## 相关文件

- `pubspec.yaml`：`hooks.user_defines.sqlite3` 块
- `.gitignore`：`.native_assets/`
- `.native_assets/sqlite3/sqlite3.c` / `.h` / `ext.h`（本地源码，gitignore）
- `C:\Users\25644\AppData\Local\Pub\Cache\hosted\pub.dev\sqlite3-3.5.1\hook\build.dart`：默认 `PrecompiledFromGithubAssets` 路径（不改）

## 预防/工程约束

**墙内 Flutter Android release 构建**：任何 Dart 包用 `PrecompiledFromGithubAssets` 路径走 `github.com` 都会卡。**审计 pubspec 里所有 native asset 包的 hook 行为**——优先用 `source: source` 走本地编译 + NDK。`sqlite3` 用 `source` 模式是官方支持的 fallback（`hook/build.dart:54-72`）。

**`sqlite3`/`sqlite3_flutter_libs` 区别**：
- `sqlite3`：核心包，提供 hook，**在 native asset build 阶段**下载/编译 .so
- `sqlite3_flutter_libs`：Android 端把 .so 放到 `android/app/src/main/jniLibs/<abi>/`——但 `sqlite3_flutter_libs 0.6.0+eol`（end of life）**不再包含 .so**——`sqlite3` hook 才是权威来源
