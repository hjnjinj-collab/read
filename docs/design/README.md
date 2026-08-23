# 设计文档索引

> 最后更新: 2026-08-21
> **当前权威架构描述：[ARCHITECTURE.md](./ARCHITECTURE.md)（先读这个）**
> 以下 8 份历史设计文档保留作背景参考；代码是权威，文档用于理解"为什么这样设计"。
> 设计与实现的差异、方案冲突的裁决记录，见 ARCHITECTURE.md 第 4、5 节。

## 文档列表

| # | 文档 | 对应模块 | 状态 |
|---|------|----------|------|
| 1 | [HIGH_PERFORMANCE_READER_CORE_DESIGN.md](./HIGH_PERFORMANCE_READER_CORE_DESIGN.md) | 整体架构 / book_parser trait 抽象 | 已实现（Trait-Based 解析、流水线、多格式） |
| 2 | [UNIFIED_READ_SESSION_AND_IMPLEMENTATION.md](./UNIFIED_READ_SESSION_AND_IMPLEMENTATION.md) | reader_core/session | 大部分实现（ReadSession、三章缓存、预加载） |
| 3 | [CORE_LAYOUT_ENGINE_DEEP_DIVE.md](./CORE_LAYOUT_ENGINE_DEEP_DIVE.md) | layout_engine | 部分实现（字形缓存已实现；EPUB 图文混排、智能分段未实现） |
| 4 | [PAGINATION_PRECISION_AND_RECOVERY.md](./PAGINATION_PRECISION_AND_RECOVERY.md) | layout_engine/pagination | 部分实现（SmartPaginator 段落完整性已实现；配置迁移位置恢复未实现） |
| 5 | [JS_ENGINE_OPTIMIZATION_TECHNICAL_DOC.md](./JS_ENGINE_OPTIMIZATION_TECHNICAL_DOC.md) | book_parser/chapter_extractor | 已实现并默认启用（js-engine feature，章节识别走 JS 规则 + 正则回退） |
| 6 | [DEEP_PREPROCESSING_OPTIMIZATION_TECHNICAL_DOC.md](./DEEP_PREPROCESSING_OPTIMIZATION_TECHNICAL_DOC.md) | reader_core/processing | 部分实现（预处理流水线 stages 已实现） |
| 7 | [FLOW_1_5_SCHEDULER_INTEGRATION_DESIGN.md](./FLOW_1_5_SCHEDULER_INTEGRATION_DESIGN.md) | reader_core/scheduler | 部分实现（task_scheduler、preload 调度已实现） |
| 8 | [FLOW_2_CHAPTER_EXTRACTION_PLAN.md](./FLOW_2_CHAPTER_EXTRACTION_PLAN.md) | book_parser 章节提取 | 进行中（JS 引擎识别已上线；净化后偏移重计算已完成，见 [bugfixes/2026-08-21_章节边界CRLF偏移漂移与净化行号失效](../bugfixes/2026-08-21_章节边界CRLF偏移漂移与净化行号失效.md)） |

## 关键工程约束（来自实际踩坑）

这些约束在对应设计文档成文时未知，实施过程中发现并固化在代码里（完整列表见 [../BUGFIX_INDEX.md](../BUGFIX_INDEX.md) 第三节）：

1. **字节偏移禁止用 `lines()[i].len() + 1` 累加** —— CRLF 行尾每行少算 1 字节，逐行累积漂移。
   必须扫描原始字节的 `\n` 建立行起始表。详见 [../bugfixes/](../bugfixes/) 中的章节边界系列报告。
2. **章节边界必须与所索引的文本同源** —— 内容净化会重构行结构，
   在原始内容上计算的行号不能用于净化后的内容；需在净化后文本上重新识别。
3. **全角空格 `\u{3000}` 占 3 字节** —— 所有 UTF-8 切片必须做字符边界检查。

## 阅读建议

- 新接手：先读 1（整体架构），再按负责模块读对应文档
- 改章节识别相关：必读 5、8，以及 [../BUGFIX_INDEX.md](../BUGFIX_INDEX.md)
- 改分页/排版：读 3、4
