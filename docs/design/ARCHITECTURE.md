# 架构设计：书籍导入 → 处理流水线

> 更新: 2026-08-22
> 地位: 本文档是当前架构的**权威描述**，以代码实际状态为准。
> 视角：**处理流程主线**——从文件导入到页面渲染的五个阶段；
> 按模块查代码的速查表见第 10 节附录。

---

## 0. 架构总原则

### D9：JS 引擎主链路原则 ⚡

**内容提炼、章节识别、规则替换一律以 QuickJS(rquickjs) 执行 JS 规则为主路径。
正则仅允许出现在两类位置：**

1. **降级兜底**：JS 异常/超时时的自动回退路径；
2. **极简构建**：`js-engine` feature 关闭时的无 JS 模式。

任何新的内容处理能力**不得以正则作为主实现**——相较于正则，
JS 引擎在大文本下能更高效地完成提炼与内容替换，且规则可由用户动态定义。

与该原则相悖的现状一律标注「⚠️ D9 违例」并列入修正路线图（§9.3）。
历史违例已全部清零：mmap 大文件章节识别走纯正则（A2 删除）、阅读级替换规则
string/regex 过渡态（A1 激活 JS 主路径）、广告净化硬编码正则（A4 迁移 JS 规则集）。

## 1. 流水线总览

```
┌────────────────────────────────────────────────────────────────────┐
│ 文件字节流                                                          │
│   │ 阶段二 编码检测（BOM→chardetng→启发式评分→GB18030 兜底）          │
│   ▼                                                                │
│ 解码文本 ──► (>10MB 走 mmap 映射，否则整本入内存)                     │
│   │ 阶段三 JS 章节规则识别 ▓JS▓（内置优先级链，超时降级正则兜底）        │
│   ▼                                                                │
│ 章节[(title, start, end, level, parent_index)]                      │
│   │ 阶段四a 导入级净化（结构规范化，一次完成；config_hash 失效重建）    │
│   │   · 净化后全文重新 JS 识别边界 ▓JS▓（数量不符按标题单调对齐兜底）    │
│   ▼                                                                │
│ 净化文本（净化章节缓存，mmap 落盘 {temp}/legado_cleaned/）            │
│   │ 阶段四b 阅读级预处理（偏好变换，随设置即时生效）                   │
│   │   · 六阶段流水线；目标态 JS 规则驱动 ▓JS▓，string/regex 为过渡态   │
│   ▼                                                                │
│ 最终显示文本 ─ CacheKey(book,chapter,config_hash,options_hash) LRU   │
│   │ 阶段五 排版分页（grapheme 切分 + 字形测宽 + 智能断页）             │
│   ▼                                                                │
│ Page[lines(x,y,w,text) + start/end_char_index] ──► Flutter 渲染     │
│       （anchor_char_offset 二分定位 → 设置变更停留在原阅读位置）       │
└────────────────────────────────────────────────────────────────────┘
▓JS▓ = QuickJS 引擎参与点；虚线兜底 = 正则仅在此出现
```

### 1.5 双线路现状矩阵（2026-08-22）

| 处理阶段 | TXT 线路 | EPUB 线路 |
|----------|----------|-----------|
| ① 加载解析工厂 | ✅ `BookSourceLoader` 格式判定 → 具体解析器 | ✅ 同一工厂判定分发 |
| ② 解码/解析 | ✅ BOM→chardetng→启发式评分→GB18030 兜底；全量解码 | ✅ ZIP 容器 + 结构 XML（container/OPF/NCX/nav，roxmltree）解析 |
| ③ 章节识别 | ✅ **JS 引擎**内置优先级规则链，正则仅降级兜底 | ✅ **TOC 提取**：OPF 声明优先（properties="nav"/media-type），NCX navMap / EPUB3 nav 标题映射到 spine |
| ④ 内容净化（导入级） | ✅ **JS 规则集主路径**（clean_rules，正则兜底）；净化缓存落盘 | ✅ EpubCleanedBook 逐章清洗 + 偏移重算，同构落盘 {temp}/legado_cleaned/ |
| ④' 内容预处理（阅读级） | ✅ 六阶段流水线；替换规则 **JS 主路径**（池化引擎），串/正则兜底 | ✅ 与 TXT 共用同一预处理 |
| ⑤ 排版分页 | ✅ 智能断页 + 字形缓存（两线共用） | ✅ 共用；图文混排等深度能力待技术选型 |
| 跨启动持久化 | ✅ 书架/进度/书签落库（drift），字符锚点恢复 | ✅ 同一机制（filePath 身份键） |

