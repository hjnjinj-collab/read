---
feature: bookshelf-continue-card-ui
status: in-progress
updated: 2026-09-19
branch: master
commits: # filled at delivery
---

# 首页 Dashboard 与书架分工（续读/图表）

## Report

## [S1] Problem

首版布局稿把 Dashboard 塞进书架页，等于「新建页却挂在书架上」；Hero 仅书卡、统计过素（无图表）。用户确认：**若做首页，应是独立首页**；书架保持书库。

## [S2] Design

### 信息架构（对齐 MD3：Home ≠ Bookshelf）

| Tab | 角色 | 顶部内容 |
|-----|------|----------|
| **首页**（新） | 任务与数据 Dashboard | 续读主卡 + 阅读折线图 + 统计/目标/最近 |
| **书架** | 书库 | 网格/列表 + 可选**轻量**续读条（非全量 Dashboard） |
| 书源 / 设置 | 不变 | — |

导航：建议 **首页为第一 Tab**；现有三 Tab 扩为四 Tab（实现轮再定 go_router）。

### 首页模块（生动化）

| ID | 模块 | 形态 | 数据（可 mock） |
|----|------|------|-----------------|
| H1 | 续读主卡 | 全宽：封面+书名/章+进度光晕+「继续」 | lastRead book + chapterProgress |
| H2 | **近 7 日阅读折线** | SVG/Canvas 折线 + 面积填充 + 今日高亮 | daily minutes |
| H3 | 统计条 | 读过本数 · 累计小时 · 连续天数 | aggregates |
| H4 | 最近阅读横滑 | 小封面卡 | recent books |
| H5 | 今日目标 | 环形或条 + 分钟文案 | today vs goal |

### 书架页（保持书库）

- 主体：封面网格/列表 + 分组
- 可选 H1-lite：顶栏下一条 **薄续读条**（书名+进度），不复制图表/统计

### 图表视觉

- 折线：primary 描边 + 低透明面积渐变；7 点；今日点更大
- 空数据：淡虚线基线 +「暂无阅读记录」
- 不引入重型图表库——布局稿用 SVG；Flutter 可用 CustomPaint

### 布局 App

`index.html`：可切换 **首页 / 书架** 两 Tab，首页含折线图模块。

## [S3] Out of Scope

- 本轮 go_router/四 Tab Flutter 实现
- WebDav 卡、真实阅读时长埋点
- 书源 homepage modules

## Tasks

- [ ] T1: index.html 首页+书架双 Tab 布局 — acceptance: 首页含续读+折线图；书架为书库网格 (covers: S2)
- [ ] T2: 用户确认首页结构后开 Flutter 实现轮 (covers: S2)
