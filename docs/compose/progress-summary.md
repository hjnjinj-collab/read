# 项目进度总结（progress summary）

> 更新：2026-09-21 ｜ 仓库：`D:\android\example\legado_flutter` ｜ 分支：`master`
> 用途：重开会话时先读本文件 +「进度文件清单」。
>
> **Compose Next 恢复**：若续跑 `/compose-next` 而指令不在上下文，先重新加载 `compose-next` skill。

---

## 一、最近主线（按时间）

| 阶段 | 内容 | 状态 |
|------|------|------|
| 阅读菜单 chrome | 顶栏液态圆键 + A 传统底栏 / B 悬浮工具球 + 渐变雾 | **已 commit**（多轮） |
| Impeller BF 缩放 | 根因：阅读页 BF → 正文缩放；blur0 圆键安全 | **已修** `c84cfa2` |
| 设置 sheet 液态 | `LiquidGlassSheet` + `shellFrostLiquidStyle(strength:1)` | **已 commit** `b3618a7` `25ea5b5` |
| sheet 玻璃体/模糊 | 着色体加厚 + 材质页「轻模糊」开关（仅本弹层） | **已 commit / 开关已接** |
| 菜单图标+动效 | Iconsax 三档 + Slide 开合 + pronounced 按压 | **已 commit** `7f4f515` |
| 设置四页 UI | 玻璃分段/滑轨 + 滑动胶囊 Tab + 字体真实接口 | **已 commit** `7f4f515` |
| 最新 UI 修 | 齿轮液态胶囊 72×44、分段选中对比、排版分区图标 | **已 commit** `7311800` |
| T2.1–T2.4 | 工具排网格 / 字距标题页眉页脚 / 背景主题 / 顶栏胶囊 | **本轮已改，待 commit** |

远端：`origin/master` 落后本地（`7311800` 及更早未推）。  
工作区未提交：工具排网格 + 排版/背景/顶栏接线。

---

## 二、已交付（可重会话直接引用）

### 阅读菜单 / 设置
- `lib/core/theme/reader_menu_icons.dart` — Iconsax 映射 + `ReaderMenuGlyph`（线性/面性/双色）
- `lib/core/theme/shell_glass_style.dart` — `shellFrostLiquidStyle` **唯一**折射配方；`strength` 0 圆键 / 1 sheet 强档
- `lib/features/reader/presentation/widgets/reader_chrome.dart` — 圆键白字液态、5 项工具排、A/B、齿轮 picker、`ReaderMenuFog` 渐变
- `lib/features/reader/presentation/widgets/reader_visual_settings_sheet.dart` — 四页 sheet：玻璃 Tab 胶囊、`_GlassSegmented`/`_GlassTrackSlider`、字体 `FontProvider`
- `lib/features/shell/providers/shell_settings.dart` — `readerIconStyle/ItemsPerRow/RowCount/ShowText`、`readerSheetBlur*`、`readerTopMergeButtons/TitlePill`
- `lib/features/reader/presentation/providers/reader_provider.dart` — 轻量 setter：粗斜体/段距/缩进/对齐/标点/边距 + `setCustomFont`/`resetToBuiltinFont`

### 已本地 commit（未推送）
| SHA | 内容 |
|-----|------|
| `7f4f515` | 图标三档 + 液态动效 + sheet 玻璃控件与参数接线 |
| `25ea5b5` | strength 强档 + 着色体加厚 |
| `b3618a7` | 设置 sheet 接液态玻璃 |
| `baec59a` | Phase 1 形态持久化 + 工具排 |
| `c84cfa2` | Impeller BF 缩放 + 渐变雾 + 齿轮 + 无 BF 滑轨 |

---

## 三、未完成（下一轮优先）

