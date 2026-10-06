---
feature: note-export-share
status: delivered
updated: 2026-10-01
branch: master
commits: 320dd21..HEAD
---

# 笔记导出与分享

## Report

**What was built** — 笔记列表支持一键带走：`formatNotesAsMarkdown` 产出契约稳定的 Markdown（书名头 / 共 N 条 / 章页标题 / 摘录引用块 / 备注 / 分隔线）；列表标题行「复制全部」进系统剪贴板、「导出」经 FilePicker SAF 存 `.md`（与日志导出同模式）。空列表只提示「暂无笔记」、不弹保存框。导出/复制 `await _future`，加载完成前点击不会误报空。

**Verification** —
- `flutter test test/note_highlight_test.dart`：PASS 13/13（含 formatNotesAsMarkdown 契约、缺省页码、空列表）
- `flutter analyze --no-pub`：基线 issues，无本轮 error
- arm64 APK 构建通过

**Journey log** —
- 不加 share_plus：剪贴板 + 存文件即可覆盖「分享」主路径；真机强需求系统分享面板再引依赖
- FutureBuilder 内副作用赋值 `_items` 有竞态，导出路径改为 `await _future`
- 导出文件名 `notes_{slug}_{yyyyMMdd_HHmm}.md` 与 spec 对齐

## [S1] Problem

笔记/划线已能添加、编辑、删除、单条复制，但**无法带走**：

1. 全书笔记不能一键导出成可归档文本（Markdown）。
2. 不能把多条笔记一次性分享出去（复制全部 / 存文件）。

（跨章选区、跨章笔记迁移仍后置，见 note-ux-and-batch-locate / note-fuzzy-relocate 的 Out of Scope。）

## [S2] Design

### 目标

| 能力 | 行为 |
|------|------|
| 导出全部 | 笔记列表 → Markdown 文件（FilePicker SAF，与日志导出同模式） |
| 复制全部 | 同一 Markdown 进系统剪贴板（分享到 IM/备忘录粘贴） |
| 单条 | 已有「复制」保持不变 |

### Markdown 契约

```markdown
# 《书名》笔记

共 N 条 · 导出时间 ISO8601

## 第 3 章 · 第 12 页

> 摘录原文

备注：用户备注（若有）

---
```

- 章/页来自 `NoteListItem`（`chapterIndex+1` / `pageIndex+1`）；无页码省略「第 P 页」。
- 空笔记书：Snackbar「暂无笔记」，不弹保存框。

### UI

- `NoteListDialog` 标题行加「导出」「复制全部」；沿用日志导出的 FilePicker.saveFile。
- 文件名：`notes_{bookSlug}_{yyyyMMdd_HHmm}.md`。

### 测试

- `formatNotesAsMarkdown`：含摘录/备注/章页、缺省页码、空列表。
- 导出/复制路径 `await _future`，避免加载竞态。

## [S3] Out of Scope

- 系统分享面板（share_plus）——先剪贴板/存文件，真机若强需求再加依赖。
- 跨章选区、跨章笔记迁移。
- 按颜色/章节筛选导出、PDF/DOCX 导出。

## Tasks

- [x] T1: `formatNotesAsMarkdown` + 单测 — acceptance: 格式契约稳定可断言 (covers: S2)
- [x] T2: 笔记列表「导出 / 复制全部」 — acceptance: 有笔记可导出 .md 或复制；空列表提示 (covers: S2; depends: T1)
- [x] T3: analyze + 测试收口 — acceptance: 测试过；文档 Report (covers: S2; depends: T1,T2)
