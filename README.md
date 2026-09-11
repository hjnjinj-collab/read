# Legado Flutter - 跨平台阅读器

> 基于 Flutter + Rust 的高性能跨平台阅读应用，从 [Legado Android](https://github.com/gedoor/legado) 迁移而来。

[![Flutter](https://img.shields.io/badge/Flutter-3.44.9-blue.svg)](https://flutter.dev/)
[![Rust](https://img.shields.io/badge/Rust-1.83-orange.svg)](https://www.rust-lang.org/)
[![Version](https://img.shields.io/badge/version-1.0.4-green.svg)](./CHANGELOG.md)
[![License](https://img.shields.io/badge/license-GPL--3.0-green.svg)](LICENSE)

## ✨ 特性

- 🚀 **高性能**: Rust 核心引擎，多级缓存 + 锁纪律，大文本秒开
- 📖 **双格式**: TXT（多编码）+ EPUB（结构化 IR 渲染：图片/表格/富文本/样式）
- 🎨 **四种翻页动画**: 仿真卷曲 / 上下滚动 / 水波纹粉碎 / 方块坍塌溶解
- 📝 **笔记与划线**: 长按词边界选区、双端手柄、高亮渲染、备注、页码定位
- 🔍 **书内全文搜索**: Rust 线程池计算，章节+摘录+跳转，TXT/EPUB 同口径
- 🔖 **书签与进度**: 章节+字符锚点，跨启动恢复
- ⚙️ **深度阅读设置**: 字号/行距/字体/简繁/净化/替换规则/分段规则/两端对齐/标点压缩
- 📱 **跨平台**: Windows 桌面 + Android 真机（分 ABI 打包）

## 🎯 当前状态

**版本 1.0.4+5**（2026-09-11）

| 方向 | 状态 |
|------|------|
| TXT 阅读全链路 | ✅ 完成 |
| EPUB 结构化渲染 | ✅ 完成（图片/表格/富文本/CSS 物化） |
| 笔记/划线/书签/搜索 | ✅ 完成 |
| 阅读设置体系 | ✅ 完成（持久化 + 即时生效） |
| 性能架构（缓存/锁纪律） | ✅ 完成（四个锁竞争热点全部闭环） |
| Windows / Android | ✅ 完成 |
| PDF / MOBI | ⏳ 计划中 |
| 在线书源 | ⏳ 计划中 |
| iOS / Web | ⏳ 计划中 |

## 📖 格式支持

| 能力 | TXT | EPUB |
|------|-----|------|
| 解析 | 编码探测（UTF-8/GBK/GB2312/GB18030）+ JS 章节识别 | roxmltree + DOM JSON + JS 规则提取 |
| 分页 | 行级布局 | 混合布局（图片原子/表格单元格） |
| 图片 / 表格 / 富文本 | — | ✅ StyledRun / Image / Table / List / Quote |
| 内容净化 | ✅ 整章（净化缓存） | ✅ 落盘缓存（跨启动复用） |
| CSS 物化 | — | ✅ 对齐/颜色/字号倍率/缩进/行距 |
| 简繁转换 | ✅ | ✅（DOM 文本节点层，锚点同源） |
| 书内搜索 | ✅ | ✅（同一 IR 字符流锚点） |
| 笔记 / 书签 | ✅ | ✅（同源锚点） |
| 替换规则 | ✅ 整章 | ✅ 块级 |
| 分段规则 | ✅ | — |

## 🎬 翻页动画

四种模式（设置面板实时切换，shader 进程级预加载消除首翻兜底）：

| 模式 | 说明 | 实现 |
|------|------|------|
| 仿真卷曲 | 贝塞尔折面 + 镜像纸背 + 阴影 | `curl_painter.dart` |
| 上下滚动 | Y 轴平移滑页 | `scroll_turn_controller.dart` |
| 水波纹粉碎 | GPU shader 双波叠加，随机种子不规则化 | `ripple_shredder.frag` |
| 方块坍塌溶解 | 点击位置为坍塌中心，块大小/滑距/阴影可调 | `block_collapse.frag` |

三档速度（快 400ms / 中 600ms / 慢 800ms，作用于水波纹与坍塌）。

## 🚀 快速开始

### 前置要求

- Flutter 3.44.9+
- Rust 工具链
- Visual Studio 2019+（Windows）
- Android NDK 27 + cargo-ndk（Android）

### Windows 运行

```powershell
# 一键全量重建（clean → codegen → Rust → DLL 拷贝 → Flutter）
.\fix_sync.ps1
flutter run -d windows
```

### Android 打包

```powershell
# 分 ABI 构建（真机一般 arm64-v8a，增量编译约 2 分钟）
.\build_apk.ps1 -Abis arm64-v8a
adb install -r build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
```

### 测试

```powershell
flutter test              # Dart 单元测试（105 项）
cd rust
cargo test -p book_parser --lib    # 123 项
cargo test -p reader_core --lib    # 154 项
cargo test -p layout_engine --lib  # 85 项
cargo test -p bridge --lib         # 17 项
cargo test -p bridge --test epub_flow  # 9 项集成
```

## 📖 使用说明

- **打开书籍**: 点击 + 按钮，选择 TXT / EPUB 文件
- **翻页**: 点击屏幕左右侧，或横向拖拽；中间呼出菜单
- **长按划线**: 长按文字进入笔记模式，拖动手柄调整选区，添加笔记/划线
- **搜索**: 菜单栏「搜索」，输入关键词全书搜索，点击结果跳转
- **书签**: 菜单栏「书签」，一键收藏当前位置

## 🏗️ 系统架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Flutter UI Layer                          │
│   Riverpod 状态管理 · Material Design 3 · CustomPaint 渲染   │
│   ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────┐   │
│   │  reader  │ │  about   │ │  翻页动画 │ │  设置/菜单   │   │
│   │ providers│ │          │ │ 4 模式   │ │              │   │
│   └──────────┘ └──────────┘ └──────────┘ └──────────────┘   │
├─────────────────────────────────────────────────────────────┤
│              FFI Bridge (flutter_rust_bridge 2.12)           │
│              rust/crates/bridge/src/api.rs（唯一入口）        │
├─────────────────────────────────────────────────────────────┤
│                       Rust Core                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ book_parser    TXT/EPUB 解析 · 编码 · 章节 · 净化       │  │
│  │                css_lite · dom_json · extract_rules      │  │
│  │                content_ir · epub_clean_cache            │  │
│  ├────────────────────────────────────────────────────────┤  │
│  │ layout_engine  字体管理 · 字形缓存 · 测量缓存           │  │
│  │                禁则处理 · 分页                          │  │
│  ├────────────────────────────────────────────────────────┤  │
│  │ reader_core    预处理流水线 · 会话 · 缓存 · 预加载调度  │  │
│  ├────────────────────────────────────────────────────────┤  │
│  │ book_source    书源规则引擎（CSS/JSONPath/Regex）       │  │
│  └────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 数据层

- **drift + SQLite**（schemaVersion 3）：Books / ReadingProgress / Bookmarks / Notes / AppSettings
- 设置经 `AppSettingsService` 100ms 防抖落库，启动同步预加载，`ReaderNotifier` 构造即用内存快照

### 性能架构

| 层 | 机制 |
|----|------|
| 分页缓存 | `PAGINATION_CACHE`（10 章 LRU）· `STRUCTURED_PAGINATION_CACHE`（TTL 900s） |
| 预处理缓存 | `PREPROCESSED_CACHE`（20 章 LRU，键含排版配置） |
| 净化缓存 | TXT 内存/mmap `cleaned_chapter_cache` · EPUB 落盘 `epub_cleaned`（跨启动） |
| 字体/测量 | `SHARED_GLYPH_CACHE`（10K + GB2312 预热）· `MEASURE_CACHE`（50K） |
| 翻页 shader | 进程级 FragmentProgram 预加载（消除首翻 curl 兜底） |
| 锁纪律 | `BOOKS: RwLock` 持锁禁再取 BOOKS；archive/css_cache/resource_cache 内部 Mutex，稳态只取读锁 |

### 锁纪律（重要）

`BOOKS` 为全局 `RwLock<HashMap>`，**非可重入**。铁律：持任何 BOOKS 锁期间禁止调用会再取 BOOKS 的函数；跨锁取数据一律「作用域探测 → 放锁 → 再调用」。全部锁点审计清单见 `rust/crates/bridge/src/lib.rs` BOOKS 声明处注释。四个历史锁竞争热点（净化缓存重建、资源 ZIP IO、搜索 IR 提取、批量定位死锁）已全部消除。

## 📁 项目结构

```
legado_flutter/
├── lib/
│   ├── core/
│   │   ├── ffi/                  # FFI 绑定（book_service.dart 包装）
│   │   ├── database/             # drift 数据库 + 设置服务
│   │   ├── models/               # 数据模型
│   │   └── services/             # 字体等全局服务
│   └── features/
│       ├── reader/               # 阅读功能
│       │   ├── providers/        # Riverpod 状态（ReaderNotifier）
│       │   ├── pages/            # 阅读页
│       │   ├── widgets/          # 翻页合成器/菜单/选区/高亮
│       │   │   └── page_turn/    # 四种翻页动画实现
│       │   ├── services/         # 图片存储等
│       │   └── diagnostics/      # reader_trace 诊断日志
│       └── about/
├── rust/crates/
│   ├── book_parser/              # TXT/EPUB 解析、净化、CSS、DOM JSON
│   ├── layout_engine/            # 布局、分页、字体、缓存
│   ├── reader_core/              # 预处理流水线、会话、调度
│   ├── book_source_engine/       # 书源规则引擎
│   └── bridge/                   # FFI 唯一入口（api.rs）
├── shaders/                      # 翻页 shader（ripple/collapse）
├── test/                         # Dart 测试（9 文件 105 项）
├── fix_sync.ps1                  # Windows 全量重建
├── build_apk.ps1                 # Android 分 ABI 打包
└── docs/
    ├── design/ARCHITECTURE.md    # 详细架构 + A1–A31 路线图
    ├── compose/spec/             # 特性文档（11 份）
    └── BUGFIX_INDEX.md           # Bug 快速查找索引
```

## 🛠️ 开发

### 修改 Rust 代码

```powershell
.\fix_sync.ps1   # Windows：clean → codegen → Rust → DLL 拷贝 → Flutter
# Android 改动后需重新打包：
.\build_apk.ps1 -Abis arm64-v8a
```

### 修改 Flutter 代码

编辑后按 `r` 热重载 / `R` 热重启。

### 重新生成 FFI 绑定

```powershell
# 修改 bridge/api.rs 签名后执行
flutter_rust_bridge_codegen generate
```

## 🔬 技术栈

### Rust
- **encoding_rs** 编码检测 · **roxmltree** XML · **scraper** HTML DOM
- **quickjs** JS 规则引擎 · **zip** EPUB 归档 · **memmap2** 大文本 mmap
- **ab_glyph** 字体光栅化 · **tokio** 异步运行时 · **anyhow** 错误处理

### Flutter
- **Riverpod** 状态管理 · **drift** 数据库 · **file_picker** 文件选择
- **CustomPaint + FragmentShader** 翻页渲染 · **flutter_rust_bridge** FFI

## 🎯 路线图

### 已完成（A1–A31）

核心阅读 → EPUB 结构化渲染 → 翻页动画家族 → 排版精度 → 搜索 → 笔记划线 → 性能架构治理。详见 [ARCHITECTURE.md §13](./docs/design/ARCHITECTURE.md)。

### 下一步候选（基于架构盘点）

| 方向 | 内容 | 规模 |
|------|------|------|
| 笔记功能补全 | 导出/分享、跨章笔记迁移、跨章选区 | 中-大 |
| 阅读菜单扩展 | 跨章连续进度滑杆、全书页数跳页 | 小-中 |
| 锁竞争热点收尾 | 净化缓存磁盘重建持锁窗口、搜索结果缓存 | 小 |
| 新格式 | PDF 支持 | 大 |
| 在线书源 | book_source_engine 已就绪，缺网络层与 UI | 中-大 |
| iOS / Web | 跨平台扩展 | 大 |

### 已知边界（架构盘点发现）

- `PREPROCESSED_CACHE` 键不含净化 config_hash（装回时靠显式 invalidate 兜底）
- `EpubParser` 导入期 `parse(&mut self)` 与运行期 `&self` 读路径生命周期不重叠，无竞争
- 分段规则仅 TXT 支持，EPUB 未接入
- bridge 集成测试存在 A35-L2 签名漂移（PRE-EXISTING，待修复）

## 📚 文档

- [开发者指南](./AGENTS.md) — 构建、架构注意事项（必读）
- [详细架构 + 路线图](./docs/design/ARCHITECTURE.md)
- [特性文档](./docs/compose/spec/) — 11 份 compose-next 交付记录
- [变更日志](./CHANGELOG.md)
- [Bug 索引](./docs/BUGFIX_INDEX.md)

## 🤝 贡献

1. Fork 项目
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启 Pull Request

## 📄 许可证

本项目采用 GPL-3.0 许可证 - 查看 [LICENSE](LICENSE) 文件了解详情

## 🙏 致谢

- [Legado](https://github.com/gedoor/legado) — 原始项目灵感
- [Flutter](https://flutter.dev/) — UI 框架
- [Rust](https://www.rust-lang.org/) — 系统编程语言
- [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge) — FFI 解决方案
