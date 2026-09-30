import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

// FragmentProgram 在 dart:ui
// ignore: unnecessary_import
import 'dart:ui' show FragmentProgram;

/// 图片纸色适配（漫画空白边 / PDF 纸白）。
///
/// **漫画**（[TintMode.comic]）：按用户算法——整行（或整列）近白占比 ≥
/// [blankRatio] 视为空白边，整条改纸色；有内容的行即使含白块也不动。
///
/// **PDF**（[TintMode.pdf]）：低色度像素 `luma → (ink, paper)` 两端重映射。
class PaperTint {
  PaperTint._();

  static FragmentProgram? _program;
  static bool _loadFailed = false;

  static bool imagesNeedTint = false;
  static TintMode mode = TintMode.comic;
  static bool enabled = true;

  /// 近白亮度阈值
  static double whiteThreshold = 0.90;

  /// 整行/整列近白占比 ≥ 此值 → 空白边（0.97：允许极少噪点）
  static double blankRatio = 0.97;

  static double strength = 1.0;

  static bool get active => enabled && imagesNeedTint;

  /// 等比 contain 目标矩形（居中）：避免 fill 非等比把竖画压细。
  /// 多出的边由调用方纸色底露出。
  static Rect fitContain(Rect dest, double imgW, double imgH) {
    if (imgW <= 0 || imgH <= 0) return dest;
    final sx = dest.width / imgW;
    final sy = dest.height / imgH;
    final s = sx < sy ? sx : sy;
    final w = imgW * s;
    final h = imgH * s;
    return Rect.fromLTWH(
      dest.center.dx - w / 2,
      dest.center.dy - h / 2,
      w,
      h,
    );
  }

  /// 空白边权重：1=整行/列白，0=有内容（与 shader 同式）
  @visibleForTesting
  static double blankBandAmount(
    double rowWhiteRatio,
    double colWhiteRatio, {
    double? ratio,
    double? str,
  }) {
    final r = ratio ?? blankRatio;
    final s = str ?? strength;
    final blank = (rowWhiteRatio >= r || colWhiteRatio >= r) ? 1.0 : 0.0;
    return blank * s;
  }

  /// 单像素是否近白（亮度 + 低色度）
  @visibleForTesting
  static bool isNearWhite(double luma, double chroma, {double? thr}) {
    final t = thr ?? whiteThreshold;
    return luma >= t && chroma <= 0.10;
  }

  /// PDF：文档感权重（低色度）
  @visibleForTesting
  static double pdfDocAmount(double chroma, {double? str}) {
    final s = str ?? strength;
    // smoothstep(0.10, 0.22, chroma) 随色度升高
    final t = ((chroma - 0.10) / (0.22 - 0.10)).clamp(0.0, 1.0);
    final ss = t * t * (3.0 - 2.0 * t);
    return (1.0 - ss) * s;
  }

  /// PDF 重映射灰度（含轻微对比提升）
  @visibleForTesting
  static double pdfMappedLuma(double luma) {
    return ((luma - 0.5) * 1.08 + 0.5).clamp(0.0, 1.0);
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

  static void warmUp() {
    if (!active || _program != null || _loadFailed) return;
    _ensureLoaded();
  }

  /// 铺满 [rect]；漫画空白边 / PDF 重映射。失败回退 [fallback]。
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
        ..setFloat(14, whiteThreshold)
        ..setFloat(15, blankRatio);
      shader.setImageSampler(0, image);
      canvas.drawRect(rect, Paint()..shader = shader);
    } catch (e) {
      debugPrint('PaperTint paint failed: $e');
      fallback?.call();
    }
  }
}

enum TintMode {
  /// 整行/整列近白 → 空白边纸色
  comic,

  /// PDF 低色度墨/纸重映射
  pdf,
}
