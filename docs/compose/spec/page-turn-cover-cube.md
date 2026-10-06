---
feature: page-turn-cover-cube
status: delivered
updated: 2026-10-01
branch: master
commits: bf4467b..HEAD
---

# 翻页 Cover / Cube + 纹理清晰度

## Report

**What was built** — ①**清晰度**：快照 `_pageToImage` 改 **2×dpr 超采样**（边长 cap 4096；禁止把 scale clamp 到 dpr，否则高 dpr 机等于不超采样）；`ripple_shredder`/`block_collapse` 精度 `mediump`→`highp`。②**Cover 覆盖**：新页从方向侧滑入盖住旧页，旧页 scale 0.92 + 12% 暗罩，时长同快/中/慢三档。③**Cube 立方体**：Y 轴透视旋转（`Matrix4.setEntry(3,2,eye)`，eye=1/(w×1.2)），旧页转出/新页转入。设置「翻页方式」新增两项。

**Verification** —
- `flutter test test/reader_gesture_single_hand_test.dart`：PASS 7/7（超采样尺寸/Cover 位移/Cube 角）
- `flutter analyze --no-pub`：无 error
- arm64 APK 构建通过

**Journey log** —
- 卷曲矢量直绘才清晰；水波/坍塌必须靠 2× 纹理 + highp
- 快照 scale 勿 clamp≤dpr，否则与 live 同像素密度无超采样
- Cover/Cube 无 shader 依赖，走 `_buildPage` 矢量

## [S1] Problem

## [S1] Problem

1. 非卷曲翻页（水波/坍塌）**清晰度下降**：shader 纹理 `mediump` + 1x 快照，变换采样发糊。
2. 需要新的翻页方式：**覆盖 Cover**（legado 风格）与 **立方体 Cube**（3D 沉浸）。

## [S2] Design

### A. 清晰度（全模式受益）

- 快照 `_pageToImage`：**2x dpr 超采样**（`pixel = size × dpr × 2`，上限 4096 边）。
- `ripple_shredder.frag` / `block_collapse.frag`：`precision highp float`（UV/几何）。
- 绘制侧继续 `FilterQuality.high`。

### B. Cover 覆盖

| 项 | 契约 |
|----|------|
| 形态 | 新页从翻页方向侧滑入**盖住**旧页；旧页同步 scale 0.92 + 12% 黑罩 |
| 时长 | 同 ripple 三档（400/600/800ms） |
| 跟手 | 拖拽 progress 映射滑入距离 |
| 落点 | 松手过阈值滑完，否则回弹 |

### C. Cube 立方体

| 项 | 契约 |
|----|------|
| 形态 | Y 轴透视旋转：旧页转出、新页转入，像立方体侧面 |
| 透视 | `Matrix4` + `setEntry(3,2, 1/eye)`，eye ≈ 页宽×1.2 |
| 时长/跟手 | 同 Cover |
| 降级 | 无 shader 依赖，纯 Transform |

### 注册

- `PageTurnMode.cover` / `PageTurnMode.cube`
- `createTurnController` + `_buildCoverTransition` / `_buildCubeTransition`
- 设置「翻页方式」chip 增加两项；持久化同现有

### 测试

- Cover：progress 0→1 新页 translateX 从 w→0（next）
- Cube：progress 0.5 时矩阵含透视项
- 快照边长 = 2×dpr（单测纯函数 `snapshotPixelSize`）

## [S3] Out of Scope

- 多指捏合、双页对开
- GPU 实例化粒子

## Tasks

- [x] T1: 2x 快照 + shader highp — acceptance: 水波/坍塌字迹不糊 (covers: S2)
- [x] T2: Cover 翻页 — acceptance: 设置可选，滑入盖页+旧页缩小 (covers: S2)
- [x] T3: Cube 翻页 — acceptance: 设置可选，透视旋转翻页 (covers: S2)
- [x] T4: 测试/构建收口 — acceptance: 测试过；APK 可装 (covers: S2; depends: T1,T2,T3)
