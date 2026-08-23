import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../../../core/ffi/book_service.dart';

/// 书内图片解码缓存（EPUB 结构化路径专用）
///
/// - 缓存键 `"$bookId|$resourceHref"`：跨书隔离，同书同图只解码一次；
/// - [get] 同步取缓存（painter 热路径）；未命中走 [ensureLoaded]
///   异步取字节 → 解码 → 回调重绘；
/// - 换书/关书调 [clear]，防止 72MB 级书的插图常驻内存。
class BookImageStore {
  BookImageStore._();

  static final BookImageStore instance = BookImageStore._();

  final Map<String, ui.Image> _cache = {};
  final Set<String> _loading = {};
  BookService? _service;
  String? _bookId;

  /// 绑定当前书籍（换书时清空旧缓存）
  void bind(BookService service, String bookId) {
    if (_bookId == bookId && _service != null) return;
    clear();
    _service = service;
    _bookId = bookId;
  }

  /// 同步取已解码图片；未命中返回 null（调用方画占位并 ensureLoaded）
  ui.Image? get(String resourceHref) {
    return _cache[_key(resourceHref)];
  }

  /// 异步加载并解码；完成后经 [onReady] 通知重绘（幂等：进行中不重复发起）
  Future<void> ensureLoaded(
    String resourceHref,
    VoidCallback onReady,
  ) async {
    final key = _key(resourceHref);
    if (_cache.containsKey(key) || _loading.contains(key)) return;
    final service = _service;
    if (service == null || _bookId == null) return;

    _loading.add(key);
    try {
      final Uint8List bytes =
          await service.getBookResource(_bookId!, resourceHref);
      if (bytes.isEmpty) return;
      final ui.Codec codec = await ui.instantiateImageCodec(bytes);
      final ui.FrameInfo frame = await codec.getNextFrame();
      _cache[key] = frame.image;
      onReady();
    } catch (_) {
      // 加载失败：保持无缓存状态，下次绘制仍尝试
    } finally {
      _loading.remove(key);
    }
  }

  /// 清空全部缓存（换书/关书）
  void clear() {
    for (final image in _cache.values) {
      image.dispose();
    }
    _cache.clear();
    _loading.clear();
    _bookId = null;
    _service = null;
  }

  String _key(String resourceHref) => '$_bookId|$resourceHref';
}
