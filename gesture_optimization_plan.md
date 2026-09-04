# 翻页手势与动画优化方案

**日期**: 2026-09-03  
**目标**: 
1. 改进点击手势检测，支持单手操作
2. 优化拖拽手势的阻尼感和跟手性

---

## 问题 1：点击区域检测不利于单手操作

### 当前实现
```dart
// reader_page.dart L196-202
void _handleTapAt(double tapX, double screenWidth) {
  if (tapX < screenWidth * 0.3) {        // 左侧 30% → 上一页
    _composerKey.currentState?.tapTurn(PageDirection.prev);
  } else if (tapX > screenWidth * 0.7) {  // 右侧 30% → 下一页
    _composerKey.currentState?.tapTurn(PageDirection.next);
  } else {                                // 中间 40% → 菜单
    _toggleMenu();
  }
}
```

### 问题
- **区域检测**：只看水平位置，不看垂直位置
- **单手困难**：右手拿手机，大拇指很难够到左侧 30%
- **固定比例**：不考虑用户习惯

### 优化方案 A：方向检测（推荐）

**改为根据拖拽方向判断翻页方向**，而不是点击位置：

```dart
// 拖拽手势判定 (page_turn_gesture.dart L47-51)
final direction = dx > 0
    ? PageDirection.prev // 右滑 = 上一页（无论起点在哪）
    : dx < 0
        ? PageDirection.next // 左滑 = 下一页（无论起点在哪）
        : PageDirection.none;
```

**优点**：
- ✅ 单手友好：右手大拇指可以从屏幕任意位置向右滑动翻上一页
- ✅ 直观自然：左滑下一页，右滑上一页
- ✅ 符合主流阅读器习惯（微信读书、Kindle、iBooks）

**点击行为保留区域检测**：
```dart
void _handleTapAt(double tapX, double tapY, double screenWidth, double screenHeight) {
  // 顶部 15% 或底部 15% → 菜单
  if (tapY < screenHeight * 0.15 || tapY > screenHeight * 0.85) {
    _toggleMenu();
    return;
  }
  
  // 其他区域：左半屏 → 上一页，右半屏 → 下一页
  if (tapX < screenWidth * 0.5) {
    _composerKey.currentState?.tapTurn(PageDirection.prev);
  } else {
    _composerKey.currentState?.tapTurn(PageDirection.next);
  }
}
```

### 优化方案 B：可配置的点击区域

如果保留区域检测，提供设置项：

```dart
class TapRegionMode {
  static const threeRegion = 0;  // 左 30% / 中 40% / 右 30%（当前）
  static const twoRegion = 1;    // 左 50% / 右 50%（简化）
  static const edgeOnly = 2;     // 左 15% / 中 70%（菜单）/ 右 15%
}
```

---

## 问题 2：拖拽手势阻尼感优化

### 当前参数
```dart
// page_turn_gesture.dart
double get turnDistanceRatio => 0.25;        // 需要拖拽屏幕宽度的 25%
double get turnVelocityThreshold => 600.0;   // 或速度 > 600 px/s
double get tapDistanceThreshold => 18.0;     // 距离 < 18px 视为点击
```

### 问题
- **距离阈值 25% 偏高**：在 400px 宽屏幕上需要拖拽 100px
- **速度阈值 600 偏高**：不够灵敏
- **缺少渐进式阻尼**：没有"越拖越费力"的物理感

### 优化方案 A：降低阈值（快速修复）

```dart
class PageTurnGestureConstants {
  const PageTurnGestureConstants();

  /// 拖拽距离超过屏幕宽度此比例时触发翻页
  double get turnDistanceRatio => 0.15;  // 25% → 15%（更灵敏）

  /// 速度超过此阈值时即使距离不够也触发翻页（px/s）
  double get turnVelocityThreshold => 400.0;  // 600 → 400（更容易触发）

  /// 距离小于此值视为点击（px）
  double get tapDistanceThreshold => 18.0;  // 保持不变
  
  /// 竖直位移需超过水平位移的此倍数，才判定为竖向意图
  double get verticalDominanceRatio => 1.5;  // 保持不变
}
```

### 优化方案 B：渐进式阻尼（高级）

在 `page_flip_session.dart` 中添加阻尼曲线：

```dart
// 计算阻尼系数（越接近边缘，阻尼越大）
double _computeDampingFactor(double progress) {
  if (progress < 0.5) {
    return 1.0;  // 前半段：无阻尼
  } else if (progress < 0.8) {
    return 1.0 - (progress - 0.5) * 0.6;  // 0.5-0.8：线性减速到 0.82
  } else {
    return 0.82 - (progress - 0.8) * 2.0;  // 0.8-1.0：快速减速到 0.4
  }
}

// 应用阻尼到触摸偏移
Offset _applyDamping(Offset rawOffset, double screenWidth) {
  final progress = (rawOffset.dx.abs() / screenWidth).clamp(0.0, 1.0);
  final damping = _computeDampingFactor(progress);
  return Offset(rawOffset.dx * damping, rawOffset.dy);
}
```

### 优化方案 C：可配置的灵敏度

添加用户设置：

```dart
enum PageTurnSensitivity {
  low(distanceRatio: 0.30, velocityThreshold: 800.0),
  normal(distanceRatio: 0.20, velocityThreshold: 600.0),
  high(distanceRatio: 0.12, velocityThreshold: 350.0);
  
  const PageTurnSensitivity({
    required this.distanceRatio,
    required this.velocityThreshold,
  });
  
  final double distanceRatio;
  final double velocityThreshold;
}
```

---

## 推荐实施顺序

### 第一阶段：快速修复（30 分钟）
1. ✅ 降低拖拽阈值（方案 2A）
   - `turnDistanceRatio: 0.25 → 0.15`
   - `turnVelocityThreshold: 600 → 400`
2. ✅ 改进点击检测（方案 1A 简化版）
   - 左半屏 → 上一页
   - 右半屏 → 下一页
   - 顶部/底部 15% → 菜单

### 第二阶段：体验优化（1-2 小时）
1. 添加渐进式阻尼（方案 2B）
2. 添加可配置的灵敏度设置（方案 2C）

### 第三阶段：高级功能（可选）
1. 添加点击区域模式选择（方案 1B）
2. 添加自定义手势配置界面

---

## 修改文件清单

### 第一阶段
- `lib/features/reader/presentation/widgets/page_turn/page_turn_gesture.dart` - 调整阈值
- `lib/features/reader/presentation/pages/reader_page.dart` - 改进点击检测

### 第二阶段
- `lib/features/reader/presentation/widgets/page_turn/page_flip_session.dart` - 添加阻尼
- `lib/features/reader/data/models/reader_settings.dart` - 添加灵敏度设置
- `lib/features/reader/presentation/widgets/reader_settings_dialog.dart` - 添加设置 UI

---

## 验证方法

1. **单手操作测试**：
   - 右手拿手机，大拇指从屏幕中间向右滑动 → 应该翻上一页
   - 左手拿手机，大拇指从屏幕中间向左滑动 → 应该翻下一页

2. **阻尼感测试**：
   - 快速滑动 → 应该触发翻页
   - 慢速滑动一半 → 应该回弹
   - 感受拖拽过程中的阻力变化

3. **点击测试**：
   - 左半屏点击 → 上一页
   - 右半屏点击 → 下一页
   - 顶部/底部点击 → 菜单
