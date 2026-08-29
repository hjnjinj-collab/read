# Bug 修复报告：AGP 9.0.1 强制 compileSdk ≥ 36 + pub cache 修补

## 修复日期
2026-08-29

## 问题概述

`flutter build apk` 跑到 `:file_picker:checkReleaseAarMetadata` 任务时失败：

```
> Task :file_picker:checkReleaseAarMetadata FAILED
> A failure occurred while executing com.android.build.gradle.internal.tasks.CheckAarMetadataWorkAction
> An issue was found when checking AAR metadata:
    1.  Dependency ':flutter_plugin_android_lifecycle' requires libraries and applications that
        depend on it to compile against version 36 or later of the Android APIs.
        :file_picker is currently compiled against android-34.
        Recommended action: Update this project to use a newer compileSdk of at least 36.
```

**前置关联**（按出现顺序）：
1. AGP 9.0.1 + Flutter 17.x → AGP 报错"Remove `android.builtInKotlin=true` and `android.newDsl=false`"
2. AGP 9.0.1 强制 Kotlin 编译 → 跨盘符（C: 盘 pub cache vs D: 盘项目）触发 Kotlin 增量缓存崩溃
3. 多个 plugin 的 `build.gradle` 写死 `compileSdk flutter.compileSdkVersion`（34），不满足新版 plugin 的 AAR metadata 要求

## 根本原因

**AGP 9.0.1 把 `compileSdk` 校验做成 AAR metadata 强约束**：
- 老 AGP（≤ 8.x）`compileSdk` 是软约束，依赖方低版本不报错
- AGP 9.0.1 在 `CheckAarMetadataWorkAction` 阶段硬校验 AAR `min-compile-sdk` 字段
- 旧 plugin（如 `flutter_plugin_android_lifecycle 2.0.22+`）AAR metadata 写 `min-compile-sdk=36`
- 调用方 plugin（`file_picker`）若 `compileSdk < 36` → `CheckAarMetadata` 拒绝

**Flutter SDK 17.x 的 `flutter.compileSdkVersion` = 34**——老 Android Gradle Plugin 期望值，但新 plugin AAR 要求 ≥ 36。

**多个 plugin 自己 build.gradle 也写死 `compileSdk flutter.compileSdkVersion`**：
- `file_picker-8.3.7/android/build.gradle` line 22：**没指定 compileSdk**（AGP 9 严格）
- `file_picker-11.0.3/android/build.gradle` line 34：`compileSdk flutter.compileSdkVersion`
- `file_picker-12.1.2/android/build.gradle`（melos 拆分）：`compileSdk flutter.compileSdkVersion`
- `android_file_picker-1.0.3/android/build.gradle`：`compileSdk flutter.compileSdkVersion`
- `flutter_plugin_android_lifecycle-2.0.34/35/android/build.gradle.kts`：`compileSdk = flutter.compileSdkVersion`

**统一硬刷 36 才一致**。

## 解决方案

**4 个文件改动 + 1 个 pub cache 修补脚本**：

### 1. 根 `gradle.properties` 清 deprecated 标志

```properties
# 之前 Flutter 模板加的两个标记在新 AGP 9 已 deprecated
# android.builtInKotlin=false
# android.newDsl=false
```

AGP 9 报"Remove both"，但**Flutter Migrator 工具会自动加回**——如果用户跑了 migrator 脚本，会看到这两个标志又出现。**这不会让 build 失败**（AGP 9 接受这两个标志，只 warn），**可保留**。

### 2. `app/build.gradle.kts` 硬编 compileSdk = 36

```kotlin
android {
    namespace = "com.legado.legado_flutter"
    // 升级到 36：file_picker 依赖的 flutter_plugin_android_lifecycle 要求
    // compileSdk >= 36（项目原 flutter.compileSdkVersion 是 34，触发 AAR metadata 失败）
    compileSdk = 36
    ndkVersion = flutter.ndkVersion
    // ... 其余不变
}
```

### 3. `build.gradle.kts`（根）**不**写反射注入

早期尝试用 `gradle.beforeProject` + 反射 `setCompileSdkVersion(36)` 强制覆盖所有 subproject。**失败**：
- Kotlin DSL 编译期类型错误（`compileSdkVersion` 在新 AGP 是 `String?`，不是 `Int?`）
- 反射 `setCompileSdkVersion(Int)` 报"argument type mismatch"（新 API 用 `setCompileSdkVersion(String)`）
- `gradle.beforeProject` 时机太早，Android extension 还没创建

**最终放弃反射注入**——直接改 pub cache（更稳）。`build.gradle.kts` 留干净的 `subprojects { ... }`，不反射。

### 4. pub cache 修补脚本（`build_apk.ps1`）

