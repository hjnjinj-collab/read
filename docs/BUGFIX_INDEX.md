# Bug 修复索引

> 最后更新: 2026-08-29
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
| **EPUB 普通正文被误判为本章说（灰色小字）** | CSS 兜底门槛过宽：font_scale<0.85 + 字数<200 捕获普通小字号段落 | A15：门槛收紧 0.85→0.75 + 字数 200→150 + 三重验证（祖先链/类名/孤立块） |
| **底部留白过大（长段落推下页场景）** | 90% 阈值仅对可拆分段落有效，长段落无法容纳时整段推下页 | A15：场景 B（低填充率<50% 首行强制留当前页）+ 场景 C（标题孤立避免） |
| **EPUB 正文行截断+下一行重复整段前缀（超宽行被 Dart 缩字渲染成"小字行"，看似本章说误标+内容重复）** | **断行禁则回退（M7-P4）flush 后未清空 pieces 已发射前缀，pulled 压在前缀之上——下一行重复发射整个前缀；EPUB styled 与 TXT 双路径同源** | M9.1：pull-back 分支 flush 后 `pieces.clear()` 再保留 pulled（layout_engine lib.rs 双路径）；回归测试 `kinsoku_pullback_no_text_duplication` + 真书探针 `jianlai_ch2_probe` 永久断言 |
| **表格单元格内容出现"首行提前换行但不右移"的破碎缩进** | CSS text-indent 经选择器/继承渗入单元格段落，三层链路（解析物化→IR 透传→布局渲染）无一处按容器上下文过滤；表格内只裁宽度不加 x 偏移 | M9.2：解析层 `clear_cell_indent` 递归清零（epub_parser Table 分支）+ 转换层强制 None（api.rs blocks_to_layout_items）；List/Quote 内段落属合法缩进保留 |
| **重新分段开启后超长段原样保留（TXT 尤甚）** | TXT Smart 模式只做软换行合并**从不切长段**；EPUB 切分器缺 ASCII 句读、回退扫全文无上界、cut==total 产空尾段、省略号可从中间切、闭引号悬段首、子段丢 align | M9.2：共享切分器 `paragraph_splitter.rs`（区间契约）双路径统一；阈值 Smart/Aggressive **用户可调**（默认 200/100，设置面板滑杆）；强标点纯 CJK 集+次级有界回退+闭标吸附+省略号原子+尾段再平衡；切口后剩余内容作为新段落从头计数继续切分（split_ranges while 循环不变式） |
| **页尾长段落整段下移造成半页空白（调低填充门槛更严重）** | layout_text 决策块在 fill≥page_fill_threshold 时无条件整段推页，空白上限=1−threshold；行级续排循环虽存在但被该分支拦截 | M9.2：删除整段推页决策，改为行级精度——算剩余空间可容行数、放得下的行留下、余量推下页；仅保留孤行(<2行)/寡行(下页单行)轻保护。TXT 路径不再消费 page_fill_threshold（EPUB 仍消费） |
| **TXT 阅读整体卡顿、越读越卡（翻页/设置面板/全局 UI 均卡）** | ①预加载自激级联：warm→miss→trigger→warm 无限推进全书、无去重无取消，10 章 LRU 被冲成滑动窗口→当前章被挤出→每次翻页同步全章重排；②命中路径每次翻页深克隆整章所有页；③is_chapter_marker 每次调用现场编译 3 个正则（每章数千次） | M9.3：①get_chapter_content 拆 impl(trigger)+quiet 封装、process_and_layout_chapter_inner(allow_preload_trigger) 参数化打断闭环 + 策略收窄 [N±1] + executor try_submit_dedup 去重（并修复 PreloadHandle Drop 自动取消误杀任务：内联等待终态）；②CachedChapterPages.pages 包 Arc（对齐 EPUB 先例），命中零克隆；③OnceLock 静态化正则（含 protect_html_tags） |
| **`flutter build apk` 卡在 "Building native assets failed"（sqlite3 hook）** | sqlite3 默认从 `github.com` 下载预编译 .so，墙内网络 `HttpException: 信号灯超时` | [bugfixes/2026-08-29_Android构建sqlite3_hook_GitHub下载不通](./bugfixes/2026-08-29_Android构建sqlite3_hook_GitHub下载不通.md) ⭐ pubspec 加 `hooks.user_defines.sqlite3: source: source + path: <相对路径>` 走 NDK 本地编译 |
| **`flutter build apk` 报 `Dependency ':flutter_plugin_android_lifecycle' requires compile against version 36 or later`** | Flutter 17.x 默认 `flutter.compileSdkVersion = 34`，但 AGP 9.0.1 在 `CheckAarMetadataWorkAction` 强制校验 AAR `min-compile-sdk=36`；多个 plugin 自己 build.gradle 写 `compileSdk flutter.compileSdkVersion` 也得改 | [bugfixes/2026-08-29_AGP9_强制compileSdk36_pub_cache修补](./bugfixes/2026-08-29_AGP9_强制compileSdk36_pub_cache修补.md) ⭐ app/build.gradle.kts 硬编 `compileSdk = 36` + 修补 pub cache 所有 plugin + 禁 Kotlin 增量编译（跨盘符相对路径错误） |
| **`flutter build apk` 报 `Member not found: 'platform'`** | file_picker 12.x 引入 plugin federation（Android 拆 `android_file_picker`），`FilePicker.platform` 移除；`pickFiles()` 返回类型从 `FilePickerResult?` 变 `List<PlatformFile>` | [bugfixes/2026-08-29_file_picker_12.x_API破坏性变更](./bugfixes/2026-08-29_file_picker_12.x_API破坏性变更.md) ⭐ `FilePicker.platform.pickFiles()` → `FilePicker.pickFiles()`，`result.files.single` → `files.first` |
| **APK 安装成功但启动白/黑屏卡死（Flutter UI 永远不出现）** | `RustLib.init()` 调 `ExternalLibrary.open('libbridge.so')` 但 **APK 缺 `libbridge.so`**——Rust 库没为 Android ABI 编译；`build_apk.ps1` 没 cargo build 步骤，`main()` 在 `await BookService.init()` 抛 `ArgumentError` 后 `runApp` 不执行 | [bugfixes/2026-08-29_APK启动黑屏_缺失libbridge.so](./bugfixes/2026-08-29_APK启动黑屏_缺失libbridge.so.md) ⭐ `cargo install cargo-ndk` + `build_apk.ps1` 加 `cargo ndk -t <4 ABIs> -o jniLibs/ build --release` |
| **`cargo ndk ... build --release` 报 `Could not find openssl via pkg-config` / `OPENSSL_DIR` 错误** | `reqwest 0.12` 默认 features 拉 `default-tls` = `native-tls` = `openssl-sys`；Windows host 编译时 link host OpenSSL 没事，Android 交叉编译时无 sysroot 必 fail | [bugfixes/2026-08-29_Android编译openssl-sys找不到OpenSSL切rustls-tls](./bugfixes/2026-08-29_Android编译openssl-sys找不到OpenSSL切rustls-tls.md) ⭐ `reqwest = { default-features = false, features = [..., "rustls-tls"] }`——纯 Rust TLS 无 C 依赖 |
| **`cargo ndk ... build --release` 报 `couldn't read rquickjs-sys ... bindings/aarch64-linux-android.rs`** | `rquickjs-sys 0.6.2` 默认走预编译 `src/bindings/<target>.rs`，**Android ABI 不在预编译列表**（只覆盖 x86_64/aarch64 macOS+Linux+Windows 等 ~10 个主流目标） | [bugfixes/2026-08-29_Android编译rquickjs-sys缺bindings加bindgen](./bugfixes/2026-08-29_Android编译rquickjs-sys缺bindings加bindgen.md) ⭐ `rquickjs features = [..., "bindgen"]`——build 时用 NDK clang 现场生成 bindings |

