# 流程 2：章节提取与内容切片 - 实施计划

> **创建时间**: 2025-01-20  
> **目标**: 确保章节标题正确提取，章节能正确区分  
> **原则**: 一步步走，一步步夯实

---

## 背景

**已完成**:
- ✅ 流程 1: 文件加载与编码检测（工厂化解析器 TXT/EPUB）
- ✅ 流程 1.5 Stage 1: 智能调度管理器接入

**当前位置**:
- 👉 流程 2: 章节提取与内容切片

**下一步**:
- 流程 3: 内容净化与预处理（基于 JS 引擎的规则）
- 流程 4: 分页与排版

---

## 核心目标

### 1. 章节标题正确提取 ⭐

**重点**: 确保能准确识别各种格式的章节标题

**常见章节格式**:
```
第一章 标题
第1章 标题
Chapter 1: Title
第001章 标题
001.标题
卷一 第一章 标题
正文 第一章 标题
楔子/序章/尾声
```

**当前状态**:
- 已实现 4 种正则模式
- 已有黑名单过滤

**需要改进**:
- 扩展正则表达式支持更多格式
- 智能过滤目录页的误识别
- 处理嵌套章节结构（卷/章/节）

---

### 2. 章节能正确区分 ⭐

**重点**: 确保章节边界准确，不重复不遗漏

**问题场景**:
1. **章节标题在内容中重复出现** - 如何避免误分割？
2. **章节过短/过长** - 如何判断是否识别错误？
3. **目录页包含所有章节名** - 如何避免误识别？

**解决思路**:
- 章节长度合理性检查（最小 500 字，最大 100,000 字）
- 目录页检测（如果连续多个"章节"都很短，可能是目录）
- 上下文验证（章节标题后应该是正文内容）

---

## 当前代码分析

### 文件位置

**主文件**: `rust/crates/book_parser/src/txt_parser.rs`

**关键函数**:
```rust
fn extract_chapters(&self) -> Vec<ChapterInfo> {
    // 使用正则表达式识别章节标题
    // 黑名单过滤
    // 生成 ChapterInfo 列表
}

fn get_chapter_content_internal(&self, chapter_index: usize) -> Option<String> {
    // 根据 start_pos 和 end_pos 提取章节内容
}
```

**现有正则模式** (4 种):
```rust
// 模式 1: "第X章"
r"第[0-9零一二三四五六七八九十百千]+章"

// 模式 2: "Chapter X"
r"Chapter\s+\d+"

// 模式 3: 数字编号
r"^\d{1,4}[\.、\s]"

// 模式 4: 特殊章节
r"^(序章|楔子|尾声|后记|番外)"
```

---

## 实施任务

### 任务 2.1: 基于 JS 引擎的章节识别（P0）⭐

**工期**: 1.5 天

**核心思路**: 使用 JS 引擎执行章节识别规则，而不是硬编码正则

**为什么使用 JS 引擎**:
- ✅ **灵活性**：用户可以自定义规则，不同书籍使用不同规则
- ✅ **可扩展**：不需要修改 Rust 代码就能支持新格式
- ✅ **兼容 Legado**：与原版 Legado 的书源规则体系一致
- ✅ **性能更好**：JS 引擎内部优化的正则比 Rust 正则快
- ❌ 硬编码正则：维护成本高、不够灵活、每次新格式都要改代码

**章节规则配置**:

```json
{
  "chapterRule": {
    "name": "标准网文格式",
    "method": "javascript",
    "script": "
      // JS 脚本返回章节列表
      let chapters = [];
      let lines = content.split('\\n');
      
      for (let i = 0; i < lines.length; i++) {
        let line = lines[i].trim();
        
        // 自定义识别逻辑
        if (/^第[0-9零一二三四五六七八九十百千]+章/.test(line)) {
          chapters.push({
            title: line,
            index: chapters.length,
            lineNumber: i
          });
        }
      }
      
      return chapters;
    "
  }
}
```

