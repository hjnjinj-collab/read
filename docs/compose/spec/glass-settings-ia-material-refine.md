---
feature: glass-settings-ia-material-refine
status: delivered
updated: 2026-09-19
branch: master
commits: b4b506d..HEAD
---

# 材质与玻璃：IA / 材质参数 / 视觉精修

## Report

**What was built** — 真机六项反馈落地：分区标题改为「渲染材质 / 材质效果」等并加 Iconsax 图标；材质效果模糊/色渗改为 **liquid / lite 双套持久化**（Windows 强制读写 lite 档，与 `applyGlassEngine` 同源）；`SettingDependents` 动画 320ms + easeInOut；霜层关态描边改 outline+primary、宽 1.0；`ShellAmbient` tertiary 抬升到 light 0.28 / dark 0.22。兼容 getter `navBlurSigma`/`navTintStrength` 保留，底栏与 appearance/hub 无调用方断裂。

**Verification** — `flutter analyze`：25 PRE-EXISTING；触碰 7 文件 No issues；`app_theme_flex_scheme_test` 2 PASS。评审 Spec/Correctness/Consistency 无 CRITICAL。

**Journey log** —
- `nav*` 已是 getter，真相字段是 liquid/lite 四元组
- Windows 上 `useLiteParams` 恒 true，liquid 档仅非 Windows 生效
- 关态 rim：`floatRowRim`+`floatRowRimWidth`；开态霜壳仍 `rimWidth`
- 旧 `navBlurSigma` encode 仍写当前生效值，便于回滚

## [S1] Problem

真机验收（条件展开后）暴露六类问题：

1. 展开/收起动画不够细腻——设置页霜层最突出。
2. 「模式」标题语义含糊，无图标。
3. 「底栏」名不副实——模糊/色渗是渲染材质参数；液态与毛玻璃不能共用。
4. 霜层关态轮廓在浅色下几乎不可见。
5. 氛围渐变 tertiary 几乎读不出。
6. 分区图标体系不齐。

## [S2] Design

### 1. 展开动画

`SettingDependents` 默认：duration **320ms**，curve `easeOutCubic`，reverseCurve `easeInOutCubic`。`maintainState: true`；禁 BoxShadow。

### 2/6. 分区标题 + Iconsax

header = `Icon(16, primary) + 8 + Text(labelLarge primary)`。

| 标题 | AppIcons |
|------|----------|
| 渲染材质 | `glass_1` |
| 材质效果 | `magicpen` |
| 页面色渗 | `drop` |
| 页底渐变 | `routing` |
| 设置页霜层 | `cloud` |
| 说明 | `info_circle` |

### 3. 材质效果双套参数

字段：`liquidBlurSigma` / `liquidTintStrength` / `liteBlurSigma` / `liteTintStrength`（默认各 12 / 0.38）。

- `useLiteParams = liteGlass || Platform.isWindows`
- getter `navBlurSigma`/`navTintStrength` → 生效档
- setter 只写生效档
- 迁移：新键缺失用旧 `nav*` 播种两套；encode 保留旧键=生效值
- UI subtitle 标明「液态玻璃参数」或「毛玻璃参数（Windows 强制）」
- 滑杆 `ValueKey` 含 useLiteParams，切档重挂

### 4. 霜层关态轮廓

- light `floatRowRim` = lerp(outlineVariant, primary, 0.12) α0.55
- dark = white α0.40
- `floatRowRimWidth` = 1.0
- `floatRowFill` light α0.22
- 开态 FrostShell 仍用 `rimWidth` 0.5/0.8

### 5. 氛围 tertiary

liftA light 0.14 / dark 0.10；liftB light **0.28** / dark **0.22**；stops `[0, 0.40, 1]`。

## [S3] Out of Scope

- 材质参数驱动设置页控件 Lens（仅底栏 chrome）
- 外观页分段器、hub Windows 摘要、其他设置页图标/disclosure

## Tasks

- [x] T1: SettingDependents 动画 320ms — acceptance: 大组展开收起更平滑 (covers: S2.1)
- [x] T2: 分区更名 + 图标 — acceptance: 渲染材质/材质效果；六分区有图标 (covers: S2.2, S2.6)
- [x] T3: 双字段材质参数 — acceptance: liquid/lite 分档；Windows 写 lite；迁移不丢 (covers: S2.3)
- [x] T4: 关态描边 — acceptance: 浅色关霜轮廓可辨 (covers: S2.4)
- [x] T5: ambient tertiary — acceptance: 末端可见 tertiary (covers: S2.5)
- [x] T6: 验证 — acceptance: analyze 基线无新增；主题测试 PASS (covers: S2; depends: T3)
