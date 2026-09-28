---
feature: pdf-scan-reflow
status: designed
updated: 2026-09-27
branch: master
commits: # leave empty while in progress
---

# 扫描件 PDF 优化（背景/字体/排版）

## Report

## [S1] Problem

真机测试扫描版 PDF（图片页）暴露三点（用户原话归纳）：

1. **背景是原有的**——扫描纸色/脏底写在位图里，主题纸色/夜间模式盖不住。
2. **字体不能更换**——页是像素图，不是文字对象，字体/字号/字距设置无效。
3. **按图片处理**——走漫画 gallery 整页图，无法进入文字工作流（搜索、选中、两端对齐、重排）。

根因：`page_kind==Image` 时只提取 XObject 位图，没有文字层，也没有主题化处理。

## [S2] Design

### 目标行为

| 能力 | 现状 | 目标 |
|------|------|------|
| 背景 | 扫描原图 | 跟随阅读主题纸色 |
| 字体/字号/字距 | 无效 | 与 TXT/EPUB 相同生效 |
| 排版/折行 | 无 | 重排进 layout_text |
| 原版面 | 整页图 | **可选**保留（对照模式） |

### 方案：扫描页 OCR 重排（主路径）

**核心**：扫描页 → OCR 文字层 → 当普通文本进现有排版/主题，而不是当图。

```
扫描页 Image
  → 页光栅（已有 extract_page_image）
  → OCR（按页、后台、可缓存）
  → 文本块
  → process_pdf 文字路径（layout_text）
  → 主题纸色 + 用户字体
```

#### 1. OCR 引擎选型（可插拔）

| 选项 | 优点 | 代价 |
|------|------|------|
| **A. 系统/云端 OCR（推荐一期）** | Windows 有内置 OCR；Android 可用系统或轻量模型 | 质量因系统而异；需平台适配 |
| B. 本地模型（如 RapidOCR / tesseract） | 效果稳定、可离线 | 包体 +5～30MB；NDK 交叉编译成本 |
| C. 仅增强图片（滤镜去底） | 实现快 | **字体仍不能换**，不满足需求 |

一期建议 **A（平台 OCR）+ 失败降级 B 或纯图对照**；接口统一 `OcrEngine::recognize(image_bytes) -> String`。

#### 2. 页模式（设置项「PDF 扫描页」）

| 模式 | 行为 |
|------|------|
| **重排（默认）** | OCR → 文本流；背景=主题；字体可调 |
| **对照** | 整页图（现状）+ 可选背景柔化 |
| 自动 | 有文本层用文本层；纯扫描页走 OCR 重排 |

#### 3. 背景与字体

- 重排模式：**不绘制扫描原图**（或仅作可选水印级底图，默认关）；`PageContentRenderer.paperColor` 即底。
- 字体/字重/字距/行距：与文字书同一 `TextStyle` 路径，设置页不再禁用。
- 对照模式：图上叠半透明主题纸色（可调透明度）降低刺眼，仍不可改字。

#### 4. OCR 缓存与大文件

- 键：`book_id + page + ocr_model_ver`；磁盘缓存（app support）。
- 按章后台 OCR，不阻塞打开；已 OCR 页立即出字。
- 识别文本走既有 `content_cleaner` OCR 错字表（已有 `fix_ocr_errors`）。

#### 5. 工作流并入

- 章节/页码/进度与现 PDF 一致。
- 搜索、选中、笔记：重排后自动可用（文字路径）。
- 扫描页无 OCR 时占位「本页为扫描件，识别中/失败可切换对照」。

### 测试边界

- 假图（纯色+已知短语）OCR mock：得到指定字符串并进 layout_text。
- 模式切换：重排页宽度随字号变化；对照页 rect 为整页。
- 缓存：同页二次识别不再调引擎。

## [S3] Out of Scope

- 保留原版面的「OCR 文字层覆盖在扫描图上」精确对齐（二期）。
- 表格/公式版面还原。
- 手写体专项优化。

## Tasks

- [ ] T1: `OcrEngine` trait + 平台实现/降级；页光栅 → 文本 — acceptance: 单测 mock OCR 出字 (covers: S2)
- [ ] T2: PDF 扫描页「重排/对照/自动」模式与设置项 — acceptance: 切换后背景/字体生效路径正确 (covers: S2; depends: T1)
- [ ] T3: OCR 磁盘缓存 + 后台按章识别 — acceptance: 同页二次不重复 OCR (covers: S2; depends: T1)
- [ ] T4: 重排文本进 layout_text + 排版设置解除对 PDF 限制 — acceptance: 扫描 PDF 改字体/字号可见生效 (covers: S2; depends: T2)
- [ ] T5: 对照模式主题叠色 + 测试/构建 — acceptance: 测试过；文档含真机清单 (covers: S2; depends: T2)
