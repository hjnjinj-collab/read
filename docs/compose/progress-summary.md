# 项目进度总结（progress summary）

> 更新：2026-09-27 ｜ 仓库：`D:\android\example\legado_flutter` ｜ 分支：`master`
> 用途：重开会话时先读本文件 +「进度文件清单」。
>
> **Compose Next 恢复**：若续跑 `/compose-next` 而指令不在上下文，先重新加载 `compose-next` skill。

---

## 一、最近主线（摘要）

| 阶段 | 内容 | 状态 |
|------|------|------|
| 阅读菜单 chrome | 顶栏液态圆键 + A 传统 / B 悬浮 + 渐变雾 | **已交付** |
| 设置 sheet 液态 | `LiquidGlassSheet` + `shellFrostLiquidStyle(strength:1)` | **已交付** |
| 设置四页 + Bug 收集 | 形态图标 / 排版 / 背景 / 材质 / **Bug 收集** | **已交付** |
| 排版 IA | 子页签字体·正文·颜色·布局；字重；日/夜文字色 | **已交付** |
| 背景主题 | 日/夜纸色取色、透明度、预设、可命名主题、跟随系统 | **已交付** |
| 字体 | 选择生效、已导入列表、液态弹层 | **已交付** |
| 翻页稳定性 | 资源就绪轮询、看门狗、邻居预热 | **已交付** |
| 日志体系 | 环形缓冲 15min + 分类过滤 + 导出选路径 | **已交付** |
| 字距进 FFI | `LayoutConfig.letter_spacing` 真实折行 + justify 扣字距 | **已交付** |

远端：`origin/master` 落后本地（字距 FFI 本轮待提交/推送）。

---

## 二、已交付要点

### 阅读菜单 / 设置 sheet
- 顶栏：返回/更多默认分开；合并=「返回\|更多」胶囊（默认关）；标题胶囊
- A/B 形态切换：液态胶囊 + 图标 + 按压缩放；分段抬升
- 工具排：`itemsPerRow`/`rowCount` 网格；溢出「更多」
- 图标 Iconsax 三档 + 栏目图标去重；`_GlassSwitchRow` 液态开关
- 设置五页：PageView 450ms 视差 + KeepAlive 防闪 + Tab 连续插值

### 排版
- 子页签：**字体**（字体/字号/字重四档/斜体）· **正文**（间距+段落）· **颜色**（强调）· **布局**
- 字距：进 FFI（`LayoutConfig.letter_spacing`）；判满 `natural+ls×n`；justify 先扣 `ls×n`；MeasureCache 恒自然宽
- 命中测试/选区/脚注与主绘制同口径 `letterGap+userLS`；拖动预览仅绘制，松手重排
- 字体：FontLoader 成功即切换；已导入字体列表；`showShellColorPicker`/`PaperColorPicker` 同源

### 背景 / 主题
- 日/夜独立：纸色 + 文字色（壳层液态取色 + 背景/文字预览）
- 明暗三档：日间 / **自动** / 夜间
- 透明度、6 预设、「我的主题」命名保存（最多 8）

### 翻页 / 日志
- 门控以 `BookImageStore` 实时状态为准；挂起 **120ms 轮询**就绪后播动画
- 邻居帧发布即预热；卡住看门狗 1.2s 强制收场
- Bug 收集页：时间 15s/2min/15min · 分类 阅读/翻页/分页/图片/错误 · 级别 · 导出选路径

---

## 三、下一步计划（优先级）

1. **真机回归**：连翻 EPUB 图多章节——动画是否跟手、是否仍卡 pending
2. **真机回归字距**：调字距后折行/justify 是否正确（本轮已进 FFI，待设备验收）
3. **T2.5 字体 sheet 增强**：系统字体列表、文件网格排序
4. **T1.3 悬浮圆键排**：间距 8、居中、溢出更多（与工具排网格对齐）
5. **spec 收口**：`reader-menu-chrome-ia.md` Tasks 勾选与 Report
6. **性能**：Bug 页/日志写文件在高频 turn 事件下的开销

---

## 四、工程约束（速查，勿再踩）

- Impeller：液态圆键**只准** `shellFrostLiquidStyle`；禁止 `ClipOval/saveLayer`、禁止 `LiquidGlassBatch`
- 阅读页 **blur 强制 0**；sheet 轻模糊仅 `readerSheetBlur*`
- 切页/开合 **禁止 Fade/Opacity 包 LiquidGlass**（只 Slide/Scale）
- 翻页资源：`usableForAnimation` 需 ready/failed；**挂起时轮询**，勿过早直翻
- 噪声事件只压控制台；**文件/环形缓冲全量**（导出可回溯）
- `shellFrostLiquidStyle` 唯一折射；大面板 `strength: 1`
- **字距**：MeasureCache 恒自然宽；判满/justify 才计 `ls`；轻量 setter 须 **await** `_syncParagraphFormat` 再 reload
- `flutter analyze` 基线：约 **20+ PRE-EXISTING** info/warning
- master 主 worktree；**push 仅在用户明确要求时**

---

## 五、进度文件清单（重开会话入口）

| 优先级 | 路径 | 用途 |
|--------|------|------|
| **P0** | `docs/compose/progress-summary.md` | 本文件 |
| **P0** | `docs/compose/spec/reader-menu-chrome-ia.md` | 菜单契约 + T0–T3 |
| **P0** | `docs/compose/spec/letter-spacing-ffi.md` | 字距进 FFI（本轮） |
| **P0** | `docs/compose/spec/gear-capsule-face-and-menu-veil.md` | 齿轮/渐变历史 |
| P1 | `docs/compose/spec/reader-statusbar-immersive-glass.md` | 沉浸 + 液态同源 |
| P1 | `docs/BUGFIX_INDEX.md` | Impeller BF 等 |
| P2 | `docs/design/reader-menu-chrome-proto.html` | 可点原型 |

### 新会话建议开场
1. 读本文件 + `reader-menu-chrome-ia.md`
2. `git log -5 --oneline` + `git status`
3. 按「下一步计划」继续；push 前再确认
