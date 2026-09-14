import 'dart:io';

import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

/// 封面取色：为无封面书生成书脊色，为有封面书提供主色点缀。
class CoverPalette {
  CoverPalette._();

  static final Map<String, Color> _cache = {};

  /// 无封面时按书名哈希取「书脊色」（纸/布/皮革感，非灰块）
  static Color spineColorFor(String title) {
    const palette = <Color>[
      Color(0xFF6B5B4F), // 栗棕
      Color(0xFF4A5D4E), // 松绿
      Color(0xFF3D4F6F), // 靛青
      Color(0xFF6E4E3E), // 赭石
      Color(0xFF4F5B62), // 石板
      Color(0xFF5C4A6E), // 茄紫
      Color(0xFF3F5F4F), // 竹绿
      Color(0xFF6B4F3A), // 胡桃
    ];
    if (title.isEmpty) return palette.first;
    final h = title.hashCode.abs();
    return palette[h % palette.length];
  }

  static Color? cached(String path) => _cache[path];

  /// 从封面文件提取 dominant / vibrant；失败返回 null。
  static Future<Color?> extractFromFile(File file) async {
    final key = file.path;
    final hit = _cache[key];
    if (hit != null) return hit;
    try {
      final generator = await PaletteGenerator.fromImageProvider(
        FileImage(file),
        maximumColorCount: 12,
        size: const Size(80, 120),
      );
      final color = generator.dominantColor?.color ??
          generator.vibrantColor?.color ??
          generator.mutedColor?.color;
      if (color != null) {
        _cache[key] = color;
      }
      return color;
    } catch (e) {
      debugPrint('封面取色失败: $e');
      return null;
    }
  }

  /// 由主色生成卡片底/高光（轻微降饱和，避免抢封面）
  static Color wash(Color source, {double amount = 0.18}) {
    final hsl = HSLColor.fromColor(source);
    return hsl
        .withLightness(
          (hsl.lightness * (1 - amount) + 0.92 * amount).clamp(0.0, 1.0),
        )
        .withSaturation(hsl.saturation * (1 - amount * 0.7))
        .toColor();
  }

  /// 对比前景（深/浅字）
  static Color onColor(Color background) {
    return background.computeLuminance() > 0.55
        ? const Color(0xFF1C1B18)
        : const Color(0xFFF7F6F1);
  }
}
