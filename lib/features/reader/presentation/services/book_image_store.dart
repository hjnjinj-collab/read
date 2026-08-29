import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../../../core/ffi/book_service.dart';
import '../../../../core/models/simple_models.dart';
import '../diagnostics/reader_trace.dart';

/// 图片资源加载状态。ready/failed 都是稳定终态，直到 bind/clear。
enum BookImageState { loading, ready, failed }

/// 简易计数信号量：限制「取字节 + 解码」并发。
class _Semaphore {
  _Semaphore(this._max);

  final int _max;
  int _running = 0;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() task) async {
    while (_running >= _max) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    _running++;
    try {
      return await task();
    } finally {
      _running--;
      if (_waiters.isNotEmpty) {
        _waiters.removeFirst().complete();
      }
    }
  }
}

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

  /// 失败计数与退避窗口：failed 不再是永久终态，按次数有限重试
  /// （一次瞬时 FFI/解码失败 = 永久灰块的根因修复）。
  /// 超过 [_maxFailureAttempts] 后回到稳定 failed：恒画占位，直到 bind/clear。
  final Map<String, int> _failureCounts = {};
  final Map<String, DateTime> _retryNotBefore = {};
  static const int _maxFailureAttempts = 3;

  /// 失败重试退避表（@visibleForTesting：测试可归零避免真实等待）
  @visibleForTesting
  static List<Duration> retryBackoff = const [
    Duration(milliseconds: 500),
    Duration(seconds: 2),
    Duration(seconds: 8),
  ];
  BookService? _service;
  String? _bookId;
  int _epoch = 0;

  /// 解码并发闸门：同时最多 2 个「取字节 + 解码」在飞。
  /// 图片密集章节一次性预热几十张时，无限制并发会挤爆内存带宽与
  /// FFI IO（对齐 BUGFIX_INDEX M9.3 洪峰教训）；限流后总吞吐几乎
  /// 不减、峰值内存平稳。
  static final _decodeGate = _Semaphore(2);

  /// LRU 内存上限（张数）：超限按访问新旧淘汰，防止图片密集书常驻爆内存
  static const int _maxCacheEntries = 64;

  /// 存活 FrameSet 引用的资源键：淘汰时跳过，保证正在绘制/定格的
  /// 帧不会被 dispose（ui.Image 释放后绘制会崩溃）。
  final Set<String> _pinned = {};

  /// 会话世代（与 ReaderNotifier._sessionEpoch 同步）：记录用，
  /// 图片内容与排版无关，会话推进不清缓存（换书仍走 bind/clear）。
  int _sessionEpoch = 0;

  /// 当前绑定世代（每次 clear/bind 都递增）。
  int get epoch => _epoch;

  /// 绑定当前书籍（换书时清空旧缓存）
  void bind(BookService service, String bookId) {
    if (_bookId == bookId && _service != null) return;
    clear();
    _service = service;
    _bookId = bookId;
    readerTrace('image.bind', {'book': bookId, 'epoch': _epoch});
  }

  /// 同步取已解码图片；未命中返回 null（调用方画占位并 ensureLoaded）。
  /// 命中时 move-to-end 维护 LRU 新旧序。
  ui.Image? get(String resourceHref) {
    final key = _key(resourceHref);
    final image = _cache.remove(key);
    if (image != null) {
      _cache[key] = image;
    }
    return image;
  }

  /// 查询资源状态；尚未请求过的资源返回 null。
  /// failed 为稳定态：退避窗口内与超过重试上限后均返回 failed，
  /// 调用方恒画占位，不会随机切换。
  BookImageState? state(String resourceHref) {
    final key = _key(resourceHref);
    if (_cache.containsKey(key)) return BookImageState.ready;
    if (_failureCounts.containsKey(key)) return BookImageState.failed;
    if (_loading.contains(key)) return BookImageState.loading;
    return null;
  }

  /// [state] 的动词形式，保留状态查询 API 的可读性。
  BookImageState? getState(String resourceHref) => state(resourceHref);

  /// 状态查询别名，避免调用方需要依赖内部缓存结构。
  BookImageState? status(String resourceHref) => state(resourceHref);

  /// 异步加载并解码；完成后经 [onReady] 通知重绘（幂等：进行中不重复发起）
  Future<void> ensureLoaded(String resourceHref, VoidCallback onReady) async {
    final key = _key(resourceHref);
    if (_cache.containsKey(key) || _loading.contains(key)) {
      // 缓存/进行中命中：无需新请求（miss 由 image.request 表达）
      readerTrace('image.hit', {'href': resourceHref, 'epoch': _epoch});
      return;
    }
    // 稳定失败终态：占位恒定，不再发起请求
    if ((_failureCounts[key] ?? 0) >= _maxFailureAttempts) {
      return;
    }
    // 退避窗口内保持占位，等窗口过后由下一次绘制/预热重试
    final notBefore = _retryNotBefore[key];
    if (notBefore != null && DateTime.now().isBefore(notBefore)) {
      return;
    }
    final service = _service;
    final bookId = _bookId;
    if (service == null || bookId == null) return;

    _loading.add(key);
    readerTrace('image.request', {
      'href': resourceHref,
      'epoch': _epoch,
      'session': _sessionEpoch,
    });
    final requestEpoch = _epoch;
    try {
      await _decodeGate.run(() async {
        final Uint8List bytes = await service.getBookResource(
          bookId,
          resourceHref,
        );
        if (bytes.isEmpty) throw StateError('empty book resource');
        final ui.Codec codec = await ui.instantiateImageCodec(bytes);
        final ui.FrameInfo frame;
        try {
          frame = await codec.getNextFrame();
        } finally {
          codec.dispose();
        }
        // bind/clear 后，旧书请求不得触碰新书的缓存或通知页面。
        if (requestEpoch != _epoch || bookId != _bookId) {
          frame.image.dispose();
          return;
        }
        _cache[key] = frame.image;
        _evictIfNeeded();
        // 成功后清空失败记录，允许后续失败重新计次
        _failureCounts.remove(key);
        _retryNotBefore.remove(key);
        readerTrace(
          'image.ready',
          {'href': resourceHref, 'epoch': requestEpoch},
        );
        onReady();
      });
    } catch (_) {
      if (requestEpoch == _epoch && bookId == _bookId) {
        final attempts = (_failureCounts[key] ?? 0) + 1;
        _failureCounts[key] = attempts;
        if (attempts < _maxFailureAttempts) {
          final backoff =
              retryBackoff[(attempts - 1).clamp(0, retryBackoff.length - 1)];
          _retryNotBefore[key] = DateTime.now().add(backoff);
        } else {
          _retryNotBefore.remove(key);
        }
        readerTrace('image.failed', {
          'href': resourceHref,
          'epoch': requestEpoch,
          'attempts': attempts,
        });
      }
    } finally {
      // 不要移除新 epoch 对同名资源发起的请求。
      if (requestEpoch == _epoch) _loading.remove(key);
    }
  }

  /// 批量预热资源清单（去重后的 href 集合），返回每个 href 的终态
  /// （ready/failed）。Future 在所有资源达到终态后完成
  /// （失败含退避窗口内的即时返回）。
  Future<Map<String, BookImageState>> prewarmManifest(
    Iterable<String> hrefs,
  ) async {
    final results = <String, BookImageState>{};
    await Future.wait(
      hrefs.map((href) async {
        await ensureLoaded(href, () {});
        final state = this.state(href);
        if (state != null) results[href] = state;
      }),
    );
    return results;
  }

  /// 资源清单是否全部达到终态（ready 或稳定 failed）。
  /// PageFrame 聚合 resourceState 的判定依据。
  bool isManifestReady(Iterable<String> hrefs) {
    for (final href in hrefs) {
      final s = state(href);
      if (s != BookImageState.ready && s != BookImageState.failed) {
        return false;
      }
    }
    return true;
  }

  /// 收集页面背景和图片 entry，去重后在后台批量预热。
  /// Future 在所有资源达到 ready 或 failed 后完成。
  Future<void> prewarm(Iterable<PageInfo> pages) {
    final hrefs = <String>{};
    for (final page in pages) {
      hrefs.addAll(_collectPageHrefs(page));
    }
    return prewarmManifest(hrefs);
  }

  /// 收集单页资源引用（背景图 + 全部图片 entry）
  static Set<String> _collectPageHrefs(PageInfo page) {
    final hrefs = <String>{};
    final background = page.backgroundHref;
    if (background != null && background.isNotEmpty) hrefs.add(background);
    for (final entry in page.entries) {
      final href = entry.resourceHref;
      if (href != null && href.isNotEmpty) hrefs.add(href);
    }
    return hrefs;
  }

  /// 更明确的兼容别名，便于调用方按页面集合预热。
  Future<void> prewarmPages(Iterable<PageInfo> pages) => prewarm(pages);

  /// 资源预加载的兼容命名别名。
  Future<void> preloadPages(Iterable<PageInfo> pages) => prewarm(pages);

  /// 批量预热的简短兼容命名。
  Future<void> preload(Iterable<PageInfo> pages) => prewarm(pages);

  // ── pin / 会话 ──

  /// 原子替换 pin 集：当前 FrameSet 三槽 manifest 的并集。
  /// 存活帧引用的图片永不淘汰（dispose 安全）；收敛在发布单点调用。
  void setPinned(Iterable<String> hrefs) {
    _pinned.clear();
    for (final href in hrefs) {
      _pinned.add(_key(href));
    }
  }

  void unpinAll() => _pinned.clear();

  /// 会话推进记录（不清缓存：图片内容与排版无关）
  void advanceSession(int sessionEpoch) {
    _sessionEpoch = sessionEpoch;
    unpinAll();
    readerTrace('image.session', {'epoch': sessionEpoch});
  }

  /// LRU 淘汰：从最旧端找未被 pin 的条目释放；全 pin 时容忍超限。
  void _evictIfNeeded() {
    if (_cache.length <= _maxCacheEntries) return;
    for (final key in _cache.keys.toList()) {
      if (_cache.length <= _maxCacheEntries) break;
      if (_pinned.contains(key)) continue;
      final image = _cache.remove(key);
      image?.dispose();
      readerTrace('image.evict', {'key': key});
    }
  }

  /// 清空全部缓存（换书/关书）
  void clear() {
    _epoch++;
    for (final image in _cache.values) {
      image.dispose();
    }
    _cache.clear();
    _loading.clear();
    _failureCounts.clear();
    _retryNotBefore.clear();
    _pinned.clear();
    _bookId = null;
    _service = null;
  }

  String _key(String resourceHref) => '$_bookId|$resourceHref';
}
