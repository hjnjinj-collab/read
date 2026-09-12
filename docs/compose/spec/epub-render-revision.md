---
feature: epub-render-revision
status: delivered
updated: 2026-09-12
branch: master
commits: 1399748..HEAD
---

# EPUB 渲染真机修订（A34.1 / A34.2）

## Report

**What was built** — A34.1 真机反馈四件套：① UI「显示本章说」→「显示注释」；② 注释默认蓝灰 `#5A6B7A` / 0.82 倍，设置三色预设 + 字号滑杆，字号进三路缓存键，颜色绘制期覆盖；③ 封面启发式 `cover*` / 标题含「封面」+ 单图 → 整页背景；④ Right/Center×indent 短行贴右缘。A34.2 修订：EPUB 结构化路径**不再**执行「去除重复标题」——阅读页无独立章节头，与目录同文的 `h1` 被剥离后页面标题完全消失（瓦尔登湖 `chapter001`「省俭有方」真机回归）。TXT 仍走原逻辑；设置副标题标明仅 TXT 生效。

**Verification** — `cargo test -p layout_engine --lib` 90 PASS；`book_parser` 125 PASS（含 `test_is_cover_like_names`）；`reader_core` 173 PASS；`bridge` 17 PASS；`fix_sync.ps1` PASS；`flutter analyze` 0 error。A34.2：探针确认 IR 保留 `H1「省俭有方」`，分页路径不再调用 `remove_duplicate_title_blocks`。

**Journey log** —
1. `text-indent` 与 `text-align:right` 不能「先对齐再加 indent」——CSS 语义是 indent 只缩首行可用宽。
2. 封面识别用 `starts_with("cover")` 而非 `contains`，避免 uncover 等误伤。
3. 注释色与字号分通道：色不进缓存键，字号必须进键。
4. `CacheKey.config_hash` 亦应含 `show_comments`/`comment_scale`。
5. A34.2：`remove_duplicate_title` 对 EPUB 是「删掉页内唯一标题」——无页头时不能剥离。

## [S1] Problem

A34 章末注适配真机验收通过（点按弹窗可用），但暴露四处渲染/命名问题：

1. **注释视觉弱**：`is_comment` 强制 0.7 倍 + `#888888` 灰，字号过小且与正文区分不足。
2. **命名过时**：设置项与注释仍叫「本章说」，功能本质是注释/脚注，用户钦定改为「注释」。
3. **封面不全屏**：`coverpage.html` 仅为 `<p><img src="Cover.jpg"/></p>`，OPF 无 `duokan-page-fullscreen`，当前按普通内嵌图渲染。
4. **右对齐溢出**：`front002.html` 的 `p.right`（`text-align:right` + 继承 `text-indent:2em`）「——梭罗」超出右边界。

样例书：`E:\epub\瓦尔登湖 (亨利·戴维·梭罗)...\OPS\`。

## [S2] Design

### 注释命名与视觉

| 项 | 约定 |
|---|---|
| UI 文案 | 「显示本章说」→「显示注释」 |
| 默认字号 | 注释行 `comment_scale` 默认 **0.82** |
| 默认色 | 蓝灰 `#5A6B7A`（亮）/ `#8A9BAB`（暗） |
| 自定义 | 设置「注释颜色」三预设 + 字号倍率滑杆 0.70–1.00 |
| 颜色通道 | 纯绘制期：`PageContentRenderer.commentColor` 覆盖，**不进**分页缓存键 |
| 字号通道 | `LayoutConfig.comment_scale` + `ParagraphFormatSettings.comment_scale`，**进**缓存键 |

预设：blueGray（默认）/ gray / sepia（亮暗双阶见 `applyCommentColorPreset`）。

### 封面全屏

判定（全部满足）：
1. href 文件名以 `cover` 开头（ASCII 不区分大小写）**或** title 含「封面」；
2. 过滤空文本段后 `blocks` 恰为一张 `Image`。

动作：转 `PageBackground { size: Cover }` 并清空 blocks。与 OPF `duokan-page-fullscreen` 路径 OR。

### 右对齐 × 缩进

```
indent_here = first_line ? indent_px : 0
align_w = content_width - indent_here
x = align_line_x(line.width, align_w, align) + indent_here
```

Right 短行右缘 = `padding.left + content_width`，不溢出。

### 缓存 / 版本

`comment_scale` 进 `StructuredPageKey.comment_scale_bits`、`ParagraphFormatSettings.hash_value`、Dart `paraFormatHash`，并进 `CacheKey.config_hash`。`LAYOUT_REVISION=4`。颜色不进键。

## [S3] Out of Scope

- 注释左缩进块/边框等更重版式分区
- 跨章脚注、弹层样式深度定制
- 非 cover 单图章节全屏
- 内部字段名批量重命名（仅 UI 可见文案）

## Tasks

- [x] T1: UI 文案「显示本章说」→「显示注释」+ 副标题 — acceptance: 设置页仅出现「显示注释」 (covers: S2 注释命名)
- [x] T2: `comment_scale` 默认 0.82 + 硬编码 0.7 改走该字段 + `LAYOUT_REVISION=4` — acceptance: 单测锁定 comment 行高来自 config (covers: S2 注释视觉)
- [x] T3: Dart 设置 `commentScale`/`commentColorPreset` + 滑杆/三色预设；颜色绘制期覆盖 — acceptance: 调预设即时变色；调字号触发重排 (covers: S2 注释视觉; depends: T2)
- [x] T4: 封面启发式 `is_cover_like_names` + 单图 → `PageBackground` — acceptance: cover* / 封面命中；uncover 不误伤（单测） (covers: S2 封面全屏)
- [x] T5: 对齐×缩进修复 + 回归测试 — acceptance: Right+indent 短行不溢出 (covers: S2 右对齐)
- [x] T6: fix_sync + cargo/analyze 验证 — acceptance: 测试 PASS，无新增 error (covers: S2)
