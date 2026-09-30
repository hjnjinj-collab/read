---
feature: pdf-original-glyph-stroke
status: delivered
updated: 2026-09-29
branch: master
commits: 52b77a3..HEAD
---

# PDF 原图字迹浓淡不均 / 缺画 — 定位与修复

## Report

**What was built** — 根因是 `fill_page` 用 `BoxFit.fill` **非等比拉伸**（样张 1570×2480 铺到 ≈1080×2400 时 sx≈0.69、sy≈0.97，竖画被压细约 31%），与 CCITT 解码无关（1:1 字形完整）。改为 **等比 contain 居中 + 纸色留边**（`PaperTint.fitContain`，横竖缩放比恒等）；shader 画在等比矩形上。暗色细笔画仍靠 PDF 墨/纸重映射。

**Verification** —
- probe：p10 CCITT 1:1 ASCII 目视字形完整、仅 0/255
- `flutter test test/paper_tint_test.dart --no-pub`：13 passed（含 fitContain 横竖比一致）
- APK 构建 PASS

**Journey log** —
1. 先怀疑 CCITT 丢画 / tint 吃灰，1:1 目视排除。
2. 数值：sx/sy≈0.71 → 横浓竖淡，与「一个字里笔画粗细不一」吻合。
3. 产品曾定「宽=页宽高=页高」；与笔画保真冲突，用户改选等比留边。
4. shader UV 必须画在 **fitted** 矩形，不能仍用全窗 rect。

## [S1] Problem

PDF **原图模式**下汉字「一个完整的字，有的笔画浓、有的淡，甚至缺画」。

## [S2] 定位结论（2026-09-29）

### 实测（《神迹六辩》probe）

| 样本 | 编码 | 分辨率 | 灰度 | 1:1 字形 |
|------|------|--------|------|----------|
| p0–p2 | JPEG 8bpc | 1618×2480 | 有连续灰阶 | — |
| p10 等 | **CCITT G4 1bpp** | 1570×2480 | **仅 0/255，无灰** | ASCII 目视：笔画完整、均匀 |

**结论 A：Rust 解码/1bpp 位图本身没问题**。

### 显示链路根因（主因）

`fill_page` 使用 **`BoxFit.fill` 非等比拉伸**：
- 横向 sx≈0.69，纵向 sy≈0.97
- 同一个字：**竖画被压细 ~31%**，横画几乎不变 → 横浓竖淡、细竖易「缺」

### 次因（暗色下更明显）

`paper_tint` PDF 墨/纸映射对缩放后的中间调灰会压低对比。

### 修复

**等比 contain 居中 + 纸色留边**（用户选定）：`PaperTint.fitContain`，绘制与 tint 均在等比矩形。

## [S3] Out of Scope
- OCR 重排字迹
- 扫描件超分

## Tasks
- [x] T1: 等比 contain + 纸色留边 — acceptance: 同一字横竖笔画粗细接近 (covers: S2)
- [x] T2: 暗色细笔画对比 — acceptance: PDF 墨/纸映射保留，测试覆盖 (covers: S2; depends: T1)
