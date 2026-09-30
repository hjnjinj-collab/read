import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

// FragmentProgram 在 dart:ui
// ignore: unnecessary_import
import 'dart:ui' show FragmentProgram;

/// 图片纸色适配（漫画白边 / PDF 纸白）。
///
/// 两种模式（[mode]）：
/// - [TintMode.comic]：只改**图边近白**（上下/左右留白），图内白底不动
/// - [TintMode.pdf]：低色度像素做 亮度→(墨色,纸色) 两端重映射，字迹对比保留
///
/// shader 失败时 [paint] 回退 [fallback]。
class PaperTint {
  PaperTint._();

  static FragmentProgram? _program;
  static bool _loadFailed = false;

  /// 当前书是否需要纸色适配（漫画 / PDF 原图）
  static bool imagesNeedTint = false;

  /// 打开书籍时的模式（comic → 边缘留白；pdf → 文档重映射）
  static TintMode mode = TintMode.comic;

  /// 用户开关（设置持久化）
  static bool enabled = true;

  /// 漫画近白阈值（偏严：0.93，少误伤图内白）
  static double comicWhiteThreshold = 0.93;

  /// 漫画边缘带宽（UV 半宽；0.14 ≈ 四周 14%）
  static double comicMargin = 0.14;

  /// 映射强度 0-1
  static double strength = 1.0;

  static bool get active => enabled && imagesNeedTint;

  /// 漫画：边缘带权重 × 近白权重（与 shader 同式，便于单测）
  @visibleForTesting
  static double comicTintAmount(
    double luma,
    double chroma,
    double edgeDist, {
    double? thr,
    double? margin,
    double? str,
  }) {
    final th = thr ?? comicWhiteThreshold;
    final mg = margin ?? comicMargin;
    final s = str ?? strength;
    final band = 1.0 - _smoothstep(mg * 0.55, mg, edgeDist);
    final white = _smoothstep(th - 0.04, th, luma) *
        (1.0 - _smoothstep(0.05, 0.12, chroma));
    return white * band * s;
  }

  /// PDF：文档感权重（低色度）
  @visibleForTesting
  static double pdfDocAmount(double chroma, {double? str}) {
    final s = str ?? strength;
    return (1.0 - _smoothstep(0.10, 0.22, chroma)) * s;
  }

  /// PDF 重映射后的灰度（0=墨，1=纸），含轻微对比提升
  @visibleForTesting
  static double pdfMappedLuma(double luma) {
    final g = (luma - 0.5) * 1.08 + 0.5;
    return g.clamp(0.0, 1.0);
  }

  static double _smoothstep(double edge0, double edge1, double x) {
    if (edge1 <= edge0) return x >= edge1 ? 1.0 : 0.0;
    final t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
  }

  static Future<void> _ensureLoaded() async {
    if (_program != null || _loadFailed) return;
    try {
      _program = await FragmentProgram.fromAsset('shaders/paper_tint.frag');
    } catch (e) {
      debugPrint('PaperTint shader load failed: $e');
      _loadFailed = true;
    }
  }

  /// 预热 shader（打开漫画/PDF 时调用一次）
  static void warmUp() {
    if (!active || _program != null || _loadFailed) return;
    _ensureLoaded();
  }

  /// 将 [image] 铺进 [rect]（BoxFit.fill 语义）。
  /// [paper] 纸色，[ink] 正文色（PDF 重映射用）。
  static void paint(
    Canvas canvas,
    Rect rect,
    ui.Image image,
    Color paper,
    Color ink, {
    VoidCallback? fallback,
  }) {
    if (!active) {
      fallback?.call();
      return;
    }
    final program = _program;
    if (program == null) {
      if (!_loadFailed) _ensureLoaded();
      fallback?.call();
      return;
    }
    try {
      final shader = program.fragmentShader();
      shader
        ..setFloat(0, rect.left)
        ..setFloat(1, rect.top)
        ..setFloat(2, rect.width <= 0 ? 1 : rect.width)
        ..setFloat(3, rect.height <= 0 ? 1 : rect.height)
        ..setFloat(4, paper.r)
        ..setFloat(5, paper.g)
        ..setFloat(6, paper.b)
        ..setFloat(7, paper.a)
        ..setFloat(8, ink.r)
        ..setFloat(9, ink.g)
        ..setFloat(10, ink.b)
        ..setFloat(11, ink.a)
        ..setFloat(12, mode == TintMode.pdf ? 1.0 : 0.0)
        ..setFloat(13, strength)
        ..setFloat(14, comicWhiteThreshold)
        ..setFloat(15, comicMargin);
      shader.setImageSampler(0, image);
      canvas.drawRect(rect, Paint()..shader = shader);
    } catch (e) {
      debugPrint('PaperTint paint failed: $e');
      fallback?.call();
    }
  }
}

/// 图片纸色适配模式
enum TintMode {
  /// 漫画：仅图边近白 → 纸色
  comic,

  /// PDF 文档：低色度 亮度→(墨色,纸色) 重映射
  pdf,
}