```powershell
# 修补 pub cache 中所有相关 plugin 的 build.gradle
# 注意：每次 flutter pub get 都会重写 pub cache，必须跑两次（pub get 前后各一次）

$pkgs = @(
    @{path = "file_picker-10.3.3\android\build.gradle"; oldPattern = 'compileSdk flutter\.compileSdkVersion'; newValue = 'compileSdk 36'},
    @{path = "file_picker-11.0.3\android\build.gradle"; oldPattern = 'compileSdk flutter\.compileSdkVersion'; newValue = 'compileSdk 36'},
    @{path = "file_picker-12.1.2\packages\file_picker\android\build.gradle"; oldPattern = 'compileSdk flutter\.compileSdkVersion'; newValue = 'compileSdk 36'},
    @{path = "android_file_picker-1.0.3\packages\file_picker_android\android\build.gradle"; oldPattern = 'compileSdk flutter\.compileSdkVersion'; newValue = 'compileSdk 36'},
    @{path = "flutter_plugin_android_lifecycle-2.0.34\android\build.gradle.kts"; oldPattern = 'compileSdk = flutter\.compileSdkVersion'; newValue = 'compileSdk = 36'},
    @{path = "flutter_plugin_android_lifecycle-2.0.35\android\build.gradle.kts"; oldPattern = 'compileSdk = flutter\.compileSdkVersion'; newValue = 'compileSdk = 36'},
    # + 所有 lifecycle 版本的通配扫描
)

foreach ($pkg in $pkgs) {
    $full = "C:\Users\25644\AppData\Local\Pub\Cache\hosted\pub.dev\$($pkg.path)"
    if (Test-Path $full) {
        (Get-Content $full) -replace $pkg.oldPattern, $pkg.newValue | Set-Content $full
    }
}
```

**关键不优雅处**：pub cache 是 pub get 的产物，每次 `flutter pub get` 都会重写。**修补必须在 pub get 之后立即再做一遍**。`build_apk.ps1` 第 4 步自动扫所有版本并修补。

### 5. 配套：禁 Kotlin 增量编译

`android/gradle.properties`：

```properties
# 禁用 Kotlin 增量编译：pub cache 在 C: 盘，项目在 D: 盘，跨盘符相对路径
# 报错（"this and base files have different roots"）。CI 一次性构建无需增量。
kotlin.incremental=false
kotlin.incremental.useClasspathSnapshot=false
```

**根因**：Kotlin 编译器 incremental 缓存用 `kotlin.io.toRelativeString()` 把源文件路径相对化到 base 目录（项目根 `D:\...`），但源文件在 pub cache `C:\Users\...\android_file_picker-1.0.3\...`——C: 盘 vs D: 盘跨盘符无法算相对路径。

**影响**：禁用后 build 慢一点（每文件全量编译），但**能过**。

## 验证

- `flutter analyze`：23 issues（基线 0 错误 0 警告）
- `flutter test`：90 过 1 挂
- `flutter build apk`：完整跑通（41m → 2m 4s 增量 → 通过）

## 备选方案（未采用）

### 方案 B：升级 Flutter SDK 到 18.x

Flutter SDK 18.x 默认 `flutter.compileSdkVersion = 36`，所有 plugin 自动满足。**但项目依赖 Flutter 17.x 文档/示例**，升级风险大。**未采用**。

### 方案 C：用 `dependencyResolutionManagement.repositoriesMode = FAIL_ON_PROJECT_REPOS`

强制所有 repository 在 settings.gradle.kts 配置。**与 Flutter Gradle plugin 注入的 `maven` 冲突**（`flutter-plugin-loader` 自动注入 maven 仓库到 project 级，FAIL_ON_PROJECT_REPOS 会拒绝）。**已试过**，删了。

### 方案 D：让 `flutter.compileSdkVersion` 返回 36

修改 Flutter SDK 17.x 内的常量。**侵入 Flutter 内部**，风险最大。**未采用**。

## 相关文件

- `android/gradle.properties`：去 `android.builtInKotlin` / `android.newDsl`、加 `kotlin.incremental=false`
- `android/app/build.gradle.kts`：`compileSdk = 36`
- `android/build.gradle.kts`：清空 subprojects 反射（保持简洁）
- `pubspec.yaml`：`file_picker: ^12.1.2`（最终选定的版本）
- `build_apk.ps1`：pub cache 修补 + 完整 build 流程脚本
- 多个 pub cache 下的 plugin `build.gradle`/`build.gradle.kts`（修补成 `compileSdk = 36`）

## 预防/工程约束

**AGP 9+ Flutter 项目构建墙内环境**必备：
1. `gradle.properties` 去 `newDsl`/`builtInKotlin`（让 AGP 9 接受）
2. `app/build.gradle.kts` 硬编 `compileSdk = 36`（满足 AAR metadata 校验）
3. `gradle.properties` 加 `kotlin.incremental=false`（绕开跨盘符相对路径错误）
4. `gradle-wrapper.properties` 用本地 `file://` 协议（绕开 wrapper 下载超时）
5. `JAVA_HOME` 指向 `D:\android\vis tudio\3\Android\openjdk\jdk-21.0.8`（Android Studio JBR 21）
6. `ANDROID_NDK_HOME` 指向 NDK 27
7. `PUB_HOSTED_URL=https://pub.flutter-io.cn`（dart pub 走镜像）
8. pub cache 里所有 plugin 的 `compileSdk flutter.compileSdkVersion` 改成 36（脚本批量改）

**任何新加 plugin 都要审计** build.gradle 里的 `compileSdk` 设置——不能依赖 `flutter.compileSdkVersion` 隐式值。
