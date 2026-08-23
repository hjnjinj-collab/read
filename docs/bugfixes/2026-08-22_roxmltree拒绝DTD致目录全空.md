# Bug 修复报告：roxmltree 默认拒绝 DTD，真实书籍目录解析全空

## 修复日期
2026-08-22

## 问题概述

打开真实书籍（如 Z-Library 转换的《剑来》epub，474 章）时目录标题全部为
默认值「章节 N」，嵌套层级失效；合成测试书一切正常。

诊断探针（`#[ignore] real_book_toc_probe`，EBOOK_PROBE_PATH 环境变量指定
真实文件）输出：

```
PARSE ERR: toc.ncx 解析失败: XML with DTD detected
toc_entries.len() = 0
```

## 根本原因

真实书籍的 NCX/OPF 常带 DOCTYPE 声明：

```xml
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN"
 "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
```

roxmltree 的 `Document::parse` 使用默认 `ParsingOptions { allow_dtd: false }`，
**遇 DOCTYPE 直接报错**。所有合成测试样本均无 DOCTYPE，故测试全绿、真书必挂。

## 解决方案

epub_parser.rs 增加模块级常量并统一用于四处结构解析
（container / OPF / NCX / nav）：

```rust
const XML_PARSE_OPTIONS: roxmltree::ParsingOptions = roxmltree::ParsingOptions {
    allow_dtd: true,
    nodes_limit: 1_000_000, // 恶意文件加固
};
// roxmltree::Document::parse_with_options(xml, XML_PARSE_OPTIONS)
```

安全性：roxmltree 不加载外部 DTD、内部实体有展开限制，本地受信文件无 XXE 风险。

## 验证

- 新增回归测试 `test_parse_ncx_with_doctype_dtd`（用户书籍同款 DOCTYPE 头）
- 真书探针：474 条目全部解析、标题命中、嵌套层级正确（人物志 lvl=1 → 角色 lvl=2 parent=人物志）

## 预防/工程约束（新增）

**roxmltree 默认拒绝含 DOCTYPE 的 XML**——解析外部来源的结构性 XML 必须
显式 `parse_with_options(allow_dtd: true)`；测试样本必须包含带 DOCTYPE 的变体。

## 相关文件
- `rust/crates/book_parser/src/epub_parser.rs` — XML_PARSE_OPTIONS + 四处调用点 + 回归测试 + real_book_toc_probe 诊断探针（保留）
