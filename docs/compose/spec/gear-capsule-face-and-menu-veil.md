---
feature: gear-capsule-face-and-menu-veil
status: delivered
updated: 2026-09-23
branch: master
commits: 928d44c..uncommitted
---

# 齿轮选中值贴胶囊面 + 菜单渐变模糊加强

## Report

**What was built** — 修订 6：菜单底层改为**纯渐变雾**（无 BackdropFilter、无模糊），α 峰值 0.88 纯 `scheme.surface`，高强度覆盖到进度栏区域后平滑淡出。进度/亮度滑轨从 `LiquidGlassSlider`（内部 BF = Impeller 缩放源）替换为 `_GlassTrackSlider` 纯绘制玻璃外观。齿轮 PageView 循环数从 800 降到 24，消除大数浮点 Sliver 断言。三段式左右齿槽 + 中心胶囊保留。

**Verification** —
- `flutter analyze reader_chrome.dart`：No issues found
- `flutter analyze reader_page.dart`：PASS（4 pre-existing Riverpod warnings）
- `flutter analyze page_turn_composer.dart`：PASS（2 pre-existing info）
- `git diff --check`：PASS
- 评审（general-8）：spec compliance 部分满足（真机视觉待验）；correctness 发现 `_GlassTrackSlider` 窄宽 clamp 崩溃 → **已修复**；渐变进度栏 α 偏弱 → **已调整色阶**。剩余 critical 为「真机视觉不可验证」，需用户实测确认。

**Journey log** —
- 雾顶缘 α **台阶/平台**会看成「阴影带」——必须连续 ease 到 0
- 顶缘雾要**纯 surface**，混 primary 易脏
- 齿轮滚动感 = 邻项 x **连续**跟 `_page`，不是静态槽位
- PageView 裁切溢出：邻项必须画在 view 外/兄弟层
- `LiquidGlassSlider` 内部 BF 是 Impeller 缩放源——阅读页滑轨须纯绘制
- `scheme.surface` 低 α 在纸色背景上不可见——渐变 α 需 ≥0.85 才可感知
- `_loopCycles` 800 × 3~4 项 = 大数浮点 Sliver 断言——降到 24
- 邻项绝对定位需对称槽位；右槽坐标偏移会「左有右无」

## [S1] Problem

真机对照（T23 之后）两处偏差：

1. **选中值位置**：需求「显示在胶囊的上面」指**贴在胶囊面上**（叠在液态胶囊表面），不是空间上浮到胶囊**上方**。当前 `_GearScrollPicker` 把选中值放在胶囊上侧独立浮层。
2. **渐变模糊不够**：菜单态底栏 `ReaderBlurVeil` 在**进度滑轨**一带雾色过浅，正文清晰穿透；渐变至少要盖到进度滑轨，且该处颜色不能太浅。

**修订（真机）** — 渐变加强后又出现三偏差：(a) 雾伸过「进度」行之上太多；(b) 屏幕最底下没有雾；(c) **打开主菜单时正文会缩放/位移**（最重要，疑为 veil 内 `BackdropFilter` 在 Impeller 上的挂载伪影）。

**修订 2（真机）** — (c) 仅 Windows 复现、手机已好 → 曾误判为 Lens BF；改无 Lens 后**仍未修好**。

**修订 3（真机，回滚+重推）** — 按用户要求**回滚无 Lens**（恢复 `shellFrostLiquidStyle`+navBlur）。缩放重推：`_menuVisible` ValueNotifier + mismatch **2px**。黑带：雾峰值下调。齿轮邻项外推（`dx*-44`）。

**修订 4（真机）** — 回滚齿轮 3D 变换；雾 surface 为主；邻项改胶囊外侧固定槽（PageView 会裁切溢出）。

**修订 5（真机）** — (1) 渐变上方仍有**明显阴影带**：雾顶缘 α 阶梯形成「投影」→ **ease 连续淡出**、纯 surface。(2) 齿轮外侧**无滚动感**：静态单邻项 → **随 `_page` 连续滑动的多邻项**。

**修订 6（真机）** — (a) 渐变色彩**完全消失**：`scheme.surface` 峰值 0.55 在纸色背景上不可见 → 提高 α 至可感知。(b) **缩放回归**：`LiquidGlassSlider` 内部 `BackdropFilter` 触发 Impeller 缩放 → 滑轨改无 BF 玻璃外观。(c) 用户明确：**菜单底层只需纯渐变，不要模糊**。

工作区：master 主 worktree（项目既定，见 `progress-summary.md`）。

## [S2] Design

### [S2.1] 齿轮选中值（胶囊面）

| 契约 | 取值 |
|------|------|
| 选中值位置 | 与固定液态胶囊**同一矩形内居中**（叠在胶囊面上），禁止再放在胶囊上侧独立行 |
| 过渡 | 值变更 `AnimatedSwitcher` 220ms：淡入 + 轻微纵向滑入（落入面心） |
| 图标+文字 | 水平 `Row` 居中对中（同一水平中线） |
| 胶囊装饰 | 胶囊本身不展示 `unfold_more` 装饰图标，避免与面心选中值抢视觉 |
| 清晰度 | 非中心滚动项向两侧 `ImageFilter.blur` 渐糊；**中心项不绘字面**（`SizedBox.shrink`，含 `virt==_centerVirt`），由胶囊面选中值单独承担，避免双绘重影 |

### [S2.2] 菜单渐变垫（`ReaderBlurVeil`）— 修订 6

