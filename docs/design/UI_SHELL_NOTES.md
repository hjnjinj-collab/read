# UI 设计笔记（书架壳层）

## 已定准则

- 主色：可切换 seed 预置（松绿默认）；明暗 system/light/dark；动态取色可覆盖
- 页面底：色渗 `pageTintOn` + `pageTintLight/Dark`（整页均匀 primary）；渐变 `ambientOn` + `ambientDir`（tlbr/trbl/top/left… 双息 primary⊕tertiary）。二者独立开关，设置→材质与玻璃可调
- 顶栏控件：`AppGlass.chromeGlass`（secondaryContainer 渗），与底栏 primary 渗区分；静止可读 + 轻描边
- 底栏：默认左 `[书架|书源]` + 右「更多」；点更多后左收成书架圆键、右横向展开 `[设置|添加书籍]`；添加经 `importRequestProvider`；宽度 `AnimatedContainer` 过渡。**禁止 AnimatedSwitcher 同时挂两个 Lens**（Impeller 双 BackdropFilter 闪黑/闪边）——左右槽同一时刻只存在一个玻璃子树
- 设置滑轨：`LiquidGlassSlider` 必须 `height: 56` 钉死，否则抬起 thumb 命中区叠手势
- 玻璃模式切换：Engine 静态开关 + AppShell `Key(glassMode)` 强制重建 Lens，否则要切页才生效
- **含 Lens 的滚动区用 glow，禁用 stretch**（`SettingsGlassScroll`）：M3 默认 stretch 把内容隔离进 `ImageFiltered` subpass，`BackdropFilter` 读不到真实背景 → 液态底层黑闪。见 `liquid_glass_easy` `LiquidGlassLens` 文档
- **设置玻璃策略（性能）**：仅滑轨 `LiquidGlassSlider`、开关 `LiquidGlassSwitch` 用液态；卡体/导航行/分段一律自有 tonal（`SettingsGroup` / `SettingsMd3Segments`）。壳层 chrome（底栏等）可继续液态
- 设置根页 float：`SettingsFrostShell` **与子栏同宽**（无内缩包裹）；外层 Clip→Blur→渐变；子栏全透明 + 发丝分割线。blur 裁剪必须贴合组件轮廓
- 设置内枚举分段：`SettingsMd3Segments`——段间 gap 8；仅首尾段有外侧圆角，中间段直角
- 书架顶栏网格切换：`LiquidGlassSegmented`（src 直引）玻璃选中胶囊滑动外鼓
- 顶栏：全宽渐变模糊（ShaderMask dstIn）+ 雾色 primary 0.52 tint；高度 = status + header 72 + **topBlurExtend 64**，衰减带盖内容顶部、不占布局；背景层 IgnorePointer
- 书架标题：滚动 56px 内 headline→titleLarge，副标题淡出
- Hero 横幅：随滚动，最近阅读前 3 轮换（4s）
- 空态：顶栏下居中，主色描边图标块
- 封面氛围：提取色底部 0.9→0.72（约 30% 区间）上涌；描边用 accent
- 阅读顶栏：继承该书封面 dominant 雾 tint（无色则黑雾）
- 列表 leading：sidecar 提取色 + 底部轻弥漫，与网格同源
- 底部氛围：`bottomAmbientHeight=160`，primary 自下 0.18→0
- 封面：palette 夹紧 L/S；海报顶光亮、底 scrim 轻；圆环进度右下；格式/剩余章徽标
- 动效：stagger 进入、FAB 弹簧、Hero flightShuttle、Zoom 转场

## 用户否定过的方向

- 中性纸色盖掉主题色（要主题色主导）
- 缎带进度（要圆环）
- `SingleTickerProvider` 双 controller
- 玻璃过透 / primaryContainer 混 tint（发脏）
- 半实色玻璃盖在 blur 上（读成两层，不是柔光混合）
- SliverAppBar.large 把标题压太低

## 下轮可试

- 底栏改更「液态」：更高圆角 + 内侧高光描边
- 封面打开后阅读页顶栏继承 dominant 色
- 书架滚动时顶栏大标题压缩动画
