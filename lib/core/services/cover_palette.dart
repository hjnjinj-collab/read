import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:path_provider/path_provider.dart';

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

/// 封面取色：内存 + 磁盘 JSON 缓存，避免每次启动全量重提
class CoverPalette {
  CoverPalette._();

  static final Map<String, CoverColors> _mem = {};
  static File? _diskFile;
  static bool _diskLoaded = false;
  static bool _dirty = false;
  static Timer? _saveTimer;

  /// 并发闸：同时最多 2 个提取，防止启动风暴
  static int _active = 0;
  static const int _maxActive = 2;
  static final List<Completer<void>> _waiters = [];

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

  static CoverColors? cached(String path) => _mem[path];

  static Future<void> _ensureDiskLoaded() async {
    if (_diskLoaded) return;
    _diskLoaded = true;
    try {
      final dir = await getApplicationSupportDirectory();
      _diskFile = File('${dir.path}/cover_palette_cache.json');
      if (await _diskFile!.exists()) {
        final raw = await _diskFile!.readAsString();
        final map = jsonDecode(raw);
        if (map is Map<String, dynamic>) {
          for (final e in map.entries) {
            final v = e.value;
            if (v is Map<String, dynamic>) {
              final c = CoverColors.fromJson(v);
              if (c != null) _mem[e.key] = c;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('取色磁盘缓存读取失败: $e');
    }
  }

  static void _scheduleSave() {
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _flushDisk);
  }

  static Future<void> _flushDisk() async {
    if (!_dirty || _diskFile == null) return;
    _dirty = false;
    try {
      final map = <String, dynamic>{
        for (final e in _mem.entries) e.key: e.value.toJson(),
      };
      await _diskFile!.writeAsString(jsonEncode(map), flush: true);
    } catch (e) {
      debugPrint('取色磁盘缓存写入失败: $e');
    }
  }

  static Future<void> _acquire() async {
    if (_active < _maxActive) {
      _active++;
      return;
    }
    final c = Completer<void>();
    _waiters.add(c);
    await c.future;
  }

  static void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _active = (_active - 1).clamp(0, _maxActive);
    }
  }

  static Future<CoverColors?> extractFromFile(File file) async {
    final key = file.path;
    final hit = _mem[key];
    if (hit != null) return hit;

    await _ensureDiskLoaded();
    final diskHit = _mem[key];
    if (diskHit != null) return diskHit;

    await _acquire();
    try {
      // 二次检查：排队期间可能已有人写入
      final again = _mem[key];
      if (again != null) return again;

      final generator = await PaletteGenerator.fromImageProvider(
        FileImage(file),
        maximumColorCount: 16,
        size: const Size(80, 120),
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
      _mem[key] = colors;
      _scheduleSave();
      return colors;
    } catch (e) {
      debugPrint('封面取色失败: $e');
      return null;
    } finally {
      _release();
    }
  }

  static Color onColor(Color background) {
    return background.computeLuminance() > 0.55
        ? const Color(0xFF1C1B18)
        : const Color(0xFFF7F6F1);
  }
}
