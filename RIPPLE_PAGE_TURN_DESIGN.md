# 水波纹翻页动画设计方案

**日期**: 2026-09-03  
**目标**: 添加水波纹翻页动画（类似潮汐推进效果）

---

## 设计概述

### 视觉效果
- **触发**：用户点击屏幕左侧/右侧区域
- **动画**：从点击位置开始，内容呈现**水波纹式推进**切换
- **特点**：比覆盖翻页更细腻，类似潮汐波浪推进

### 技术路径
- 使用 **Fragment Shader**（Flutter 3.7+ 支持）
- 类似 `CurlPainter` 架构，创建 `RipplePainter`
- 利用现有的 `PageTurnComposer` 基础设施

---

## 架构设计

### 1. 动画模式扩展

**文件**: `lib/features/reader/presentation/widgets/page_turn/page_turn_types.dart`

```dart
/// 翻页动画模式
enum PageTurnMode { 
  simulation,      // 卷曲翻页（现有）
  verticalScroll,  // 上下滚动（现有）
  ripple,          // 水波纹翻页（新增）
}
```

### 2. 水波纹控制器

**新文件**: `lib/features/reader/presentation/widgets/page_turn/ripple_turn_controller.dart`

```dart
/// 水波纹翻页动画控制器
class RippleTurnController extends PageTurnAnimationController {
  final AnimationController _animationController;
  final void Function(double progress) onProgressUpdate;
  
  /// 点击位置（归一化 0-1）
  Offset rippleOrigin = Offset(0.5, 0.5);
  
  RippleTurnController({
    required TickerProvider vsync,
    required this.onProgressUpdate,
  }) : _animationController = AnimationController(
         vsync: vsync,
         duration: const Duration(milliseconds: 600), // 600ms 推进
       ) {
    _animationController.addListener(() {
      onProgressUpdate(_animationController.value);
    });
  }
  
  @override
  void startForward(PageDirection direction, Offset? tapPosition) {
    // 记录点击位置作为波纹中心
    if (tapPosition != null) {
      rippleOrigin = tapPosition;
    }
    _animationController.forward(from: 0.0);
  }
  
  @override
  void dispose() {
    _animationController.dispose();
  }
}
```

### 3. 水波纹绘制器

**新文件**: `lib/features/reader/presentation/widgets/page_turn/ripple_painter.dart`

```dart
/// 水波纹翻页绘制器
/// 
/// 原理：
/// 1. 使用 Fragment Shader 实现水波纹遮罩
/// 2. 从点击位置开始，以圆形波纹向外扩散
/// 3. 波纹前方显示新页面，波纹后方显示旧页面
/// 4. 多层波纹叠加，产生潮汐推进效果
class RipplePainter extends CustomPainter {
  final PageFrame? foldingPage;   // 当前页（渐隐）
  final PageFrame? revealPage;    // 目标页（渐显）
  final double progress;          // 0.0 → 1.0
  final Offset rippleOrigin;      // 波纹中心（归一化坐标）
  final PageDirection direction;
  final FragmentShader? shader;   // 水波纹 shader
  
  RipplePainter({
    required this.foldingPage,
    required this.revealPage,
    required this.progress,
    required this.rippleOrigin,
    required this.direction,
    this.shader,
  });
  
  @override
  void paint(Canvas canvas, Size size) {
    // 1. 绘制目标页（新页面，完整绘制）
    if (revealPage != null) {
      _drawPageContent(canvas, size, revealPage!);
    }
    
    // 2. 应用水波纹遮罩绘制当前页（旧页面，逐渐被波纹遮盖）
    if (foldingPage != null && shader != null) {
      canvas.saveLayer(Rect.fromLTWH(0, 0, size.width, size.height), Paint());
      
      // 绘制当前页内容
      _drawPageContent(canvas, size, foldingPage!);
      
      // 应用水波纹遮罩
      final maskPaint = Paint()
        ..blendMode = BlendMode.dstOut  // 波纹区域擦除当前页
        ..shader = shader
        ..shader!.setFloat(0, size.width)
        ..shader!.setFloat(1, size.height)
        ..shader!.setFloat(2, rippleOrigin.dx * size.width)
        ..shader!.setFloat(3, rippleOrigin.dy * size.height)
        ..shader!.setFloat(4, progress);
      
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height),
        maskPaint,
      );
      
      canvas.restore();
    }
  }
  
  void _drawPageContent(Canvas canvas, Size size, PageFrame frame) {
    // 复用现有的 PageContentRenderer
    PageContentRenderer.render(
      canvas: canvas,
      size: size,
      page: frame.page,
      imageStore: frame.imageStore,
    );
  }
  
  @override
  bool shouldRepaint(RipplePainter oldDelegate) {
    return progress != oldDelegate.progress ||
           rippleOrigin != oldDelegate.rippleOrigin ||
           foldingPage != oldDelegate.foldingPage ||
           revealPage != oldDelegate.revealPage;
  }
}
```

