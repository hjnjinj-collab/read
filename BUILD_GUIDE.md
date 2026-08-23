# Flutter + Rust 构建和运行指南

## 快速开始

### 步骤 1: 运行 Flutter 代码生成

```bash
cd D:\android\example\legado_flutter
flutter pub get
dart run build_runner build --delete-conflicting-outputs
```

**这会生成：**
- `*.freezed.dart` 文件（用于不可变数据类）
- `*.g.dart` 文件（用于 JSON 序列化）

### 步骤 2: 构建 Rust 代码

```bash
cd D:\android\example\legado_flutter\rust
cargo build --workspace
```

### 步骤 3: 运行应用

```bash
cd D:\android\example\legado_flutter
flutter run
```

---

## 详细步骤

### 1. Flutter 环境准备

```bash
# 检查 Flutter 环境
flutter doctor

# 安装依赖
cd D:\android\example\legado_flutter
flutter pub get
```

### 2. 运行代码生成

```bash
# 生成 Dart 代码
dart run build_runner build --delete-conflicting-outputs

# 如果需要持续监听文件变化
dart run build_runner watch --delete-conflicting-outputs
```

### 3. 构建 Rust 后端

```bash
cd rust

# 构建所有 crate
cargo build --workspace

# 或者单独构建
cargo build --package book_parser
cargo build --package reader_core
cargo build --package layout_engine
cargo build --package bridge
```

### 4. 生成 FFI 绑定

```bash
# 在 rust 目录下
flutter_rust_bridge_codegen generate
```

### 5. 运行应用

```bash
cd D:\android\example\legado_flutter

# 运行在调试模式
flutter run

# 运行在 release 模式
flutter run --release

# 指定设备
flutter run -d windows
flutter run -d chrome
```

---

## 常见问题

### Q: 代码生成失败

**解决方案：**
```bash
# 清理旧的生成文件
flutter clean
flutter pub get

# 重新生成
dart run build_runner build --delete-conflicting-outputs
```

### Q: Rust 编译错误

**解决方案：**
```bash
cd rust

# 清理构建缓存
cargo clean

# 重新构建
cargo build --workspace
```

### Q: FFI 绑定错误

**解决方案：**
```bash
# 确保安装了 flutter_rust_bridge_codegen
cargo install flutter_rust_bridge_codegen

# 重新生成绑定
flutter_rust_bridge_codegen generate
```

---

## 开发工作流

### 修改 Dart 代码后

```bash
# 如果修改了使用 @freezed 或 @JsonSerializable 的类
dart run build_runner build --delete-conflicting-outputs

# 然后运行
flutter run
```

### 修改 Rust 代码后

```bash
cd rust
cargo build --package <修改的包名>

# 然后运行
cd ..
flutter run
```

### 修改 FFI 接口后

```bash
cd rust
flutter_rust_bridge_codegen generate
cd ..
flutter pub get
flutter run
```

---

## 测试命令

### Rust 测试

```bash
cd rust

# 运行所有测试
cargo test --workspace

# 运行特定包的测试
cargo test --package reader_core

# 运行特定测试
cargo test --package reader_core --test pipeline_demo test_chapter_info_extraction -- --nocapture
```

### Flutter 测试

```bash
cd D:\android\example\legado_flutter

# 运行所有测试
flutter test

# 分析代码
flutter analyze
```

---

## 性能分析

### Rust 性能测试

```bash
cd rust
cargo test --package reader_core --test pipeline_demo test_performance_benchmark -- --nocapture --release
```

### Flutter 性能分析

```bash
flutter run --profile
```

---

## 调试技巧

### 查看 Rust 日志

在 Rust 代码中使用：
```rust
println!("调试信息: {:?}", variable);
```

### 查看 Flutter 日志

```bash
flutter logs
```

### 使用 DevTools

```bash
flutter run
# 然后在控制台中点击 DevTools 链接
```

---

## 清理命令

### 完全清理重建

```bash
# Flutter
cd D:\android\example\legado_flutter
flutter clean
rm -rf .dart_tool
rm -rf build

# Rust
cd rust
cargo clean

# 重新构建
flutter pub get
dart run build_runner build --delete-conflicting-outputs
cargo build --workspace
flutter run
```

---

## 快速命令参考

### 一键构建（PowerShell）

```powershell
# 保存为 build.ps1
cd D:\android\example\legado_flutter

Write-Host "步骤 1: Flutter pub get..." -ForegroundColor Green
flutter pub get

Write-Host "步骤 2: 代码生成..." -ForegroundColor Green
dart run build_runner build --delete-conflicting-outputs

Write-Host "步骤 3: 构建 Rust..." -ForegroundColor Green
cd rust
cargo build --workspace
cd ..

Write-Host "完成！运行 'flutter run' 启动应用" -ForegroundColor Green
```

运行：
```bash
powershell -ExecutionPolicy Bypass -File build.ps1
```

---

## 部署

### Windows 桌面

```bash
flutter build windows --release
```

### Android

```bash
flutter build apk --release
```

### iOS

```bash
flutter build ios --release
```

---

## 相关链接

- [Flutter 文档](https://flutter.dev/docs)
- [flutter_rust_bridge 文档](https://cjycode.com/flutter_rust_bridge/)
- [Freezed 文档](https://pub.dev/packages/freezed)
- [Riverpod 文档](https://riverpod.dev/)

---

## 目录结构

```
legado_flutter/
├── lib/                          # Flutter Dart 代码
│   ├── core/
│   │   ├── ffi/                 # FFI 绑定
│   │   └── models/              # 数据模型
│   └── features/
│       └── reader/
│           └── presentation/
│               ├── pages/       # 页面
│               ├── providers/   # 状态管理
│               └── widgets/     # UI 组件
├── rust/                         # Rust 后端
│   ├── crates/
│   │   ├── book_parser/         # 书籍解析
│   │   ├── reader_core/         # 阅读核心
│   │   ├── layout_engine/       # 排版引擎
│   │   └── bridge/              # FFI 桥接
│   └── Cargo.toml
├── pubspec.yaml                  # Flutter 依赖
└── build.rs                      # Rust 构建脚本
```
