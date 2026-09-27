---
feature: archive-comic
status: delivered
updated: 2026-09-27
branch: master
commits: # leave empty while in progress; fill at delivery
---

# 压缩包漫画（CBZ/ZIP/CBR/RAR）

## Report

**What was built** — 压缩包漫画全链路：`BookFormat::Comic`（cbz/zip/cbr/rar；ZIP 看 mimetype/container 区分 EPUB）；`comic_archive.rs` Zip + Rar 双后端（zip-slip/64MB/条目上限）；`ComicArchiveParser` 文件夹=章、图=页、自然排序、gallery 一页一图、封面；bridge 导入/分页/资源/格式；Dart 导入与排版占位。RAR 经 `unrar` 0.5.8（libunrar），Windows 链 `advapi32`。

**Verification** — `cargo test --package book_parser --lib` 131 passed（含 comic/RAR 拒坏包）；`bridge` 19 passed（含 CBZ 集成）；`layout_engine` 95 passed；`fix_sync.ps1` 全量构建；`flutter analyze` 25 条基线；**`build_apk.ps1 -Abis arm64-v8a` 成功**（`app-arm64-v8a-release.apk` 47.1MB，含 libbridge.so）。

**Journey log** — ZIP magic 与 EPUB 歧义必须用 mimetype/container 纠正。自然排序数值相同要比数字串长度（2 &lt; 002）。`unrar-rs` 依赖 reedsolomon-rs 要求 rustc 1.97（本机 1.95）→ 改用 `unrar` C 绑定并链接 advapi32。libunrar 流式无随机访问，read_entry 按名扫到目标再 `read()`。漫画分页复用 `LayoutItem::Image{gallery,bleed}`。**libunrar C++ 含 Win32 源，Android NDK 编不过 → RAR 仅 Windows；Android 仅 CBZ/ZIP**，`.cbr/.rar` 解析期明确报错。

## [S1] Problem

用户有大量压缩包漫画（`.cbz`/`.zip`/`.cbr`/`.rar`），当前应用只认 `txt`/`epub`：

1. 书架导入过滤器不含漫画扩展名，无法打开。
2. `BookFormat` 无 Comic/Cbz；ZIP magic 一律判成 EPUB，漫画包会被 EPUB 解析器误吃。
3. 无「图片列表 → 章节/页」映射，也无按需解压图片的资源通道（EPUB 的 `get_book_resource` 只挂在 structured EPUB 会话上）。

目标：**并入现有文字工作流**——同一套 openBook → 章节 → 页 → 进度/书签/翻页/日志，而不是另起漫画阅读器。

## [S2] Design

### 已拍板决策

| 轴 | 选择 |
|----|------|
| 格式 | **CBZ/ZIP + CBR/RAR**（首期）；7z 明确不做 |
| 结构 | **文件夹 = 章，图片文件 = 页**；扁平包 = 整本一章 |
| 解压 | **按需读条目**（对齐 EPUB `get_resource_cached`），不整包落盘展开 |
| 阅读 | **复用 gallery 一页一图** + 现有翻页/进度/书签 |

### 格式识别

```
BookFormat::Comic  // 新增
```

- 扩展名：`cbz`/`zip` → Comic；`cbr`/`rar` → Comic。
- Magic：`PK\x03\x04` **不得**再一律判 EPUB。改为：
  1. 扩展名优先（`.cbz`/`.cbr`/`.zip`/`.rar` → Comic）；
  2. 扩展名是 `.epub` 或 ZIP 内含 `mimetype`=`application/epub+zip` 或 `META-INF/container.xml` → Epub；
  3. 其余 ZIP → Comic。
- RAR magic：`Rar!\x1A\x07` → Comic。
- `supports_resources() = true`；`supports_chapters() = true`。

### 压缩包解压层

新增 `book_parser/src/comic_archive.rs`（或 `archive_reader.rs`）：

```rust
trait ArchiveReader: Send + Sync {
    fn list_entries(&self) -> Result<Vec<ArchiveEntry>>; // 路径、是否目录、大小
    fn read_entry(&self, path: &str) -> Result<Vec<u8>>;
}
```

| 后端 | 依赖 | 说明 |
|------|------|------|
| ZipArchiveReader | 已有 `zip = "0.6"` | CBZ/ZIP；与 EPUB 同 crate |
| RarArchiveReader | `unrar`（或 `libarchive`） | CBR/RAR；**Windows 需验证链接**，失败则降级提示「暂不支持 RAR」 |

安全约束：

- 拒绝 `..`、绝对路径、符号链接条目（zip-slip）。
- 单条目解压上限（默认 64MB）防炸弹；总条目数上限（如 20000）。
- 不执行任何包内脚本/HTML。

### 章节/页映射（文件夹=章，图=页）

```
ComicArchiveParser::parse():
  entries = list_images()  // png/jpg/jpeg/webp/gif/bmp
  groups:
    顶层相对路径第一段为目录名 → 一章
    无目录（根下散图）→ 合成一章「全本」
  章内按「自然排序」（001 < 2 < 10；忽略大小写）
  ChapterInfo {
    title: 目录名 or 文件名（无目录时）,
    resource_href: Some(该章第一张图路径),  // 供封面/锚点
    estimated_words: 图片数,  // UI 显示「N 页」
  }
  每页 = 一张图 → LayoutItem::Image { gallery: true, aspect: probe_image_size }
```