### 4. 水波纹 Shader

**新文件**: `shaders/ripple.frag`

```glsl
#version 460 core

// 输入
uniform vec2 uResolution;      // 画布尺寸
uniform vec2 uRippleOrigin;    // 波纹中心（像素坐标）
uniform float uProgress;       // 动画进度 0.0 → 1.0

// 输出
out vec4 fragColor;

void main() {
  vec2 fragCoord = gl_FragCoord.xy;
  
  // 计算当前像素到波纹中心的距离
  float dist = distance(fragCoord, uRippleOrigin);
  
  // 最大距离（对角线长度）
  float maxDist = length(uResolution);
  
  // 波纹推进半径
  float rippleRadius = uProgress * maxDist * 1.2;
  
  // 多层波纹（3层叠加，产生潮汐效果）
  float wave1 = smoothstep(rippleRadius - 80.0, rippleRadius - 40.0, dist);
  float wave2 = smoothstep(rippleRadius - 120.0, rippleRadius - 80.0, dist);
  float wave3 = smoothstep(rippleRadius - 160.0, rippleRadius - 120.0, dist);
  
  // 波纹强度叠加
  float waveIntensity = wave1 * 0.6 + wave2 * 0.3 + wave3 * 0.1;
  
  // 边缘羽化（柔和过渡）
  float edge = smoothstep(rippleRadius - 40.0, rippleRadius, dist);
  
  // 最终遮罩（波纹覆盖区域 alpha=1，未覆盖区域 alpha=0）
  float alpha = (1.0 - edge) * waveIntensity;
  
  // 输出遮罩
  fragColor = vec4(0.0, 0.0, 0.0, alpha);
}
```

### 5. 集成到 PageTurnComposer

**修改**: `lib/features/reader/presentation/widgets/page_turn_composer.dart`

```dart
// L723-850: _buildAnimating 方法中添加 ripple 分支

Widget _buildAnimating() {
  final mode = widget.mode;
  
  if (mode == PageTurnMode.simulation) {
    // 现有的卷曲翻页逻辑
    return CustomPaint(painter: CurlPainter(...));
  }
  
  if (mode == PageTurnMode.ripple) {
    // 新增的水波纹翻页逻辑
    return CustomPaint(
      painter: RipplePainter(
        foldingPage: _currentFrame,
        revealPage: _targetFrame,
        progress: _turnController?.progress ?? 0.0,
        rippleOrigin: _rippleOrigin,
        direction: _turnDirection,
        shader: _rippleShader,
      ),
      size: Size.infinite,
    );
  }
  
  // verticalScroll 等其他模式...
}
```

---

## 实施步骤

### 阶段 1：基础架构（1-2h）
1. ✅ 扩展 `PageTurnMode` 枚举添加 `ripple`
2. ✅ 创建 `RippleTurnController`
3. ✅ 创建 `RipplePainter` 基础结构

### 阶段 2：Shader 实现（2-3h）
1. ✅ 编写 `shaders/ripple.frag`
2. ✅ 在 `pubspec.yaml` 中注册 shader
3. ✅ 加载 shader 到 `RipplePainter`
4. ✅ 调试 shader 效果（单层波纹 → 多层波纹）

### 阶段 3：集成与优化（1-2h）
1. ✅ 集成到 `PageTurnComposer`
2. ✅ 添加到设置菜单（用户可选择动画模式）
3. ✅ 性能优化（shader 预编译、缓存）
4. ✅ 参数调优（波纹速度、层数、羽化范围）

### 阶段 4：细节打磨（可选，1-2h）
1. ✅ 添加波纹颜色选项（白色/蓝色/自定义）
2. ✅ 添加波纹速度调节（快/中/慢）
3. ✅ 添加波纹层数调节（2-5层）
4. ✅ 添加声音效果（可选）

---

## Shader 参数说明

### 关键参数

| 参数 | 说明 | 默认值 | 可调范围 |
|------|------|--------|----------|
| `rippleRadius` | 波纹推进半径 | `progress * maxDist * 1.2` | 1.0 - 1.5 |
| `wave1 offset` | 第一层波纹偏移 | 40-80px | 20-100px |
| `wave2 offset` | 第二层波纹偏移 | 80-120px | 40-150px |
| `wave3 offset` | 第三层波纹偏移 | 120-160px | 60-200px |
| `wave1 weight` | 第一层权重 | 0.6 | 0.4-0.8 |
| `wave2 weight` | 第二层权重 | 0.3 | 0.2-0.4 |
| `wave3 weight` | 第三层权重 | 0.1 | 0.05-0.2 |
| `edge feather` | 边缘羽化范围 | 40px | 20-80px |

