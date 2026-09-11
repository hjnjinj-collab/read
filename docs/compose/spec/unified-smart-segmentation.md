---
feature: unified-smart-segmentation
status: delivered
updated: 2026-09-12
branch: master
commits: bb99730..HEAD
---

# 统一智能分段（A35 语义双路径）

## Report

**What was built** — 把原先分裂的 M9 `reParagraphMode` 与 A35 智能分段收成一套引擎：总开关 `reSegment` 真实控制是否重分段；阈值默认 50、UI 可调（20–2000）；默认规则为强语气终结构 + 引号吸附 + 闭标禁则，可叠加用户规则。TXT 走行流 `segment_lines`，EPUB 走块内 `split_paragraph_ranges` + `clip_runs`（表格/注释块不切）。M9 三选一 UI 退役，生产路径 formatter 恒 None（仅缩进/段距）。修复中文省略号跨软换行被拆开的问题（行尾 `…` defer 与下一行行首续接）。EPUB 四口（展示/页数/预取/搜索）接入 `re_segment`+`segment_rules` 并入缓存键；TXT 预处理缓存键在 `re_segment` 时混入阈值，阈值变更同步失效预处理缓存。

**Verification** — `cargo test -p reader_core --lib` 168 PASS（含跨行省略号）；`cargo test -p bridge --lib` 17 PASS；`cargo test -p book_parser --lib` 123 PASS；`cargo test -p layout_engine --lib` 85 PASS；`fix_sync.ps1` PASS；`flutter analyze` 28 issues 0 error（既有基线）。独立审查 1 critical（PREPROCESSED_CACHE 缺阈值）+ minors；修复后聚焦复审 PASS。

**Journey log** —
1. 两套分段并存是历史层积：M9（两边）+ A35（仅 TXT）；用户记忆的「两边都做了」对应 M9 超长段切分。
2. TXT 上 A35 曾因内置规则列表恒非空而恒开，总开关空转——统一后激活条件收窄为仅 `re_segment`。
3. 省略号误切根因：A35 逐行处理时行尾 `…` 立刻 flush，下一行行首 `…` 成新段。
4. 预处理缓存键原先假设「格式化不影响预处理」；Stage2 消费阈值后该假设失效——任何影响预处理输出的设置都必须入 pre_key 或强制失效。
5. 阈值迁移：旧默认 200 一律迁到 50，避免老用户从 A35 实际体验的 50 突然变松。

## [S1] Problem

（已交付，见 Report。）

## [S2] Design

产品契约与引擎核见交付实现；关键接口：

- `reader_core::smart_segment::{SmartSegConfig, segment_lines, split_paragraph_ranges, DEFAULT_SEG_THRESHOLD=50}`
- TXT 激活：`ProcessOptions.re_segment` + `segment_threshold`
- EPUB：`StructuredParams.{re_segment, segment_rules, seg_hash}` 入 `StructuredPageKey`
- M9 `re_paragraph_mode` 生产路径恒 `None`

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
