// 水波纹翻页 Fragment Shader
// 2026-09-03 v3: 渐变遮罩推进效果（无内容重叠）
//
// 原理：
// 1. 从屏幕右边缘开始，一条渐变遮罩从右向左扫过
// 2. 遮罩值：0.0 = 显示新页面，1.0 = 显示旧页面
// 3. 波浪效果：遮罩边缘有柔和的起伏
// 4. 任何时刻任何位置只显示一页内容（不重叠）

#version 460 core

precision mediump float;

#include <flutter/runtime_effect.glsl>

// 输入（由 Dart 端设置）
uniform vec2 uResolution;      // 画布尺寸（宽, 高）
uniform float uProgress;       // 动画进度 0.0 → 1.0
uniform float uDirection;      // 推进方向：1.0=从左向右（下一页），-1.0=从右向左（上一页）

// 输出：遮罩值 0-1
out vec4 fragColor;

void main() {
  vec2 fragCoord = FlutterFragCoord().xy;
  
  // 根据方向计算当前像素的 x 位置
  // next (1.0): 从左向右推进，x = fragCoord.x
  // prev (-1.0): 从右向左推进，x = width - fragCoord.x
  float x = (uDirection > 0.0) ? fragCoord.x : (uResolution.x - fragCoord.x);
  
  // 推进位置（像素）
  float pushPosition = uProgress * uResolution.x;
  
  // === 波浪边缘效果 ===
  // 在推进边缘添加柔和的波浪起伏
  float frequency = 2.5;   // 波浪频率（2.5 个周期）
  float amplitude = 20.0;  // 波浪振幅（20px）
  
  // 计算波浪偏移（基于 y 坐标）
  float waveOffset = sin((fragCoord.y / uResolution.y) * frequency * 6.28318) * amplitude;
  
  // 推进边界（带波浪偏移）
  float boundary = pushPosition + waveOffset;
  
  // === 渐变遮罩 ===
  // smoothstep 产生柔和过渡（50px 渐变宽度）
  float mask = smoothstep(boundary - 50.0, boundary, x);
  
  // mask = 0.0: 显示新页面（波浪已推进过）
  // mask = 1.0: 显示旧页面（波浪未推进）
  
  // 输出遮罩值（灰度）
  fragColor = vec4(mask, mask, mask, 1.0);
}
