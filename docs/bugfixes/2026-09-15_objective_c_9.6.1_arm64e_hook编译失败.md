# Bug 修复报告：objective_c 9.6.1 引用不存在的 Architecture.arm64e

## 修复日期
2026-09-15

## 问题概述

`build.ps1` / `fix_sync.ps1` 在 Windows 构建阶段失败：

```
objective_c-9.6.1/hook/build.dart(222,16): error G75B77105: Member not found: 'arm64e'
objective_c-9.6.1/hook/build.dart(231,16): error G75B77105: Member not found: 'arm64e'
Target build_hooks failed : error : Building native assets failed.
```

Rust DLL 已编译成功，挂在 Flutter native assets hook 编译。

## 根本原因

- `path_provider` → `path_provider_foundation` → 传递依赖 `objective_c`
- `objective_c 9.6.1` 的 `hook/build.dart` 顶层 map 使用 `Architecture.arm64e`
- 已发布的 `code_assets 2.0.0` 的 `Architecture` 只有：
  `arm / arm64 / ia32 / riscv32 / riscv64 / x64`，**没有 `arm64e`**
- 9.6.1 在 monorepo 里对着未发布的 `code_assets`（path override）开发后直接发包，
  对 pub 上的 2.0.0 不兼容 → hook 脚本本身编不过（Windows 也会跑所有 hook 的编译）

`objective_c 9.6.0` 的 hook 只用字符串 `'arm64e'` 作 clang `-arch` 参数，
且仅在 iOS/macOS 的 testMode 分支，Windows 构建安全。

## 解决方案

`pubspec.yaml` 增加：

```yaml
dependency_overrides:
  objective_c: 9.6.0
```

然后 `flutter pub get`，再 `build.ps1 -SkipRust`。

## 预防

- 传递依赖的 native hook 若引用 `code_assets` 新 API，必须确认对应版本已发 pub
- 遇到 `Member not found` 在 `hook/build.dart`：优先钉旧版本，不要改 pub cache
  （`pub get` / 缓存修复会冲掉）
