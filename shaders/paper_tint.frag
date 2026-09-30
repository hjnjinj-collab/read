// 图片纸色适配：漫画边缘留白 / PDF 文档重映射
//
// 模式（uMode）：
//   0 = 漫画：只改靠近图边的近白（上下/左右白边），图内白底、高光不动
//   1 = PDF 文档：低色度像素做 亮度→(墨色,纸色) 两端重映射，字迹对比保留
//
// uniform 顺序（Dart setFloat / setImageSampler 同序）：
// 0-3  uRect: left, top, width, height
// 4-7  uPaper: r, g, b, a（0-1）
// 8-11 uInk:   r, g, b, a（正文色；暗色=浅、亮色=深）
// 12   uMode（0/1）
// 13   uStrength（0-1）
// 14   uThreshold（漫画白阈值，默认 0.93）
// 15   uMargin（漫画边缘带宽，UV 半宽，默认 0.14）

#version 460 core

precision mediump float;

#include <flutter/runtime_effect.glsl>

uniform vec4 uRect;
uniform vec4 uPaper;
uniform vec4 uInk;
uniform float uMode;
uniform float uStrength;
uniform float uThreshold;
uniform float uMargin;
uniform sampler2D uTexture;

out vec4 fragColor;

void main() {
  vec2 uv = (FlutterFragCoord().xy - uRect.xy) / uRect.zw;
  if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
    fragColor = uPaper;
    return;
  }
  vec4 c = texture(uTexture, uv);
  float luma = dot(c.rgb, vec3(0.299, 0.587, 0.114));
  float chroma = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));

  if (uMode < 0.5) {
    // 漫画：仅边缘留白
    float edge = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
    float band = 1.0 - smoothstep(uMargin * 0.55, uMargin, edge);
    float white = smoothstep(uThreshold - 0.04, uThreshold, luma)
                * (1.0 - smoothstep(0.05, 0.12, chroma));
    fragColor = vec4(mix(c.rgb, uPaper.rgb, white * band * uStrength), c.a);
  } else {
    // PDF 文档：低色度做墨色↔纸色重映射（保字迹对比）
    float doc = 1.0 - smoothstep(0.10, 0.22, chroma);
    float g = clamp((luma - 0.5) * 1.08 + 0.5, 0.0, 1.0);
    vec3 mapped = mix(uInk.rgb, uPaper.rgb, g);
    fragColor = vec4(mix(c.rgb, mapped, doc * uStrength), c.a);
  }
}
