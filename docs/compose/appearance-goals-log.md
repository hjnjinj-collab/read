# 外观页目标台账（appearance goals log）

> 范围：外观设置页视觉与主题色体系整条线
> 时间：2026-09-19 起，起点 commit `a85c66e`（设置页玻璃重构）之后
> 相关 spec：
> - `docs/compose/spec/appearance-seed-source.md`
> - `docs/compose/spec/appearance-shell-refinement.md`
> - `docs/compose/spec/appearance-scheme-preview-picker.md`
> 相关 bug 记录：`docs/bugfixes/2026-09-19_LiquidGlassSwitch预留膨胀区致开关不靠右.md`
> + BUGFIX_INDEX 速查行与工程约束第 10 条

## 目标线时间线

### G1 排版对齐与取色器初版 — commit `c083a3f`（fix）

| 项 | 内容 |
|----|------|
| 目标 | 「动态取色」开关右对齐；HSV 取色对话框；分隔线精修；Iconsax 图标统一；标签更名 |
| 关键根因 | `LiquidGlassSwitch reserveSwellRoom: true` 时布局占位 120px vs 可视轨道 63px（右侧 28.5px 隐形空白）——padding/结构调整全部无效的真因 |
| 交付 | `reserveSwellRoom: false` + 裁切余量论证；`_ColorPickerDialog`；分隔线 alpha0.60/0.8；`AppIcons` 扩展；`_EvenWrap` spaceBetween |
| 状态 | ✅ 已验收；bug 报告 + 工程约束第 10 条入库（`6c977f1`） |

### G2 主题色来源互斥 — spec `appearance-seed-source`，commit `27f1500` + 文档 `d4560f2`

| 项 | 内容 |
|----|------|
| 目标 | 任一时刻仅一种主题色来源生效，其余视觉置灰（MD3 disabled 38%）且仍可点击切换 |
| 契约 | `ShellSettings.seedSource`（preset/palette/picker）持久化 + 旧数据按色值命中调色板迁移；`effectiveSeedSource`（dynamicColor 优先）；`applySeed(color, source)` 单次持久化自动关动态取色；预置色改 MD3 ChoiceChip；分隔线 1dp + primary α0.18 |
| 状态 | ✅ 已交付（含动态取色行纳入互斥，`67e79e1` 时点回补） |

### G3 flex_color_scheme 全局色彩引擎 + 壳体间距 — spec `appearance-shell-refinement`，commit `67e79e1` + 文档 `a50e012`

| 项 | 内容 |
|----|------|
| 目标 | 引入 flex_color_scheme 作为主题色生成引擎；外观页壳体四边间距统一协调；动态取色行纳入互斥 |
| 关键约束 | **flex_color_scheme v9 迁移自研 material_ui**（ColorScheme 与 framework 分叉）——锁定 `^8.2.0`（8.4.0）；`FlexColorScheme.light/dark(primary, keyColors: FlexKeyColors())` 与 fromSeed 同源补全 surfaceContainer 角色；dark 传 `primaryLightRef` 消 fixed 色警告 |
| 交付 | AppTheme 引擎替换 + 冒烟测试 `test/app_theme_flex_scheme_test.dart`；标签水平 16；开关行垂直间距统一；明暗分段垫高（后续 G4 撤销——设计语义是复刻导航栏尺寸） |
| 状态 | ✅ 已交付 |

### G4 派生色预览 + FlexColorPicker + 容器尺寸与取色器打磨 — spec `appearance-scheme-preview-picker`，commits `5ffbb56`…`ac817d6`/`b985e0d`

| 轮次 | 目标 | 关键结论 | commit |
|------|------|----------|--------|
| T1-T4 初版 | 64px 统一 / 派生色 8 角色卡 / FlexColorPicker 接入 | 容器高度对齐液态导航栏；来源互斥四区块 | `5ffbb56` |
| T5-T6 真机修正 | 派生色底距 14；取色器 FrostShell 玻璃壳 + 中英色名 + 删顶部复制按钮；霜向渐变跟随用户自定义 | Dialog 透明底 + FrostShell 组合成立（BackdropFilter 采样先行内容） | `5143dc7` `0829b87` |
| T7 打磨 | 分段派生色 thumb；rim 细腻化；按钮右移 | rim 是全局视觉语言 | `fc3964a` |
| T8-T9 明暗分档与圆角 | rim 明暗双档（浅 0.5px α0.32 / 深 0.8px α0.28，`AppGlass.rimWidth` 单点）；描边提前景层修深色圆角缺角 | **Stack 全定位子节点取 constraints.biggest**（Column 无界崩溃/Dialog 撑满）——内容层必须非定位子节点；rim 必须画在模糊层之上 | `4d349c1` `fd070e6` `82cac1f` |
| T10-T12 切换器与去重 | 明暗/网格统一 60；液态玻璃切换器（IndexedStack 三单类型 ColorPicker）；双切换器去重；SettingsRowShell 派生色底衬；自绘 primaryContainer 色码行 | **`pickersEnabled[X] ?? true` 陷阱**：未传的 accent 默认开启 → 包 selector 不隐藏；包内色码 fillColor 写死不可定制 | `8058a1f` `05a11c5` |
| T13-T14 居中与比例 | 面板 Center；切换器 32/5→36/4 pill 28；growHeight 6 恢复鼓动；色码条收缩居中 | 「臃肿」常源于组件体量；瘦身过头失去动效观感——静态比例与动态动效一起定；「居中」分清 Column 对齐 / Wrap 行内 / 容器收缩后再居中 | `ec3c22c` `ac817d6` |
| T15（本轮） | 目标台账沉淀；明暗分段选中 pill 比例优化 + 选中色派生化（可读性） | 见下「进行中」 | 本轮 |

## 工程约束沉淀（跨 spec）

1. `liquid_glass_easy reserveSwellRoom` 布局占位 ≠ 视觉尺寸（BUGFIX_INDEX 约束 10）
2. Stack 分层壳体：内容层非定位、覆盖层 Positioned.fill
3. frost 描边明暗双档 + 层序（rim 在模糊层之上）
4. 第三方包 map 参数 `?? 默认值`陷阱——显式关闭无关键
5. flex_color_scheme 锁 8.x（v9 类型分叉）；液态组件 padding/尺寸先问设计意图

## 当前状态（截至本台账）

- **已收口**：G1 / G2 / G3；G4 的 T1–T16 全部落地且各轮审查 PASS
- **T15–T16 已交付**：
  1. 目标台账落库（本文档）
  2. 明暗分段 pill 比例：padding 10 → pill 40/60 按钮感
  3. 两处切换器选中态派生色：primaryContainer α0.9 / onPrimaryContainer
     ——**glassStyle（玻璃动画态）+ restStyle（动画回落静止态）双层同色**
     （根因：包内静止选中态走 restStyle，未设即默认白色"透明遮罩感"）
  4. shadow cornerRadius 按 pillH/2 派生（20/14）
- **待用户**：`appearance-scheme-preview-picker` 的 T4 真机验收
  （外观线整体视觉确认）
