---
feature: epub-footnote-adapt
status: delivered
updated: 2026-09-12
branch: master
commits: bfcd41d..HEAD
---

# EPUB 注释引用适配（章末注）

## Report

**What was built** — 以《瓦尔登湖》为样例的章末注适配：`p.note`/`note1` 并入本章说通道（JS class + CSS `has_note_class`）；正文 `<a href="#mN"><sup>[N]</sup></a>` 产出 `footnote_ref` 上标 run（不上链、默认 0.7 字号）；JS `harvestNotes` 采集 `StructuredContent.footnotes`；`PageInfo.footnotes` 随页下发；点按走既有 Listener 管线（`hitFootnote` 优先于翻页/菜单），弹层显示注释全文。

**Verification** — `cargo test -p book_parser --lib` 124 PASS（含 `walden_style_endnotes`）；layout_engine 89 / bridge 17 PASS；`fix_sync.ps1` PASS；flutter analyze 无新增 error。独立审查 1 critical（GestureDetector 与外层 Listener 双触发）→ 改为单一指针管线后复审 PASS。

**Journey log** —
1. 章末注不能只靠 CSS 0.75 阈值：`.note` 为 0.85em，需 note class 正向特征。
2. `p.note` 须在 JS flush 时标 `is_comment`，不能只靠容器 walk。
3. 阅读页手势是外层 raw Listener，任何子 GestureDetector 都会双触发——命中逻辑必须挂在 `_handleTapGesture`。
4. `<a>` 默认 underline；脚注引用须显式覆盖为不上链 + 0.7 字号。

## [S1] Problem

以《瓦尔登湖》为代表的标准中文 EPUB 使用**章末注**：

- 正文引用：`<a id="wN"></a><a href="ch.html#mN"><sup>[N]</sup></a>`
- 章末注释：`<p class="note"><a id="mN"></a><a href="ch.html#wN">[N]</a> 正文…</p>`
- CSS 仅 `.note { font-size: 0.85em; }`

现状缺口：

1. JS 提取只认 class 含 `footnote`，**不含 `note`** → 注释不进「本章说」。
2. CSS 兜底要求 `font_scale < 0.75`，0.85em 过不了 → 仍不标。
3. 正文 `[N]` 当普通字符，无上标、不可点。

产品钦定（2026-09-12）：

- 注释体 **并入本章说通道**（灰字小号，可用「显示本章说」隐藏）。
- 正文引用 **上标样式 + 点按弹层** 显示注释全文。

## [S2] Design

### 检测

| 来源 | 规则 |
|---|---|
| JS | class 精确 `note`/`note1` 或含 `footnote`/`endnote`/`sidenote`/`annotation` → 子段落 `is_comment=true` |
| CSS | `has_note_class` 命中时 **不再要求** `font_scale < 0.75`（仍要求 `char_count < 200`） |

### 引用 run

`StyledRun` 增加：

```
footnote_ref: Option<String>  // 目标注 id，如 "m1"
```

提取时：`<a href="#mN">` / `href="file#mN"` 内含 `sup` 或文本形如 `[N]` → 产出 run（`footnote_ref=Some("mN")`，`font_scale≈0.7`，`underline=false`）。

### 注释表

`StructuredContent.footnotes: BTreeMap<String, String>`  
键 = 注 id（`mN`），值 = 去掉 `[N]` 前缀后的正文。

`process_structured_chapter` 把本章 `footnotes` 挂到 `PageInfo.footnotes`（每页重复携带，容量小）。

### Dart 交互

- 绘制：带 `footnote_ref` 的 run 按小字号上标绘制（复用现有 segments 通道）。
- 点按：命中该 run → 读 `page.footnotes[ref]` → 底部弹层/对话框显示注释全文；无映射则不弹。

### 缓存 / FFI

- `PageInfo` 增加 `footnotes: Map<String,String>`（FRB）。
- structured 缓存键不需新增字段（脚注随 IR 固定，不随设置变）；`CONTENT_IR_VERSION` 保持 2（serde default 向后兼容）。

## [S3] Out of Scope

- 跨章脚注、弹层内再跳转、注释区折叠 UI。
- 不改 TXT。
- 不做 epub:type="noteref" 的完整 EPUB3 语义（可后续叠加）。

## Tasks

- [x] T1: 检测 `p.note` 为本章说（JS class + CSS 兜底放宽 + note1）— acceptance: 瓦尔登湖式 note 段 `is_comment=true`（covers: S2）
- [x] T2: `StyledRun.footnote_ref` + 提取 sup/[N] 引用 run + `StructuredContent.footnotes` — acceptance: `walden_style_endnotes` 单测过 (covers: S2; depends: T1)
- [x] T3: `PageInfo.footnotes` 贯通 + Dart 上标绘制与点按弹层 — acceptance: _mapPage 映射 footnoteRef/footnotes；绘制 superscript；点按 showDialog (covers: S2; depends: T2)
- [x] T4: 验证 + 独立审查 — acceptance: book_parser/bridge/layout 测试 + analyze；审查 critical 清零 (covers: S2; depends: T3)
