---
feature: a31-stabilize-and-release
status: delivered
updated: 2026-09-11
branch: master
commits: d0c4179..af4943e
---

# A31 稳定性收尾 + 发版 1.0.4

## Report

**What was built** — ①BOOKS 全局锁「锁纪律」铁律 + 26 处锁点审计清单 + 4 处竞争热点标记（纯注释，审计确认死锁模式仅已修的 batch_locate_notes 一处）；②beginSelection 页尾空选区防御（返回 bool，空区间拒绝建立，调用方复位笔记独占模式）；③onPointerCancel 复位缺口（镜像 _onPointerUp 语义，来电/手势导航打断后手势不再失灵）；④发版 1.0.4+5（CHANGELOG、README 功能清单刷新、ARCHITECTURE 路线图补登 A26–A31）。

**Verification** — `cargo check -p bridge` PASS；`flutter analyze` 34 条既有基线无新增 PASS；`flutter test` 105 全通过 PASS。

**Journey log** — 死锁审计发现全库仅 1 处犯「持锁调分层封装函数」模式，其余 25 处作用域干净——结构性文档约束比逐点重构更划算；`long-press-selection-collapse` spec 中"真根因指向 entry 粒度"的记录已过时（真根因是弹窗行宽挤占，见 d0c4179），该 spec 保留作死因记录。

## [S1] Problem

A31 功能线遗留三类债：死锁模式无结构性约束防回归、选区两处边界缺陷（页尾空选区、指针取消残留）、文档与版本严重滞后（1.0.3 期间大量修复未记档）。

## [S2] Design

- 锁纪律：注释立规 + 审计清单，不动逻辑（审计已证实现有锁点安全）
- 空选区：beginSelection 返回 bool，调用方失败复位
- onPointerCancel：镜像 Up 复位语义，保留选区分支，绝不触发翻页/菜单
- 发版：文档四件套 + 版本号

## [S3] Out of Scope

- 4 处锁竞争热点优化（净化缓存磁盘重建等，已标记待后续）
- 笔记导出/分享、跨章迁移（下阶段候选）

## Tasks

- [x] T1: Rust 锁纪律注释 — acceptance: cargo check 通过 (covers: S2)
- [x] T2: 空选区防御 — acceptance: 页尾长按不产生空选区 (covers: S2)
- [x] T3: onPointerCancel — acceptance: 打断后手势可恢复 (covers: S2)
- [x] T4: 发版文档 — acceptance: CHANGELOG/README/路线图/版本号齐备 (covers: S2)
