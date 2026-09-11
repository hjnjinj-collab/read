---
feature: unified-smart-segmentation
status: delivered
updated: 2026-09-12
branch: master
commits: bb99730..6746006
---

# 统一智能分段（A35 语义双路径）

## Report

**What was built** — 把原先分裂的 M9 `reParagraphMode` 与 A35 智能分段收成一套引擎：总开关 `reSegment` 真实控制是否重分段；阈值默认 50、UI 可调（5–2000）；默认规则为强语气终结构 + 引号吸附 + 闭标禁则，可叠加用户规则。TXT 走行流 `segment_lines`，EPUB 走块内 `split_paragraph_ranges` + `clip_runs`（表格/注释块不切）。M9 三选一 UI 退役，生产路径 formatter 恒 None（仅缩进/段距）。修复中文省略号跨软换行被拆开；无终结构长段按硬上限（2×阈值）以次级标点/硬切兜底。EPUB 四口接入分段参数入缓存键；TXT 预处理缓存键在开启时混入阈值。A32.1 真机修订：阈值下限降至 5、无标点兜底、设置页分段规则区块去重。

**Verification** — 首轮：`reader_core` 168 / `bridge` 17 / `book_parser` 123 / `layout_engine` 85 PASS；`fix_sync.ps1` PASS；审查 1 critical（预处理缓存缺阈值）修复后复审 PASS。A32.1：`reader_core` 172 PASS（含硬上限 4 例）/ `bridge` 17 PASS；`fix_sync.ps1` PASS；`flutter analyze` 28 issues 0 error；审查 0 critical。

**Journey log** —
1. 两套分段并存是历史层积：M9（两边）+ A35（仅 TXT）。
2. TXT 上 A35 曾因内置规则列表恒非空而恒开，总开关空转——统一后激活条件收窄为仅 `re_segment`。
3. 省略号误切根因：行尾 `…` 立刻 flush，下一行行首 `…` 成新段。
4. 预处理缓存键原先假设「格式化不影响预处理」；Stage2 消费阈值后该假设失效。
5. 真机修订三件套：阈值下限、无标点硬上限、UI 重复调用 `_buildSegmentRulesSection()`。

## [S1] Problem

（已交付，见 Report。）

## [S2] Design

产品契约与引擎核见交付实现；关键接口：

- `reader_core::smart_segment::{SmartSegConfig, segment_lines, split_paragraph_ranges, DEFAULT_SEG_THRESHOLD=50, hard_limit}`
- TXT 激活：`ProcessOptions.re_segment` + `segment_threshold`
- EPUB：`StructuredParams.{re_segment, segment_rules, seg_hash}` 入 `StructuredPageKey`
- M9 `re_paragraph_mode` 生产路径恒 `None`

### [S2.1] A32.1 真机修订（2026-09-12）

| 项 | 契约 |
|---|---|
| 阈值下限 | UI/Rust clamp 下限降为 **5**（上限 **200**）；默认仍 50 |
| 无终结构兜底 | 累积达到 **2×阈值**（硬上限 `max(2×T, T+10)`）仍无终结构时：优先在段内自阈值起**最靠近硬上限**的次级标点（，、；：及 ASCII 对应）处切开并吞并紧随闭标；否则在硬上限处硬切。引号未闭合仍压制切分。两入口（`segment_lines` / `split_paragraph_ranges`）同语义。 |
| UI 去重 | 设置页「分段规则」区块只保留一处（挂在「智能分段」开关下）；删除简繁转换后的重复调用。规则说明文案中的「50 字」改为显示当前阈值。 |

## [S3] Out of Scope

- 不改笔记导出、阅读菜单、在线书源、PDF。
- 不做 M9 `ParagraphFormatter` Smart/Aggressive 的物理删除（仅生产路径退役）。
- 不引入新的分段规则类型。
- 不改布局层 kinsoku/标点压缩。
- bridge 集成测试 A35-L2 既有签名漂移（PRE-EXISTING）不作为本 feature 验收门槛。

## Tasks

- [x] T1: reader_core 抽出 `smart_segment` 核（阈值可配 + 省略号跨行原子 + `split_paragraph_ranges`）— acceptance: `cargo test -p reader_core` 新旧分段单测全过，含跨行省略号用例 (covers: S2)
- [x] T2: TXT 激活条件改为仅 `re_segment`，阈值接入设置；M9 生产路径退役 — acceptance: bridge 编译过；关开关不重分段、开开关按阈值切 (covers: S2; depends: T1)
- [x] T3: EPUB `StructuredParams` + 四 FFI 口接入 re_segment/segment_rules/seg_hash，块级切分 + clip_runs — acceptance: `cargo test -p bridge --lib` 与 reader_core 同核用例过；开开关长段被切、关开关不切；表格块不切 (covers: S2; depends: T1)
- [x] T4: Dart 调用链 EPUB 四口补参；设置 UI 废三选一、阈值滑杆挂到智能分段下；持久化迁移 200→50 — acceptance: `flutter analyze` 无新增；设置面板仅一组分段控件；默认阈值 50 (covers: S2; depends: T2, T3)
- [x] T5: 验证（`fix_sync.ps1` + 全量 Rust/Flutter 测试）+ 独立审查 — acceptance: 测试命令与结果入 Report；审查 critical 清零 (covers: S2; depends: T4)
- [x] T6: 阈值下限降为 5（Rust clamp + UI 滑杆）— acceptance: 滑杆可拖到 5；Rust 接受 5 (covers: S2.1)
- [x] T7: 无终结构硬上限兜底（次级标点优先，否则硬切；双入口同语义 + 单测）— acceptance: 超 2×阈值无终结构时被切开；引号未闭合仍不切 (covers: S2.1; depends: T6)
- [x] T8: 设置页分段规则区块去重 + 说明文案用当前阈值 — acceptance: 设置页仅一处「分段规则」；文案含当前阈值 (covers: S2.1)
- [x] T9: 修订验证 + 独立审查 — acceptance: 测试过；审查 critical 清零 (covers: S2.1; depends: T7, T8)
