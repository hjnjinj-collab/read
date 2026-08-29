import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/core/ffi/book_service.dart';
import 'package:legado_flutter/core/models/simple_models.dart';
import 'package:legado_flutter/features/reader/presentation/services/book_image_store.dart';

/// 1x1 PNG（合法图像字节，用于解码成功路径）。
/// 注意：必须是可解码的完整 PNG——早期手写字节常量损坏导致
/// "Codec failed to produce an image"，改由知名 base64 生成。
final Uint8List _png1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
  'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// fake 服务：按 href 提供响应队列
///
/// - [responses]：每次 getBookResource 按序弹出队首（空字节=失败）。
///   支持同 href「先失败后成功」的重试序列；
/// - 无队列的 href 挂起在 [results]，由测试手动 complete 控制时机
///   （completer 首次调用时创建，后续调用复用同一 future——
///   与 store 的 dedupe 语义对齐）。
class _FakeBookService extends BookService {
  int calls = 0;
  final Map<String, List<Uint8List>> responses = {};
  final Map<String, Completer<Uint8List>> results = {};

  @override
  Future<Uint8List> getBookResource(String bookId, String resourceHref) {
    calls++;
    final queue = responses[resourceHref];
    if (queue != null && queue.isNotEmpty) {
      return Future.value(queue.removeAt(0));
    }
    return (results[resourceHref] ??= Completer<Uint8List>()).future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final store = BookImageStore.instance;
  final defaultBackoff = List<Duration>.from(BookImageStore.retryBackoff);

  setUp(() {
    BookImageStore.retryBackoff = List<Duration>.from(defaultBackoff);
  });

  tearDown(store.clear);

  test(
    'deduplicates requests and failed stays stable within the backoff window',
    () async {
      final service = _FakeBookService();
      store.bind(service, 'book');

      final first = store.ensureLoaded('images/a.png', () {});
      final second = store.ensureLoaded('images/a.png', () {});
      expect(service.calls, 1);
      service.results['images/a.png']!.complete(Uint8List(0));
      await Future.wait([first, second]);

      expect(store.state('images/a.png'), BookImageState.failed);
      // 退避窗口内再遇到：保持稳定占位，不发新请求
      await store.ensureLoaded('images/a.png', () {});
      expect(service.calls, 1);
    },
  );

  test(
    'prewarm collects and deduplicates background and entry hrefs',
    () async {
      final service = _FakeBookService();
      store.bind(service, 'book');
      final pages = [
        PageInfo(
          pageIndex: 0,
          backgroundHref: 'images/bg.png',
          entries: const [
            PageEntry(
              resourceHref: 'images/a.png',
              x: 0,
              y: 0,
              width: 1,
              height: 1,
            ),
          ],
          startCharIndex: 0,
          endCharIndex: 0,
        ),
        PageInfo(
          pageIndex: 1,
          backgroundHref: 'images/bg.png',
          entries: const [
            PageEntry(
              resourceHref: 'images/a.png',
              x: 0,
              y: 0,
              width: 1,
              height: 1,
            ),
          ],
          startCharIndex: 0,
          endCharIndex: 0,
        ),
      ];
      final warming = store.prewarm(pages);
      await Future<void>.delayed(Duration.zero);
      expect(service.calls, 2);
      service.results['images/a.png']!.complete(Uint8List(0));
      service.results['images/bg.png']!.complete(Uint8List(0));
      await warming;
      expect(store.state('images/a.png'), BookImageState.failed);
      expect(store.state('images/bg.png'), BookImageState.failed);
    },
  );

  test(
    'old epoch cannot publish failed state into a newly bound book',
    () async {
      final oldService = _FakeBookService();
      store.bind(oldService, 'old');
      final oldRequest = store.ensureLoaded('images/a.png', () {});
      final oldEpoch = store.epoch;

      final newService = _FakeBookService();
      store.bind(newService, 'new');
      expect(store.epoch, greaterThan(oldEpoch));
      oldService.results['images/a.png']!.complete(Uint8List(0));
      await oldRequest;

      expect(store.state('images/a.png'), isNull);
      expect(newService.calls, 0);
    },
  );

  test('failed retries after the backoff window and succeeds', () async {
    BookImageStore.retryBackoff = [Duration.zero, Duration.zero];
    final service = _FakeBookService();
    service.responses['ok:r1.png'] = [
      Uint8List(0), // 第一次：空字节 → 失败
      Uint8List.fromList(_png1x1), // 退避归零后重试：合法 PNG → 成功
    ];
    store.bind(service, 'book');

    await store.ensureLoaded('ok:r1.png', () {});
    expect(store.state('ok:r1.png'), BookImageState.failed);
    expect(service.calls, 1);

    await store.ensureLoaded('ok:r1.png', () {});
    expect(store.state('ok:r1.png'), BookImageState.ready);
    expect(service.calls, 2);
    // 成功后失败记录清空
    expect(store.get('ok:r1.png'), isNotNull);
  });

  test('stable failed terminal state after max attempts', () async {
    BookImageStore.retryBackoff = [Duration.zero, Duration.zero];
    final service = _FakeBookService();
    service.responses['bad.png'] = [
      Uint8List(0),
      Uint8List(0),
      Uint8List(0),
    ];
    store.bind(service, 'book');

    await store.ensureLoaded('bad.png', () {}); // attempt 1
    await store.ensureLoaded('bad.png', () {}); // attempt 2
    await store.ensureLoaded('bad.png', () {}); // attempt 3 → 上限
    expect(service.calls, 3);
    expect(store.state('bad.png'), BookImageState.failed);

    // 第 4 次遇到：稳定终态，不再发请求
    await store.ensureLoaded('bad.png', () {});
    expect(service.calls, 3);
  });

  test('prewarmManifest returns terminal states per href', () async {
    BookImageStore.retryBackoff = [Duration.zero, Duration.zero];
    final service = _FakeBookService();
    service.responses['ok:m1.png'] = [Uint8List.fromList(_png1x1)];
    service.responses['bad-m2.png'] = [Uint8List(0)];
    store.bind(service, 'book');

    final states = await store.prewarmManifest({'ok:m1.png', 'bad-m2.png'});
    expect(states['ok:m1.png'], BookImageState.ready);
    expect(states['bad-m2.png'], BookImageState.failed);
  });

  test('LRU eviction never disposes pinned images', () async {
    final service = _FakeBookService();
    store.bind(service, 'book');

    // pin 并加载 images/0.png（当前 FrameSet 引用）：
    // pin 集合只标记键，图片必须实际加载后 get 才非 null
    store.setPinned(['ok:pin0.png']);
    service.responses['ok:pin0.png'] = [Uint8List.fromList(_png1x1)];
    await store.ensureLoaded('ok:pin0.png', () {});

    // 填满缓存（上限 64）+ 溢出
    for (var i = 0; i < 70; i++) {
      service.responses['ok:fill$i.png'] = [Uint8List.fromList(_png1x1)];
      await store.ensureLoaded('ok:fill$i.png', () {});
    }

    // pinned 存活
    expect(store.get('ok:pin0.png'), isNotNull);
    // 最早的未 pin 条目被淘汰
    expect(store.get('ok:fill0.png'), isNull);
    // 最新条目存活
    expect(store.get('ok:fill69.png'), isNotNull);

    // 重新 pin 换绑：旧 pin 集合被原子替换
    store.setPinned(['ok:fill69.png']);
    for (var i = 70; i < 80; i++) {
      service.responses['ok:fill$i.png'] = [Uint8List.fromList(_png1x1)];
      await store.ensureLoaded('ok:fill$i.png', () {});
    }
    // 新 pin 存活（被淘汰的是旧未 pin 批次）
    expect(store.get('ok:fill69.png'), isNotNull);
  });
}
