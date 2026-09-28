/// 扫描页 OCR（系统文字识别 / ML Kit）
///
/// 识别结果写入 Rust OCR 缓存；分页优先用文字重排（主题底 + 可换字体）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
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
  Future<String> recognizeImage(Uint8List bytes) async {
    if (!_supported || bytes.isEmpty) return '';
    File? tmp;
    try {
      final dir = await getTemporaryDirectory();
      tmp = File(
        '${dir.path}/ocr_${DateTime.now().microsecondsSinceEpoch}.img',
      );
      await tmp.writeAsBytes(bytes, flush: true);
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

  /// 预识别 PDF 章扫描页，写入 Rust 缓存（key = image href）
  Future<int> preOcrPdfChapter(String bookId, int chapterIndex) async {
    if (!_supported) return 0;
    try {
      final hrefs = await BookService().pdfImageHrefs(bookId, chapterIndex);
      var ok = 0;
      for (final href in hrefs) {
        try {
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
      debugPrint('preOcrPdfChapter ch=$chapterIndex ok=$ok/${hrefs.length}');
      return ok;
    } catch (e) {
      debugPrint('preOcrPdfChapter: $e');
      return 0;
    }
  }

  void dispose() {
    _recognizer?.close();
    _recognizer = null;
  }
}