> **里程碑（2026-08-22，A4+A5 交付后）**：TXT 与 EPUB 双线在**净化（④）、
> 预处理（④'）、排版（⑤）、持久化**四层已完全统一——同一 `ContentCleaner`
> （JS 规则主路径）、同一 `ContentPreprocessor`、同一 `LayoutEngine`、
> 同一落库机制；EPUB 侧仅剩**深度加载解析**（图文混排、资源渲染、样式映射）
> 维持过渡物化线，待新线路技术选型后整体替换。

> EPUB 决策：现有「物化为同构 Book」为过渡方案；EPUB 处理流程将**另行技术选型**
> （图文混排、资源渲染、样式映射等按新线路整体设计，不在现线路深投）。
> 物化线内已完成**地基修正与净化对齐**（A5）：结构解析走 roxmltree、
> 净化缓存与 TXT 同构落盘——深度选型仍另行。

## 2. 阶段一：加载解析工厂

**统一入口**：`book_parser/src/loader.rs`
`BookSourceLoader`（L47）— `load()`（L54）按三级策略检测格式：
扩展名 → 16 字节魔数 → 文本内容分析（默认 TXT 兜底）（`detect_format_detailed` L79），
再分发构造器（`create_parser` L165）：`Txt→TxtParser::from_file`、
`Epub→EpubParser::from_file`；PDF/MOBI 明确拒绝。

| 现状 | 说明 |
|------|------|
| ✅ 工厂能力完整 | TXT/EPUB 分发 + 格式信息查询（`get_format/get_format_info`） |
| ✅ 主导入已收敛工厂判定（A3，2026-08-22） | `parse_txt_file_inner` 经 `BookSourceLoader::detect_format` 判定后走具体解析器（保留净化缓存能力）；非 TXT 明确报错；带 parser:None 缺陷的死入口 open_book_sync/async/unified 已删除 |
| ✅ EPUB 链路已打通（2026-08-22） | 导入经工厂分发 EpubParser，逐章提取物化为同构 Book（偏移与内容同源）；Dart 选择器已放行 .epub。三连阻塞 bug（NCX 无限递归、OPF 自闭合嵌套漏配、TOC 标题时序）已随 **A5 roxmltree 迁移根因消除**（scraper 仅留正文 XHTML 提取） |
| ✅ EPUB 结构解析迁移 roxmltree（A5，2026-08-22） | container/OPF/NCX/nav 全部走正规 XML 解析器：自闭合按规范闭合、nav 识别改由 OPF `properties="nav"` / media-type 声明驱动（文件名猜测仅兜底）、NCX 单遍文档序扫描替代递归；命名空间按本地名匹配 |
| 📌 决策 | **EPUB 处理流程将另行技术选型**（有别于 TXT 的独立线路）：现有物化方案为过渡实现，深度问题（图文混排、资源渲染、样式映射等）不在现线路投入，待选型后整体替换 |

→ 收敛方案见 §9.3 任务 A3。

## 3. 阶段二：编码检测与解析准备

`SmartEncodingDetector`（encoding.rs L21）四级策略：