- 根下若有少量封面图（`cover.*`/`folder.*`）且存在子目录 → 用作封面不进正文。
- 多级目录：仅第一级分章（Vol/Ch 子夹合并进该章），避免碎片化；写入设计备注。

### 接入现有文字工作流

| 环节 | 做法 |
|------|------|
| 导入 | `FilePicker` `allowedExtensions` 加 `cbz,zip,cbr,rar` |
| openBook | `detect_format` → Comic → `ComicArchiveParser`；沿用 `_openBookSeq` 取消逻辑 |
| 分页 | 不走 TXT/EPUB 文本排版；直接 `layout_items([Image(gallery)])` → 一页一图（已有测试 `items_gallery_forces_one_image_per_page`） |
| 资源 | 扩展 `get_book_resource`：Comic 会话按 `resource_href` 读压缩包条目 → `BookImageStore`（已有预热/就绪门控） |
| 进度/书签 | 现有 chapterIndex + charOffset 语义：charOffset → 页序号；章节=文件夹 |
| 翻页 | 现有 page turn + 资源就绪 120ms 轮询（图片未就绪不播动画） |
| 目录 | 章节列表 UI 显示「第 N 话 · M 页」 |
| 封面 | 第一张有效图 `probe_image_size` + 写 CoverStore |

### 与文字设置的关系（「并入」边界）

- **仍进同一阅读器 chrome**：顶栏、A/B 形态、翻页、日志、Bug 收集。
- **排版设置对漫画隐藏或只读禁用**（字号/字距/行距/两端对齐/缩进）——无文字流可排；背景/纸色仍可留作边框垫色。
- 搜索、替换规则、简繁、净化：**不适用**（Out of Scope）。
- 字体/字重：不适用。

### 错误行为

| 场景 | 行为 |
|------|------|
| 空包/无图 | 明确错误「压缩包内没有图片」，不进阅读器 |
| 损坏 ZIP/RAR | `detect`/`parse` 返回错误并 toast |
| 单图损坏 | 该页占位「图片加载失败」，不拖垮整章 |
| 非 UTF-8 文件名 | 按 lossy / 系统编码尽力解；展示用文件名 |
| 加密包 | 报错「暂不支持加密压缩包」 |

### 测试边界

- Rust：自然排序、目录分章、zip-slip 拒绝、gallery 一页一图、封面探测。
- 集成：最小 CBZ fixture（2 目录 × 各 2 图）→ parse 章节数/页数/顺序。
- Dart：导入过滤器含新扩展；Comic 时排版控件隐藏。

## [S3] Out of Scope

- 7z / 7zip。
- 双页对开、从右到左日漫模式（可后续加「阅读方向」设置）。
- 在线漫画源 / 书源规则。
- 压缩包内 PDF/音频混排。
- 整包解压到磁盘缓存目录。
- 搜索、替换、简繁、净化、字体/字距等纯文字排版能力。

## Tasks

- [x] T1: `BookFormat::Comic` + 扩展名/magic 识别（ZIP 区分 EPUB vs Comic） — acceptance: 单测 cbz/cbr/zip/rar/epub 识别正确；纯 ZIP 无 mimetype 不再判 EPUB (covers: S2)
- [x] T2: `ArchiveReader` Zip 后端 + 条目列表/读取 + zip-slip/大小防护 — acceptance: 单测 list/read/拒绝 `..` (covers: S2; depends: T1)
- [x] T3: `ComicArchiveParser` 实现 `BookParser`（文件夹=章、自然排序、gallery ImageItems、封面） — acceptance: fixture CBZ 章节/页数/顺序正确 (covers: S2; depends: T2)
- [x] T4: bridge `get_book_resource`/open 路径接 Comic；`layout_items` gallery 分页打通 — acceptance: 打开 fixture 能出页且图 href 可取字节 (covers: S2; depends: T3)
- [x] T5: RAR 后端（`unrar`）或明确降级提示 — acceptance: 样例 cbr 可读或 toast「暂不支持 RAR」且不崩溃 (covers: S2; depends: T2) — **已接 `unrar` 0.5.8（libunrar）；Windows 链 `advapi32`**
- [x] T6: Dart 书架导入扩展名 + Comic 隐藏排版控件 + 目录「N 页」 — acceptance: 选 cbz 能进阅读器；排版页对漫画不可用 (covers: S2; depends: T4)
- [x] T7: 集成测试 + fix_sync + 设备回归清单 — acceptance: cargo/bridge 测试过；文档写明真机检查项 (covers: S2; depends: T3, T4, T6)

### 真机回归清单（T7）

1. 书架导入 `.cbz` / `.cbr`，封面与书名正确
2. 目录：文件夹成章，章内图序 001→010 正确
3. 一页一图；缩放/裁切不拉伸变形（bleed 贴边）
4. 快速连翻：图未就绪不播残动画，就绪后翻页跟手
5. 进度/书签：跨章记录与恢复
6. 漫画打开时设置「排版」页为占位；背景/材质仍可用
7. 空包/坏包/加密包：错误提示清晰、不崩溃
