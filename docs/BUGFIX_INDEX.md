# Bug 修复索引

> 最后更新: 2026-08-21
> 用途：遇到问题时按**症状**或**错误信息**快速定位到根因和修复方案。
> 详细修复步骤在 [BUG_FIXES.md](./BUG_FIXES.md)；单次问题的完整分析报告在 [bugfixes/](./bugfixes/)。

---

## 一、按症状速查

| 症状 | 根因 | 去哪看 |
|------|------|--------|
| 打开书籍乱码 | 编码检测不准确，未用 GB18030 兜底 | BUG_FIXES §1 |
| 简繁转换不生效 / 替换规则不生效 / 设置需重启才生效 | 转换是占位实现（9 词 replace / TODO 桩）；对话框不回读设置；双重加载竞态 | [bugfixes/2026-08-21_简繁转换占位实现与管线顺序](./bugfixes/2026-08-21_简繁转换占位实现与管线顺序.md) ⭐ 取代 BUG_FIXES §2 的旧诊断 |
| 分页出现孤行/寡行 | 分页未做段落完整性保护 | BUG_FIXES §3 |
| 章节末尾有多余内容/空白 | 章节结束偏移计算不准 | BUG_FIXES §4 |
| 章节数量异常（过多/过少） | 正则误匹配正文中的"第N章"引用 | BUG_FIXES §5 |
| **章节内容开头是上一章结尾、重复标题、或标题被截断（如"身"）** | **CRLF 行尾下字节偏移逐行少算 1 字节累积漂移；净化后行号失效** | [bugfixes/2026-08-21_章节边界CRLF偏移漂移与净化行号失效](./bugfixes/2026-08-21_章节边界CRLF偏移漂移与净化行号失效.md) ⭐ 最终结论 |
| 新章节没有另起一页 | 分页器缺少章节边界标记 | 同上 + layout_engine `TextLine.is_chapter_start` |
| 内容开头的重复标题删不掉 | 标题带全角空格缩进，旧逻辑精确匹配失败 | [bugfixes/2026-08-21_重复标题删除修复](./bugfixes/2026-08-21_重复标题删除修复.md)，最终方案：`remove_duplicate_title()` 逐行 trim 后比对 |
| 解析大型中文书籍时 panic | UTF-8 字符边界切片 | BUG_FIXES §6 |
| 修改 Rust 后应用跑不起来 / DLL 未更新 | Rust 与 Flutter 的 DLL 路径不一致 | BUG_FIXES §7（直接用 `fix_sync.ps1`） |
| 应用能启动但排版异常/无文字 | 字体未加载 | BUG_FIXES §8 |
| debug 构建报 `Unable to execute patch` | rquickjs-sys 需要 patch 命令，PATH 缺 Git usr\bin | BUG_FIXES §9 + [bugfixes/2026-08-20_rquickjs缺少patch编译失败](./bugfixes/2026-08-20_rquickjs缺少patch编译失败.md) |
| `future cannot be sent between threads safely` | 跨 await 持有 std Mutex | BUG_FIXES §10 |
| Content Hash 不匹配 | 改了 API 未重新 codegen | BUG_FIXES §11 |
| **重开书籍报 `UNIQUE constraint failed: books.file_path`（2067）** | `insertOnConflictUpdate` 只对主键生效，身份键是 filePath UNIQUE 列 | [bugfixes/2026-08-22_书架唯一约束冲突](./bugfixes/2026-08-22_书架唯一约束冲突.md) ⭐ 需 DoUpdate(target:) |
| **真实书籍目录标题全空/无嵌套，合成测试书正常** | roxmltree 默认拒绝带 DOCTYPE 的 XML（`XML with DTD detected`） | [bugfixes/2026-08-22_roxmltree拒绝DTD致目录全空](./bugfixes/2026-08-22_roxmltree拒绝DTD致目录全空.md) ⭐ parse_with_options(allow_dtd:true) |

## 二、按错误信息查找

| 错误信息片段 | 对应问题 |
|--------------|----------|
| `byte index ... is not a char boundary` | UTF-8 边界 Panic → BUG_FIXES §6 |
| `Target build_hooks failed` / `Building native assets failed` | 构建失败 → BUG_FIXES §7 |
| `Unable to execute patch, you may need to install it` | rquickjs patch → BUG_FIXES §9 |
| `Content hash on Dart side ... is different from Rust side` | Content Hash → BUG_FIXES §11 |
| `Cannot start a runtime from within a runtime` | 异步嵌套：同步代码里已 block_on，外层不要再套 tokio::main |
| `missing field ... in initializer` | 结构体加了新字段，构造处未同步更新 |

## 三、工程约束（踩坑沉淀，写代码前先看）

这些不是"某个 bug"，而是会导致一类 bug 的硬约束：

1. **禁止用 `lines()[i].len() + 1` 累加字节偏移** —— CRLF 文件每行少算 1 字节。
   必须扫描原始字节的 `\n` 建立行起始表。（2026-08-21 章节漂移的根因）
2. **章节边界必须与所索引的文本同源** —— 净化会重构行结构，
   原始内容的行号不能用于净化后的内容。
3. **全角空格 `\u{3000}` 占 3 字节**，JS 的 `trim()` 会去掉它而精确匹配会失败 ——
   标题比对前必须两侧都 trim。
4. 所有字符串切片过 `is_char_boundary()` 检查。
5. **替换规则必须先于简繁转换执行** —— 用户规则按书籍原文书写，
   先转换会导致规则无法命中。（2026-08-21 管线顺序）
6. **简繁转换只经由 `book_parser::chinese_convert` 一个权威实现** ——
   阅读级与导入级两套实现必然漂移。

## 四、记录规范

新增 bug 记录时：
1. 单个问题的完整分析报告放 `docs/bugfixes/`，命名 `YYYY-MM-DD_简短描述.md`
2. 通用性强的修复步骤并入 `BUG_FIXES.md`（含根因/解决/预防三段）
3. 在本索引"按症状速查"表中加一行；若发现新的工程约束，加到第三节
4. 被后续分析推翻的中间结论，标注"已被 XXX 取代"，不要删除（保留排查思路）