## 二、按错误信息查找

| 错误信息片段 | 对应问题 |
|--------------|----------|
| `byte index ... is not a char boundary` | UTF-8 边界 Panic → BUG_FIXES §6 |
| `Target build_hooks failed` / `Building native assets failed` | 构建失败 → BUG_FIXES §7 |
| `Unable to execute patch, you may need to install it` | rquickjs patch → BUG_FIXES §9 |
| `Content hash on Dart side ... is different from Rust side` | Content Hash → BUG_FIXES §11 |
| `Cannot start a runtime from within a runtime` | 异步嵌套：同步代码里已 block_on，外层不要再套 tokio::main |
| `Failed to load dynamic library 'libbridge.so'` / APK 启动白/黑屏 | `flutter_rust_bridge` Android 集成：Rust 必须为 4 ABI 编译到 `android/app/src/main/jniLibs/<abi>/libbridge.so` | 8-29 报告：build_apk.ps1 缺 cargo ndk 步骤 |
| `Could not find openssl via pkg-config` / `OPENSSL_DIR` unset（Android 编译） | `reqwest` 默认 `default-tls` = `native-tls` = `openssl-sys`；Android 交叉编译无 sysroot 必 fail | 8-29 报告：`reqwest default-features=false + rustls-tls` |
| `couldn't read ... rquickjs-sys ... bindings/aarch64-linux-android.rs` | `rquickjs-sys` 预编译 bindings 不覆盖 Android ABI | 8-29 报告：`rquickjs features += "bindgen"` 用 NDK clang 现场生成 |
| `missing field ... in initializer` | 结构体加了新字段，构造处未同步更新 |
| EPUB 段间出现小字号行（本章说/脚注） | display:none 漏过滤 Paragraph/Heading；aside/footnote 块下沉为正文；CSS font-size<0.85 未分类 | A14：extract_rules aside 检测 + CSS 兜底 is_comment |
| EPUB 底部留白过大且不统一 | layout_items 无填充率门槛，≥3 行即整段推下页 | A14：page_fill_threshold 默认 0.9（可调） |
| EPUB 普通正文被标灰小字（非注释） | CSS 兜底 font_scale<0.85 门槛过宽，误判短段落正文 | A15：收紧到 0.75 + 三重验证（祖先链/类名/孤立块） |
| 底部留白过大（长段落场景） | 90% 阈值对不可拆分长段落无效，整段推下页 | A15：场景 B（低填充率首行强制）+ 场景 C（标题孤立避免） |
| 正文行截断+下一行超宽重复（缩字"小字行"） | 禁则回退 flush 后 pieces 前缀未清空，下次 flush 重复发射 | M9.1：pull-back 后 pieces.clear() 再保留 pulled（双路径） |
| 表格内容首行提前换行不右移（破碎缩进） | text-indent 渗入单元格段落，布局只裁宽度不加偏移 | M9.2：解析层递归清零 + 转换层强制 None |
| 重新分段开了但长段没切开 | TXT Smart 从不切长段；EPUB 切分器标点集/回退/吸附多处缺陷 | M9.2：共享切分器 paragraph_splitter（200/100 阈值统一） |
| 页尾长段整段下移、半页空白 | fill≥门槛时无条件整段推页，空白上限=1−threshold | M9.2：TXT 行级分页（孤行/寡行轻保护），TXT 不再消费该门槛 |
| TXT 越读越卡、全局 UI 卡顿 | 预加载级联冲刷 LRU + 命中整章克隆 + 正则风暴 | M9.3：断级联(quiet 回源)+收窄±1+去重；pages 包 Arc；OnceLock 正则 |
| 预加载任务大量 cancelled/预热不生效 | PreloadHandle drop 自动发取消信号（oneshot sender drop 也唤醒 receiver） | M9.3：try_submit_dedup 内联等待终态，句柄存活到任务完成 |
| 双引擎行重叠/截断（TXT+EPUB） | Rust ab_glyph 与 Dart sans-serif 字体不同源；Dart 硬编码字号+无防护 | A13：字体统一 + 参数同源 + 无约束排版分级兜底 |

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
