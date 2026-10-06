---
feature: reader-experience-zoom-tint
status: delivered
updated: 2026-10-01
branch: master
commits: 671ca7f..671ca7f
---

# 阅读体验增强：PDF/图缩放 + 纸色强度

## Report

**What was built** — ①双击图片命中区打开 `ImageZoomViewer`（捏合 0.5–5x + 平移），与长按并存；双击窗 ~300ms 不与单击菜单冲突。②纸色适配强度滑杆 0–100%（`PaperTint.strength`），持久化 `imagePaperTintStrength`，strength=0 等同关闭映射。与后续「原图整页 fill + 墨迹加深」「自定义背景蒙版」共同构成扫描 PDF 视觉链。

**Verification** — 交付于 `671ca7f`；纸色强度相关单测见 `paper_tint_test.dart`；真机已多轮使用。

**Journey log** —
- 双击缩放复用 ImageZoomViewer，勿再写第二套捏合
- strength 进指纹/缓存键由 PaperTint 全局量承担，切换即时重绘

## [S1] Problem

## [S1] Problem

扫描 PDF / 漫画需要更易用的放大；纸色适配（近白→背景）目前只有开/关，无法调强弱。

## [S2] Design

### 目标
1. **双指/双击放大**看原图（复用 `ImageZoomViewer`）
2. **纸色适配强度**可调（0–100%）

### 合同

**A. 打开放大**
- **长按**（已有）+ **双击**图片命中区 → `ImageZoomViewer`（捏合 0.5–5x + 平移）
- 双击不与单击菜单冲突：双击窗 ~300ms 内第二次点击开缩放，否则走原菜单/翻页

**B. 纸色强度**
- `PaperTint.strength`（已有）0–1；设置「背景」区滑杆默认 100%
- 持久化 `imagePaperTintStrength`（double）
- strength=0 等同关闭映射（仍可保持开关）

### 测试
- 双击命中图打开 viewer
- strength 滑杆改 `PaperTint.strength` 并落盘

## [S3] Out of Scope
- 页内持续捏合（翻页手势冲突，二期）
- 超分/锐化

## Tasks
- [x] T1: 双击打开 ImageZoomViewer — acceptance: PDF/漫画双击出缩放层 (covers: S2)
- [x] T2: 纸色强度滑杆+持久化 — acceptance: 调滑杆即时改 tint，重启保持 (covers: S2)
