---
feature: letter-spacing-ffi
status: delivered
updated: 2026-09-27
branch: master
commits: 736ea1c..HEAD  # 本轮改动待提交后回填
---

# 字距进 FFI（真实折行）

## Report

**What was built** — 用户字距从「仅绘制层 `TextStyle.letterSpacing` + `layoutPadH` 近似折行」改为进入 Rust `LayoutConfig.letter_spacing`：判满/标点压缩按 `natural + ls × n_chars`（Flutter n 字 n 隙）计预算，`justify_gap` 先扣 `ls × n` 再均分，绘制仍 `letterGap + userLS` 恰好贴满行宽。`measure_text_width` 恒返回自然宽（MeasureCache 红线不破）。Dart 侧 `setLetterSpacing` 经 `setParagraphFormatSettings` 同步全局并等待完成后再重排；`para_format_hash` / EPUB `StructuredPageKey` 均纳入字距；删除 padding 近似。命中测试/选区/脚注 TextPainter 与主绘制同口径叠加 `userLetterSpacing`。

**Verification** — `cargo test --package layout_engine --lib` 95 passed（含字距折行/自然宽/justify 扣字距新测）；`cargo test --package reader_core --lib` 173 passed（含 hash 含字距）；`cargo test --package bridge --lib` 18 passed；`fix_sync.ps1` 全量构建成功；`flutter analyze` 25 issues 全为 PRE-EXISTING 基线。

**Journey log** — MeasureCache 只存自然宽，字距只能在判满/justify 处计入，否则缓存污染或双重计量。justify 必须先扣 `user_ls × n`，否则 `letterGap + userLS` 绘制会系统性溢出。`unawaited(_syncParagraphFormat())` + 立刻 reload 会与 FFI 赛跑，布局可能读到旧字距——轻量 setter 须先 await 同步。EPUB `StructuredPageKey` 与 TXT `pagination_cache` 双侧都要 hash 字距，不能只靠 `para_format_hash`。选区/脚注 hit-test 的 TextPainter 必须与主绘制同 letterSpacing，否则字距≠0 时几何错位。

## [S1] Problem

用户字距（设置「字距」滑杆）目前**只在 Dart 绘制层**以 `TextStyle.letterSpacing` 叠加，Rust 折行仍按自然宽断行：

1. **折行错误**：用 `layoutPadH` 把左右 padding 按「约 content/fontSize 字/行」估算加宽/收窄来近似补偿，实际行字数随中英混排/字体变化，导致行溢出右边距或行尾参差。
2. **justify 叠加溢出**：两端对齐 `letter_gap = (可用宽 − 自然宽) / n_chars` 未扣除用户字距；绘制端 `letterSpacing = letterGap + userLS` 后行宽 = 可用宽 + userLS×n，**系统性溢出**。
3. **调节过程观感**：超宽时曾触发 `canvas.scale` 压小字形（像改字号）；已禁缩放后改为直接溢出边距，调距后仍「挤出/缩进不对」。

根因：`LayoutConfig.letter_spacing` 在 bridge 全部硬编码 `0.0`，测量/判满/justify 均不知用户字距。

## [S2] Design

### 契约：Flutter letterSpacing 语义

`TextStyle.letterSpacing = L` 对**每个字符（含行尾）**加 L 个间隙（n 字 n 隙）：

```
painted_width = natural_width + L * n_chars
```

绘制端继续 `letterSpacing: entry.letterGap + PageContentRenderer.userLetterSpacing`。

### MeasureCache 红线（保持）

- `MeasureCache` / Dart `MeasureTextService` **只存自然宽**（letterSpacing=0）。
- `measure_text_width` **恒返回自然宽**（含 ttf-parser 回退；去掉回退里对 `config.letter_spacing` 的加减）。
- 用户字距只在**判满预算**与 **justify 空隙**处计入，不进缓存键、不污染测量。

### Rust

1. `ParagraphFormatSettings.letter_spacing: f32`（px，默认 0.0；钳制 [-2, 8]）。
2. `set_paragraph_format_settings` 增参 `letter_spacing: f32`，与 justify/punctuation_compress 同源全局。
3. `effective_letter_spacing()` → 所有 `LayoutConfig` 构造点（含 `structured_layout_config`）写入 `letter_spacing`（替换硬编码 0.0）。
4. **判满**（TXT `find_longest_fit` / EPUB `find_longest_fit_styled` / 标点压缩延伸）：

   ```
   spaced(n) = natural + letter_spacing * n
   接受条件: spaced(n) <= max_width + eps
   ```

5. **justify_gap** 增参 `letter_spacing`：

   ```
   slack = available − natural − letter_spacing * n_chars
   gap   = slack / n_chars
   ```

   绘制 `letterGap + userLS` 后行宽恰为 available。短行/末行豁免规则不变。
6. 旧参考实现 `layout_paragraph`（已退役）不改；生产路径 oracle + styled 全覆盖。

### Dart

1. `BookService.setParagraphFormatSettings` 增 `letterSpacing`。
2. `setLetterSpacing` / 持久化恢复 → `_syncParagraphFormat()`（写入 Rust 全局）+ `_paraFormatHash` 含字距 + **await 完成后**再 `_reloadAfterLayoutChange`。
3. **删除 `layoutPadH` 近似**：排版 padding 一律用 `_paddingHorizontal`。
4. `previewLetterSpacing` 保持拖动中只改绘制（不落库、不重排）；松手 `setLetterSpacing` 触发完整重排。禁止 `canvas.scale` 规则保持。
5. 命中测试/选区/脚注 TextPainter 与主绘制同口径：`letterGap + userLetterSpacing`。

### 缓存

- `_computeParaFormatHash` 纳入 `(_letterSpacing * 1000).round()`。
- TXT 分页缓存 hash `config.letter_spacing`；EPUB `StructuredPageKey.letter_spacing_bits` 双保险。
- `layoutFingerprint` 已含 `_letterSpacing`。

## [S3] Out of Scope

- 拖动过程中防抖实时重排（松手才重排，预览仅绘制）。
- 字体 sheet / 悬浮工具排等其它 P 项。
- 旧 `layout_paragraph` 参考实现改造。
- MeasureCache 键扩展（红线：不进缓存）。

## Tasks

- [x] T1: Rust `ParagraphFormatSettings.letter_spacing` + `set_paragraph_format_settings` 增参 + `effective_letter_spacing` 写入全部 LayoutConfig — acceptance: bridge 编译通过；structured 配置 letter_spacing 非硬编码 0 (covers: S2)
- [x] T2: 判满/标点压缩计入字距 + `justify_gap` 扣除字距 + `measure_text_width` 恒自然宽 — acceptance: 单测 letter_spacing>0 行字数减少；justify+字距后 spaced 宽≈available (covers: S2; depends: T1)
- [x] T3: Dart 同步 letterSpacing 至 FFI/para_format_hash，删除 layoutPadH — acceptance: 调字距后重排折行正确，无 padding 近似 (covers: S2; depends: T1)
- [x] T4: Rust 单测 + fix_sync 全量构建 — acceptance: cargo test layout_engine 通过；fix_sync 成功 (covers: S2; depends: T2, T3)
