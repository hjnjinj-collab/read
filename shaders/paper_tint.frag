// 图片纸色适配 v3：整行/整列白 → 空白边
//
// 用户算法：检测每一行白色像素占比；整行连续近白 = 还不是画面，整行改纸色。
// 图内有内容的行（哪怕行里有白块）一律不动。列同理（左右白边）。
//
// uMode:
//   0 = 漫画空白边（行/列白占比）
//   1 = PDF 文档（低色度 亮度→墨色/纸色，保字迹）
//
// uniform 顺序（Dart setFloat / setImageSampler 同序）：
// 0-3  uRect
// 4-7  uPaper
// 8-11 uInk
// 12   uMode
// 13   uStrength
// 14   uThreshold（近白亮度，默认 0.90）
// 15   uBlankRatio（行/列白占比阈值，默认 0.97）

#version 460 core

precision mediump float;

#include <flutter/runtime_effect.glsl>

uniform vec4 uRect;
uniform vec4 uPaper;
uniform vec4 uInk;
uniform float uMode;
uniform float uStrength;
uniform float uThreshold;
uniform float uBlankRatio;
uniform sampler2D uTexture;

out vec4 fragColor;

bool isNearWhite(vec3 rgb) {
  float luma = dot(rgb, vec3(0.299, 0.587, 0.114));
  float chroma = max(rgb.r, max(rgb.g, rgb.b)) - min(rgb.r, min(rgb.g, rgb.b));
  return luma >= uThreshold && chroma <= 0.10;
}

void main() {
  vec2 uv = (FlutterFragCoord().xy - uRect.xy) / uRect.zw;
  if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
    fragColor = uPaper;
    return;
  }
  vec4 c = texture(uTexture, uv);

  if (uMode < 0.5) {
    // ── 漫画：整行/整列近白 = 空白边 ──
    // 沿行采 16 点、沿列采 16 点，统计近白占比
    float rowWhite = 0.0;
    float colWhite = 0.0;
    for (int i = 0; i < 16; i++) {
      float t = (float(i) + 0.5) / 16.0;
      if (isNearWhite(texture(uTexture, vec2(t, uv.y)).rgb)) rowWhite += 1.0;
      if (isNearWhite(texture(uTexture, vec2(uv.x, t)).rgb)) colWhite += 1.0;
    }
    rowWhite /= 16.0;
    colWhite /= 16.0;
    // 整行白 或 整列白 → 本像素视为空白边，改纸色
    // uPaper.a<1（风景底）时保留透明，让阅读底图透出
    float blank = max(step(uBlankRatio, rowWhite), step(uBlankRatio, colWhite)) * uStrength;
    vec3 rgb = mix(c.rgb, uPaper.rgb, blank);
    float a = mix(c.a, uPaper.a, blank);
    fragColor = vec4(rgb, a);
  } else {
    // ── PDF：低色度做墨色↔纸色重映射 + 暗部墨迹加深 ──
    // 原图整页拉伸后笔画易断：暗部再压向 ink，补笔画缺口
    float luma = dot(c.rgb, vec3(0.299, 0.587, 0.114));
    float chroma = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
    float doc = 1.0 - smoothstep(0.10, 0.22, chroma);
    float g = clamp((luma - 0.5) * 1.08 + 0.5, 0.0, 1.0);
    // inkPush：luma 越低越贴墨色（smoothstep 0.05→0.42）
    float inkPush = (1.0 - smoothstep(0.05, 0.42, luma)) * uStrength * 0.45;
    g = clamp(g - inkPush, 0.0, 1.0);
    vec3 mapped = mix(uInk.rgb, uPaper.rgb, g);
    // 纸侧透明度跟随 uPaper.a（风景底时 <1，透出阅读背景）
    float mappedA = mix(1.0, uPaper.a, g);
    float k = doc * uStrength;
    fragColor = vec4(mix(c.rgb, mapped, k), mix(c.a, mappedA, k));
  }
}
