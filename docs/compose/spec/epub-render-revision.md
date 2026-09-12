---
feature: epub-render-revision
status: delivered
updated: 2026-09-12
branch: master
commits: 1399748..HEAD
---

# EPUB 渲染真机修订（A34.1 / A34.2 / A34.3）

## Report

**What was built** — A34.1 真机反馈四件套：注释可配样式、封面全屏启发式、右对齐缩进修复、UI 改名「显示注释」。A34.2：EPUB 不再剥离页内章节标题（无独立章节头时去重即丢失）。A34.3：适配 `h1.zw-text1 { border-bottom: solid 2px #2C7938 }`——CSS border-bottom 物化为标题下内容区宽填充分割线（`LayoutItem::Hr` → `RectEntry` filled，Dart 按色填充）。`LAYOUT_REVISION=5`。

**Verification** — layout_engine 91 / book_parser 126 / reader_core 173 / bridge 17 PASS；含 `test_heading_border_bottom_css`、`items_hr_emits_filled_rect`。`fix_sync.ps1` PASS。

**Journey log** —
1. `text-indent` 与 `text-align:right` 不能「先对齐再加 indent」。
2. 封面识别用 `starts_with("cover")`。
3. 注释色不进缓存键，字号必须进键。
4. EPUB 页内标题是唯一标题源，不能去重剥离。
5. border-bottom 复用 `isTableFrame`+`color`+小高度填充，避免 FRB 枚举。

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
