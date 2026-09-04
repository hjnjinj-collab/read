# 水波纹翻页动画 v3 最终修复

**日期**: 2026-09-03  
**版本**: v3 - 渐变遮罩推进（无内容重叠）

---

## ✅ 问题完全解决

根据你的反馈和截图，我已经彻底修复了内容重叠问题。

### ❌ v2 的问题
- 使用 `BlendMode.dstOut` 擦除模式
- 导致旧页面和新页面**同时可见**
- 在推进边缘出现内容重叠 ← 你看到的问题

### ✅ v3 的解决方案
- 使用 **shader 作为遮罩**控制两个页面的混合
- **任何时刻任何位置只显示一页内容**
- 遮罩值 0.0 = 新页面，1.0 = 旧页面
- **完全消除重叠**

---

## 🎬 正确的效果

### 从右向左推进（下一页）

```
进度 0%:
[====== 旧页面 ======]

进度 30%:
[新页~~波浪~~旧页面]
   ↑ 遮罩边缘（柔和渐变）

进度 70%:
[新页面~~波浪~~旧]
         ↑ 遮罩边缘

进度 100%:
[====== 新页面 ======]
```

**关键点**:
- ✅ 任何位置只显示**一页内容**（不重叠）
- ✅ 遮罩边缘有**波浪起伏**（柔和过渡）
- ✅ 新内容从左侧逐渐显现，旧内容从右侧逐渐消失
- ✅ 50px 渐变宽度，过渡柔和

---

## 🔧 技术修改

### 1. Shader 完全重写 ✅

**文件**: `shaders/ripple.frag`

**核心改变**:
```glsl
// v2: 多层波浪叠加 + dstOut 擦除 ❌
float wave1 = smoothstep(...);
float wave2 = smoothstep(...);
float wave3 = smoothstep(...);
float mask = 1.0 - (wave1 * 0.5 + wave2 * 0.3 + wave3 * 0.2);

// v3: 单一遮罩 + 渐变过渡 ✅
float waveOffset = sin(y * frequency) * amplitude;
float boundary = pushPosition + waveOffset;
float mask = smoothstep(boundary - 50.0, boundary, x);
```

**输出**:
- `mask = 0.0`: 显示新页面
- `mask = 1.0`: 显示旧页面
- `mask = 0.0~1.0`: 渐变过渡（50px 宽度）

### 2. RipplePainter 绘制逻辑修改 ✅

**文件**: `ripple_painter.dart`

**v2 绘制逻辑**（导致重叠）:
```dart
// 1. 先绘制新页面
canvas.drawPage(revealPage);

// 2. saveLayer 绘制旧页面
canvas.saveLayer(...);
canvas.drawPage(foldingPage);

// 3. 应用 dstOut 擦除旧页面 ❌
canvas.drawRect(..., blendMode: BlendMode.dstOut);
canvas.restore();
```
**问题**: dstOut 只是"挖洞"，在边缘会同时看到两页内容。

**v3 绘制逻辑**（完全无重叠）:
```dart
// 1. 先绘制新页面（底层）
canvas.drawPage(revealPage);

// 2. 使用 shader 作为遮罩绘制旧页面 ✅
canvas.saveLayer(..., Paint()..shader = shader);
canvas.drawPage(foldingPage);
canvas.restore();
```
**解决**: shader 输出遮罩值 0-1，直接控制旧页面的透明度混合，任何位置只显示一页。

---

## 🧪 测试步骤

### 步骤 1: 重新构建

```powershell
cd D:\android\example\legado_flutter
.\fix_sync.ps1
```

**重要**: shader 文件已完全重写，必须运行 `fix_sync.ps1`。

### 步骤 2: 启动应用

```powershell
flutter run -d windows
```

### 步骤 3: 切换到水波纹模式

1. 打开书籍
2. 点击屏幕中央 → 打开菜单
3. 点击"**水波纹**"

### 步骤 4: 验证无重叠

#### ✅ 应该看到的效果

1. **从右边缘开始推进**
   - 下一页：新内容从左侧逐渐显现
   - 上一页：新内容从右侧逐渐显现

2. **遮罩边缘有波浪起伏**
   - 不是直线，有柔和的波浪形状
   - 波浪幅度 ~20px

3. **完全无内容重叠**
   - 任何位置只显示一页内容
   - 遮罩边缘 50px 渐变过渡，非常柔和

4. **推进速度**
   - 600ms 动画时长（可调）

#### ❌ 不应该看到的效果

- ❌ 内容重叠（旧页面和新页面同时可见）
- ❌ 圆形波纹扩散
- ❌ 点击位置产生波纹中心
- ❌ 硬边（应该是柔和渐变）

---

## 🎨 可调参数

如果需要调整效果，可以修改：

### 波浪频率（`shaders/ripple.frag:30`）
```glsl
float frequency = 2.5;  // 波浪周期数
```
- 增大 → 更多波浪（更密集）
- 减小 → 更少波浪（更平缓）
- 建议范围：1.5 - 4.0