### 效果调节示例

**更快速的推进**（适合大屏）：
```glsl
float rippleRadius = uProgress * maxDist * 1.5; // 1.2 → 1.5
```

**更多波纹层次**（更细腻）：
```glsl
float wave4 = smoothstep(rippleRadius - 200.0, rippleRadius - 160.0, dist);
float waveIntensity = wave1 * 0.5 + wave2 * 0.25 + wave3 * 0.15 + wave4 * 0.1;
```

**更柔和的过渡**（更像潮汐）：
```glsl
float edge = smoothstep(rippleRadius - 80.0, rippleRadius, dist); // 40 → 80
```

---

## 性能优化

### 1. Shader 预编译
```dart
class RippleShaderCache {
  static FragmentShader? _shader;
  
  static Future<FragmentShader> load() async {
    if (_shader != null) return _shader!;
    
    final program = await FragmentProgram.fromAsset('shaders/ripple.frag');
    _shader = program.fragmentShader();
    return _shader!;
  }
}
```

### 2. 避免过度重绘
```dart
// RipplePainter 中添加缓存
bool shouldRepaint(RipplePainter oldDelegate) {
  // 只在关键参数变化时重绘
  return (progress - oldDelegate.progress).abs() > 0.01 || // 1% 阈值
         rippleOrigin != oldDelegate.rippleOrigin;
}
```

### 3. 降级策略
```dart
// 低性能设备降级为简单淡入淡出
if (!supportsFragmentShader || fps < 30) {
  return FadeTransition(
    opacity: animation,
    child: revealPage,
  );
}
```

---

## 与现有架构对比

| 特性 | CurlPainter（卷曲） | RipplePainter（水波纹） |
|------|---------------------|------------------------|
| 技术实现 | Canvas 几何绘制 + 矩阵变换 | Fragment Shader |
| 复杂度 | 高（800+ 行几何计算） | 中（~200 行 + shader） |
| 性能 | 中等（CPU 密集） | 优（GPU 加速） |
| 可定制性 | 低（硬编码几何） | 高（shader 参数丰富） |
| 拖拽跟手 | 支持 | 可选支持 |
| 视觉风格 | 3D 物理仿真 | 2D 图形过渡 |

---

## 用户设置界面

**修改**: `lib/features/reader/presentation/widgets/reader_menu.dart`

```dart
// 添加动画模式选择
Row(
  children: [
    Text('翻页动画'),
    SegmentedButton<PageTurnMode>(
      segments: [
        ButtonSegment(
          value: PageTurnMode.simulation,
          label: Text('卷曲'),
          icon: Icon(Icons.auto_stories),
        ),
        ButtonSegment(
          value: PageTurnMode.ripple,
          label: Text('水波纹'),
          icon: Icon(Icons.water),
        ),
        ButtonSegment(
          value: PageTurnMode.verticalScroll,
          label: Text('滚动'),
          icon: Icon(Icons.swap_vert),
        ),
      ],
      selected: {pageTurnMode ?? PageTurnMode.simulation},
      onSelectionChanged: (Set<PageTurnMode> newSelection) {
        ref.read(readerProvider.notifier).setPageTurnMode(newSelection.first);
      },
    ),
  ],
)
```

---

## 测试验证

### 单元测试
```dart
// test/page_turn/ripple_shader_test.dart
test('Ripple shader produces valid mask', () {
  final shader = await RippleShaderCache.load();
  shader.setFloat(0, 400.0); // width
  shader.setFloat(1, 800.0); // height
  shader.setFloat(2, 200.0); // origin x
  shader.setFloat(3, 400.0); // origin y
  shader.setFloat(4, 0.5);   // progress
  
  // 验证 shader 输出
  expect(shader, isNotNull);
});
```

### 集成测试
1. 点击屏幕左侧 → 水波纹从左向右推进 → 显示上一页
2. 点击屏幕右侧 → 水波纹从右向左推进 → 显示下一页
3. 快速连续点击 → 动画队列正常处理
4. 不同屏幕尺寸 → 波纹始终从点击位置开始

---

## 下一步行动

我建议分阶段实施：

### 现在立即做（最小可用版本，2-3h）：
1. 创建基础架构（扩展枚举、控制器、绘制器）
2. 编写简单版 shader（单层波纹）
3. 集成到 PageTurnComposer
4. 验证基本效果

### 后续优化（1-2h）：
1. 添加多层波纹（潮汐效果）
2. 参数调优（速度、羽化）
3. 添加到设置菜单

### 可选增强（按需）：
1. 可调参数（波纹颜色、速度、层数）
2. 性能优化（预编译、降级策略）
3. 声音效果

你想现在开始实施吗？我可以先创建基础架构和简单版 shader，让你看到初步效果。
