/// M9.4 翻页动画类型定义
///
/// 首期模式：仿真卷曲 / 上下滚动；覆盖 / 平移 / 无动画 留作二期扩展位
/// （对齐 legado PageDelegate 家族：Simulation/Scroll/Cover/Slide/NoAnim）。

/// 翻页方向
enum PageDirection { none, prev, next }

/// 翻页动画模式
enum PageTurnMode { simulation, verticalScroll }

/// 翻页请求结果（供动画层区分「成功提交」与「到边界回弹」）
enum PageTurnResult { success, atStart, atEnd, failed }
