# Legado Flutter - 跨平台阅读器

> 基于 Flutter + Rust 的高性能跨平台阅读应用,从 [Legado Android](https://github.com/gedoor/legado) 迁移而来。

[![Flutter](https://img.shields.io/badge/Flutter-3.44.9-blue.svg)](https://flutter.dev/)
[![Rust](https://img.shields.io/badge/Rust-1.83-orange.svg)](https://www.rust-lang.org/)
[![License](https://img.shields.io/badge/license-GPL--3.0-green.svg)](LICENSE)

## ✨ 特性

- 🚀 **高性能**: Rust 核心引擎,接近原生性能
- 📱 **跨平台**: 一套代码,支持 Windows/Android/iOS/Web
- 📖 **多格式**: 支持 TXT (UTF-8/GBK/GB2312/GB18030)
- 🎨 **Material Design 3**: 现代化 UI 设计
- ⚡ **快速分页**: Rust 布局引擎,大文本秒开
- 🔧 **可扩展**: 模块化设计,易于添加新功能

## 🎯 当前状态

**完成度: 70%** ✅

- ✅ Rust 核心功能 (解析、布局、FFI)
- ✅ Flutter UI 框架
- ✅ FFI 集成
- ✅ 基础阅读功能
- ⏳ 数据持久化
- ⏳ EPUB 支持
- ⏳ 网络书源

## 🚀 快速开始

### 前置要求

- Flutter 3.44.9+
- Rust 工具链
- Visual Studio 2019+ (Windows)

### 安装运行

```bash
# 1. 克隆项目
cd D:\android\example\legado_flutter

# 2. 安装 Flutter 依赖
flutter pub get

# 3. 编译 Rust 代码
cd rust
cargo build --release

# 4. 复制 DLL
New-Item -Path "crates/bridge/target/release/" -ItemType Directory -Force
Copy-Item "target/release/bridge.dll" -Destination "crates/bridge/target/release/" -Force
cd ..

# 5. 运行应用
flutter run -d windows
```

### 测试

使用提供的测试文件:
```bash
# 打开应用后,点击 + 选择文件:
D:\android\example\test_book.txt
```

## 📖 使用说明

### 基础操作

- **打开书籍**: 点击 + 按钮,选择 TXT 文件
- **翻页**: 
  - 下一页: 点击屏幕右侧
  - 上一页: 点击屏幕左侧
  - 菜单: 点击屏幕中间
- **查看信息**: 菜单中查看章节、进度

### 支持的格式

| 格式 | 状态 | 编码支持 |
|------|------|----------|
| TXT | ✅ 已支持 | UTF-8, GBK, GB2312, GB18030 |
| EPUB | ⏳ 计划中 | - |
| PDF | ⏳ 计划中 | - |
| MOBI | ⏳ 计划中 | - |

## 🏗️ 架构

```
┌─────────────────────────────────────┐
│         Flutter UI Layer            │
│  (Riverpod + Material Design 3)     │
├─────────────────────────────────────┤
│      FFI Bridge (flutter_rust_bridge)     │
├─────────────────────────────────────┤
│           Rust Core                 │
│  ┌──────────┬──────────┬─────────┐  │
│  │  Parser  │  Layout  │  Cache  │  │
│  │  Engine  │  Engine  │ Manager │  │
│  └──────────┴──────────┴─────────┘  │
└─────────────────────────────────────┘
```

### 核心模块

- **book_parser**: TXT/EPUB 解析, 编码检测, 章节识别（JS 引擎规则）
- **layout_engine**: 文本布局, 智能分页, 字形缓存
- **reader_core**: 阅读会话, 内容预处理流水线, 缓存与调度
- **book_source_engine**: 书源规则解析（CSS/JSONPath/Regex）
- **bridge**: FFI 桥接, 类型转换, API 导出

## 📁 项目结构

```
legado_flutter/
├── lib/                          # Flutter 代码
│   ├── core/
│   │   ├── ffi/                  # FFI 绑定
│   │   └── models/               # 数据模型
│   └── features/
│       └── reader/               # 阅读功能
│           ├── data/
│           └── presentation/
├── rust/                         # Rust 代码
│   └── crates/
│       ├── book_parser/          # 书籍解析（TXT/EPUB、编码检测、章节识别）
│       ├── layout_engine/        # 布局引擎（排版、分页）
│       ├── reader_core/          # 阅读核心（会话、预处理、缓存）
│       ├── book_source_engine/   # 书源规则引擎
│       └── bridge/               # FFI 桥接
├── flutter_rust_bridge.yaml      # FFI 配置
└── test_book.txt                 # 测试文件
```

## 📚 文档

- [开发者指南](./AGENTS.md) - 构建、开发、架构注意事项（必读）
- [文档索引](./docs/README.md) - 全部文档导航
- [设计文档](./docs/design/README.md) - 各 Rust 模块的设计背景
- [Bug 修复记录](./docs/BUG_FIXES.md) - 已知问题与修复
- [用户指南](./USER_GUIDE.md) - 详细使用说明

## 🛠️ 开发

### 修改 Rust 代码

```bash
# 1. 编辑代码
vim rust/crates/bridge/src/api.rs

# 2. 重新编译
cd rust
cargo build --release

# 3. 复制 DLL
Copy-Item "target/release/bridge.dll" -Destination "crates/bridge/target/release/" -Force

# 4. 重启应用
flutter run -d windows
```

### 修改 Flutter 代码

```bash
# 编辑代码后按 r 热重载
# 或按 R 热重启
```

### 重新生成 FFI 绑定

```bash
# 修改 API 签名后执行
flutter_rust_bridge_codegen generate
```

## 🔬 技术栈

### Rust
- **encoding_rs**: 编码检测
- **regex**: 正则匹配
- **unicode-segmentation**: Unicode 处理
- **flutter_rust_bridge**: FFI 桥接
- **anyhow**: 错误处理

### Flutter
- **Riverpod**: 状态管理
- **file_picker**: 文件选择
- **CustomPaint**: 自定义渲染

## 🎯 路线图

### Phase 1: 核心功能 ✅ (当前)
- [x] TXT 解析
- [x] 文本布局
- [x] FFI 集成
- [x] 基础阅读

### Phase 2: 功能完善 (进行中)
- [ ] 数据持久化
- [ ] 书架管理
- [ ] 阅读设置
- [ ] 书签功能

### Phase 3: 格式扩展
- [ ] EPUB 支持
- [ ] PDF 支持
- [ ] 在线书源

### Phase 4: 跨平台
- [ ] Android 打包
- [ ] iOS 适配
- [ ] Web 版本

## 🤝 贡献

欢迎贡献代码!

1. Fork 项目
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启 Pull Request

## 📄 许可证

本项目采用 GPL-3.0 许可证 - 查看 [LICENSE](LICENSE) 文件了解详情

## 🙏 致谢

- [Legado](https://github.com/gedoor/legado) - 原始项目灵感
- [Flutter](https://flutter.dev/) - UI 框架
- [Rust](https://www.rust-lang.org/) - 系统编程语言
- [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge) - FFI 解决方案

## 📧 联系方式

- 项目地址: `D:\android\example\legado_flutter`
- 测试文件: `D:\android\example\test_book.txt`

## ⭐ Star History

如果这个项目对你有帮助,请给一个 ⭐!

---

**注**: 本项目正在积极开发中,欢迎反馈和建议!
