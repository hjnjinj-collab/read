# 内容净化功能测试指南

## 已完成的工作

### 1. Rust 层修复
- ✅ 修复了 `chapter_extractor.rs:263` 的字符串切片 panic 问题
- ✅ 添加了边界检查：确保 `start_offset <= end_offset`
- ✅ 添加了防御性验证：在 `validate_chapter()` 中检查偏移量有效性

### 2. Flutter UI 集成
- ✅ 在 `BookService` 中添加了内容净化 API 封装
- ✅ 在 `ReaderProvider` 中添加了净化设置状态
- ✅ 在设置对话框中添加了 3 个净化选项开关
- ✅ 打开书籍时自动应用净化设置

### 3. 测试文件
- ✅ 创建了 `test_cleaning.txt` 包含：
  - HTML 标签 (`<p>`, `<div>`, `<br>`, `<span>`)
  - 广告内容（笔趣阁网址、域名提醒）
  - 需要智能分段的长句

## 如何测试

### 步骤 1: 打开测试文件
1. 应用已启动，字体加载成功 ✓
2. 点击主界面的「打开书籍」按钮
3. 选择 `D:\android\example\legado_flutter\test_cleaning.txt`

### 步骤 2: 查看默认效果
1. 书籍加载后，查看第一章内容
2. **预期看到**：HTML 标签和广告已被清理（默认开启）
3. 浏览不同章节，观察内容

### 步骤 3: 测试净化开关
1. 点击设置按钮（或快捷键），打开「内容处理设置」对话框
2. 看到 **内容净化** 区域（在最上方），包含 3 个开关：
   - ✅ 清理 HTML 标签
   - ✅ 移除广告内容
   - ✅ 智能分段

#### 测试场景 A：关闭所有净化
1. 关闭 3 个开关
2. 点击「应用设置」
3. **预期效果**：
   - 第一章看到 `<p>这是一个包含HTML标签的段落。</p>`
   - 看到 `【本章节由笔趣阁www.biquge.com提供】`
   - 段落保持原始格式

#### 测试场景 B：只开启 HTML 清理
1. 开启「清理 HTML 标签」
2. 关闭「移除广告内容」和「智能分段」
3. 点击「应用设置」
4. **预期效果**：
   - HTML 标签消失（`<p>`, `<div>` 等被删除）
   - 广告仍然存在
   - 段落未优化

#### 测试场景 C：只开启广告删除
1. 关闭「清理 HTML 标签」
2. 开启「移除广告内容」
3. 关闭「智能分段」
4. **预期效果**：
   - HTML 标签仍在
   - `【笔趣阁】`、`===广告===` 等消失
   - 段落未优化

#### 测试场景 D：全部开启（推荐）
1. 开启所有 3 个净化选项
2. 点击「应用设置」
3. **预期效果**：
   - HTML 标签消失
   - 广告消失
   - 段落间距优化，阅读舒适

### 步骤 4: 对比测试
在不同章节之间切换，验证：
- 第一章：HTML 标签测试
- 第二章：广告清理测试
- 第三章：智能分段测试
- 第四章：综合测试

## 验证要点

### ✅ 功能正确性
- [ ] HTML 标签开关有效
- [ ] 广告删除开关有效
- [ ] 智能分段开关有效
- [ ] 设置持久化（重新打开书籍仍生效）

### ✅ 边界情况
- [ ] 空章节不崩溃
- [ ] 纯文本章节正常显示
- [ ] 复杂 HTML 嵌套正常处理

### ✅ 用户体验
- [ ] 设置对话框操作流畅
- [ ] 应用设置后立即生效
- [ ] 提示信息清晰

## 已知问题

### Rust 编译警告（非致命）
- 6 个 unused imports（可选修复）
- 未使用的变量 `i`, `start`, `end`（可选修复）

### 原 panic 问题
**已修复** - `chapter_extractor.rs:263` 的 `begin > end` panic

## 后续改进

### 1. 繁简转换实现
当前状态：接口预留，实际转换未实现
- 需要添加 `opencc-rust` 依赖
- 实现 `ConvertMode::S2T` 和 `T2S`

### 2. 更智能的广告识别
当前：基于正则表达式匹配
可改进：
- 添加更多广告模式
- 机器学习模型识别
- 用户自定义广告规则

### 3. 性能优化
- 内容净化缓存（避免重复处理）
- 异步净化（大文件不阻塞 UI）

## 文件清单

### 修改的文件
1. `rust/crates/book_parser/src/chapter_extractor.rs` - 修复字符串切片 panic
2. `rust/crates/bridge/src/api.rs` - 修复 Tokio 运行时 panic，使用 OnceLock 延迟初始化
3. `lib/core/ffi/book_service.dart` - 添加净化 API
4. `lib/features/reader/presentation/providers/reader_provider.dart` - 集成净化设置
5. `lib/features/reader/presentation/widgets/reader_settings_dialog.dart` - 添加 UI 控件

### 新增的文件
1. `test_cleaning.txt` - 测试用书籍文件
2. `TESTING_GUIDE.md` - 本测试指南

## 已修复的 Panic 问题

### Issue #1: 字符串切片越界
**位置**: `chapter_extractor.rs:263`  
**错误**: `begin > end (120 > 117) when slicing`  
**原因**: UTF-8 字符边界调整时，`end_offset` 向前查找可能变得比 `start_offset` 小  
**修复**:
- 添加边界调整后的顺序检查（第 218-225 行）
- 在 `validate_chapter()` 中添加防御性检查（第 264-274 行）
- 跳过无效章节而不是 panic

### Issue #2: Tokio 运行时缺失
**位置**: `preload_executor.rs:183`  
**错误**: `there is no reactor running, must be called from the context of a Tokio 1.x runtime`  
**原因**: `PRELOAD_EXECUTOR` 静态初始化时调用 `tokio::spawn()`，但没有运行时上下文  
**修复**:
- 将 `Lazy` 改为 `OnceLock`（第 1296 行）
- 添加 `get_preload_executor()` 函数（第 1299-1321 行）
- 在 Tokio 运行时中初始化 executor
- 更新所有使用点（5 处）

## 相关文档
- `docs/FFI_CODEGEN_SUCCESS.md` - FFI 代码生成技术报告
- `docs/BUG_FIXES.md` - 历史 bug 记录
- `AGENTS.md` - 项目构建规范
