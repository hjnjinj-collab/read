# UI 设计笔记（书架壳层）

## 已定准则

- 主色：松绿 seed `#5B6C5A`，`ColorScheme.fromSeed` 主导明暗
- 玻璃底栏：`surface↔primaryContainer` 混合 **alpha 0.5** + blur 48 + 主色描边/光晕
- 顶栏：悬浮圆角轻雾面板（参考系统设置），blur 56 + 近白 alpha 0.7 + 白描边
- 封面氛围：**提取色自底部弥漫上涌**（dominant 0.95 → 中部厚 → 顶消散），黑压仅 0.22 保字
- 底部氛围：`bottomAmbientHeight=160`，primary 自下 0.18→0
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
