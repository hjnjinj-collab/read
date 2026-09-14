---
feature: bookshelf-perf-covers
status: designed
updated: 2026-09-13
branch: master
commits: 
---

# 书架性能与封面持久化

## Report

## [S1] Problem

1. 重启后书架卡顿（封面取色/解码、列表全量刷新）
2. 切 Tab 回来封面偶发重刷
3. 阅读返回后首本未及时变成「最近阅读」，无反馈动画
4. 封面只在打开书时写入 `systemTemp`，重启后常丢，需再点开才有封面

## [S2] Design

- 封面缓存目录：`getApplicationSupportDirectory()/legado_covers`（跨启动稳定）；启动时若 systemTemp 有旧文件则迁移
- 路由：`StatefulShellRoute.indexedStack`，书架/书源/设置状态保留
- 列表：`ValueKey(filePath)` 复用卡片 State；返回阅读只 `_refresh` 不闪 loading；进度并行拉取
- 卡片：stagger 仅书架会话首帧；`Image.file` 限制 `cacheWidth`；首本最近阅读做短暂高亮反馈
- 打开书时 `touchLastRead` 已有；返回后刷新排序

## [S3] Out of Scope

- 在线书源、阅读器性能、封面手动更换

## Tasks

- [ ] T1: 封面目录迁到 app support + 启动迁移 — acceptance: 重启不点开仍有封面 (covers: S2)
- [ ] T2: StatefulShellRoute 保活三 Tab — acceptance: 切走再回书架不重建/不闪封面 (covers: S2; depends: T1)
- [ ] T3: 列表刷新与卡片复用 — acceptance: 返回阅读排序正确、无全屏 loading (covers: S2; depends: T2)
- [ ] T4: 首本高亮 + 减少解码/取色压力 — acceptance: 返回有反馈；热重启不明显掉帧 (covers: S2; depends: T3)
- [ ] T5: analyze 0 error — acceptance: shell/ffi analyze 过 (covers: S2; depends: T1–T4)
