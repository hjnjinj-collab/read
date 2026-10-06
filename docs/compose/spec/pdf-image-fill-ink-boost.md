---
feature: pdf-image-fill-ink-boost
status: delivered
updated: 2026-10-01
branch: master
commits: 822902a..HEAD
---

# PDF 原图铺满 + 墨迹加深

## Report

**What was built** — PDF「原图」绘制改为与漫画同策略：矩形=entry（`fill_page` 时即整页），`BoxFit.fill` 拉伸铺满，**宽=页宽、高=页高**，切换文字/原图不再尺寸漂移。拉伸笔画缺口由 `paper_tint.frag` PDF 分支墨迹加深补偿：`inkPush = (1-smoothstep(0.05,0.42,luma))*strength*0.45`，暗部压向 ink，纸白不动；`strength=0` 关闭。Dart 侧 `pdfInkPush`/`pdfFinalLuma` 与 shader 同式可单测。

**Verification** —
- `flutter test test/paper_tint_test.dart`：PASS 17/17（含墨迹加深）
- `flutter analyze --no-pub`：基线，无本轮 error
- arm64 APK 构建通过

**Journey log** —
- `fitContent`/`fitSafeCover` 随内容框缩放 → 切换模式尺寸漂移；统一 fill 才稳定
- 拉伸断笔用 shader 暗部加压，不必改几何
- 独立审查子代理当前不可用（会员限制），验收以单测+代码对照为准

## [S1] Problem

## [S1] Problem

1. PDF「原图」在文字↔原图切换时尺寸不稳定（`fitContent`/`fitSafeCover` 随内容框缩放），观感「莫名放大」，无统一原图尺寸。
2. 用户要求原图**宽=页宽、高=页高**整页拉伸铺满。
3. 拉伸后笔画易断/缺口，需着色器**加深字体墨迹**补偿。

## [S2] Design

### 原图尺寸（统一）

- PDF 原图/对照页：绘制矩形 = **entry 矩形**（`fill_page` 时即整页），`BoxFit.fill` 拉伸铺满，与漫画同策略。
- **不再**对 PDF 调用 `PaperTint.fitContent`/`fitSafeCover`（该路径导致切换模式尺寸漂移）。
- 文字重排模式不受影响。

### 墨迹加深（`paper_tint.frag` PDF 分支）

拉伸填页后笔画变细易断，在既有 `luma→(ink,paper)` 重映射上对**暗部再压向墨色**：

```
inkPush = (1 - smoothstep(0.05, 0.42, luma)) * uStrength * 0.45
g = clamp(g - inkPush, 0, 1)
```

- 只影响低亮度（字体/笔画）；纸白不动。
- `uStrength` 沿用纸色适配强度滑杆；0 时无加深。
- 原图模式（无 tint / tint 关）仍走 `paintImage` fill，不经过 shader。

### 测试

- `pdfMappedLuma` / 新 `pdfInkPush` 单测：暗部 luma 映射更靠 ink。
- 绘制路径：PDF 不再调用 `fitContent`（代码审查点）。

## [S3] Out of Scope

- 页内持续捏合缩放。
- 非等比/分栏扫描版面还原。
- 漫画空白边算法变更。

## Tasks

- [x] T1: PDF 原图改整页 fill 铺满 — acceptance: 切换文字/原图尺寸恒=页 (covers: S2)
- [x] T2: shader 墨迹加深 + 单测 — acceptance: 暗部映射更贴 ink；strength=0 不变 (covers: S2)
- [x] T3: 测试/构建收口 — acceptance: 测试过；APK 可装 (covers: S2; depends: T1,T2)