1. **BOM 探测**（L64）
2. **chardetng** 前 8KB 采样，置信度 ≥0.9 直接采纳（L32–39）
3. **启发式评分**（`heuristic_detect` L115）：GBK/GB18030/BIG5/UTF-8 按
   文本质量打分（L154：CJK 字符占比 40 分、可打印字符 30、CJK 标点 20、无 U+FFFD 10）
4. **默认 UTF-8**；另有 GB18030 双重兜底（txt_parser.rs L878/L1000）

内存策略：`from_file`（L110）文件 >10MB（L119）自动切 mmap 模式
（编码取前 8KB 判定），否则整本读入内存解码。

## 4. 阶段三：JS 章节规则识别 ✅ 符合 D9

**执行引擎**：rquickjs 0.6（chapter_extractor.rs `execute_js_sync` L98：
新建 Runtime+Context，注入全局 `content`，脚本返回 JSON 化的
`Vec<JsChapterInfo>{title, lineNumber}`）。整体包裹
tokio timeout **5s**（L66）+ spawn_blocking；单章长度约束 500B–100KB（L67–68）。

**内置规则优先级链**（`build_default_rules` L380，`extract_with_default` L132，
首个非空结果胜出）：

| 优先级 | 规则 | 示例 |
|--------|------|------|
| p100 | 卷章结构 | `第X卷/第X章` 复合（L393） |
| p90 | 标准网文格式 | `第X章 …`（L412） |
| p80 | 英文书籍格式 | `Chapter N`（L429） |
| p70 | 数字编号 | `1/2/3…` |
| p60 | 特殊章节 | 序章/楔子/终章… |

**嵌套层级**：`build_chapter_info`（L153）行号→字节偏移
（扫描原始字节 `\n` 建表，CRLF 安全，L165–171；边界修复 L195–225）；
`detect_chapter_level`（L256）：卷/部/篇=0、章/Chapter=1、节/Section=2；
`parent_index` = 最近上级章节（L231–240）。

**降级兜底（符合 D9 定位）**：JS 失败/超时 → `extract_chapters_static`（L684，
4 正则模式 + 标题黑名单）；无 JS 构建经 cfg 门使用同函数（L620–624）。

| 现状 | 说明 |
|------|------|
| ✅ 统一 JS 识别（A2，2026-08-22） | 原 mmap 流式正则路径已删除（其存在 D2 偏移累加违例与 GBK「文件字节+解码偏移」混合错位 bug）；现全量解码后统一走 JS 识别，偏移与解码文本同源（D3），B4 实测 50MB 亚线性无回归 |
| ◐ 未接线资产 | `chapter_recognizer`（ChapterRecognizer L113：多模式置信度 + ContextAnalyzer 校验 L94 + 层级合并 L397）已实现但仅自测使用 |

## 5. 阶段四：内容净化与预处理

分层混合净化：导入时做**结构规范化**（一次完成，成本 ≈0），
阅读时只做**用户偏好变换**（随设置即时生效）。TXT 与 EPUB 共用同一净化器。

### 5a. 导入级 ContentCleaner（结构净化）

`book_parser/src/content_cleaner.rs`：

- `CleanOptions{clean_html, remove_ads, remove_extra_whitespace}`（默认全开）
- HTML 剥离 `<[^>]+>`；段落模式 `None | Smart(缩进/空行识别) | Force(两行一段)`
- 简繁转换经 `chinese_convert` 权威实现（zhconv 词组级，D6）
- `config_hash()` 逐项哈希配置 **+ 内置规则集内容哈希**（`ruleset_hash()`，
  规则升级即自动失效全部净化缓存）→ 净化章节缓存失效检测
- 广告清理：**内置 JS 规则集主路径**（A4，2026-08-22）——
  `clean_rules.rs::BUILTIN_AD_RULES_JS` 单一合并脚本，经进程级持久
  QuickJS Context 执行（懒初始化复用；rquickjs 中断句柄真超时 3s；
  失败告警限频），原 5 条硬编码正则保留为**兜底**
  （JS 异常/超时/极简构建时回落）

