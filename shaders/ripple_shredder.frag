// 水波纹翻页粉碎效果 Fragment Shader
// 2026-09-03 v16.9.8: 双波分界线 + 大幅随机旋转崩解（移除余波高光）
//
// 架构：
//   层1: 新页整页（painter 实时矢量直绘，含纸色底）
//   层2: 本 shader 全屏绘制旧页方块层
//
// 核心语义：
// 1. 方块恒不透明，崩解 = 缩放到 0（无半透明混合 → 零重叠）
// 2. 崩解严格发生在分界线的新页侧；jitter 恒减法（只推迟、不提前）
// 3. 双波叠加分界线 + 每页随机 seed（波形不规则化）
// 4. v16.9.8 崩解动态增强：大幅随机旋转（0.8~2.4 rad，每块独立）
//    + 滑移 45px——纸色底修复后无重叠风险，幅度可以放开
// 5. v16.10：移除描边/内阴影，改为方向性阴影（底重顶轻，光从上方）
//    + 阴影颜色可配置（uShadowColor）
// 6. 半纹素中心对齐采样；两段式崩解（0→0.6 完整，0.6→1.0 快速碎掉）

#version 460 core

precision mediump float;

#include <flutter/runtime_effect.glsl>

// 输入（由 Dart 端设置，索引按声明顺序）
uniform vec2 uResolution;       // 0/1: 画布尺寸（宽, 高）
uniform float uProgress;        // 2: 动画进度 0.0 → 1.0（控制波浪相位）
uniform float uBlockSize;       // 3: 方块大小（像素）
uniform float uDirection;       // 4: 翻页方向：1.0=next, -1.0=prev
uniform float uBoundaryX;       // 5: 波浪线基准 x（屏幕坐标）
uniform float uWaveAmp;         // 6: 波浪振幅（px）
uniform float uWaveLength;      // 7: 波浪波长（px）
uniform float uSeed;            // 8: 每页随机种子（波形不规则化）
uniform vec3 uShadowColor;      // 9/10/11: 阴影颜色（rgb，可配置）
uniform sampler2D uPageTexture; // sampler 0: 旧页面纹理

// 输出
out vec4 fragColor;

// 常量
const float SWEEP_RANGE = 3.0;        // 崩解带宽度（方块宽的倍数）
const float SLIDE_DISTANCE = 45.0;    // 崩解块向新页侧滑移距离（px，v16.9.9: 30→45）

// Hash 函数（用于方块随机化）
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

  // === v16.9.7 双波叠加分界线（不规则化 + 每页随机 seed）===
  // 主波：长波长，随 progress 正向流动
  float w1 = sin(blockCenter.y / uWaveLength * 6.2831
                 + uProgress * 9.4248 + uSeed) * uWaveAmp;
  // 次波：短波长（0.53×），反向流动，振幅 35% → 叠加后行间形状不重复
  float w2 = sin(blockCenter.y / (uWaveLength * 0.53) * 6.2831
                 - uProgress * 6.2831 + uSeed * 1.7) * uWaveAmp * 0.35;
  float rowBoundary = uBoundaryX + w1 + w2;

  // === sweep：波浪线扫过方块的程度 ===
  // 线处=0（完整），新页侧递增崩解，旧页侧恒 0（完整方块）
  // 上限 1.2：崩解完成后多余量（无余波高光，直接透明露新页）
  // jitter 恒减法（只推迟、不提前）
  float h0 = hash(col, row);
  float sweep = clamp(uDirection * (blockCenter.x - rowBoundary)
                      / (blockSize * SWEEP_RANGE) - h0 * 0.15, 0.0, 1.2);

  // === 两段式缩放崩解（恒不透明）===
  // sweep 0→0.6: 保持完整（scale=1）；0.6→1.0: 快速崩解（scale 1→0）
  float collapse = clamp((sweep - 0.6) / 0.4, 0.0, 1.0);
  float scale = 1.0 - collapse;
  if (scale <= 0.02) {
    // 已崩解完 → 透明露新页（无余波高光——暗黑模式下白色提亮刺眼，v16.9.8 移除）
    fragColor = vec4(0.0);
    return;
  }

  // === v16.9.9 崩解动态增强（用户确认滑移+旋转是视觉关键，幅度再增大）===
  float rotDir = hash(col, row + 7.0) - 0.5;          // -0.5 ~ 0.5 方向
  float rotAmp = 1.2 + hash(col, row + 11.0) * 2.0;   // 1.2 ~ 3.2 rad 幅度随机（v16.9.9 增大）
  float slide = uDirection * collapse * SLIDE_DISTANCE;
  float rotation = collapse * rotDir * 2.0 * rotAmp;
  vec2 dispCenter = blockCenter + vec2(slide, 0.0);

  // 像素相对显示中心偏移；缩小块之外 → 透明露新页（无混合）
  vec2 halfSize = vec2(blockSize * 0.5 * scale);
  vec2 delta = fragCoord - dispCenter;
  if (abs(delta.x) > halfSize.x || abs(delta.y) > halfSize.y) {
    fragColor = vec4(0.0);
    return;
  }

  // === 采样（半纹素中心对齐）===
  // 逆向旋转 + 逆向缩放 → 源坐标（内容随块一起运动）
  float cosR = cos(-rotation);
  float sinR = sin(-rotation);
  vec2 rotated = vec2(delta.x * cosR - delta.y * sinR,
                      delta.x * sinR + delta.y * cosR);
  vec2 srcPos = blockCenter + rotated / scale;
  vec2 uv = (floor(srcPos) + 0.5) / uResolution;

  // 恒不透明采样（无 alpha 淡出）
  vec4 color = texture(uPageTexture, uv);

  // === v16.10 方向性阴影塑造立体感（替代描边/内阴影）===
  // 光源假设在上方：底边阴影重（范围 ×1.8）、顶边轻（×0.5）、左右居中（×1.0）
  // 阴影 = 颜色向 uShadowColor 渐变（可配置色，非简单压暗 → 深浅主题都自然）
  float dxE = halfSize.x - abs(delta.x);
  float dyRaw = halfSize.y - delta.y;  // 顶缘→底缘单调递增（顶 0 → 底 2*half）
  // 顶半区 (delta.y<0)：权重 0.5 → 阴影范围窄；下半区：权重 1.8 → 阴影范围宽
  float edgeDistY = delta.y < 0.0 ? dyRaw / 0.5 : dyRaw / 1.8;
  float distToEdge = min(dxE, edgeDistY);

  // 8px 渐变阴影带（无硬边线 → 无"描边感"，纯阴影立体感）
  float shadowBand = 1.0 - smoothstep(0.0, 8.0, distToEdge);
  color.rgb = mix(color.rgb, uShadowColor, shadowBand * 0.55);

  // 视觉边缘 0.5px 抗锯齿
  if (distToEdge < 0.5) {
    color.a *= smoothstep(0.0, 0.5, distToEdge);
  }

  // 视觉边缘 0.5px 抗锯齿
  if (distToEdge < 0.5) {
    color.a *= smoothstep(0.0, 0.5, distToEdge);
  }

  fragColor = color;
}
