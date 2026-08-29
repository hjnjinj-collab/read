import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/models/simple_models.dart';
import 'package:legado_flutter/features/reader/presentation/providers/page_frame.dart';
import 'package:legado_flutter/features/reader/presentation/widgets/page_turn/page_turn_types.dart';

PageInfo _page(
  int chapter,
  int index, {
  String? backgroundHref,
  List<String> images = const [],
}) {
  return PageInfo(
    chapterIndex: chapter,
    pageIndex: index,
    backgroundHref: backgroundHref,
    entries: [
      for (final href in images)
        PageEntry(
          resourceHref: href,
          x: 0,
          y: 0,
          width: 1,
          height: 1,
        ),
    ],
    startCharIndex: index * 100,
    endCharIndex: (index + 1) * 100,
  );
}

PageFrame _frame(
  PageInfo page, {
  FrameResourceState state = FrameResourceState.ready,
  int sessionEpoch = 1,
  int generation = 1,
  String fingerprint = 'fp',
  String bookId = 'book',
}) {
  return PageFrame(
    identity: FrameIdentity.of(bookId, page),
    configFingerprint: fingerprint,
    sessionEpoch: sessionEpoch,
    requestGeneration: generation,
    page: page,
    manifest: ResourceManifest.of(page),
    resourceState: state,
  );
}

FrameSet _set(
  PageFrame current, {
  FrameSlot? previous,
  FrameSlot? next,
  int sessionEpoch = 1,
  String fingerprint = 'fp',
}) {
  return FrameSet(
    setRevision: 1,
    current: current,
    previous: previous ?? const FrameSlot.pending(),
    next: next ?? const FrameSlot.pending(),
    configFingerprint: fingerprint,
    sessionEpoch: sessionEpoch,
  );
}

