// 方块坍塌溶解翻页 Fragment Shader（collapse dissolve）
// 2026-09-04 M1: 以点击位置为引力中心的径向坍塌方案
//
// 架构（与水波纹 v16.10 两层架构同源）：
//   层1: 新页整页（painter 实时矢量直绘，含纸色底）
//   层2: 本 shader 全屏绘制旧页方块层
//
// 核心语义：
// 1. 方块恒不透明，坍塌 = 缩放到 0（无半透明混合 → 零重叠）
// 2. 径向波前时序：距点击点近的方块先坍塌，波前向外环形扩散
//    （近→远，用户定音 2026-09-04）
// 3. 坍塌块向心滑移（被吸向点击点，区别于水波纹的横向滑移）+ 大幅随机旋转
// 4. jitter 恒减法（只推迟、不提前）——沿用 2026-09-03 报告结论
// 5. 方向性阴影（底重顶轻）+ 可配置阴影色（对齐 v16.10）
// 6. 半纹素中心对齐采样；单块坍塌窗口内线性缩放（对齐水波纹手感）

#version 460 core

precision mediump float;

#include <flutter/runtime_effect.glsl>

// 输入（由 Dart 端设置，索引按声明顺序）
uniform vec2 uResolution;       // 0/1: 画布尺寸（宽, 高）
uniform float uProgress;        // 2: 动画进度 0.0 → 1.0
uniform float uBlockSize;       // 3: 方块大小（像素）
uniform vec2 uCenter;           // 4/5: 坍塌中心（点击点，屏幕逻辑坐标）
uniform float uSeed;            // 6: 每页随机种子（波次抖动不规则化）
uniform vec3 uShadowColor;      // 7/8/9: 阴影颜色（rgb，可配置）
uniform float uSlideDistance;   // 10: 向心滑移距离（px，用户可调）
uniform sampler2D uPageTexture; // sampler 0: 旧页面纹理

// 输出
out vec4 fragColor;

// 常量
const float COLLAPSE_FRAC = 0.45;    // 单块坍塌窗口（0.45=波前扫 55% + 每块塌 45%，观感更从容）
const float JITTER_DELAY = 0.12;     // 波次抖动幅度（恒减法：只推迟坍塌）

// Hash 函数（用于方块随机化，与水波纹同源）
float hash(float col, float row) {
  return fract(sin(col * 73.0 + row * 131.0) * 43758.5453);
}

void main() {
  vec2 fragCoord = FlutterFragCoord().xy;

  // === 方块网格（全屏）===
  float blockSize = uBlockSize;
  float col = floor(fragCoord.x / blockSize);
  float row = floor(fragCoord.y / blockSize);
  vec2 blockCenter = vec2(col * blockSize + blockSize * 0.5,
                          row * blockSize + blockSize * 0.5);

  // === 径向波前时序（近点击点先塌，向外扩散）===
  // maxD = 中心到四角的最大距离（按屏幕几何归一化，四角同时收尾）
  float maxD = max(max(distance(uCenter, vec2(0.0, 0.0)),
                       distance(uCenter, vec2(uResolution.x, 0.0))),
                   max(distance(uCenter, vec2(0.0, uResolution.y)),
                       distance(uCenter, uResolution)));
  float dNorm = clamp(distance(blockCenter, uCenter) / maxD, 0.0, 1.0);

  // 波前到达时刻：dNorm=0 → 立即开始；dNorm=1 → 在 (1-COLLAPSE_FRAC) 时刻开始，
  // 恰在 progress=1.0 时完成（全屏同时收尾，无拖沓尾段）
  float startAt = dNorm * (1.0 - COLLAPSE_FRAC);

  // jitter 恒减法（对进度做减法 = 只推迟、不提前，防旧页侧抢跑）
  float h0 = hash(col, row);
  float local = (uProgress - startAt - h0 * JITTER_DELAY) / COLLAPSE_FRAC;
  float collapse = clamp(local, 0.0, 1.0);

  // === 缩放崩解（恒不透明，对齐水波纹 v16.10）===
  float scale = 1.0 - collapse;
  if (scale <= 0.02) {
    // 已坍塌完 → 透明露新页（无余波高光）
    fragColor = vec4(0.0);
    return;
  }

  // === 坍塌动态：向心滑移 + 大幅随机旋转（幅度对齐水波纹 v16.9.9）===
  float rotDir = hash(col, row + 7.0) - 0.5;          // -0.5 ~ 0.5 方向
  float rotAmp = 1.2 + hash(col, row + 11.0) * 2.0;   // 1.2 ~ 3.2 rad 幅度随机
  // 向心方向（坍塌块被吸向点击点）；d 极小时退化为不滑移
  vec2 toCenter = uCenter - blockCenter;
  float d = length(toCenter);
  vec2 slideDir = d > 1.0 ? toCenter / d : vec2(0.0);
  vec2 dispCenter = blockCenter + slideDir * collapse * uSlideDistance;
  float rotation = collapse * rotDir * 2.0 * rotAmp;

  // 像素相对显示中心偏移；缩小块之外 → 透明露新页（无混合）
  vec2 halfSize = vec2(blockSize * 0.5 * scale);
  vec2 delta = fragCoord - dispCenter;
  if (abs(delta.x) > halfSize.x || abs(delta.y) > halfSize.y) {
    fragColor = vec4(0.0);
    return;
  }

  // === 采样（半纹素中心对齐，与水波纹同源）===
  // 逆向旋转 + 逆向缩放 → 源坐标（内容随块一起运动）
  float cosR = cos(-rotation);
  float sinR = sin(-rotation);
  vec2 rotated = vec2(delta.x * cosR - delta.y * sinR,
                      delta.x * sinR + delta.y * cosR);
  vec2 srcPos = blockCenter + rotated / scale;
  vec2 uv = (floor(srcPos) + 0.5) / uResolution;

  // 恒不透明采样（无 alpha 淡出）
  vec4 color = texture(uPageTexture, uv);

  // === 方向性阴影塑造立体感（对齐水波纹 v16.10：底重顶轻，颜色可配置）===
  float dxE = halfSize.x - abs(delta.x);
  float dyRaw = halfSize.y - delta.y;
  float edgeDistY = delta.y < 0.0 ? dyRaw / 0.5 : dyRaw / 1.8;
  float distToEdge = min(dxE, edgeDistY);

  float shadowBand = 1.0 - smoothstep(0.0, 8.0, distToEdge);
  color.rgb = mix(color.rgb, uShadowColor, shadowBand * 0.55);

  // 视觉边缘 0.5px 抗锯齿
  if (distToEdge < 0.5) {
    color.a *= smoothstep(0.0, 0.5, distToEdge);
  }

  fragColor = color;
}