**净化章节缓存**（txt_parser.rs `build_cleaned_chapter_cache` L278，
懒执行于首读 `ensure_cleaned_chapter_cache` L533）：
解码原文 → `clean()` → **在净化后文本上重新运行 JS 章节识别**
（`compute_cleaned_offsets` L344；数量不符或异常 → 按标题单调对齐兜底 L393）
→ 写盘 `{temp}/legado_cleaned/{filehash}_{config_hash}.txt`（mmap 模式 L552）。
设置变更时 hash 不匹配自动重建；api.rs `update_book_cleaning` 同步清空分页缓存。

### 5a'. EPUB 导入级净化缓存（EpubCleanedBook，A5）

`book_parser/src/epub_clean_cache.rs`：物化 Book 视同 TXT 解码全文处理——
逐章独立清洗（clean() 各阶段无跨章上下文；标题行不参与清洗）
→ 按导入同款框架（`title\n`+body+`\n\n`）串联并累加字节偏移
（天然 D3 同源，无需 JS 重识别/标题对齐）。懒构建于首读，
config_hash 不符自动重建；落盘 `{temp}/legado_cleaned/{pathhash}_{hash}.epub.txt`
（首行 JSON 偏移头 + 全文），跨启动命中免重建。
EPUB 清洗器强制 `clean_html=false`（内容已是纯文本，防正则误删字面 `<xxx>`）。
读取路径 api.rs `get_chapter_content` 三分支：TXT parser 缓存 /
EPUB 缓存切片 / 无净化选项原样切片（构建失败回落旧「切片+逐读净化」）。

### 5b. 阅读级 ContentPreprocessor（偏好变换）

`reader_core/src/content_preprocessor.rs` 六阶段流水线（顺序即 D7 决策）：

```
① 去重标题 → ② 重分段 → ③ HTML保护(占位符映射)
→ ④ 替换规则(string直替 + regex带超时,超时自动禁用)
→ ⑤ HTML恢复 → ⑥ 简繁转换(最后执行: 用户规则按原文书写)
```

- `ReplaceRule{pattern, replacement, rule_type(String|Regex|Js), timeout_ms, enabled}`
  （JS 规则：`pattern` 承载脚本，全局 `chapterContent` 入、返回全文，legado 风格）
- 性能基建：`RegexCache` LRU(256) 摊销编译；bridge 按规则集哈希池化预处理器
  （`RULES_PREPROCESSORS` max 8，规则不变复用实例）
- 即时生效机制：处理选项进 `CacheKey.options_hash`（去重标题/重分段/简繁/规则哈希，
  D8）→ 变更即新 key 自然重算；`anchor_char_offset` 二分定位保证进度保持；
  分页计数与页面内容必须携带同一组选项

| 现状 | 说明 |
|------|------|
| ✅ JS 主路径已激活（A1，2026-08-22） | `RuleType::Js` 规则经进程级共享 `JsRuntimePool` 执行（持久化 QuickJS 实例，中断句柄超时）；string/regex 为兜底。FFI `FfiReplaceRule.rule_type`（0=串/1=正则/2=JS） |
| ✅ 池化资产已接线 | `processing/js_runtime_pool.rs` 全局池(容量4)接入 ContentPreprocessor 与 JsExecutorWithPool（真语义）；`JsExecutor` 遗留的每规则新建实例反模式已消除 |
| ⚠️ D9 违例（轻） | 广告净化 5 条硬编码正则（见 5a），演进为 JS 规则集待办 |

性能实测（B2/B3，详见 PERF 报告）：JS 规则 ~0.13ms/条/10KB（注入直构+元数据懒注入优化后），
线性扩展；池化收益 1.6x；嵌套章节识别 35.5ms/百万字符（预算 300ms）。

## 6. 阶段五：排版（现状）

`layout_engine`：

