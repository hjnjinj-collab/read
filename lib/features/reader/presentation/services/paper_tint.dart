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

  /// 图像墨迹内容框（图像像素坐标）缓存：href → content rect
  static final Map<String, Rect> _contentBoxes = {};

  static void setContentBox(String key, Rect box) {
    if (box.width > 1 && box.height > 1) _contentBoxes[key] = box;
  }

  static Rect? contentBox(String key) => _contentBoxes[key];

  static void clearContentBoxes() => _contentBoxes.clear();

  /// 低分辨率采样估算墨迹包围盒（去空白纸边）；失败返回 null。
  static Future<Rect?> estimateContentBox(ui.Image image) async {
    try {
      const n = 48;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(0, 0, n.toDouble(), n.toDouble()),
        Paint()..filterQuality = FilterQuality.low,
      );
      final small = await recorder.endRecording().toImage(n, n);
      final bd = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
      small.dispose();
      if (bd == null) return null;
      var minX = n, maxX = -1, minY = n, maxY = -1;
      for (var y = 0; y < n; y++) {
        for (var x = 0; x < n; x++) {
          final i = (y * n + x) * 4;
          final r = bd.getUint8(i) / 255.0;
          final g = bd.getUint8(i + 1) / 255.0;
          final b = bd.getUint8(i + 2) / 255.0;
          final luma = 0.299 * r + 0.587 * g + 0.114 * b;
          var mx = r;
          var mn = r;
          if (g > mx) mx = g;
          if (b > mx) mx = b;
          if (g < mn) mn = g;
          if (b < mn) mn = b;
          final chroma = mx - mn;
          if (luma < 0.90 || chroma > 0.10) {
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
          }
        }
      }
      if (maxX < minX || maxY < minY) return null;
      // 放大回图像坐标，并留 1 格余量
      final sx = image.width / n;
      final sy = image.height / n;
      return Rect.fromLTRB(
        (minX * sx).clamp(0, image.width.toDouble()),
        (minY * sy).clamp(0, image.height.toDouble()),
        ((maxX + 1) * sx).clamp(0, image.width.toDouble()),
        ((maxY + 1) * sy).clamp(0, image.height.toDouble()),
      );
    } catch (_) {
      return null;
    }
  }

  /// 等比适配 **内容框**：让墨迹区域尽量贴合 [dest]，少留边且不裁字。
  /// [content] 为图像像素坐标；无内容框时退化为 [fitSafeCover]。
  static Rect fitContent(
    Rect dest,
    double imgW,
    double imgH, [
    Rect? content,
  ]) {
    if (content == null || content.width < 2 || content.height < 2) {
      return fitSafeCover(dest, imgW, imgH);
    }
    final cw = content.width.clamp(1.0, imgW);
    final ch = content.height.clamp(1.0, imgH);
    final sx = dest.width / cw;
    final sy = dest.height / ch;
    final s = sx < sy ? sx : sy;
    final w = imgW * s;
    final h = imgH * s;
    final cx = content.center.dx * s;
    final cy = content.center.dy * s;
    return Rect.fromLTWH(dest.center.dx - cx, dest.center.dy - cy, w, h);
  }

  /// 等比 cover，但限制水平裁切不超过 [maxSideCrop]（防切到正文）。
  static Rect fitSafeCover(
    Rect dest,
    double imgW,
    double imgH, {
    double maxSideCrop = 0.04,
  }) {
    if (imgW <= 0 || imgH <= 0) return dest;
    var s = dest.width / imgW;
    final sy = dest.height / imgH;
    if (sy > s) s = sy;
    final maxW = dest.width * (1.0 + maxSideCrop);
    if (imgW * s > maxW) {
      s = maxW / imgW;
    }
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
