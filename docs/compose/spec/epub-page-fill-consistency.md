---
feature: epub-page-fill-consistency
status: delivered
updated: 2026-09-12
branch: master
commits: 153abc4..HEAD
---

# EPUB 页底行级填满一致性

## Report

**What was built** — 在 fill=100% 行级贴底语义下，收紧 EPUB 页底残余：① 基线测试锁定「纯文本非末页残余 &lt; 1 行高」；② 页尾 `space_before` 折叠——预加后首行放不下则不计入段前距；③ 逐行真实行高（`LaidLine.scale`）参与放置与越界判断，混字号段落不再整段共用 max scale；本章说强制 0.7 **单次覆盖**（审查 C1：禁止与 CSS scale 双重相乘）。`LAYOUT_REVISION` 升至 2 使旧分页缓存失效。A26 多级图文预留因基线显示纯文本已达标而暂缓（T4）。

**Verification** — `cargo test -p layout_engine --lib` 89 PASS（含 4 个 A33 用例：纯文本残余 / space_before 折叠 / 混 scale / 本章说单次 0.7）；`cargo test -p bridge --lib` 17 PASS；`cargo test -p reader_core --lib` 172 PASS；`cargo test -p book_parser --lib` 123 PASS；`fix_sync.ps1` PASS；`flutter analyze` 29 issues 0 error。独立审查 1 critical（注释 0.7 双乘）→ 修复后聚焦复审 PASS。

**Journey log** —
1. fill=1.0 纯文本基线在改动前已达标——真机「忽满忽空」更可能来自混 scale 行高、段前距、图文原子或 MeasureCache 未命中导致的断行抖动。
2. 本章说 0.7 必须是**覆盖**而非乘数：与 Dart `font_scale=0.7` 绘制对齐，否则 y 递进比绘制矮 30% 导致重叠。
3. `para_max_scale` 的 max-identity 应为 0.0 再 `.max(1.0)`，`fold(1.0, max)` 会吞掉 &lt;1 的 scale。
4. 段前距折叠与段后距折叠同构：只在「还能放下首行」时计入 current_y。

## [S1] Problem

A32 统一智能分段后段落变长，EPUB **页底留白不一致**被放大：有的页贴底、有的页空出 1～N 行，观感「忽满忽空」。

用户钦定目标：**行级填充**，在不阻塞 Flutter UI 线程的前提下，**最大避免留白不一致**。

根因不是 MeasureCache 断行（另见 `epub-layout-measure-parity`，主体已落地），而是填充决策层：

1. **fill=1.0 时孤寡行保护整体挂起**（A25b）——纯行级填满下，残余应 &lt;1 行；若仍出现 ≥1 行空洞，来自下列结构原因。
2. **孤寡行只在段首决策一次**；断页后余行流式续页不再检查。
3. **Image/Table 原子块**放不下整块则整块下推。
4. **标题隔离**：剩余空间 &lt; 1 标题行 + 2 正文行时标题整块下推。
5. **A26 一级图前瞻**预留失败 → 图独占下页。
6. **行高按段内 max scale 取单一值**再算 fit；混字号段落与逐行真实行高不一致。
7. **`space_before` 先加后判满**。
8. 本章说 0.7 与 CSS scale 双重缩小（本批审查发现并修复）。

## [S2] Design

### 产品契约

| 项 | 契约 |
|---|---|
| 目标 | 纯文本章节：除末页外，页底残余 **&lt; 1 行高**；图文页残余可解释（仅来自原子块/标题隔离） |
| fill 语义 | `page_fill_threshold` 仍为内容区利用率；**100% = 行级尽量贴底**，不因孤寡行主动让出整行（A25b） |
| fill&lt;100% | 保留现有孤寡行保护 |
| 行高 | 逐行 `font_size × line_h × LaidLine.scale`；本章说强制 `×0.7` 单次覆盖 |
| UI 线程 | 不新增同步 Skia |
| D11 | 不合并 `layout_text` / `layout_items` |
| 锚点 | char_index / start_char_index 口径不变 |
| 缓存 | `LAYOUT_REVISION = 2` |

## [S3] Out of Scope

- 不改 TXT `layout_text` 填充算法。
- 不重新启用 A25 Scene A/B。
- 不在热路径同步 Skia。
- A26 多级图文预留（T4 暂缓，真机若仍以图独占为主再开）。
- 表格单元格路径的逐行行高（仍用 max scale）。

## Tasks

- [x] T1: 填充残余基线测试（纯文本/混 scale/段前距/本章说）— acceptance: `items_pure_text_full_fill_residual_under_one_line` 等锁定非末页残余 (covers: S2)
- [x] T2: 页尾 space_before 折叠 — acceptance: `items_space_before_folded_at_page_bottom` 过 (covers: S2; depends: T1)
- [x] T3: 逐行真实行高 fit + 本章说单次 0.7 — acceptance: 混 scale/注释行高测试过；孤寡行/锚点回归过 (covers: S2; depends: T1)
- [ ] T4: A26 多级图文预留（暂缓）— acceptance: 真机确认 atomic 空洞为主因后再做 (covers: S2)
- [x] T5: 全量验证 + 独立审查 + 定稿 — acceptance: 测试过；审查 critical 清零 (covers: S2; depends: T2, T3)