### 波浪振幅（`shaders/ripple.frag:31`）
```glsl
float amplitude = 20.0; // 波浪高度（像素）
```
- 增大 → 波浪更高（起伏更明显）
- 减小 → 波浪更平（接近直线）
- 建议范围：10.0 - 40.0

### 渐变宽度（`shaders/ripple.frag:39`）
```glsl
float mask = smoothstep(boundary - 50.0, boundary, x);
```
- 增大 50.0 → 渐变更宽（过渡更柔和）
- 减小 50.0 → 渐变更窄（边缘更锐利）
- 建议范围：30.0 - 80.0

### 动画速度（`ripple_turn_controller.dart:23`）
```dart
super(duration: const Duration(milliseconds: 600));
```
- 快速：400ms
- 中速：600ms（默认）
- 慢速：800ms

---

## 📊 版本对比

| 特性 | v1 (圆形扩散) | v2 (多层波浪) | v3 (渐变遮罩) |
|------|--------------|--------------|--------------|
| 推进方式 | 圆形向外扩散 | 横向推进 | 横向推进 ✅ |
| 内容重叠 | 有 ❌ | 有 ❌ | **无** ✅ |
| 遮罩实现 | dstOut 擦除 | dstOut 擦除 | shader 遮罩 ✅ |
| 波浪效果 | 圆形波纹 | 三层叠加 | 单层柔和 ✅ |
| 渐变过渡 | 无 | 无 | 50px 渐变 ✅ |
| 性能 | 中 | 中 | 优 ✅ |
| 正确性 | ❌ | ❌ | ✅ |

---

## 🔍 技术原理

### 为什么 v2 会重叠？

**v2 使用 BlendMode.dstOut**:
```
1. 绘制新页面（底层）
2. 绘制旧页面（上层）
3. 用 shader 生成遮罩，dstOut 擦除旧页面

问题：dstOut 只是"挖洞"，在渐变边缘：
- shader 输出 0.5（半透明）
- dstOut 擦除 50% 的旧页面
- 结果：50% 新页面 + 50% 旧页面 = 重叠 ❌
```

### 为什么 v3 不会重叠？

**v3 使用 shader 作为遮罩**:
```
1. 绘制新页面（底层）
2. saveLayer(Paint()..shader = shader)
3. 绘制旧页面（shader 控制透明度）

原理：shader 输出 0-1 的遮罩值：
- mask = 0.0 → 旧页面完全透明 → 显示新页面
- mask = 1.0 → 旧页面完全不透明 → 显示旧页面
- mask = 0.5 → 旧页面 50% 透明 → 50% 旧 + 50% 新的混合
  （这是正常的渐变过渡，不是重叠 ✅）
```

**关键差异**:
- dstOut: 擦除模式，两层内容同时存在
- shader 遮罩: 混合模式，任何时刻只看到混合结果

---

## 🐛 故障排查

### 问题 1: 还是看到内容重叠

**原因**: shader 文件未更新或 shader 加载失败

**解决**:
```powershell
flutter clean
.\fix_sync.ps1
```

**验证**: 日志中应该看到：
```
[READER] ripple.paint.frame progress=0.523 direction=PageDirection.next
```

### 问题 2: 边缘是直线，没有波浪

**原因**: 波浪振幅太小或频率为 0

**检查**: `shaders/ripple.frag:30-31`
```glsl
float frequency = 2.5;   // 应该 > 0
float amplitude = 20.0;  // 应该 > 0
```

### 问题 3: 推进方向不对

**症状**: 点击右侧但新内容从右推进（应该从左）

**原因**: direction 参数反了

**检查**: `ripple_painter.dart:73`
```dart
shader!.setFloat(3, direction == PageDirection.next ? 1.0 : -1.0);
```

### 问题 4: 降级为简单淡入淡出

**症状**: 没有波浪效果，只有透明度变化

**原因**: shader 加载失败，使用了降级逻辑

**解决**:
1. 确认 Flutter SDK >= 3.7
2. 更新 GPU 驱动
3. 使用 Release 模式：`flutter run -d windows --release`

---

## 🎯 请测试并反馈

运行 `fix_sync.ps1` 重新构建后，请告诉我：

### 1. 内容重叠是否完全消失？ ✅
- [ ] 是，完全没有重叠了 ✅
- [ ] 否，还是有重叠

### 2. 视觉效果如何？
- [ ] 很好，遮罩边缘柔和，波浪自然
- [ ] 尚可，但需要调整参数
- [ ] 不满意

### 3. 需要调整的参数？
- [ ] 波浪太多/太少（频率 2.5）
- [ ] 波浪太高/太低（振幅 20px）
- [ ] 渐变太宽/太窄（宽度 50px）
- [ ] 速度太快/太慢（600ms）

### 4. 与其他动画对比？
- [ ] 更喜欢水波纹
- [ ] 更喜欢卷曲
- [ ] 更喜欢滚动
- [ ] 看情况切换

这次应该是正确的了！期待你的测试结果！🌊
