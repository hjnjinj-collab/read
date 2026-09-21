---
feature: glass-settings-mode-nav
status: delivered
updated: 2026-09-19
branch: master
commits: 3ec3693..63aabd2
---

# 材质与玻璃页：全页 霜壳 + 液态切换

## Report

**本轮** — 方向分段图标改 **Iconsax**（`AppIcons.dirAxis/dirDown` +
对角 `Transform.rotate`），与壳层 `AppIcons` 体系一致。

### 调研：设置页液态切换「高光 / 描边」现状（倒角立体感弱）

| 层 | 当前实现 | 对立体感的贡献 |
|----|----------|----------------|
| 轨道 shape | R16，`borderWidth:0`，`lightIntensity:0`，透明色 | **无**包内光学描边/倒角 |
| 轨道 appearance | blur 0，shadow null | 无景深、无接触影 |
| 轨道 refraction | distortion 0.03 / width 10 | 折射极弱 |
| 前景 rim | 纯色 Border：浅 0.6/α0.38 · 深 0.8/α0.30 | 仅细线轮廓，无上亮下暗渐变 |
| pill glass（动画） | 透明 + blur 1.5 + shadow **null** | 动画无厚度感 |
| pill rest（静止） | `restPillTint`，blur 0，无 shape/light | 平色块，无内高光 |

**对照底栏 `_shellFrost`（立体感更强）**：
- `borderWidth 1.0` + 白边 α0.45/0.22 + **`lightIntensity: 1.1`**
- blur=`navBlurSigma`，shadow 18/0.16 offset(0,6)
- refraction 0.1 / width 28 / chroma 0.002

**结论**：设置页分段为防外泄/色盖，主动关掉了包内 light/border/shadow，
前景 rim 又是单色细线——倒角与立体感必然弱。下一步可选（待你拍板）：

1. **A 对齐底栏光学边**：轨道/pill 恢复 `lightIntensity≈0.9–1.1` +
   白边 1px α0.35–0.45（最像现在底栏）
2. **B 前景 rim 升级为双色 bevel**：上白亮 / 下暗，不碰包 Lens
3. **C 静止 pill 加轻内高光**（上缘白 α0.25 渐变）+ 轨道轻 blur（0.5–1）
4. **A+B 组合**（推荐试）：包光学边 + 前景 bevel，Clip 仍防外泄

## [S1] Problem

方向图标过旧；倒角/立体感弱需先摸清实现。

## [S2] Design

- Iconsax 方向图标 + rotate；高光/描边 **仅调研，未改切换器光学参数**

## [S3] Out of Scope

- 本轮不改 lightIntensity/border（等用户选方案）

## Tasks

- [x] T1: Iconsax 方向图标 (covers: S2)
- [x] T2: 高光/描边现状调研报告 (covers: S2)
- [ ] T3: 按用户选定方案增强倒角/立体感 (covers: 待定)
