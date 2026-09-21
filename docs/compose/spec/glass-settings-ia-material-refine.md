---
feature: glass-settings-ia-material-refine
status: delivered
updated: 2026-09-19
branch: master
commits: b4b506d..HEAD
---

# 材质与玻璃：IA / 材质参数 / 视觉精修

## Report

**What was built** — 两轮真机反馈 + 组内装饰条澄清。首轮：分区更名+Iconsax、材质效果双套参数（Windows 读写 lite 档）、320ms 展开、关态描边、ambient tertiary。二轮：霜层收展去闪（Fade + Gate AnimatedSwitcher）；「方向」→「渐变方向」；开关/滑杆派生 thumb/track。澄清：装饰条除分栏之间外，**同一分组内相邻参数之间**也用同款 `SettingsDivider`（indent 16），例如材质效果「模糊 ↔ 色渗滤镜」。

**Verification** — `flutter analyze` 25 PRE-EXISTING；触碰文件 No issues；主题测试 2 PASS。自动评审曾超时取消；生命周期/配色/装饰条接线本地复核。待真机验收。

**Journey log** —
- `nav*` 为 getter，持久化在 liquid/lite 四字段
- Windows `useLiteParams` 恒 true
- frostOn 闪帧 = 高度动画与 Gate 同帧硬切 → 双动画对齐
- 包 `thumbColor` 默认白，须显式派生
- 装饰条两层：分栏 indent4 / 组内参数 indent16

## [S1] Problem

材质页 IA/参数/视觉两轮真机问题：分区语义与图标、液态/毛玻璃共用参数、展开生硬、关霜轮廓消失、tertiary 弱、霜层收展一闪、分栏无装饰、方向文案不清、开关/滑杆 thumb 纯白。

## [S2] Design

### 首轮（已交付）

- 标题：渲染材质 / 材质效果 + Iconsax；动画 320ms
- 双套参数 `liquid*`/`lite*`；`useLiteParams = lite || Windows`
- 关态 rim outline+primary；ambient liftB light 0.28 / dark 0.22

### 二轮

**收展去闪** — `expansibleBuilder`：`FadeTransition` 包 body；`SettingsFrostGate` 对 frost/row 壳 `AnimatedSwitcher` 320ms 同曲线。

**分栏装饰** — 非末栏 `_FrostSection` 尾部 `SettingsDivider`（indent 4）。

**组内装饰（真机澄清）** — 同一分组内**相邻参数之间**同款装饰条 `SettingsDivider(indent: 16)`：材质效果「模糊↔色渗滤镜」、页面色渗「浅色底↔深色底」、霜层「方案↔渐变方向↔子栏高度↔渐变深浅↔起点色↔终点色」、渲染材质展开「果冻」前。不在「标题+其控件」中间打断。

**文案** — 氛围/霜层方向标题为「渐变方向」。

**派生控件色**（`AppGlass`）：

| 控件 | 状态 | 轨道 | thumb |
|------|------|------|-------|
| 开关 | ON | `primary` | lerp(primaryContainer, white, 0.35) |
| 开关 | OFF | lerp(surfaceHighest, outline, 0.28) α0.72 | lerp(surface, outlineVariant, 0.22) |
| 滑杆 | — | active primary；inactive outlineVariant α0.45 | lerp(primaryContainer, surface, 0.35) α0.92 |

## [S3] Out of Scope

- 材质参数驱动设置页 Lens；外观页/底栏本体；其他设置页 disclosure

## Tasks

- [x] T1–T6: 首轮 IA/双参数/描边/tertiary/图标/验证
- [x] T7: 收展去闪（Fade + Gate AnimatedSwitcher）(covers: S2 二轮)
- [x] T8: 分栏装饰条 + 渐变方向 (covers: S2 二轮)
- [x] T8b: 组内相邻参数装饰条 — acceptance: 模糊与色渗、色渗展开项、霜层相邻细调之间可见 indent16 装饰条；标题与其控件间不断开 (covers: S2 二轮)
- [x] T9: 开关/滑杆派生色 (covers: S2 二轮)
- [x] T10: 二轮验证 — analyze 基线无新增；主题测试 PASS；契约本地复核 (covers: S2; depends: T7, T9)