- `LayoutEngine::layout_text`：grapheme 切分 → 逐字符宽度测量
  （GlyphCache 线程安全 LRU 10,000 条 + 命中率统计）
- 智能断页：段落完整性优先（75% 填充阈值）、最少 3 行孤行守卫
  （`MIN_LINES_PER_PAGE=3`）、`is_chapter_start` 强制新页（D5）
- 页面携带 `start/end_char_index`（章内字符偏移）——锚点定位与进度恢复的基础

**未接线资产**（benches/单测在用，热路径未用）：
`SmartPaginator`（y-gap 段落探测 + 寡行/孤行避免 flag）、
`parallel.rs`（rayon 多章并行布局 + 共享字形缓存）、
`AdvancedGlyphCache`（GB2312 一二级字预热）。

**缺口清单**：避头尾(kinsoku 行首行尾禁则)、两端对齐、诗歌/对话智能分段、
图文混排（EPUB 内容现为纯文本流）、首字下沉、连字断词。

## 7. 阶段六（未来设计草案）：高级智能排版

> 本节是蓝图，未经实现；接口以届时专项设计文档为准。
> 总原则不变：算法能力优先在 layout_engine 内闭环，不引入正则主实现。

| 优先级 | 特性 | 依赖说明 |
|--------|------|----------|
| P1 | CJK 避头尾与行首行尾禁则 | 纯换行决策算法，layout_engine 内闭环 |
| P1 | 两端对齐 | 逐行 justify pass（字距微调），需行内可伸缩度量 |
| P2 | 诗歌/对话/引用智能分段 | 挂接阶段四b 规则扩展点（届时为 JS 规则） |
| P2 | 激活 SmartPaginator / parallel / AdvancedGlyphCache 至 bridge 热路径 | 现成资产接线，含缓存一致性验证 |
| P3 | 图文混排 | 强依赖 EPUB 链路打通 + Page 结构支持 inline object |
| P4 | 首字下沉、竖排 | 远期 |

## 8. 性能实测汇总（2026-08-21 v2 口径）

测试环境：Windows release；《贷款武圣(1-280章)》5.0MB / 279 章。
复现：`cargo run --release --package reader_core --example perf_baseline`
（v2 含 CPU 时间 GetProcessTimes + 工作集 GetProcessMemoryInfo 维度）

| 链路 | 实测 | 设计目标 | 结论 |
|------|------|----------|------|
| 导入 parse（JS 章节识别） | 无净化 99ms / 含净化 98ms | 打开 <300ms | ✅ 净化零成本，3 倍余量 |
| 净化缓存构建（净化后全文 JS 重识别） | ~101ms（一次性） | — | ✅ |
| 章节读取 ×20（缓存命中） | max 3µs | — | ✅ |
| 内容预处理（单章，小规则集） | avg ~67–162µs | <100ms/10k 字 | ✅ 微秒级 |
| 排版分页（单章 12 页，字形缓存热） | avg 438µs | 首屏 <100ms | ✅ |
| 锚点定位（二分，单次） | ~3ns | — | ✅ 可忽略 |
| 设置变更重建（清缓存+重排单章） | 118ms / ΔWS +0.3MB | 即时响应 | ✅ 无感 |

其余基准资产：`layout_engine/benches/layout_bench.rs`（criterion：单章 1k/5k/10k 字、
并行 3/5/10 章、字形命中率）；`verify_real_book.rs`（真实书功能断言，无计时）。

**注意**：以上均为小规则集场景。JS 规则规模化（嵌套规则、多规则、引擎冷启动）
的数据空白见 §9.1 盲区登记。

## 9. 性能盲区登记 + 补测计划

### 9.0 测量口径（D9 落实）

**所有基准在 `js-engine` 启用（默认特性）、JS 流水线为主路径的状态下测量。**
正则只单列一组「降级兜底护栏」用例，用于验证降级正确性与兜底性能上限，
**不作为性能达标对象**。

### 9.1 盲区登记

