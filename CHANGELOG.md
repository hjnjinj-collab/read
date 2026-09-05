# 变更日志

本项目的所有重要变更都会记录在此文件中。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [未发布]

### 新增
- A25 批次：统一 EPUB/TXT 行级分页精度
- 页面填充率滑杆对 EPUB/TXT 双类型真实生效
- 页面溢出时的内容截断逻辑优化

### 修复
- 页面溢出保护（页面内容超出底界时的截断处理）
- 孤寡行保护的浮点容差修复（0.5px 容差防止精度漂移导致的分页碎片）

### 变更
- 优化 APK 构建脚本（支持分 ABI 打包，`build_apk.ps1 -Abis arm64-v8a`）
- `page_fill_threshold` 语义重定义：从"EPUB 整段推页门槛"改为"内容区利用率"（0.50-1.00，对 EPUB/TXT 双类型统一生效）

## [1.0.0] - 2026-09-05

### 新增
- 初始版本
- EPUB 与 TXT 阅读支持
- 自定义字体、字号、行距
- 分页填充率调节
- 书签与阅读进度保存
- 章节导航
- Rust + Flutter 跨平台架构（book_parser、layout_engine、reader_core）
