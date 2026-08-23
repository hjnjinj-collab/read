# Legado Flutter - 使用说明

## 🚀 快速开始

### 前置要求
- ✅ Flutter SDK 3.44.9+
- ✅ Rust 工具链 (已安装)
- ✅ Visual Studio 2019+ (Windows)
- ✅ flutter_rust_bridge_codegen v2.12.0

### 安装步骤

1. **克隆项目**
   ```bash
   cd D:\android\example\legado_flutter
   ```

2. **安装 Flutter 依赖**
   ```bash
   flutter pub get
   ```

3. **编译 Rust 代码**
   ```bash
   cd rust
   cargo build --release
   cd ..
   ```

4. **复制 DLL 到正确位置**
   ```bash
   New-Item -Path "rust/crates/bridge/target/release/" -ItemType Directory -Force
   Copy-Item "rust/target/release/bridge.dll" -Destination "rust/crates/bridge/target/release/" -Force
   ```

5. **运行应用**
   ```bash
   flutter run -d windows
   ```

---

## 📖 使用教程

### 打开书籍

1. 启动应用后,你会看到空白的书架页面
2. 点击右下角的 **+** 按钮
3. 选择一个 TXT 文件 (编码支持 UTF-8, GBK, GB2312, GB18030)
4. 应用会自动:
   - 检测文件编码
   - 识别章节
   - 进行分页
   - 打开阅读界面

### 阅读操作

#### 翻页
- **下一页**: 点击屏幕右侧 (右 30% 区域)
- **上一页**: 点击屏幕左侧 (左 30% 区域)
- **显示菜单**: 点击屏幕中间 (中间 40% 区域)

#### 菜单功能
- **章节信息**: 显示当前章节标题
- **进度条**: 查看当前阅读位置
- **字体设置**: 调整字号 (待实现)
- **章节列表**: 跳转到指定章节 (待实现)
- **书签**: 添加/查看书签 (待实现)
- **设置**: 更多阅读设置 (待实现)

---

## 🧪 测试说明

### 使用测试文件

我已经创建了一个测试文件: `D:\android\example\test_book.txt`

**内容特点**:
- 4 个章节
- 中英文混排
- 多种段落格式
- 适合测试分页效果

**测试步骤**:
1. 运行应用: `flutter run -d windows`
2. 点击 + 按钮
3. 选择 `D:\android\example\test_book.txt`
4. 观察:
   - ✅ 章节识别是否正确 (应该识别出4章)
   - ✅ 中文显示是否正常
   - ✅ 英文显示是否正常
   - ✅ 分页是否合理
   - ✅ 翻页是否流畅

---

## ⚙️ 开发指南

### 修改 Rust 代码

1. **编辑代码**
   ```bash
   # 编辑文件
   # rust/crates/book_parser/src/lib.rs
   # rust/crates/layout_engine/src/lib.rs
   # rust/crates/bridge/src/api.rs
   ```

2. **重新编译**
   ```bash
   cd rust
   cargo build --release
   ```

3. **复制 DLL**
   ```bash
   Copy-Item "target/release/bridge.dll" -Destination "crates/bridge/target/release/" -Force
   ```

4. **重启应用**
   ```bash
   flutter run -d windows
   ```

### 修改 Flutter 代码

1. **编辑代码**
   ```bash
   # 编辑 lib/ 下的 Dart 文件
   ```

2. **热重载** (在运行的应用中)
   - 按 `r` - 热重载
   - 按 `R` - 热重启
   - 按 `q` - 退出

### 重新生成 FFI 绑定

**仅在修改 Rust API 签名时需要**:

```bash
# 1. 修改 rust/crates/bridge/src/api.rs
# 2. 重新生成绑定
flutter_rust_bridge_codegen generate

# 3. 重新编译 Rust
cd rust
cargo build --release

# 4. 复制 DLL
Copy-Item "target/release/bridge.dll" -Destination "crates/bridge/target/release/" -Force

# 5. 重启应用
flutter run -d windows
```

---

## 🔧 故障排查

### 问题 1: DLL 找不到

**症状**: 
```
Invalid argument(s): Failed to load dynamic library 'bridge.dll'
```

**解决**:
```bash
# 确保 DLL 在正确位置
ls rust/crates/bridge/target/release/bridge.dll

# 如果不存在,重新复制
Copy-Item "rust/target/release/bridge.dll" -Destination "rust/crates/bridge/target/release/" -Force
```

### 问题 2: Rust 编译失败

**症状**:
```
error: could not compile `bridge`
```

**解决**:
```bash
# 清理并重新编译
cd rust
cargo clean
cargo build --release
```

### 问题 3: FFI 类型不匹配

**症状**:
```
type mismatch in FFI call
```