| # | 盲区 | 状态（2026-08-22） |
|---|------|----------|
| G1 | 嵌套章节规则识别成本 | ✅ 已测：35.5ms/百万字符（B1，预算 300ms 的 1/8.7） |
| G2 | 多条 JS 净化/替换规则扩展性 | ✅ 已测：~0.13ms/条/10KB 线性（B2） |
| G3 | QuickJS 引擎调用成本 | ✅ 已测：冷启动 0.92ms vs 池化 0.57ms（B3，收益 1.6x） |
| G4 | 大文件缩放曲线 | ✅ 已测：1/5/20/50MB 导入 24/74/237/581ms，**亚线性**（50x 体积→24x 耗时）（B4） |
| G5 | 端到端 miss 延迟分解 | ✅ 已测：单章 0.771ms = 取内容 7% + JS 预处理 70% + 排版 23%（B5） |

### 9.2 补测结果（B1–B3 已完成，2026-08-22 实测）

| # | 场景 | 结果 |
|---|------|------|
| B1 | 嵌套章节规则（JS 路径）：卷50×章20×节2 ≈ 千章书 / 1M 字符 | **34.5ms avg → 35.5ms/M 字符 [PASS]**（预算 <300ms）。发现：默认规则集以"章"为切分粒度，卷/节不单独成章——层级字段就绪，拆分需自定义 JS 规则 |
| B2 | 多规则扩展性：10KB 章 × N=1/10/50/200，js/string/regex 对照 | JS: 0.18/1.30/6.31/24.48ms（avg），**线性 ~0.13ms/条**；string 0.005–0.28ms；regex 0.05–3.2ms。两项注入优化（正文直构 + 元数据懒注入）共降 ~40% |
| B3 | QuickJS 成本：冷启动 vs 池化 | 冷 0.923ms / 池化 0.570ms / 持守卫纯执行 0.519ms；池命中 30/31。实际冷启动远低于传闻 10–20ms，池化稳定省 ~40% |
| B4 | 大文件缩放 | ✅ 1/5/20/50MB 导入 24.2/74.0/236.6/580.5ms（164/824/3297/8243 章），**亚线性**；首读 <10µs |
| B5 | 端到端分解（缓存 miss，300 章书单章） | ✅ 合计 **0.771ms**：取内容 0.051ms(7%) + JS 预处理 0.541ms(70%) + 排版 0.178ms(23%)；净化缓存首次构建一次性 16.1ms |

复现：
```
cargo run --release -p reader_core --features js-engine --example bench_quickjs_cost
cargo run --release -p reader_core --features js-engine --example bench_rule_scaling
cargo run --release -p book_parser --example bench_nested_chapter_rules
cargo run --release -p book_parser --example bench_large_file_scaling
cargo run --release -p bridge --features js-engine --example bench_e2e_decomposition
```

### 9.3 修正路线图

| # | 任务 | 内容 | 状态 |
|---|------|------|------|
| A1 | **激活 JS 预处理流水线** | JsRuntimePool 接线热路径；`RuleType::Js` 主路径（string/regex 兜底）；JsExecutorWithPool 真语义；持久化 QuickJS 实例 + 中断句柄超时 | ✅ 完成（2026-08-22） |
| A2 | **统一章节识别走 JS** | 删除 mmap 流式正则识别（含 D2 累加违例与 GBK 混合偏移 bug），全量解码后统一 JS 识别；净化缓存改按大小落盘 mmap；新增 GBK 偏移回归测试 | ✅ 完成（2026-08-22），B4 验证无性能回归 |
| A3 | **收敛统一加载工厂** | `parse_txt_file_inner` 经工厂格式判定（非 TXT 明确报错）；删除三个带 parser:None 缺陷的死入口 open_book_sync/async/unified | ✅ 完成（2026-08-22） |
| A4 | **净化规则 JS 化** | 内置 JS 广告规则集主路径（`clean_rules.rs` 持久 Context + 中断句柄真超时），原 5 条正则转兜底；`ruleset_hash()` 并入 config_hash，TXT/EPUB 双线受益 | ✅ 完成（2026-08-22） |
| A5 | **EPUB 净化链路对齐 TXT** | 结构解析迁移 roxmltree（根除 html5ever 解析 XML 的自闭合嵌套/递归溢出类 bug）；`EpubCleanedBook` 逐章清洗+偏移重算+同构落盘；废除逐读重复净化；EPUB 强制 clean_html=false | ✅ 完成（2026-08-22） |

