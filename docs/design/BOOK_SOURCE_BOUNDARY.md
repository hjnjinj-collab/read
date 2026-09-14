# 在线书源：实现边界盘点

> 更新: 2026-09-13
> 地位: 正式开工在线书源前的**权威边界清单**。以代码实际状态为准。
> 关联: [ARCHITECTURE.md](./ARCHITECTURE.md) · [README 在线书源](../README.md) · [book_source_engine](../../rust/crates/book_source_engine/) · [BookSourceService](../../lib/core/services/book_source_service.dart)

---

## 1. 一句话结论

**规则引擎 + HTTP 网络层 + FFI 全链路 + Dart 封装已就绪；书源持久化是空壳，UI 零调用，在线书→本地书架闭环未建。**

正式开工时，优先做持久化与 UI 接线，而不是重写解析器。

---

## 2. 已就绪（可直接调用）

### 2.1 Rust 规则引擎 `book_source_engine`

| 模块 | 路径 | 能力 |
|------|------|------|
| 类型 | `src/types.rs` | Legado 风格 `BookSource`（camelCase）：search / book_info / toc / content / explore 规则、header / cookie / login_url / weight |
| 规则解析 | `src/rule_parser.rs` | `@css:` / `@json:` / `@xpath:` / `@js:` 前缀；`@@` = 取全部；`##regex##replace` 后缀；无前缀走 Default 自动检测 |
| CSS | `src/analyzers/jsoup.rs` | scraper CSS 选择器；`.sel@attr` 取属性；text / html 两种抽取 |
| JSONPath | `src/analyzers/jsonpath.rs` | 简化 JSONPath：`$.a.b` / `$[0]` / `[*]` / 组合路径（非完整 RFC） |
| Regex | `src/analyzers/regex.rs` | 提取与替换 |
| 编排 | `src/lib.rs` | `search` / `get_book_info` / `get_toc` / `get_content`：占位符 `{{key}}` `{{keyword}}` `${key}`、相对 URL 解析、正文 `replace_regex`、VIP/volume 标记 |

### 2.2 HTTP 网络层 `http_client.rs`

- reqwest 0.12 + **rustls-tls**（与主工程一致，无 OpenSSL）
- Cookie 存储、gzip、charset 自动探测解码
- 全局并发信号量 8，默认超时 30s
- GET / POST（含自定义 header / body）

> README 历史表述「缺网络层」已过时——网络层在引擎 crate 内已完备。

### 2.3 FFI（bridge/api.rs §书源解析引擎 API）

| API | 状态 | 说明 |
|-----|------|------|
| `search_book` / `search_book_by_json` | ✅ 可用 | 返回 `SearchBookItem` JSON 数组 |
| `get_book_info` / `get_book_info_by_json` | ✅ 可用 | 返回书籍信息 JSON |
| `get_toc` / `get_toc_by_json` | ✅ 可用 | 返回章节 JSON 数组 |
| `get_chapter_content_from_source` / `..._json` | ✅ 可用 | 返回 `{content, next_url}` |
| `load_book_source` / `load_book_source_ffi` | ⚠️ 仅校验 | 反序列化成功即返回 URL，**不落库** |
| `get_book_source_json` | ❌ 占位 | 恒返回 not found |
| `list_book_sources` | ❌ 占位 | 恒返回 `"[]"` |
| `delete_book_source` | ❌ 占位 | no-op Ok |
| `set_book_source_enabled` | ❌ 占位 | no-op Ok |

### 2.4 Dart 封装

- [`lib/core/services/book_source_service.dart`](../../lib/core/services/book_source_service.dart)：全部可用 API 的薄封装 + `SearchBookItem` / `BookInfo` / `ChapterInfoItem` / `ChapterContent` 模型
- [`test/book_source_service_test.dart`](../../test/book_source_service_test.dart)：JSON 模型往返测试
- **零 UI 调用点**（全库 grep 确认）

---

## 3. 明确未做（正式开工清单）

### 3.1 持久化（阻塞一切管理 UI）

当前 `load_*` 只校验解析，不写存储；list / get / delete / enable 全是 stub。

需要：

1. 存储层选型：drift 表（与 Books/Notes 同库）或独立 JSON 文件目录
2. `load` 真正 upsert；`list` / `get` / `delete` / `set_enabled` 落地
3. 启动加载、分组、权重排序
4. 导入路径：本地 `.json` 文件 / 剪贴板粘贴 /（可选）订阅 URL

### 3.2 UI 零接线

无书源管理页、无在线搜索页、无书籍详情页、无下载进书架。

本期 UI 批次只做应用壳与书架重做，书源页为空壳占位；正式书源批次再接。

### 3.3 在线书 → 阅读器闭环

现有阅读器只吃**本地文件路径**（`ReaderPage(filePath:)`）。缺：

1. 章节正文缓存策略（内存 / 磁盘、分章落盘）
2. 在线书在 drift `Books` 表的建模（`filePath` 身份键 vs source+bookUrl）
3. 进度 / 书签 / 笔记对「无本地文件」书的锚点约定
4. 封面网络下载与书架封面缓存（现仅 EPUB 本地提取）
5. 下一章预取与失败重试

### 3.4 规则能力边界（解析器侧）

| 能力 | 状态 | 说明 |
|------|------|------|
| CSS / JSONPath / Regex | ✅ | 主路径 |
| XPath | ⚠️ 降级 | 有前缀解析，执行时当 CSS 用，真实 XPath 会失败 |
| 书源内 JS 规则 | ❌ | `RuleType::JavaScript` 直接 `Err`，**与章节识别用的 QuickJS 不是同一条链** |
| 多页正文拼接 | ⚠️ 半成品 | 能解析 `next_url`，引擎**不会自动翻页拉齐**，调用方需自己循环 |
| 请求头 / Cookie 注入 | ⚠️ 部分 | `BookSource.header` / `cookie` 字段存在，**search/content 主路径未统一注入** |
| 登录 / 验证码 | ❌ | `login_url` 仅字段占位 |
| 发现 / 推荐 | ❌ | `rule_explore` 未实现 |
| 音频书源 | ❌ | `book_source_type=1` 未区分处理 |

### 3.5 与章节识别 JS 的关系（易混）

```
章节识别 / 内容净化 / 阅读级替换  →  QuickJS(rquickjs)  ✅ 已在主链路
书源规则 JS (@js:)                 →  未实现              ❌ 正式书源批次决策
```

正式开工时二选一：接到同一 QuickJS 运行时，或明确声明「书源不支持 JS 规则」并在导入时过滤。

---

## 4. 正式开工建议顺序

| 步 | 内容 | 依赖 |
|----|------|------|
| 1 | 书源持久化（drift 或 JSON 目录）+ 补齐 list/get/delete/enable | 无 |
| 2 | 书源管理 UI（导入 / 列表 / 启用 / 删除 / 测试连通） | 1 |
| 3 | 在线搜索页（关键词 → 多源并发 → 结果列表） | 1–2 |
| 4 | 书籍详情 + TOC 预览 | 3 |
| 5 | 正文缓存 + 在线书进书架 + 与现有 Reader 管线对接 | 3–4 |
| 6 | 多页正文 / header-cookie 注入 /（可选）书源 JS | 5 之后按需 |

**不要**在步骤 1 完成前做搜索 UI——没有持久化源列表就无处选源。

---

## 5. 快速验证命令

```powershell
# 引擎单测（若后续补）
cd rust
cargo test -p book_source_engine

# Dart 模型测试
flutter test test/book_source_service_test.dart
```

真实书源联调需自备合法书源 JSON；本仓库不内置任何站点规则。