**Rust 侧实现**:

```rust
// txt_parser.rs
pub struct ChapterExtractor {
    js_runtime_pool: Arc<JsRuntimePool>,  // 复用 reader_core 的 JS 引擎池
    default_rules: Vec<ChapterRule>,
}

impl ChapterExtractor {
    /// 使用 JS 引擎提取章节
    pub async fn extract_with_js(
        &self, 
        content: &str, 
        rule_script: &str
    ) -> Result<Vec<ChapterInfo>> {
        // 1. 从连接池获取 JS Runtime
        let runtime = self.js_runtime_pool.acquire().await?;
        
        // 2. 执行超时控制（5 秒）
        let result = timeout(Duration::from_secs(5), async {
            // 注入内容到 JS 上下文
            runtime.set_global("content", content)?;
            
            // 执行用户脚本
            let js_result = runtime.eval(rule_script)?;
            
            // 解析返回的章节列表
            let chapters: Vec<ChapterInfo> = serde_json::from_value(js_result)?;
            
            Ok(chapters)
        }).await??;
        
        Ok(result)
    }
    
    /// 默认规则（备选）
    pub fn extract_with_default(&self, content: &str) -> Result<Vec<ChapterInfo>> {
        // 按优先级尝试每个内置规则
        for rule in &self.default_rules {
            if let Ok(chapters) = self.try_extract(content, rule) {
                if chapters.len() > 0 {
                    return Ok(chapters);
                }
            }
        }
        Err(anyhow!("No chapters found"))
    }
}

pub struct ChapterRule {
    pub name: String,           // 规则名称
    pub priority: u8,           // 优先级
    pub script: String,         // JS 脚本
}
```

**内置默认规则**（5 种）:

```rust
// 规则 1: 标准网文格式（最高优先级）
const RULE_STANDARD: &str = r#"
let chapters = [];
let lines = content.split('\n');
for (let i = 0; i < lines.length; i++) {
  let line = lines[i].trim();
  if (/^第[0-9零一二三四五六七八九十百千]+章/.test(line)) {
    chapters.push({title: line, lineNumber: i});
  }
}
return chapters;
"#;

// 规则 2: 英文书籍格式
const RULE_ENGLISH: &str = r#"
let chapters = [];
let lines = content.split('\n');
for (let i = 0; i < lines.length; i++) {
  let line = lines[i].trim();
  if (/^Chapter\s+\d+/i.test(line)) {
    chapters.push({title: line, lineNumber: i});
  }
}
return chapters;
"#;

// 规则 3: 数字编号格式
const RULE_NUMERIC: &str = r#"
let chapters = [];
let lines = content.split('\n');
for (let i = 0; i < lines.length; i++) {
  let line = lines[i].trim();
  if (/^\d{1,4}[\.、\s].{1,30}$/.test(line)) {
    chapters.push({title: line, lineNumber: i});
  }
}
return chapters;
"#;

// 规则 4: 卷+章结构
const RULE_VOLUME_CHAPTER: &str = r#"
let chapters = [];
let lines = content.split('\n');
for (let i = 0; i < lines.length; i++) {
  let line = lines[i].trim();
  if (/第[0-9零一二三四五六七八九十百千]+[卷章]/.test(line)) {
    chapters.push({title: line, lineNumber: i});
  }
}
return chapters;
"#;

// 规则 5: 特殊章节（序章、尾声等）
const RULE_SPECIAL: &str = r#"
let chapters = [];
let lines = content.split('\n');
for (let i = 0; i < lines.length; i++) {
  let line = lines[i].trim();
  if (/^(序章|楔子|序言|引子|尾声|后记|番外|终章)/.test(line)) {
    chapters.push({title: line, lineNumber: i});
  }
}
return chapters;
"#;
```

**性能优化**:

