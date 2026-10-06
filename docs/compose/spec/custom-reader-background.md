---
feature: custom-reader-background
status: delivered
updated: 2026-10-01
branch: master
commits: 3a55517..HEAD
---

# 自定义阅读背景（用户壁纸 + 蒙版强度）

## Report

**What was built** — 设置「背景」区新增「自定义」瓦片：系统相册选图后拷入 `{appDocs}/backgrounds/custom_bg.*` 持久化，与 24 套内置同级可切换/取消。`BgImageStore` 支持 `custom` 伪 id 与 `file:` 路径解码。背景图（内置/自定义）可调**蒙版强度**滑杆 0–100%（默认 35%），`scrimAlpha = strength × paperOpacity` 夹取 0.05–0.85，保证正文可读。路径与强度入 `reader_settings`（`bgCustomPath` / `bgScrimStrength`）。

**Verification** —
- `flutter test test/paper_tint_test.dart`：PASS 18/18（含 scrimAlpha 夹取）
- `flutter analyze --no-pub`：无 error
- arm64 APK 构建通过

**Journey log** —
- file_picker 12.x 无 `bytes` 字段，须经 `path` 读文件
- 自定义图单张同时用于日/夜；双图后置
- 蒙版默认 0.35（高于旧 0.22），照片底更花

## [S1] Problem

## [S1] Problem

内置 24 套明暗背景已可切换，但用户不能用**自己的图片**当阅读底；正文可读性靠固定纸色罩（α≈0.22），无法按图调节。

## [S2] Design

### 目标

| 能力 | 行为 |
|------|------|
| 自定义壁纸 | 设置「背景」区选图（系统相册/文件），拷入应用目录持久化 |
| 选中/取消 | 自定义瓦片与内置 24 套同级；再点取消回纯色纸 |
| 蒙版强度 | 滑杆 0–100% 调纸色罩透明度，作用于当前背景图（内置/自定义） |
| 明暗 | 自定义图**单张**同时用于日/夜（不提供双图） |

### 合同

**A. 自定义图存储**

- `FilePicker` 选图片 → 复制到 `{appSupport}/backgrounds/custom_bg.*`（覆盖旧的）。
- `BgImageStore` 支持 `custom` 伪 id：从文件路径解码，不走 `rootBundle`。
- 失败（取消/非图/解码失败）Snackbar 提示，不改变当前背景。

**B. 蒙版**

- 绘制：图 `BoxFit.cover` 铺满 + 纸色罩 `alpha = scrimStrength × paperOpacity`，clamp 0.05–0.85。
- 默认 0.35（略高于旧 0.22，自定义照片通常更花）；持久化 `bgScrimStrength`。

**C. 持久化（`reader_settings`）**

- `bgImagePreset`：`''` | 内置 id | `'custom'`
- `bgCustomPath`：String（空=未设）
- `bgScrimStrength`：double 0–1

**D. UI**

- 网格首个「纯色纸」后加「自定义」瓦片（占一格，显示缩略或图标）。
- 选中背景图时显示「蒙版强度」滑杆。

### 测试

- 蒙版 alpha 计算：strength 0/0.35/1 与 paperOpacity 夹取。
- `BgImageStore`：custom 路径解码失败返回 null 不抛。

## [S3] Out of Scope

- 多张自定义壁纸库/相册管理。
- 明暗双图自定义。
- 背景模糊/景深/动态壁纸。

## Tasks

- [x] T1: BgImageStore 支持 custom 文件路径 — acceptance: 本地图片可解码显示 (covers: S2)
- [x] T2: 设置页选图 + 蒙版滑杆 + 持久化 — acceptance: 选图后阅读底为该图；滑杆改罩浓度并重启保持 (covers: S2; depends: T1)
- [x] T3: 测试/构建收口 — acceptance: 测试过；APK 可装 (covers: S2; depends: T1,T2)
