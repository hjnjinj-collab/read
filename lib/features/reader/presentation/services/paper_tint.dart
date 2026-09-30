import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

// FragmentProgram 在 dart:ui
// ignore: unnecessary_import
import 'dart:ui' show FragmentProgram;

/// 近白像素 → 纸色（漫画白边 / PDF 纸白适配暗色主题）。
///
/// - 不整图染色：仅 `luma ≥ threshold` 的像素向 [paperColor] 插值
/// - shader 加载失败时 [paint] 回退 [paintImage]
/// - 语义与 `paperTintAmount` 一致，便于单测阈值边界
class PaperTint {
  PaperTint._();

  static FragmentProgram? _program;
  static bool _loadFailed = false;

  /// 当前书是否需要纸色适配（漫画 / PDF 原图；由打开书籍时设置）
  static bool imagesNeedTint = false;

  /// 用户开关（设置持久化）
  static bool enabled = true;

  /// 近白判定阈值（亮度 0-1）
  static double threshold = 0.90;

  /// 映射强度 0-1
  static double strength = 1.0;

  static bool get active => enabled && imagesNeedTint;

  /// 阈值混合权重：luma 越接近白，t 越大（与 shader smoothstep 同式）
  @visibleForTesting
  static double paperTintAmount(double luma, {double? thr, double? str}) {
    final th = thr ?? threshold;
    final s = str ?? strength;
    final t = _smoothstep(th - 0.08, th, luma);
    return t * s;
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

  /// 将 [image] 铺进 [rect]（BoxFit.fill 语义），近白映射为 [paper]。
  /// 失败回退 [fallback]（通常 paintImage）。
  static void paint(
    Canvas canvas,
    Rect rect,
    ui.Image image,
    Color paper, {
    VoidCallback? fallback,
  }) {
    if (!active) {
      fallback?.call();
      return;
    }
    final program = _program;
    if (program == null) {
      // 异步加载未完成或失败：本帧回退，下次可能就绪
      if (!_loadFailed) _ensureLoaded();
      fallback?.call();
      return;
    }
    try {
      final shader = program.fragmentShader();
      // Color.r/g/b/a 已是 0-1
      shader
        ..setFloat(0, rect.left)
        ..setFloat(1, rect.top)
        ..setFloat(2, rect.width <= 0 ? 1 : rect.width)
        ..setFloat(3, rect.height <= 0 ? 1 : rect.height)
        ..setFloat(4, paper.r)
        ..setFloat(5, paper.g)
        ..setFloat(6, paper.b)
        ..setFloat(7, paper.a)
        ..setFloat(8, threshold)
        ..setFloat(9, strength);
      shader.setImageSampler(0, image);
      canvas.drawRect(rect, Paint()..shader = shader);
    } catch (e) {
      debugPrint('PaperTint paint failed: $e');
      fallback?.call();
    }
  }
}
