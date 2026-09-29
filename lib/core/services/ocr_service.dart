/// 扫描页 OCR（系统文字识别 / ML Kit）
///
/// 识别结果写入 Rust OCR 缓存；分页优先用文字重排（主题底 + 可换字体）。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart'
    show Canvas, Paint, Rect, FilterQuality;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

import '../ffi/book_service.dart';

class OcrService {
  OcrService._();

  static final instance = OcrService._();

  TextRecognizer? _recognizer;
  bool _supported = !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  TextRecognizer get _rec {
    return _recognizer ??=
        TextRecognizer(script: TextRecognitionScript.chinese);
  }

  /// 图片字节 → 文本；失败/不支持返回空串
  /// 精度：小图先放大到宽≥1200 再识别，减少小字漏识
  Future<String> recognizeImage(Uint8List bytes) async {
    if (!_supported || bytes.isEmpty) return '';
    File? tmp;
    try {
      final dir = await getTemporaryDirectory();
      tmp = File(
        '${dir.path}/ocr_${DateTime.now().microsecondsSinceEpoch}.img',
      );
      final prepared = await _upscaleIfNeeded(bytes);
      await tmp.writeAsBytes(prepared, flush: true);
      final input = InputImage.fromFilePath(tmp.path);
      final result = await _rec.processImage(input);
      return result.text.trim();
    } catch (e) {
      debugPrint('OcrService.recognizeImage: $e');
      return '';
    } finally {
      try {
        await tmp?.delete();
      } catch (_) {}
    }
  }

  /// 小图放大到宽 ≥1200px（PNG），提升小字识别率
  Future<Uint8List> _upscaleIfNeeded(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final w = img.width;
      final h = img.height;
      if (w >= 1200 || w == 0 || h == 0) {
        return bytes;
      }
      final scale = 1200 / w;
      final tw = (w * scale).round();
      final th = (h * scale).round();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Rect.fromLTWH(0, 0, tw.toDouble(), th.toDouble()),
        Paint()..filterQuality = FilterQuality.high,
      );
      final pic = recorder.endRecording();
      final out = await pic.toImage(tw, th);
      final bd = await out.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      out.dispose();
      if (bd == null) return bytes;
      return bd.buffer.asUint8List();
    } catch (_) {
      return bytes;
    }
  }

  /// 已 OCR 过的章（避免每次翻页重复识别导致卡顿）
  final Set<String> _doneChapters = {};
  final Set<String> _inflight = {};

  /// 预识别 PDF 章扫描页；[blocking]=false 时后台跑不挡翻页
  Future<int> preOcrPdfChapter(
    String bookId,
    int chapterIndex, {
    bool blocking = false,
  }) async {
    if (!_supported) return 0;
    final key = '$bookId#$chapterIndex';
    if (_doneChapters.contains(key) || _inflight.contains(key)) return 0;
    _inflight.add(key);
    try {
      final hrefs = await BookService().pdfImageHrefs(bookId, chapterIndex);
      var ok = 0;
      for (final href in hrefs) {
        try {
          // 已有缓存则跳过（性能）
          final cached = await BookService().getOcrPageText(href);
          if (cached.trim().isNotEmpty) {
            ok++;
            continue;
          }
          final bytes = await BookService().getBookResource(bookId, href);
          final text = await recognizeImage(bytes);
          if (text.isNotEmpty) {
            await BookService().putOcrPageText(href, text);
            ok++;
          }
        } catch (e) {
          debugPrint('preOcr $href: $e');
        }
      }
      _doneChapters.add(key);
      debugPrint('preOcrPdfChapter ch=$chapterIndex ok=$ok/${hrefs.length}');
      if (ok > 0) {
        // 批量完成后一次失效分页缓存（不要每页 clear）
        try {
          await BookService().finalizeOcrBatch();
        } catch (_) {}
      }
      return ok;
    } catch (e) {
      debugPrint('preOcrPdfChapter: $e');
      return 0;
    } finally {
      _inflight.remove(key);
    }
  }

  void dispose() {
    _recognizer?.close();
    _recognizer = null;
    _doneChapters.clear();
    _inflight.clear();
  }
}