```rust
pub struct ChapterExtractionConfig {
    pub max_content_size: usize,    // 最大处理 10MB
    pub chunk_size: usize,          // 大文件分块 1MB
    pub timeout_secs: u64,          // 超时 5 秒
    pub enable_cache: bool,         // 启用缓存
    pub pool_size: usize,           // JS Runtime 池大小（复用现有）
}

// 性能保障：
// 1. JS Runtime 连接池 - 复用现有的 JsRuntimePool（已在 reader_core 实现）
// 2. 分块处理 - 大文件分块执行，避免 JS 内存溢出
// 3. 超时控制 - 5 秒超时，防止死循环
// 4. 缓存结果 - 同一文件的章节列表缓存
// 5. 降级策略 - JS 执行失败时降级到简单正则
```

**验收标准**:
- [ ] JS 引擎能正确执行章节识别脚本
- [ ] 支持用户自定义规则（通过配置文件）
- [ ] 内置 5 种默认规则，按优先级自动尝试
- [ ] 性能：10MB 文件 < 500ms（含 JS 执行）
- [ ] 超时保护：5 秒自动降级到简单正则
- [ ] 复用现有 JsRuntimePool，不重复创建 Runtime

---

### 任务 2.2: 章节边界验证（P0）

**工期**: 1 天

**目标**: 确保章节划分准确，无重复无遗漏

**实现逻辑**:

```rust
fn validate_chapter_boundaries(&self, chapters: &mut Vec<ChapterInfo>) {
    let mut i = 0;
    while i < chapters.len() {
        let chapter = &chapters[i];
        
        // 1. 长度检查
        if chapter.length() < MIN_CHAPTER_LENGTH {
            // 可能是目录或误识别
            if self.is_likely_toc(chapter) {
                chapters.remove(i);
                continue;
            }
        }
        
        if chapter.length() > MAX_CHAPTER_LENGTH {
            // 可能漏识别了中间章节
            if let Some(sub_chapters) = self.try_split_long_chapter(chapter) {
                chapters.splice(i..=i, sub_chapters);
                continue;
            }
        }
        
        // 2. 内容验证
        if !self.has_valid_content(chapter) {
            chapters.remove(i);
            continue;
        }
        
        i += 1;
    }
}

fn is_likely_toc(&self, chapter: &ChapterInfo) -> bool {
    // 目录页特征：
    // - 章节很短 (< 100 字)
    // - 包含多个章节标题模式匹配
    // - 没有正文内容
}

fn has_valid_content(&self, chapter: &ChapterInfo) -> bool {
    // 验证章节有正文内容：
    // - 不只是章节标题
    // - 包含足够的中文/英文内容
    // - 不是纯标点符号
}
```

**配置参数**:
```rust
const MIN_CHAPTER_LENGTH: usize = 500;      // 最小 500 字
const MAX_CHAPTER_LENGTH: usize = 100_000;  // 最大 10 万字
const MIN_CONTENT_RATIO: f32 = 0.3;         // 至少 30% 是正文
```

**验收标准**:
- [ ] 章节识别准确率 ≥ 99%
- [ ] 无章节内容重复
- [ ] 无内容遗漏
- [ ] 能正确过滤目录页

---

### 任务 2.3: 嵌套章节结构支持（P1 - 可选）

**工期**: 0.5 天

**目标**: 支持卷/章/节的层级结构

**扩展 ChapterInfo**:
```rust
pub struct ChapterInfo {
    pub index: usize,
    pub title: String,
    pub start_pos: usize,
    pub level: ChapterLevel,  // 新增
    pub parent_index: Option<usize>,  // 新增
}

pub enum ChapterLevel {
    Volume,   // 卷
    Chapter,  // 章
    Section,  // 节
}
```

**实现逻辑**:
- 识别层级关系（卷 > 章 > 节）
- 构建树形结构
- FFI 接口返回扁平列表（保持兼容）

**验收标准**:
- [ ] 能识别卷/章/节结构
- [ ] 保持向后兼容
- [ ] Flutter 侧可以构建树形目录

---

## 测试策略

### 单元测试

