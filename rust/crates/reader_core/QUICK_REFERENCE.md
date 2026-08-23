# Reader Core 快速命令参考

## 🚀 快速测试命令

### 运行所有测试
```bash
cd D:\android\example\legado_flutter\rust
cargo test --package reader_core
```

### 章节信息提取演示
```bash
cargo test --package reader_core --test pipeline_demo test_chapter_info_extraction -- --nocapture
```

### 内容预处理演示
```bash
cargo test --package reader_core --test pipeline_demo test_content_preprocessing -- --nocapture
```

### 并发处理演示
```bash
cargo test --package reader_core --test pipeline_demo test_concurrent_chapter_processing -- --nocapture
```

### 快速翻页场景测试
```bash
cargo test --package reader_core --test pipeline_demo test_rapid_chapter_switching -- --nocapture
```

### 性能基准测试（100章）
```bash
cargo test --package reader_core --test pipeline_demo test_performance_benchmark -- --nocapture
```

### 运行所有演示测试
```bash
cargo test --package reader_core --test pipeline_demo -- --nocapture --test-threads=1
```

## 🔧 开发命令

### 构建
```bash
cargo build --package reader_core
```

### 构建整个工作空间
```bash
cargo build --workspace
```

### 检查代码
```bash
cargo check --package reader_core
```

### 格式化代码
```bash
cargo fmt --package reader_core
```

### 运行 Clippy 检查
```bash
cargo clippy --package reader_core
```

## 📊 测试统计

### 当前测试覆盖
- **单元测试**: 22 个 ✅
- **集成测试**: 6 个 ✅
- **演示测试**: 5 个 ✅
- **总计**: 33 个测试 ✅

### 性能指标
- **吞吐量**: 7874 章/秒
- **平均延迟**: 127µs/章
- **首次处理**: 650µs

## 📁 关键文件位置

```
D:\android\example\legado_flutter\rust\crates\reader_core\
├── src/
│   ├── lib.rs                      # 模块导出
│   ├── content_preprocessor.rs     # 内容预处理器
│   ├── task_scheduler.rs           # 任务调度器
│   └── chapter_utils.rs            # 章节工具
├── tests/
│   ├── integration_test.rs         # 集成测试
│   └── pipeline_demo.rs            # 演示测试
├── README.md                       # 使用指南
└── PHASE1_COMPLETE.md              # 完成总结
```

## 🎯 常用代码片段

### 创建 ChapterInfo
```rust
use reader_core::ChapterInfo;

let info = ChapterInfo::new("第123章 大决战".to_string());
println!("章节号: {}", info.chapter_number);  // 123
println!("纯净标题: {}", info.pure_title);    // "大决战"
```

### 内容预处理
```rust
use reader_core::{ContentPreprocessor, ProcessOptions};
use std::sync::Arc;

let preprocessor = Arc::new(ContentPreprocessor::empty());
let options = ProcessOptions::default();
let processed = preprocessor.process("内容", &options).await?;
```

### 提交章节任务
```rust
use reader_core::ChapterTaskScheduler;
use std::sync::Arc;

let scheduler = Arc::new(ChapterTaskScheduler::new());
scheduler.submit(0, async {
    // 处理章节 0
});
```

## 📚 文档链接

- [完整使用指南](./README.md)
- [Phase 1 测试报告](../../../PHASE1_TEST_REPORT.md)
- [Phase 1 完成总结](./PHASE1_COMPLETE.md)
- [并发管道分析](../../../docs/CONCURRENT_PIPELINE_ANALYSIS.md)
