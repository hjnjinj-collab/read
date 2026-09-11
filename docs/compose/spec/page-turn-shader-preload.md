---
feature: page-turn-shader-preload
status: delivered
updated: 2026-09-11
branch: master
commits: 657292c..ff90c02
---

# 进书首次翻页强制走仿真（shader 未就绪兜底）

## Report

**What was built** — 三层修复消除「进书首翻强制仿真」：①`_ShaderPrograms` 进程级 FragmentProgram singleflight 缓存（失败驱逐 + identical 保护防并发双重 fromAsset；FragmentShader 实例仍每 composer 创建，dispose 时释放）；②`main()` 启动 fire-and-forget 预热，进书时缓存命中同步完成；③`_startTurnAnimated` 门控按**当前 mode 判所需 shader**（ripple/collapse 各查各的），未就绪有界等待 500ms，仍未就绪才走既有 curl 兜底。

**Verification** — `flutter analyze` 34 条既有基线无新增 PASS；`flutter test` 105 全通过 PASS。独立审查 1 critical（门控「双 null」判据在串行加载半就绪窗口漏过，collapse 模式首翻仍 curl）+ 4 minor；修复后 C1/M1/M3 闭环。

**Journey log** — ①根因不是设置竞态（设置已在 runApp 前同步加载），而是 shader 异步加载 + 绘制层 curl 兜底——排查「首次用默认值」类问题时先分清「数据未就绪」与「渲染资源未就绪」。②串行加载多个资源时，任何「全部为 null」的门控都会在半就绪窗口漏过，应按消费方判所需字段。③Dart 静态 Future singleflight 在无中间 await 的 check→assign 段安全；失败驱逐分支必须加 identical 保护。

## [S1] Problem

每次进入书籍后第一次翻页永远显示默认仿真（curl）动画，之后才切换到用户选中的水波纹/坍塌模式。根因不是设置竞态（设置已在 runApp 前同步加载），而是 `PageTurnComposer.initState` 每次进书都异步 `FragmentProgram.fromAsset` 加载 shader，加载完成前 `_rippleShredderShader/_collapseShader` 为 null，绘制层强制 `_buildCurlTransition()` 兜底。shader 未做全局缓存，每次进书都重新经历这个窗口。

## [S2] Design

三层修复：

1. **FragmentProgram 静态缓存**：`ui.FragmentProgram` 进程级 singleflight 缓存（失败驱逐 + identical 保护）；`fragmentShader()` 实例仍每 composer 创建并在 dispose 释放（uniform 状态不可跨 painter 共享）。
2. **启动预加载**：`main()` 在设置加载后 fire-and-forget 预热两个 program——正常情况下用户进书时缓存已命中。
3. **启动门控等待**：`_startTurnAnimated` 按当前 mode 判所需 shader（ripple 查 `_rippleShredderShader`、collapse 查 `_collapseShader`），未就绪先 await `_loadShaders`（走缓存 Future，500ms 有界），未就绪才允许走既有 curl 兜底。

行为：进书首次翻页即用用户选中模式；极端情况（shader 加载失败）仍回退 curl 不冻结。

## [S3] Out of Scope

- `_holdingFinalFrame` 收尾恒用 CurlPainter 的视觉一致性问题（独立缺陷，未复现用户报告）
- shader 加载失败的上层重试机制

## Tasks

- [x] T1: FragmentProgram 静态缓存 + main 预加载 — acceptance: 二次进书不再触发 fromAsset (covers: S2)
- [x] T2: 启动门控 await shader — acceptance: 首次进书（缓存未命中）首翻也用用户模式或明确等待 (covers: S2)
- [x] T3: 验证 — acceptance: flutter analyze 无新增；既有测试通过 (covers: S1 S2)
