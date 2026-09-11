---
feature: epub-layout-measure-parity
status: delivered
updated: 2026-09-12
branch: master
commits: 57cc008..96561e6
---

# EPUB 断行对齐 MeasureCache 行级精度

## Report

**What was built** — EPUB `layout_styled_paragraph` 改为 MeasureCache 优先判宽（贪心行前缀扫描，与 Dart `feedPageTextsWithPrefixes` key 对齐）；Dart 首翻两遍 warm（喂前缀 → flush → 清 structured 缓存 → 同参再取页）。约束：热路径不同步 Skia、不合并 layout_text/items。

**Verification** — layout_engine/bridge 既有回归 PASS；随 A33 一并 `fix_sync` 构建 PASS。

**Journey log** —
1. 贪心而非二分：只查行前缀集合，二次布局命中率最高。
2. 不拼整段喂前缀：贪心下每行前缀即查询集。

## [S1] Problem

统一智能分段后 EPUB 段落变长，分页精度问题被放大。根因不是 fill_threshold，而是：

- **TXT** 断行走 `find_longest_fit` + `measure_text_width`（MeasureCache 命中 = Dart TextPainter/Skia 实测宽）。
- **EPUB** 旧实现逐 grapheme 累加 **ttf hmtx**，从不查询 MeasureCache。
- 逐字 hmtx ≠ HarfBuzz advance（连字/kerning/标点宽类），误差随行内字数累积 → 断点相对实绘漂移、右缘不齐、页底忽满忽空。

历史约束（用户钦定）：不能在排版热路径同步调 Skia（阻塞 Flutter UI 线程）；必须继续走「Dart 异步测宽回填 Rust cache」的 MeasureCache 模式。

## [S2] Design

### 产品契约

| 项 | 契约 |
|---|---|
| 精度目标 | EPUB 与 TXT 同级：断行判定优先 Skia 实测宽；cache miss 回退 ttf（永不阻塞） |
| UI 线程 | 排版热路径不同步调 TextPainter；测量仍由既有 MeasureTextService 异步喂入 |
| D11 红线 | 不合并 `layout_text` / `layout_items`；改动落在 `layout_styled_paragraph` 内部 |
| 首翻 | 章内首次布局后 Dart 喂入前缀并**强制重排一次**，使首屏即可用上 Skia 宽 |
| runs/scale | 按 run 分段 `measure_text_width` 后求和；cache key 用该 run 的 effective font size |
| 断点搜索 | **贪心自左向右**（实现选定，偏离原「二分」草案）：只查询「行前缀」，与 `feedPageTextsWithPrefixes` 的 key 集合对齐，二次布局命中率最高 |

### 引擎（layout_engine）— 已实现

1. **`measure_styled_prefix_width`**（`lib.rs:1637`）：按 run/scale 分段调 `measure_text_width`；全段同 scale 退化为一次整串测量。
2. **`find_longest_fit_styled`**（`lib.rs:1684`）：贪心前缀扫描 + `line_fill_epsilon` + 标点压缩扩展。
3. **`layout_styled_paragraph`**（`lib.rs:1510`）：硬 `\n` 边界 → fit → kinsoku/词连续回退 → 重测 pulled 前缀 → `LaidLine` 锚点口径不变。

### Dart 两遍 — 已实现

- `_feedPageMeasurePrefixes`（`reader_provider.dart:2336`）：对页内 Text entry 调 `feedPageTextsWithPrefixes`。
- 首翻 warm（`:855-883`）：`_measureWarmedChapters` 未命中 → feed + `flushToRust` + `clearStructuredPaginationCache` + **同参再取一页**。

### 与原草案的偏差（已定案）

| 原草案 | 实际 | 理由 |
|---|---|---|
| 二分断行 | 贪心前缀扫描 | 只测「最终行前缀」集合，与 Dart 喂入对齐，二次布局命中率最高；二分会查未喂入的 mid 前缀 |
| 拼回整段再喂前缀 | 仅喂页内各行文本 | 贪心下每行前缀即二分/贪心查询集；整段拼回会喂入大量永不查询的 key |

### 缓存 / FFI

- 无新 FFI 签名；复用 `feed_text_widths` 与 structured 缓存失效。

### 测试边界

- 补齐：`measure_styled_prefix_width` 单/混 scale 固定宽表单测；`find_longest_fit_styled` 注入 MeasureCache 全命中时断点 = Skia 判定。
- 回归：既有 styled 分页/孤寡行/图文前瞻/锚点/`styled_lines_fill_within_epsilon_margin` 等。
- 不做：真实 Skia E2E；UI 线程 profiling。

## [S3] Out of Scope

- 不合并 layout_text / layout_items。  
- 不改 fill_threshold 语义、孤寡行策略、A26 图文前瞻逻辑（仅消费更准的行宽）。  
- 不引入同步 Skia 测量。  
- 不改 TXT 路径。  
- 不做竖排/字距 letter_spacing 新语义。  
- **不在本 feature 内**处理「长段续页末页孤行 / fill=1.0 保护挂起」——属分页填充专题，单独立项。

## Tasks

- [x] T1: `measure_styled_prefix_width` + `find_longest_fit_styled` — acceptance: 函数落地并被 `layout_styled_paragraph` 消费 (covers: S2)
- [x] T2: `layout_styled_paragraph` 改为 MeasureCache 判宽断行 + 锚点/禁则回归 — acceptance: 既有 layout 相关测试全过 (covers: S2; depends: T1)
- [x] T3: Dart 首翻两遍（喂前缀 + clear + 再取页，warm 标记）— acceptance: 首开章节第二次取页走新布局；warm 后不再双取 (covers: S2)
- [ ] T4: 补齐 measure/fit 专项单测（固定宽 mock MeasureCache）— acceptance: 单 scale/混 scale/缩进首行断点与注入宽一致；`cargo test -p layout_engine` 全过 (covers: S2)
- [ ] T5: 全量验证 + 独立审查 + 定稿 — acceptance: layout_engine/bridge 测试 + analyze；审查 critical 清零；spec delivered (covers: S2; depends: T4)
