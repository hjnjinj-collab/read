# UI 设计笔记（书架壳层）

## 已定准则

- 主色：松绿 seed `#5B6C5A`，`ColorScheme.fromSeed` 主导明暗
- 玻璃：**重模糊 + 高不透明近白/近黑**；primary 只作发丝描边。透太多会把封面色糊成橄榄脏色（多轮反馈根因）
- 顶栏：`topBlurSigma=64`，近白 alpha≈0.82，下渐隐到 0
- 封面：palette 夹紧 L/S；海报顶光亮、底 scrim 轻；圆环进度右下；格式/剩余章徽标
- 动效：stagger 进入、FAB 弹簧、Hero flightShuttle、Zoom 转场

## 用户否定过的方向

- 中性纸色盖掉主题色（要主题色主导）
- 缎带进度（要圆环）
- `SingleTickerProvider` 双 controller
- 玻璃过透 / primaryContainer 混 tint（发脏）
- SliverAppBar.large 把标题压太低

## 下轮可试

- 底栏改更「液态」：更高圆角 + 内侧高光描边
- 封面打开后阅读页顶栏继承 dominant 色
- 书架滚动时顶栏大标题压缩动画
