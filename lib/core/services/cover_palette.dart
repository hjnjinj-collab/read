import 'dart:io';

import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

/// 封面取色结果（电影海报用色）
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

  /// 阴影色：略提饱和的 dominant
  Color get shadowColor => HSLColor.fromColor(dominant)
      .withSaturation(
        (HSLColor.fromColor(dominant).saturation * 1.15).clamp(0.0, 1.0),
      )
      .toColor();

  /// 海报底部 scrim 用色（暗部偏向 dominant）
  Color get posterScrim => Color.lerp(dark, dominant, 0.35)!;

  /// 顶部微光（海报高光）
  Color get posterHighlight => Color.lerp(vibrant, Colors.white, 0.25)!;

  /// 缎带/强调
  Color get accent => vibrant;
}

/// 封面取色 + 无封面书脊色
class CoverPalette {
  CoverPalette._();

  static final Map<String, CoverColors> _cache = {};

  /// 无封面时按书名哈希取「书脊色」
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

  /// 无封面时的伪 CoverColors
  static CoverColors synthetic(String title) {
    final base = spineColorFor(title);
    final hsl = HSLColor.fromColor(base);
    return CoverColors(
      dominant: base,
      vibrant: hsl.withLightness((hsl.lightness + 0.08).clamp(0, 1)).toColor(),
      dark: hsl.withLightness((hsl.lightness * 0.35).clamp(0, 1)).toColor(),
    );
  }

  static CoverColors? cached(String path) => _cache[path];

  /// 从封面提取 dominant / vibrant / darkMuted
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
      final dominant = generator.dominantColor?.color ??
          generator.vibrantColor?.color ??
          generator.mutedColor?.color;
      if (dominant == null) return null;
      final vibrant = generator.vibrantColor?.color ??
          generator.lightVibrantColor?.color ??
          dominant;
      final dark = generator.darkMutedColor?.color ??
          generator.darkVibrantColor?.color ??
          Color.lerp(dominant, Colors.black, 0.45)!;
      final colors = CoverColors(
        dominant: dominant,
        vibrant: vibrant,
        dark: dark,
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
