import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import 'app_theme.dart' show AppGlass;

/// 壳层液态圆键/胶囊共用样式（书架顶栏、底栏圆键、阅读 chrome 同源）。
///
/// **唯一实现**：禁止在阅读侧另写一套折射/模糊参数——真机「有液态/没液态」
/// 必须与书架观感一致，只允许改 radius 适配键径。
LiquidGlassStyle shellFrostLiquidStyle(
  ColorScheme scheme, {
  required double navBlur,
  required double navTint,
  double radius = 28,
}) {
  return LiquidGlassStyle(
    shape: LiquidGlassShape.continuousRoundedRectangle(
      cornerRadius: radius,
      borderWidth: 1.0,
      borderColor: Colors.white.withValues(
        alpha: scheme.brightness == Brightness.light ? 0.45 : 0.22,
      ),
      lightIntensity: 1.1,
    ),
    appearance: LiquidGlassAppearance(
      color: AppGlass.navGlass(scheme, strength: navTint),
      blur: LiquidGlassBlur(sigmaX: navBlur, sigmaY: navBlur),
      shadow: LiquidGlassShadow(
        blur: 18,
        opacity: 0.16,
        offset: const Offset(0, 6),
        cornerRadius: radius,
      ),
    ),
    refraction: const LiquidGlassRefraction(
      distortion: 0.1,
      distortionWidth: 28,
      chromaticAberration: 0.002,
    ),
  );
}
