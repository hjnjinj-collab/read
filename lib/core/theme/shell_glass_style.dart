import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import 'app_theme.dart' show AppGlass;

/// 壳层液态圆键/胶囊共用样式（书架顶栏、底栏圆键、阅读 chrome、设置 sheet 同源）。
///
/// **唯一实现**：禁止在阅读侧另写一套折射/模糊参数——真机「有液态/没液态」
/// 必须与书架观感一致，只允许改 radius 适配键径，以及 [strength] 选档。
///
/// [strength] 0–1 玻璃强度档（仍只此一处配方）：
/// - `0`（默认）圆键现档：轻折射 + 细描边 + 轻透着色，贴近小键径
/// - `1` 大面板/sheet 强档：重折射带 + 光学描边 + **加厚滤镜着色体**
///   （压住底下正文，避免 sheet 中心过透）
///
/// Impeller：阅读页调用方必须 `navBlur: 0`（blur≠0 挂 BF → 正文缩放）。
/// 加厚靠 tint alpha / saturation，**禁止**用模糊冒充滤镜。
LiquidGlassStyle shellFrostLiquidStyle(
  ColorScheme scheme, {
  required double navBlur,
  required double navTint,
  double radius = 28,
  double strength = 0,
}) {
  final s = strength.clamp(0.0, 1.0);
  double mix(double key, double panel) => key + (panel - key) * s;

  // 圆键档 → 面板强档（只在本函数内插值，禁止调用方另写折射）
  final lightIntensity = mix(1.1, 1.35);
  final distortion = mix(0.1, 0.18);
  final distortionWidth = mix(28, 56);
  final ca = mix(0.002, 0.005);
  final magnification = mix(1.0, 1.03);
  final borderAlpha =
      mix(scheme.brightness == Brightness.light ? 0.45 : 0.22,
          scheme.brightness == Brightness.light ? 0.55 : 0.32);
  final borderSaturation = mix(1.0, 1.3);
  final ambientIntensity = mix(1.0, 1.25);
  final borderSolidity = mix(0.0, 0.4);
  final lightSpread = mix(0.5, 0.65);
  // 面板（底贴屏）影向上；圆键影向下
  final shadowDy = mix(6, -4);
  final shadowBlur = mix(18, 24);
  final shadowOpacity = mix(0.16, 0.22);

  // 滤镜着色体：圆键轻透；sheet 强档向 surface 收并抬 alpha，
  // 让中心也有“玻璃体”而不是一层膜（折射只在边缘带，压不住正文）。
  final baseTint = AppGlass.navGlass(scheme, strength: navTint);
  final bodyTint = Color.lerp(baseTint, scheme.surface, 0.22 * s)!
      .withValues(alpha: (baseTint.a + 0.30 * s).clamp(0.0, 0.84));

  return LiquidGlassStyle(
    shape: LiquidGlassShape.continuousRoundedRectangle(
      cornerRadius: radius,
      borderWidth: 1.0,
      borderColor: Colors.white.withValues(alpha: borderAlpha),
      lightIntensity: lightIntensity,
      lightDirection: mix(0, 39),
      borderType: OpticalBorder(
        borderSaturation: borderSaturation,
        ambientIntensity: ambientIntensity,
        borderSolidity: borderSolidity,
        lightSpread: lightSpread,
      ),
    ),
    appearance: LiquidGlassAppearance(
      color: bodyTint,
      // 面板略提饱和：透上来的正文色更“滤过”，不像裸字
      saturation: mix(1.0, 1.14),
      blur: LiquidGlassBlur(sigmaX: navBlur, sigmaY: navBlur),
      // 中心保持填色（false=内区也有 tint；true 会中心镂空）
      enableInnerRadiusTransparent: false,
      shadow: LiquidGlassShadow(
        blur: shadowBlur,
        opacity: shadowOpacity,
        offset: Offset(0, shadowDy),
        cornerRadius: radius,
      ),
    ),
    refraction: LiquidGlassRefraction(
      distortion: distortion,
      distortionWidth: distortionWidth,
      magnification: magnification,
      chromaticAberration: ca,
    ),
  );
}