void main() {
  group('FrameIdentity', () {
    test('章节必须参与身份（不变量 5）：同 pageIndex 跨章不匹配', () {
      final identity = FrameIdentity.of('book', _page(3, 0));
      expect(identity.matchesPage(_page(3, 0)), isTrue);
      expect(identity.matchesPage(_page(4, 0)), isFalse);
    });

    test('同位置换新实例（FFI 重算）视为同一逻辑页', () {
      final identity = FrameIdentity.of('book', _page(1, 5));
      // 相同 chapter/pageIndex/startCharIndex，不同实例与 endChar
      final reflowed = PageInfo(
        chapterIndex: 1,
        pageIndex: 5,
        startCharIndex: 500,
        endCharIndex: 999,
      );
      expect(identity.matchesPage(reflowed), isTrue);
      // 锚点漂移（设置变更重排）不匹配
      final drifted = PageInfo(
        chapterIndex: 1,
        pageIndex: 5,
        startCharIndex: 505,
        endCharIndex: 600,
      );
      expect(identity.matchesPage(drifted), isFalse);
    });

    test('key 含书/章/页/锚点，诊断可读', () {
      final identity = FrameIdentity.of('book', _page(2, 3));
      expect(identity.key, 'book#2/3[300-400]');
    });
  });

  group('ResourceManifest', () {
    test('背景 + 图片 entry 去重收集', () {
      final manifest = ResourceManifest.of(_page(
        0,
        0,
        backgroundHref: 'images/bg.png',
        images: ['images/a.png', 'images/a.png', 'images/b.png'],
      ));
      expect(manifest.hrefs, {'images/bg.png', 'images/a.png', 'images/b.png'});
    });

    test('ofAll 跨页合并去重', () {
      final manifest = ResourceManifest.ofAll([
        _page(0, 0, backgroundHref: 'images/bg.png'),
        _page(0, 1, images: ['images/a.png']),
        _page(0, 2, images: ['images/a.png']),
      ]);
      expect(manifest.hrefs, {'images/bg.png', 'images/a.png'});
    });

    test('纯文本页 manifest 为空', () {
      expect(ResourceManifest.of(_page(0, 0)).isEmpty, isTrue);
    });
  });

  group('PageFrame', () {
    test('usableForAnimation：ready 与稳定 failed 可启动，pending/loading 不可（不变量 4）', () {
      final page = _page(0, 0);
      expect(
        _frame(page, state: FrameResourceState.ready).usableForAnimation,
        isTrue,
      );
      expect(
        _frame(page, state: FrameResourceState.failed).usableForAnimation,
        isTrue,
      );
      expect(
        _frame(page, state: FrameResourceState.loading).usableForAnimation,
        isFalse,
      );
      expect(
        _frame(page, state: FrameResourceState.pending).usableForAnimation,
        isFalse,
      );
    });

    test('帧携带批次身份：epoch/指纹/代际', () {
      final frame = _frame(_page(0, 0), sessionEpoch: 3, generation: 7);
      expect(frame.sessionEpoch, 3);
      expect(frame.requestGeneration, 7);
      expect(frame.configFingerprint, 'fp');
    });
  });

  group('FrameSet', () {
    test('id 由 epoch/指纹/当前页身份组成', () {
      final set = _set(_frame(_page(2, 3)));
      expect(set.id, contains('1|fp|book#2/3[300-400]'));
    });

    test('slotFor 按方向取槽', () {
      final current = _frame(_page(1, 4));
      final prev = FrameSlot.ready(_frame(_page(1, 3)));
      final next = const FrameSlot.outOfRange();
      final set = _set(current, previous: prev, next: next);

      expect(set.slotFor(PageDirection.prev), same(prev));
      expect(set.slotFor(PageDirection.next), same(next));
    });
  });

  group('手势门控协议（场景复现：store + 门控数据，无 FFI）', () {
    test('场景2 快速连翻：provisional 发布后 next=pending → 等待而非错帧', () {
      // 模拟：采纳 P4 后同步预发布 provisional（next 槽 pending），
      // 真实邻居尚未加载。此时手势门控数据不得提供可动画帧。
      final provisionalNext = const FrameSlot.pending();
      final set = _set(
        _frame(_page(1, 4)),
        previous: FrameSlot.ready(_frame(_page(1, 3))),
        next: provisionalNext,
      );
      final slot = set.slotFor(PageDirection.next);
      expect(slot.frame, isNull);
      expect(slot.outOfRange, isFalse);
      // 门控判定：frame==null → TargetWait（等待补全发布），不启动动画
    });

    test('场景2 补全发布后 next 槽就绪 → 可启动', () {
      final set = _set(
        _frame(_page(1, 4)),
        previous: FrameSlot.ready(_frame(_page(1, 3))),
        next: FrameSlot.ready(_frame(_page(1, 5))),
      );
      final slot = set.slotFor(PageDirection.next);
      expect(slot.frame, isNotNull);
      expect(slot.frame!.usableForAnimation, isTrue);
    });

    test('场景3 邻居加载失败 → 槽位标记 failed（可直翻，不悬挂）', () {
      final set = _set(
        _frame(_page(1, 4)),
        next: const FrameSlot.failed(),
      );
      final slot = set.slotFor(PageDirection.next);
      expect(slot.loadFailed, isTrue);
      expect(slot.frame, isNull);
    });

    test('场景4 设置变更：旧指纹集合与 store 身份不匹配 → 门控拒绝', () {
      // store 已 advanceSession 到 fp2/epoch2；旧集合仍是 fp1/epoch1
      final storeEpoch = 2;
      final storeFp = 'fp2';
      final staleSet = _set(
        _frame(_page(1, 4), sessionEpoch: 1, fingerprint: 'fp1'),
        next: FrameSlot.ready(_frame(_page(1, 5), fingerprint: 'fp1')),
      );
      // 门控前置校验（composer _targetFrameFor 的等价判定）
      final stale = staleSet.sessionEpoch != storeEpoch ||
          staleSet.configFingerprint != storeFp;
      expect(stale, isTrue);
    });

    test('场景5 adopt 批次校验：identical 槽位帧 + epoch/指纹/代际一致', () {
      final target = _page(1, 5);
      final targetFrame = _frame(target, generation: 3);
      final set = _set(
        _frame(_page(1, 4), generation: 3),
        next: FrameSlot.ready(targetFrame),
      );

      // 模拟 adopt 第一道校验
      final batchOk = identical(set.next.frame!.page, target) &&
          set.sessionEpoch == 1 &&
          set.configFingerprint == 'fp' &&
          set.current.requestGeneration == 3;
      expect(batchOk, isTrue);

      // 旧批次邻居（不同实例）→ identical 失败 → 拒绝采纳
      final staleNeighbor = _frame(_page(1, 5), generation: 2);
      final batchStale = identical(staleNeighbor.page, target);
      expect(batchStale, isFalse);
    });

    test('provisional 预发布槽位映射：旧当前帧降级为 previous', () {
      // 采纳 P4：current=P4 帧，previous=旧当前 P3 帧，next=pending
      final adopted = _frame(_page(1, 4), generation: 3);
      final oldCurrent = _frame(_page(1, 3), generation: 3);
      final provisional = _set(
        adopted,
        previous: FrameSlot.ready(oldCurrent),
        next: const FrameSlot.pending(),
      );
      expect(provisional.current.identity.matchesPage(_page(1, 4)), isTrue);
      expect(provisional.previous.frame!.identity.matchesPage(_page(1, 3)),
          isTrue);
      expect(provisional.next.frame, isNull);
    });

    test('frameSlotTrace 输出槽位态诊断串', () {
      expect(frameSlotTrace(const FrameSlot.outOfRange()), 'out-of-range');
      expect(frameSlotTrace(const FrameSlot.failed()), 'failed');
      expect(frameSlotTrace(const FrameSlot.pending()), 'pending');
      final ready = frameSlotTrace(FrameSlot.ready(_frame(_page(1, 4))));
      expect(ready, contains('1/4'));
      expect(ready, contains('ready'));
    });
  });
}
