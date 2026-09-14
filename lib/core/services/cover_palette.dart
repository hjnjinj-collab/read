import 'dart:io';

import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

/// 封面取色结果（电影海报用色，全部做过亮/暗夹紧）
@immutable
class CoverColors {
  const CoverColors({
    required this.dominant,
    required this.vibrant,
    required this.dark,
  });

  final Color dominant;
  final Color vibrant;
  final Color dark;

  /// 阴影：中等明度、中等饱和，避免刺眼或脏黑
  Color get shadowColor => CoverPalette.clampMood(dominant);

  /// 海报底部 scrim：偏中亮，避免整卡发闷
  Color get posterScrim => CoverPalette.clampMood(
        Color.lerp(dark, dominant, 0.5)!,
        minL: 0.18,
        maxL: 0.48,
      );

  /// 顶部微光：更亮，氛围能看出来
  Color get posterHighlight => CoverPalette.clampMood(
        Color.lerp(vibrant, Colors.white, 0.35)!,
        minL: 0.62,
        maxL: 0.82,
      );

  /// 缎带/强调（需足够对比，不可过暗）
  Color get accent => CoverPalette.clampMood(
        vibrant,
        minL: 0.42,
        maxL: 0.68,
        minS: 0.35,
      );
}

/// 封面取色 + 色彩夹紧
class CoverPalette {
  CoverPalette._();

  static final Map<String, CoverColors> _cache = {};

  /// 夹紧 HSL：避免过亮/过暗/过艳，保证阴影与 scrim 有氛围又不脏
  static Color clampMood(
    Color source, {
    double minL = 0.22,
    double maxL = 0.62,
    double minS = 0.18,
    double maxS = 0.72,
  }) {
    final hsl = HSLColor.fromColor(source);
    return hsl
        .withLightness(hsl.lightness.clamp(minL, maxL))
        .withSaturation(hsl.saturation.clamp(minS, maxS))
        .toColor();
  }

  static Color spineColorFor(String title) {
    const palette = <Color>[
      Color(0xFF6B5B4F),
      Color(0xFF4A5D4E),
      Color(0xFF3D4F6F),
      Color(0xFF6E4E3E),
      Color(0xFF4F5B62),
      Color(0xFF5C4A6E),
      Color(0xFF3F5F4F),
      Color(0xFF6B4F3A),
    ];
    if (title.isEmpty) return palette.first;
    return palette[title.hashCode.abs() % palette.length];
  }

  static CoverColors synthetic(String title) {
    final base = clampMood(spineColorFor(title));
    final hsl = HSLColor.fromColor(base);
    return CoverColors(
      dominant: base,
      vibrant: clampMood(
        hsl.withLightness((hsl.lightness + 0.1).clamp(0, 1)).toColor(),
        minL: 0.35,
        maxL: 0.7,
      ),
      dark: clampMood(
        hsl.withLightness((hsl.lightness * 0.4).clamp(0, 1)).toColor(),
        minL: 0.12,
        maxL: 0.35,
      ),
    );
  }

  static CoverColors? cached(String path) => _cache[path];

  static Future<CoverColors?> extractFromFile(File file) async {
    final key = file.path;
    final hit = _cache[key];
    if (hit != null) return hit;
    try {
      final generator = await PaletteGenerator.fromImageProvider(
        FileImage(file),
        maximumColorCount: 16,
        size: const Size(100, 150),
      );
      final rawDominant = generator.dominantColor?.color ??
          generator.vibrantColor?.color ??
          generator.mutedColor?.color;
      if (rawDominant == null) return null;
      final rawVibrant = generator.vibrantColor?.color ??
          generator.lightVibrantColor?.color ??
          rawDominant;
      final rawDark = generator.darkMutedColor?.color ??
          generator.darkVibrantColor?.color ??
          Color.lerp(rawDominant, Colors.black, 0.45)!;

      final colors = CoverColors(
        dominant: clampMood(rawDominant),
        vibrant: clampMood(rawVibrant, minL: 0.3, maxL: 0.72),
        dark: clampMood(rawDark, minL: 0.1, maxL: 0.36),
      );
      _cache[key] = colors;
      return colors;
    } catch (e) {
      debugPrint('封面取色失败: $e');
      return null;
    }
  }

  static Color onColor(Color background) {
    return background.computeLuminance() > 0.55
        ? const Color(0xFF1C1B18)
        : const Color(0xFFF7F6F1);
  }
}
