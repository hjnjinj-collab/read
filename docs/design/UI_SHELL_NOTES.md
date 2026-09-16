# UI 设计笔记（书架壳层）

## 已定准则

- 主色：可切换 seed 预置（松绿默认）；明暗 system/light/dark；动态取色可覆盖
- 底栏：默认左 `[书架|书源]` + 右「更多」；点更多后左收成书架圆键、右横向展开 `[设置|添加书籍]`；添加经 `importRequestProvider`；宽度过渡，不叠 Morph
- 设置滑轨：`LiquidGlassSlider` 必须 `height: 56` 钉死，否则抬起 thumb 命中区叠手势
- 玻璃模式切换：Engine 静态开关 + AppShell `Key(glassMode)` 强制重建 Lens，否则要切页才生效
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
