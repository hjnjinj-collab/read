---
feature: epub-cover-gallery-pageturn
status: delivered
updated: 2026-09-12
branch: master
commits: 52f5173..HEAD
---

# EPUB 封面提取 / 画廊 / 翻页卡死

## Report

**What was built** — ① 封面兜底：`meta name=coverpage`、manifest `id/href cover*`、cover-like spine 章取首图（含 SVG `xlink:href` 正则兜底）；**A35.1**：`opf_base_path` 须在封面提取前赋值，否则 `join_opf_dir` 丢 OPF 目录（剑来回归）。② 画廊：`Image.gallery` 每图一页，max 高=内容区（A35.1 自 0.85 放宽）；点按全屏缩放。③ 翻页钳回原页视为章末进下一章。**A35.1**：Right/Center 段不套用户缩进（诗词 `text-align:right` 不再被 2em 推偏）。

**Verification** — probe_cover：剑来 1122964 / 瓦尔登湖 13827270 均 Some；layout 92 / book_parser 127 / reader_core 173 / bridge 17 PASS；`fix_sync.ps1` PASS。

**Journey log** —
1. 瓦尔登湖 OPF 是非标 `meta name="coverpage"`。
2. 封面提取必须在 `opf_base_path` 赋值之后——否则 join 丢目录。
3. scraper 常丢 `xlink:href`，SVG 封面需正则兜底。
4. pageCount 虚高时钳回原页 + 章末兜底解卡死。
5. 用户缩进不得覆盖 CSS `text-align:right/center` 段（诗词页）。
4. 画廊复用 Image.gallery 字段 + 布局强制分页，避免新 IR 块类型。

## [S1] Problem

真机三连：

1. **瓦尔登湖封面未提取**：书架封面空。OPF 仅有 `<meta name="coverpage" content="CoverDesign"/>`；实际封面 `coverpage.html` → `Cover.jpg`（manifest `id="cover"`）。
2. **大奉打更人画廊未适配**：`duokan-image-gallery`。钦定分页画廊 + 点按放大。
3. **翻页卡死**：`page.adopt.reject not-adjacent`，请求 page=1 却 commit 回 3/0。

## [S2] Design

### 封面提取兜底链

1. EPUB3 `properties="cover-image"`
2. EPUB2 `meta name="cover"`
3. `meta name="coverpage"` → manifest id（xhtml 则取首图）
4. manifest `id/href` 文件名以 `cover` 开头的图片
5. spine 首个 cover-like 章取首个 img

### 画廊

- JS：`duokan-image-gallery-cell` 内图 → `gallery=true`
- 布局：非空页强制分页；max 高 = 内容区×0.85
- 交互：点按 `hitImage` → `ImageZoomViewer`（InteractiveViewer 捏合）

### 翻页卡死

`nextPage`：请求 `pageCount-1` 以内但 load 钳回原页 → 清 `_chapterPageCounts` + 进下一章 page=0。

## [S3] Out of Scope

- 画廊横向滑动专用页 / 缩略图条
- 非 duokan 画廊标记
- 查看器双击放大快捷手势

## Tasks

- [x] T1: 封面兜底链 — acceptance: 瓦尔登湖 cover_data 非空
- [x] T2: 画廊提取 + 布局分页 — acceptance: 每图一页
- [x] T3: 图片点按全屏缩放 — acceptance: 查看器打开/关闭不翻页
- [x] T4: 翻页钳制 + 章末兜底 — acceptance: clamp-to-end 后进下一章
- [x] T5: 验证 + 审查 — acceptance: 测试 PASS，审查 0 critical
