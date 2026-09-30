---
feature: reader-experience-zoom-tint
status: designed
updated: 2026-09-29
branch: master
commits: # empty while in progress
---

# 阅读体验增强：PDF/图缩放 + 纸色强度

## Report

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
- [ ] T1: 双击打开 ImageZoomViewer — acceptance: PDF/漫画双击出缩放层 (covers: S2)
- [ ] T2: 纸色强度滑杆+持久化 — acceptance: 调滑杆即时改 tint，重启保持 (covers: S2)