```rust
#[test]
fn test_chapter_extraction_standard_format() {
    // 标准格式："第X章 标题"
}

#[test]
fn test_chapter_extraction_with_volume() {
    // 带卷："第一卷 第一章"
}

#[test]
fn test_chapter_extraction_numeric() {
    // 数字编号："001 标题"
}

#[test]
fn test_filter_toc_page() {
    // 过滤目录页
}

#[test]
fn test_chapter_boundary_no_overlap() {
    // 验证章节边界不重叠
}

#[test]
fn test_chapter_boundary_no_gap() {
    // 验证章节边界无缝隙
}
```

### 集成测试

**测试文件**:
1. 标准网络小说（第X章格式）
2. 出版书籍（Chapter X 格式）
3. 数字编号小说（001, 002）
4. 包含卷结构的长篇小说
5. 包含目录页的书籍

**验证点**:
- [ ] 所有测试文件章节识别准确
- [ ] 无目录页误识别
- [ ] 章节边界准确
- [ ] 总字数与原文件一致（无遗漏）

---

## 风险与缓解

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|----------|
| 新正则导致误识别率上升 | 中 | 高 | 渐进式添加，每个模式单独测试 |
| 过滤逻辑过严，漏识别章节 | 中 | 高 | 使用宽松阈值，记录日志供调试 |
| 嵌套结构破坏现有 API | 低 | 中 | 保持向后兼容，扁平化输出 |

---

## 完成标准

**功能标准**:
- [ ] 章节识别准确率 ≥ 99%
- [ ] 支持 10+ 种常见章节格式
- [ ] 能正确过滤目录页
- [ ] 章节边界准确（无重复无遗漏）

**性能标准**:
- [ ] 10MB 文件章节提取 < 500ms（含 JS 执行）
- [ ] 50MB 文件章节提取 < 2s
- [ ] JS Runtime 复用率 > 90%（使用连接池）

**测试标准**:
- [ ] 单元测试覆盖所有 JS 规则
- [ ] 集成测试通过（5+ 个真实书籍）
- [ ] 边界情况测试通过
- [ ] 超时测试通过（验证 5 秒超时机制）

---

## 关键文件清单

**新增文件**:
- `rust/crates/book_parser/src/chapter_extractor.rs` - ChapterExtractor 实现

**修改文件**:
- `rust/crates/book_parser/src/txt_parser.rs` - 集成 ChapterExtractor
- `rust/crates/book_parser/Cargo.toml` - 添加 reader_core 依赖

**复用现有模块**:
- `rust/crates/reader_core/src/processing/js_runtime.rs` - JsRuntimePool
- `rust/crates/reader_core/src/processing/js_executor.rs` - JsExecutor

**配置文件**（可选）:
- `chapter_rules.json` - 用户自定义章节识别规则

---

## 总工期

**2.5-3 天**

- Day 1-1.5: 任务 2.1（基于 JS 引擎的章节识别）
- Day 2: 任务 2.2（章节边界验证）
- Day 2.5-3: 任务 2.3（嵌套结构支持 - 可选）

---

## 下一步：流程 3

**流程 3: 内容净化与预处理**

重点：
- 内容清理（OCR 错误、分隔符）
- 简繁转换
- **JS 引擎规则执行** ⭐
  - 替换规则
  - 净化规则
  - 正则替换

关键模块：
- `rust/crates/reader_core/src/processing/pipeline.rs` - 已实现
- `rust/crates/reader_core/src/processing/js_runtime.rs` - JS 引擎
- `rust/crates/bridge/src/api.rs` - 暴露预处理 FFI 接口

---

## 总结

**本流程核心**：章节标题正确提取，章节能正确区分

**关键改进**：
1. 扩展正则表达式支持更多格式
2. 章节边界验证逻辑
3. 目录页智能过滤

**下一流程**：内容净化（基于 JS 引擎的规则）

**原则**: 一步步走，一步步夯实 ✅