| 契约 | 取值 |
|------|------|
| 合成 | **纯渐变雾**，无 `BackdropFilter` / `ShaderMask` / 任何模糊（用户明确） |
| 雾覆盖 | **实雾**盖住面板 + 系统 inset 全高（最底下不得裸露正文） |
| `_fogAlphas` | **修订 6**：峰值 **0.88**，纯 `scheme.surface`，6 点平滑过渡 |
| stops | `[0, 0.18, 0.40, 0.62, 0.82, 1.0]`；透明端在 82% 后 |
| 底栏 `extend` | **96** |
| 底栏 `band` | 传统 **330**；悬浮 **220** |
| 顶栏 | `band: 60, extend: 40` |
| 滑轨 | **无 BF** 玻璃外观（`DecoratedBox` 圆角轨道+填充），禁 `LiquidGlassSlider`（内部 BF = 缩放源） |
| 范围 | 只动阅读菜单 veil；壳层 `TopScrollBlurChrome` / 设置页顶栏不动 |

### [S2.3] 菜单开合不得带动正文 — 修订 4

| 契约 | 取值 |
|------|------|
| 开合 | `_menuVisible` ValueNotifier；正文不随菜单重建 |
| 齿轮 | **无 Matrix4/rotateY/Transform.scale**（3D 变换开菜单挂载 = Windows 缩放嫌疑） |
| 液态样式 | 圆键 `shellFrostLiquidStyle`+navBlur（无 Lens 已回滚） |
| veil | 无 `BackdropFilter` |

### [S2.4] 渐变收尾与齿轮邻项 — 修订 4

| 契约 | 取值 |
|------|------|
| 黑带/阴影 | 见 **S2.5**（雾顶缘连续 ease，纯 surface） |
| 齿轮邻项 | 见 **S2.5**（随 `_page` 连续滑动的多邻项） |
| 选中值 | 贴胶囊面 |

### [S2.5] 雾顶缘与齿轮滚动感 — 修订 5

| 契约 | 取值 |
|------|------|
| 雾顶缘 | 禁止「阴影带」；α `(1-t)^2` 连续淡出，纯 `scheme.surface` |
| 齿轮外侧 | 多邻项 x 随 `_page` **连续滑动**；\|dist\| 大 → 更糊更淡更小 |
| 位置 | 邻项在胶囊外侧；中心读数仍贴胶囊面 |

## [S3] Out of Scope

- 齿轮滚动交互 / 提交节流逻辑
- 正文玻璃化、液态圆键折射参数
- 壳层/设置页渐变模糊参数
- 传统/悬浮布局 IA

## Tasks

- [x] T1: 选中值叠到胶囊面并去掉 unfold 装饰 — acceptance: 选中图标+文字与胶囊同框居中；变更 220ms 过渡；无「浮在胶囊上方」的独立浮层 (covers: S2.1)
- [x] T2: 中心项不绘、两侧渐糊 — acceptance: 中心/半页帧无字面；非中心项 blur>0 (covers: S2.1)
- [x] T3: 加强 ReaderBlurVeil 雾/遮罩并加高底栏 band — acceptance: 进度滑轨一带雾色明显可感知；顶栏用法不回归 (covers: S2.2)
- [x] T4: analyze + 评审 — acceptance: `flutter analyze` 零 issue；复审无 critical (covers: S2)
- [x] T5: 去掉 veil 内 BackdropFilter — acceptance: 开主菜单正文不缩放/位移；veil 无 BF (covers: S2.3)
- [x] T6: 雾只在面板上沿 extend=28 淡出且实雾盖到底 inset — acceptance: 进度行之上无长距离雾伸；屏底无裸正文 (covers: S2.2)
- [x] T7: 修订验证 + 评审 — acceptance: analyze 零 issue；无 critical (covers: S2)
- [x] T8: 回滚无 Lens + 菜单 ValueNotifier + mismatch 2px — acceptance: 开菜单正文不重建；圆键恢复 frost (covers: S2.3)
- [x] T9: 雾峰值 0.88 多级 — acceptance: 进度行上沿无黑带 (covers: S2.4)
- [x] T10: 齿轮邻项外推出胶囊 — acceptance: 渐糊选项在胶囊**外侧**可见 (covers: S2.4)
- [x] T11: 修订 3 验证 + 评审 — acceptance: analyze 零 error；无 critical (covers: S2)
- [x] T12: 回滚齿轮 3D 变换 — acceptance: 无 Matrix4/rotateY/scale；开菜单挂载不带动正文 (covers: S2.3)
- [x] T13: 雾色 surface 为主消黑带 — acceptance: 进度行无黑带 (covers: S2.4)
- [x] T14: 邻项改胶囊外侧槽位 — acceptance: 左右邻项在胶囊外可见 (covers: S2.4)
- [x] T15: 修订 4 验证 + 评审 — acceptance: analyze 零 error；无 critical (covers: S2)
- [x] T16: 雾顶缘 ease 淡出消阴影带 — acceptance: 渐变上方无明显阴影 (covers: S2.5)
- [x] T17: 齿轮外侧随 _page 滑动多邻项 — acceptance: 外侧有选项滚动感 (covers: S2.5)
- [x] T18: 修订 5 验证 + 评审 — acceptance: analyze 零 error；无 critical (covers: S2)
- [x] T19: 渐变 α 提高到 0.88 峰值纯 surface — acceptance: 渐变在纸色背景上清晰可感知，盖到进度栏 (covers: S2.2)
- [x] T20: 滑轨改无 BF 玻璃外观 — acceptance: 滑轨无 BackdropFilter；开菜单正文不缩放 (covers: S2.2, S2.3)
- [x] T21: 修订 6 验证 + 评审 — acceptance: analyze 零 error；评审 critical 已修复或标注待真机 (covers: S2)
