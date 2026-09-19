# Bug 修复报告：LiquidGlassSwitch reserveSwellRoom 布局占位导致开关视觉不靠右

## 修复日期

2026-09-19

## 问题概述

外观设置页「动态取色」开关距容器右边缘明显大于预期（视觉右边距 ≈ 44.5px），
与左侧文字距边 16px 不对称。用户反馈 3+ 次，期间调整 Row padding、
增删外层 Padding、加 `SizedBox(width: double.infinity)` 均**完全无效**——
因为问题不在这些层级，而在 `LiquidGlassSwitch` 组件自身的布局框。

## 根本原因

`liquid_glass_easy 4.3.1` 的 `LiquidGlassSwitch`：

- 默认（`reserveSwellRoom: false`）布局占位 = 轨道本身 **63×28**；
  拇指膨胀时通过 `OverflowBox` 溢出绘制，不占布局空间。
- `reserveSwellRoom: true` 时（本设置页原跟随 `lgMotionOn` 传入 true），
  占位改为捕获视图全尺寸：`viewWidth = width + padX * 2`。
  默认参数下 `padX = max(0, 42.5 + 58/2 − 63) + overshootRoom 20 = 28.5`，
  即 **占位 120px，可视轨道 63px 居中，两侧各 28.5px 隐形空白**。

Row 将这个 120px 的框靠右放置 → 可视轨道右缘 = 16(padding) + 28.5 = **44.5px**。
这是包的**有意设计**（为裁切祖先预留玻璃膨胀空间），不是渲染错误，
所以在 padding/结构层面怎么调都"代码正确、渲染不变"。

## 解决方案

`settings_chrome.dart` `SettingSwitchRow`：

```dart
LiquidGlassSwitch(
  ...
  reserveSwellRoom: false,  // 布局占位 = 轨道 63×28，右边距精确 16px
)
```

裁切风险评估：`SettingsFrostShell` 有 `ClipRRect(antiAlias)`，但开关距壳边
16px，而按住时玻璃拇指最多超出轨道 8.5px（expandedThumbWidth 58 的一半
29 − 轨道内余量 20.5），仍在壳内 7.5px，不会被裁。仅鼠标按住后超行程拖拽
~72px 以上（橡皮筋 allowance 20px 耗尽前）才可能瞬时触到裁切边。

## 预防

- liquid_glass_easy 的 `reserveSwellRoom`（及同类"预留"参数）语义是
  **布局占位 ≠ 视觉尺寸**：对齐敏感的场景必须用 false + 确认裁切余量，
  而不是靠调外层 padding 补偿。
- 第三方控件类组件排查"对不齐"时，先读包源码确认**布局占位尺寸**，
  再调外层结构；`OverflowBox` 类溢出绘制组件两边距不对称是常见根因。
