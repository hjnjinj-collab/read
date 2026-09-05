# 文档索引 - Legado Flutter

> 最后更新: 2026-08-21
> 原则: 只保留当前有效的文档，历史记录在 [archive/](./archive/) 中

---

## 核心文档

| 文档 | 说明 |
|------|------|
| [../AGENTS.md](../AGENTS.md) | **开发者指南（必读）**：构建步骤、开发命令、架构、关键注意事项 |
| [../CHANGELOG.md](../CHANGELOG.md) | **变更日志**：版本历史与功能变更记录（遵循 Keep a Changelog 格式） |
| [BUGFIX_INDEX.md](./BUGFIX_INDEX.md) | **Bug 快速查找索引（遇到问题先看这里）**：按症状/错误信息定位根因 |
| [BUG_FIXES.md](./BUG_FIXES.md) | Bug 修复总记录：UTF-8 边界 panic、构建问题、已知问题 |
| [bugfixes/](./bugfixes/) | 单次问题的完整分析报告（按日期命名），含章节边界系列修复的最终结论 |

## 设计文档（docs/design/）

**当前权威架构描述：[design/ARCHITECTURE.md](./design/ARCHITECTURE.md)** —— 模块现状、数据流、设计↔实现映射、关键决策记录（ADR）、技术债清单。

以下历史设计文档作为模块背景参考：

| 文档 | 对应模块 | 说明 |
|------|----------|------|
| [HIGH_PERFORMANCE_READER_CORE_DESIGN.md](./design/HIGH_PERFORMANCE_READER_CORE_DESIGN.md) | 整体架构 | 高性能核心阅读加载方案（Trait 抽象、流水线、零拷贝） |
| [UNIFIED_READ_SESSION_AND_IMPLEMENTATION.md](./design/UNIFIED_READ_SESSION_AND_IMPLEMENTATION.md) | reader_core/session | 统一阅读会话管理器（ReadSession、三章缓存、预加载） |
| [CORE_LAYOUT_ENGINE_DEEP_DIVE.md](./design/CORE_LAYOUT_ENGINE_DEEP_DIVE.md) | layout_engine | 排版引擎深度设计（字符边界、字形缓存、智能分段） |
| [PAGINATION_PRECISION_AND_RECOVERY.md](./design/PAGINATION_PRECISION_AND_RECOVERY.md) | layout_engine/pagination | 分页精度与配置迁移（字符偏移定位、孤行寡行避免） |
| [JS_ENGINE_OPTIMIZATION_TECHNICAL_DOC.md](./design/JS_ENGINE_OPTIMIZATION_TECHNICAL_DOC.md) | book_parser/chapter_extractor 等 | JS 引擎优化（rquickjs 集成、超时保护） |
| [DEEP_PREPROCESSING_OPTIMIZATION_TECHNICAL_DOC.md](./design/DEEP_PREPROCESSING_OPTIMIZATION_TECHNICAL_DOC.md) | reader_core/processing | 内容预处理流水线深度优化 |
| [FLOW_1_5_SCHEDULER_INTEGRATION_DESIGN.md](./design/FLOW_1_5_SCHEDULER_INTEGRATION_DESIGN.md) | reader_core/scheduler | 调度器集成方案 |
| [FLOW_2_CHAPTER_EXTRACTION_PLAN.md](./design/FLOW_2_CHAPTER_EXTRACTION_PLAN.md) | book_parser | 章节提取方案（JS 引擎识别 + 自定义规则） |
| [IMAGE_LOADING_PERFORMANCE.md](./design/IMAGE_LOADING_PERFORMANCE.md) | reader 图片链路 | 图片加载性能优化报告（A27 三阶段：链路图、根因、调优参数表） |

## 归档（docs/archive/）

历史性的一次性文档，已被后续工作取代或仅作过程记录：
- 各阶段完成报告 / 进度报告 / 状态快照（root_*）
- 被 CRLF 最终结论取代的中间修复分析
- 引擎迁移分析（BOOK_SOURCE_ENGINE / LAYOUT_ENGINE）

需要考古时再看，日常开发无需阅读。确认无用后可整体删除。

## 工具脚本

| 脚本 | 用途 |
|------|------|
| `fix_sync.ps1` | 完整重建流程：清理 → FFI codegen → Rust 构建 → 复制 DLL → Flutter 构建 |
| `build.ps1 -SkipRust` | 跳过 Rust 的快速构建 |