**解决**:
```bash
# 重新生成 FFI 绑定
flutter_rust_bridge_codegen generate

# 删除旧的生成文件
Remove-Item lib/core/ffi/rust_bridge.dart/* -Recurse -Force

# 重新生成
flutter_rust_bridge_codegen generate
```

### 问题 4: Flutter 构建失败

**症状**:
```
error: Build process failed
```

**解决**:
```bash
# 清理 Flutter 缓存
flutter clean

# 重新获取依赖
flutter pub get

# 重新运行
flutter run -d windows
```

---

## 📁 重要文件说明

### 配置文件

- **`pubspec.yaml`**: Flutter 依赖配置
- **`rust/Cargo.toml`**: Rust workspace 配置
- **`flutter_rust_bridge.yaml`**: FFI 绑定生成配置

### 核心代码

#### Rust 侧
- **`rust/crates/book_parser/src/lib.rs`**: TXT 解析器
- **`rust/crates/layout_engine/src/lib.rs`**: 布局引擎
- **`rust/crates/bridge/src/lib.rs`**: 类型定义
- **`rust/crates/bridge/src/api.rs`**: API 实现

#### Flutter 侧
- **`lib/main.dart`**: 应用入口
- **`lib/core/ffi/book_service.dart`**: FFI 服务封装
- **`lib/core/models/simple_models.dart`**: 数据模型
- **`lib/features/reader/presentation/providers/reader_provider.dart`**: 状态管理
- **`lib/features/reader/presentation/pages/reader_page.dart`**: 阅读页面

---

## 🎨 自定义设置

### 修改默认字体大小

编辑 `lib/features/reader/presentation/providers/reader_provider.dart`:

```dart
// Reading settings
double _fontSize = 18.0;      // 改为你想要的字号
double _lineHeight = 1.5;     // 改为你想要的行高
```

### 修改页面边距

编辑 `lib/features/reader/presentation/providers/reader_provider.dart`:

```dart
double _paddingHorizontal = 20.0;  // 左右边距
double _paddingVertical = 20.0;    // 上下边距
```

### 修改背景颜色

编辑 `lib/features/reader/presentation/pages/reader_page.dart`:

```dart
backgroundColor: const Color(0xFFF5F5DC), // Beige
// 改为你想要的颜色,例如:
// backgroundColor: Colors.white,     // 白色
// backgroundColor: Color(0xFFE8E8E8), // 浅灰
```

---

## 📊 性能优化建议

### 1. 编译优化版本

```bash
# 使用 release 模式
cd rust
cargo build --release

# 或者启用更激进的优化
cargo build --release --target x86_64-pc-windows-msvc
```

### 2. 减少页面重绘

- 只在翻页时更新页面
- 使用 CustomPaint 而非 Widget 树
- 缓存已渲染的页面

### 3. 内存管理

```dart
@override
void dispose() {
  // 确保关闭书籍释放内存
  ref.read(readerProvider.notifier).closeBook();
  super.dispose();
}
```

---

## 🐛 Bug 反馈

如果遇到问题:

1. **检查日志**
   ```bash
   # Flutter 日志
   flutter logs
   ```

2. **查看错误信息**
   - 在运行的终端查看输出
   - 应用崩溃时查看堆栈跟踪

3. **记录问题**
   - 操作步骤
   - 错误信息
   - 系统环境

---

## 📚 学习资源

### Flutter
- [Flutter 官方文档](https://flutter.dev/docs)
- [Dart 语言教程](https://dart.dev/guides)
- [Riverpod 状态管理](https://riverpod.dev/)

### Rust
- [Rust 官方教程](https://www.rust-lang.org/learn)
- [Rust 异步编程](https://rust-lang.github.io/async-book/)
- [Rust FFI 指南](https://doc.rust-lang.org/nomicon/ffi.html)

### Flutter Rust Bridge
- [官方文档](https://cjycode.com/flutter_rust_bridge/)
- [示例项目](https://github.com/fzyzcjy/flutter_rust_bridge/tree/master/frb_example)

---

## 🎯 下一步学习建议

1. **理解 FFI 工作原理**
   - 阅读 `lib/core/ffi/rust_bridge.dart/` 生成的代码
   - 理解类型如何在 Rust 和 Dart 之间转换

2. **掌握 Riverpod 状态管理**
   - 学习 Notifier 模式
   - 理解 Provider 的生命周期

3. **深入 Rust 异步编程**
   - 虽然当前 API 是同步的,但可以改为异步
   - 学习 tokio 运行时

4. **优化性能**
   - 使用 profiler 找出瓶颈
   - 优化 Rust 算法
   - 减少 FFI 调用次数

---

**祝你开发愉快!** 🎉

如有问题,欢迎查看其他文档:
- [开发者指南](./AGENTS.md)
- [文档索引](./docs/README.md)
- [Bug 修复记录](./docs/BUG_FIXES.md)
