---
feature: bookshelf-continue-card-ui
status: designed
updated: 2026-09-19
branch: master
commits: # filled at delivery
---

# 书架「续读主卡」UI 推进计划（布局优先）

## Report

## [S1] Problem

书架打开后任务层弱：仅有封面轮换 `RecentHeroBanner`（视觉海报），缺少 MD3 目标应用 `HomeDashboard` 那样的**可操作续读主卡 + 功能卡模块**。需先定布局与模块，再进 Flutter 实现。

## [S2] Design

### 现状 vs 目标

| | legado_flutter 现状 | legado-with-MD3 目标 |
|--|---------------------|----------------------|
| 位置 | 书架滚动区顶部 Hero 横幅 120px | **Home** Dashboard（书架/源 Tab 之外的首页概念） |
| 主卡 | 海报底图 + 「继续阅读」文案 + 细进度条 | `RecentBookCard` GlassCard：封面 56×(5/7) + 书名/作者/章名 + % chip + **底部光晕进度条** |
| 模块体系 | 无 | `HomeDashboardSection` 可开关：RecentBook / 统计×2 / RecentBooks 横滑 / DailyGoal / WebDav |
| 书架页 | 网格 + 分组 | 分组书架（style 0/1/2），非 Dashboard |

**迁移策略（本项目）**：不新建 Home Tab；在 **书架页**落地 Dashboard 式「功能卡堆」，替代/升级现有 Hero。模块可后续配置显隐。

### 主卡与功能卡模块（布局）

| 模块 ID | 名称 | 形态 | 内容模块 | 优先级 |
|---------|------|------|----------|--------|
| **M1** | 续读主卡 Continue | 全宽卡 ~128–140px | 标题行「继续阅读」+ 封面 + 书名/作者/章名 + % + 底缘进度光晕 + 主按钮「继续」 | **P0** |
| M2 | 统计双卡 | 两列等宽 | 读过 N 本 · 累计 H 小时（可后置数据） | P1 |
| M3 | 最近阅读横滑 | LazyRow 小卡 | 封面 + 书名 + 章进度 | P1 |
| M4 | 今日阅读目标 | 全宽卡 | 分钟目标环/条 + 点按进记录 | P2 |
| M5 | 快捷操作 | 可选 | 导入本地 / 书源（对齐现有 FAB/空态） | P2 |

### M1 主卡布局（权威稿）

```
┌─────────────────────────────────────────┐
│ ◎ 继续阅读                    [42% chip]│  ← 标题行 primary icon + 强调标题
│                                         │
│ ┌────┐  书名（2 行截断）                 │
│ │封面│  作者                             │
│ │56  │  章名 · marquee · 1 行            │
│ └────┘                          [继续 ▸] │  ← 质感主按钮（非纯白）
│ ═══════════════════════════════════════ │  ← 底缘进度 + 微光晕（MD3 RecentReadingProgress）
└─────────────────────────────────────────┘
```

- 底：tonal / 浅霜 **一张卡**（settingsCardRadius 16），**不要**海报全出血（与书架封面网格抢戏）
- 封面：`BookshelfCover` 语义 = Flutter CoverStore；圆角与 `kCoverRadius` 可略大（10–12）
- 进度：章节比 `(chapterIndex+1)/total`；无进度书 **不显示 M1**，回落纯网格
- 点按：整卡/主按钮 → 打开该书（沿用 slot 缩放转场）
- 玻璃：chrome 可选 frost；**禁止**盖正文语义的重 Lens

### 功能主卡（M2–M4 布局要点）

- **M2 StatisticCard**：icon + 小标题 + 大数字 + 单位；两列 gap 12
- **M3 RecentBooksRow**：横滑 64px 封面卡 + 书名截断；点按进对应书
- **M4 ReadingGoalCard**：今日分钟 / 目标分钟；线性或圆环 + 次文案

### 布局原型（本轮交付）

交互稿：`ui-bookshelf-continue-cards.html`（手机宽度，可切换空态/有进度/全模块）。

### 主流应用启示（摘要）

| 产品 | 主卡模式 |
|------|----------|
| Kindle / Apple Books | Continue reading 大卡 + 进度，任务第一 |
| 微信读书 | 续读条 + 时长社交信息 |
| MD3 Legado | Glass RecentBookCard + 可开关 Dashboard 模块 |

### 实现阶段（布局定稿后）

1. P0：书架 M1 数据绑定（lastRead + progress）+ 替换 Hero  
2. P1：M2/M3 可选模块与显隐  
3. P2：M4 目标 / 配置 sheet  

## [S3] Out of Scope

- WebDav 备份卡、完整阅读记录页  
- 书源 homepageModules（那是源首页，不是书架）  
- 本轮 Flutter 代码实现（先锁布局）

## Tasks

- [ ] T1: 布局稿 HTML 可预览 — acceptance: 手机宽度展示 M1 + 功能卡分区 (covers: S2)
- [ ] T2: 用户确认 M1 结构后再开 compose 实现轮 (covers: S2)
- [ ] T3: M1 Flutter 落地（后续轮）— acceptance: 有进度书显示续读主卡并可一键进书 (covers: S2)
