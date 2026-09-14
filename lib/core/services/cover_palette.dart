import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

/// 封面取色结果（与封面同级 sidecar 永久缓存：`{hash}.pal.json`）
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

  Map<String, dynamic> toJson() => {
        'd': dominant.toARGB32(),
        'v': vibrant.toARGB32(),
        'k': dark.toARGB32(),
      };

  static CoverColors? fromJson(Map<String, dynamic> json) {
    try {
      return CoverColors(
        dominant: Color(json['d'] as int),
        vibrant: Color(json['v'] as int),
        dark: Color(json['k'] as int),
      );
    } catch (_) {
      return null;
    }
  }

  Color get shadowColor => CoverPalette.clampMood(dominant);

  Color get posterScrim => CoverPalette.clampMood(
        Color.lerp(dark, dominant, 0.55)!,
        minL: 0.22,
        maxL: 0.55,
      );

  Color get posterHighlight => CoverPalette.clampMood(
        Color.lerp(vibrant, Colors.white, 0.42)!,
        minL: 0.68,
        maxL: 0.88,
      );

  Color get accent => CoverPalette.clampMood(
        vibrant,
        minL: 0.42,
        maxL: 0.68,
        minS: 0.35,
      );
}

/// 主色缓存：**只读 sidecar，不在书架路径做取色**。
/// 取色仅在「封面首次落盘」时执行一次并写 `{cover}.pal.json`。
class CoverPalette {
  CoverPalette._();

  static final Map<String, CoverColors> _mem = {};

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

  /// [sourcePath] 为书籍路径；[coverFile] 为封面图片，sidecar = 同名 .pal.json
  static File sidecarOf(File coverFile) =>
      File('${coverFile.path}.pal.json');

  static CoverColors? cached(String sourcePath) => _mem[sourcePath];

  static void put(String sourcePath, CoverColors colors) {
    _mem[sourcePath] = colors;
  }

  /// 仅读 sidecar（书架启动路径）。无文件则不取色。
  static CoverColors? loadSidecar(String sourcePath, File coverFile) {
    final hit = _mem[sourcePath];
    if (hit != null) return hit;
    final side = sidecarOf(coverFile);
    if (!side.existsSync()) return null;
    try {
      final map = jsonDecode(side.readAsStringSync());
      if (map is! Map<String, dynamic>) return null;
      final c = CoverColors.fromJson(map);
      if (c != null) _mem[sourcePath] = c;
      return c;
    } catch (_) {
      return null;
    }
  }

  /// 从封面图提取主色并写 sidecar（**仅封面首次落盘时调用**）
  static Future<CoverColors?> extractAndPersist(
    String sourcePath,
    File coverFile,
  ) async {
    final hit = _mem[sourcePath];
    if (hit != null) return hit;
    final existing = loadSidecar(sourcePath, coverFile);
    if (existing != null) return existing;
    try {
      final generator = await PaletteGenerator.fromImageProvider(
        FileImage(coverFile),
        maximumColorCount: 24,
        size: const Size(120, 180),
      );
      final colors = _pickFromGenerator(generator);
      if (colors == null) return null;
      _mem[sourcePath] = colors;
      final side = sidecarOf(coverFile);
      side.writeAsStringSync(jsonEncode(colors.toJson()));
      return colors;
    } catch (e) {
      debugPrint('封面取色失败: $e');
      return null;
    }
  }

  static CoverColors? _pickFromGenerator(PaletteGenerator generator) {
    final swatches = generator.paletteColors.toList()
      ..sort((a, b) => b.population.compareTo(a.population));

    Color? dominant;
    for (final s in swatches) {
      final hsl = HSLColor.fromColor(s.color);
      if (hsl.saturation < 0.12) continue;
      if (hsl.lightness < 0.08 || hsl.lightness > 0.92) continue;
      dominant = s.color;
      break;
    }
    dominant ??= generator.dominantColor?.color;
    if (dominant == null) return null;

    final dHue = HSLColor.fromColor(dominant).hue;
    Color? vibrant;
    double best = 1e9;
    for (final s in swatches) {
      final hsl = HSLColor.fromColor(s.color);
      if (hsl.saturation < 0.2 || hsl.lightness < 0.15 || hsl.lightness > 0.85) {
        continue;
      }
      var dh = (hsl.hue - dHue).abs() % 360;
      if (dh > 180) dh = 360 - dh;
      final score = dh - hsl.saturation * 40;
      if (score < best) {
        best = score;
        vibrant = s.color;
      }
    }
    vibrant ??= generator.vibrantColor?.color ?? dominant;

    final rawDark = generator.darkMutedColor?.color ??
        generator.darkVibrantColor?.color ??
        Color.lerp(dominant, Colors.black, 0.45)!;

    return CoverColors(
      dominant: clampMood(dominant),
      vibrant: clampMood(vibrant, minL: 0.3, maxL: 0.72),
      dark: clampMood(rawDark, minL: 0.1, maxL: 0.36),
    );
  }

  static Color onColor(Color background) {
    return background.computeLuminance() > 0.55
        ? const Color(0xFF1C1B18)
        : const Color(0xFFF7F6F1);
  }
}