## 10. 附录

### 10.1 模块速查表（按模块查代码用）

| Crate | 关键组件 | 一句话职责 |
|-------|----------|-----------|
| book_parser | loader / txt_parser / epub_parser / chapter_extractor / chapter_recognizer / content_cleaner / clean_rules / epub_clean_cache / chinese_convert / encoding | 加载工厂、TXT 主解析、EPUB 解析(roxmltree 结构解析)、JS 章节规则、置信度识别器(未接线)、导入级净化(JS 规则主路径)、EPUB 净化缓存、zhconv 简繁权威实现、编码检测 |
| layout_engine | LayoutEngine / SmartPaginator(未接线) / GlyphCache / parallel(未接线) / AdvancedGlyphCache(未接线) | 排版分页、智能分页、字形测宽缓存、多章并行、GB2312 预热 |
| reader_core | ContentPreprocessor / processing/(休眠) / ReadSessionManager / position_tracker / PaginationCache | 阅读级六阶段预处理、富流水线+JS池(待激活)、阅读会话、偏移定位、LRU 分页缓存 |
| bridge | api.rs（BOOKS/PAGINATION_CACHE/RULES_PREPROCESSORS/FONT_MANAGER） | 全部 FFI 入口；process_and_layout_chapter 统一「处理+排版」实现 |
| book_source_engine | CSS/JSONPath/Regex 分析器 | 书源规则（无 JS，与章节识别 JS 是两回事） |

### 10.2 关键决策记录（ADR）

- **D1** 章节识别走 JS 引擎规则，放弃多级正则+置信度评分；正则仅为降级路径
- **D2** 字节偏移一律扫描原始字节 `\n` 建立行起始表（禁止 `lines()[i].len()+1` 累加）
- **D3** 章节边界与所索引文本同源：净化后必须重新计算边界，不符按标题单调对齐兜底
- **D4** 调度落地形态为 PreloadExecutor + DefaultPreloadStrategy（旧文档命名漂移注意）
- **D5** 章节强制分页通过 `TextLine.is_chapter_start` 标记传递
- **D6** 简繁转换唯一权威实现 = `book_parser::chinese_convert`（zhconv 词组级），
  导入级与阅读级共用；另立实现必然漂移
- **D7** 替换规则先于简繁转换执行（规则按原文书写，先转换则规则无法命中）
- **D8** 处理选项进 `CacheKey.options_hash`：设置变更新 key 自然重算 + 锚点二分定位保进度
- **D9** **JS 引擎主链路原则**：提炼/识别/替换以 QuickJS 执行 JS 规则为主，
  正则仅降级兜底与极简构建两种存在形式（§0）

### 10.3 工程硬约束（违反即出 Bug）

1. 字节偏移禁止 `lines()[i].len()+1` 累加 → 扫描原始 `\n`
2. 章节边界必须与所索引文本同源（净化后需重算）
3. UTF-8 切片必过字符边界检查；`\u{3000}` 占 3 字节
4. 标题比对前两侧都需 trim（全角空格）
5. 替换规则先于简繁转换执行
6. 简繁转换只经由 `book_parser::chinese_convert`，不得另建实现
7. 影响页面文本的处理选项必须纳入 options_hash；分页计数与内容携带同一组选项
8. **内容提炼/替换类新能力禁止以正则为主实现——正则仅兜底（D9）**