1. **T2.5 字体 sheet**：已接 `FontProvider`；文件网格/系统字体列表可增强
2. **T1.3 悬浮圆键排**：间距 8、居中、第 6 个进更多（网格已共享 perRow/rowCount）
3. **字距 FFI**：绘制层已叠加；LayoutConfig.letter_spacing 仍写死 0，断行未计
4. **T3**：真机验证、spec 收口、push（需用户明确要求）

### 真机反馈修复（2026-09-23）
- 顶栏「更多」恒在右侧；合并=页码+更多右侧胶囊（默认关）
- A/B 形态切换钮：液态胶囊 + 图标 + 按压缩放
- 设置栏目补图标（形态/风格/网格/页眉页脚/背景/材质）
- `_GlassSegmented` 选中抬升过渡 + 可选图标

### 第二轮真机反馈（2026-09-23）
- 顶栏合并恢复「返回|更多」胶囊；页码独立；默认左右分开
- 显示文字标签等开关改 `_GlassSwitchRow`（LiquidGlassSwitch）
- A/B 抬升加强：分段 -3px+scale1.03+影；切换钮按压下沉；A/B 320ms 0.88→1
- 设置四页 PageView 切换 320ms + Tab 连续插值上浮

### 本轮已落地（2026-09-23）
- 工具排网格：`readerIconItemsPerRow/RowCount` 真正切行，溢出进「更多」sheet
- 排版：字距、标题倍率、页眉/页脚显隐、边距滑杆回显
- 背景主题：纸色覆盖 + 透明度 + 6 内置预设 + 预设主题卡 → `PageContentRenderer`
- 顶栏：合并按钮胶囊、标题胶囊（`readerTopMergeButtons/TitlePill`）

---

## 四、工程约束（速查，勿再踩）

- Impeller：液态圆键**只准** `shellFrostLiquidStyle`；禁止 `ClipOval/saveLayer`、禁止 `LiquidGlassBatch`
- 阅读页 **blur 强制 0**（blur≠0 挂 BF → 正文缩放）；sheet 轻模糊仅 `readerSheetBlur*` 可开关
- 液态祖先裁切必须 **`Clip.none`**；切页/开合 **禁止 Fade/Opacity 包 LiquidGlass**（只 Slide/Scale Transform）
- 垫层渐变：`ReaderMenuFog` 固定贴边不随 slide；页码区保浓，其后 fade 到透明
- 图标：Iconsax 三档，白字（选中白 / 未选 white@0.92）；`readerIconStyle` 持久化
- 工具排 **5 项**（设置=更多）；齿轮中心胶囊 **72×44** 与侧槽对齐 + blur0 液态
- `shellFrostLiquidStyle` 是唯一折射配方；大面板 `strength: 1`
- `flutter analyze` 全量基线：**24–25 PRE-EXISTING**（reader/test）
- 真机验收后再 `push`；master 主 worktree，不建 `.worktrees`
- 本地 commit 不推送，除非用户明确要求 push
- 回复 **zh-CN**；用户若说 `/compose-next` 走该工作流

---

## 五、进度文件清单（重开会话入口）

| 优先级 | 路径 | 用途 |
|--------|------|------|
| **P0** | `docs/compose/progress-summary.md` | 本文件 |
| **P0** | `docs/compose/spec/reader-menu-chrome-ia.md` | 菜单契约 + S2.8 图标/动效 + T0–T3 |
| **P0** | `docs/compose/spec/gear-capsule-face-and-menu-veil.md` | 齿轮/渐变历史 |
| P1 | `docs/compose/spec/reader-statusbar-immersive-glass.md` | 沉浸 + 液态同源 |
| P1 | `docs/BUGFIX_INDEX.md` | Impeller BF 缩放等 bug |
| P2 | `docs/design/reader-menu-chrome-proto.html` | 可点原型 |

### 新会话建议开场
1. 读本文件 + `reader-menu-chrome-ia.md` §S2.8 / Tasks  
2. `git log -5 --oneline` + `git status`  
3. 优先：commit 工作区 → 工具排网格/顶栏视觉/背景接线 → 真机 → push 需用户点头
