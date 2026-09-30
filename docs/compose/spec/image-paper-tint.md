---
feature: image-paper-tint
status: delivered
updated: 2026-09-29
branch: master
commits: 56222a6..HEAD
---

# 图片纸色适配（漫画白边 / PDF 原图纸白）

## Report

**What was built** — 图内近白像素映射为当前 `paperColor`（非整图染色）：`shaders/paper_tint.frag` 用 smoothstep(0.82–0.90) 将 luma≈白 的像素 mix 到纸色，线稿与彩块保留。漫画（gallery）与 PDF 原图（fill_page）默认启用；EPUB 插图默认不染。设置「背景」区增加「图片纸色适配」开关（`imagePaperTint`，默认开），持久化到 reader settings。shader 加载/绘制失败回退 `paintImage`。

**Verification** —
- `dart analyze`（paper_tint / settings / provider / page widget / visual sheet / test）：PASS（仅 5 条既有 info）
- `flutter test test/paper_tint_test.dart --no-pub`：5 passed（纯白映射、暗色不映射、阈值过渡、strength、active 门控）
- `.\build_apk.ps1 -Abis arm64-v8a`：`app-arm64-v8a-release.apk` 64.4MB PASS（含 paper_tint.frag）

**Journey log** —
1. 用户否决「整图 WPS 绿膜」与「只裁白边」；定为近白映射，彩画面保留。
2. ColorFilter.matrix 做不了阈值，必须 FragmentShader；uniform 顺序 = uRect(0-3) / uPaper(4-7) / thr(8) / strength(9) + sampler0。
3. `flutter pub get` 易因镜像挂起；验证用 `flutter test --no-pub` + `dart analyze`。
4. 适用范围用打开书时的 format 标志（comic|pdf）而不是改 FFI entry 字段，避免 Rust 重签。

## [S1] Problem

1. **漫画**：部分图源自带上下大白边；高度又 ≥65% 走独页拉伸后，暗色模式下上下仍是刺眼纯白。
2. **PDF 原图**：扫描页以纸白为主，暗色主题下整页发白。
3. 用户对照 WPS「护眼」：即使 PDF 也会把纸面压成主题色；但明确要求**不要盖住画面**，只适配空白/纸白。

## [S2] Design

### 目标
图内**近白像素**映射为当前阅读器 `paperColor`（日间纸色/夜间深灰/自定义护眼绿），彩色内容尽量保留。

### 合同

**A. 近白映射（非整图染色）**
- 片元着色器 `shaders/paper_tint.frag`：
  - `luma = dot(rgb, (0.299,0.587,0.114))`
  - `t = smoothstep(threshold - 0.08, threshold, luma) * strength`
  - `rgb' = mix(rgb, paper.rgb, t)`，alpha 不变
- 默认 `threshold=0.90`、`strength=1.0`：纯白/近白 → 纸色；线稿黑、彩漫色保留。
- 纸色取 `PageContentRenderer.paperColor`（含用户纸色覆盖 + 透明度），随主题即时变化。

**B. 适用范围（默认开）**
- 漫画（`format==comic`，gallery 图）与 **PDF 原图/对照**（`fill_page` 扫描图）。
- EPUB 正文插图默认**不**染（`paperTintImages=false`）。
- 设置开关 `imagePaperTint`（默认 true）；关闭走原 `paintImage`。

**C. 绘制**
- 有 shader 且开关开且当前书需要 → `drawRect` + FragmentShader 采样。
- shader 加载失败 → 回退 `paintImage`（行为与现网一致）。

**D. 设置持久化**
- `reader_settings`：`imagePaperTint` bool，进出 JSON；视觉设置「背景」区增加开关。

### 测试
- 单元：`paperTintAmount` 阈值边界（纯白/暗色/过渡/strength/active 门控）。
- 暗色主题 + 纯白图：输出接近 paperColor；luma 低的像素不变。
- 开关关闭与 shader 失败时与旧绘制一致。

## [S3] Out of Scope
- 整图 WPS 式绿膜（可二期作「强度」滑杆）
- 裁切白边改变布局（只改颜色，不改几何）
- OCR/预处理管线里的纸色处理

## Tasks
- [x] T1: paper_tint.frag + 绘制封装（阈值/强度/paper 色） — acceptance: 近白→纸色、暗色不变 (covers: S2)
- [x] T2: 漫画/PDF 默认启用 + 设置开关持久化 — acceptance: comic/pdf 生效，开关可关 (covers: S2)
- [x] T3: 回退与测试 — acceptance: shader 失败走 paintImage；阈值用例过 (covers: S2)
