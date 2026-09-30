// 图片纸色适配：近白像素 → 阅读器纸色（不整图染色）
// 暗色主题下漫画白边 / PDF 纸白不再刺眼；线稿与彩块尽量保留。
//
// uniform 顺序（Dart setFloat / setImageSampler 同序）：
// 0-3  uRect: left, top, width, height（设备像素，用于算 UV）
// 4-7  uPaper: r, g, b, a（0-1）
// 8    uThreshold（默认 0.90）
// 9    uStrength（0-1，默认 1）

#version 460 core

precision mediump float;

#include <flutter/runtime_effect.glsl>

uniform vec4 uRect;
uniform vec4 uPaper;
uniform float uThreshold;
uniform float uStrength;
uniform sampler2D uTexture;

out vec4 fragColor;

void main() {
  vec2 uv = (FlutterFragCoord().xy - uRect.xy) / uRect.zw;
  // 防越界采样垃圾
  if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
    fragColor = uPaper;
    return;
  }
  vec4 c = texture(uTexture, uv);
  float luma = dot(c.rgb, vec3(0.299, 0.587, 0.114));
  // 近白 → 纸色；阈值以下保留原色
  float t = smoothstep(uThreshold - 0.08, uThreshold, luma) * uStrength;
  fragColor = vec4(mix(c.rgb, uPaper.rgb, t), c.a);
}
