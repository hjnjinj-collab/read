import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/models/simple_models.dart';
import 'package:legado_flutter/features/reader/presentation/providers/page_frame.dart';
import 'package:legado_flutter/features/reader/presentation/providers/reader_render_state.dart';
import 'package:legado_flutter/features/reader/presentation/widgets/page_turn/page_turn_types.dart';

/// 测试工厂：构建页面与帧集合
PageInfo _page(int chapter, int index) => PageInfo(
      chapterIndex: chapter,
      pageIndex: index,
      startCharIndex: index * 100,
      endCharIndex: (index + 1) * 100,
    );

PageFrame _frame(
  ReaderRenderStateStore store,
  PageInfo page, {
  FrameResourceState state = FrameResourceState.ready,
  int generation = 1,
}) {
  return PageFrame(
    identity: FrameIdentity.of('book', page),
    configFingerprint: 'fp',
    sessionEpoch: store.sessionEpoch,
    requestGeneration: generation,
    page: page,
    manifest: ResourceManifest.of(page),
    resourceState: state,
  );
}

FrameSet _set(
  ReaderRenderStateStore store,
  PageInfo current, {
  FrameSlot? previous,
  FrameSlot? next,
  FrameResourceState state = FrameResourceState.ready,
}) {
  return FrameSet(
    setRevision: store.nextSetRevision(),
    current: _frame(store, current, state: state),
    previous: previous ?? const FrameSlot.pending(),
    next: next ?? const FrameSlot.pending(),
    configFingerprint: 'fp',
    sessionEpoch: store.sessionEpoch,
  );
}

void main() {
  group('ReaderRenderStateStore', () {
    test('viewport 更新不替换结构态 model', () {
      final store = ReaderRenderStateStore();
      store.publishFrameSet(_set(store, _page(0, 0)));
      final structural = store.model;

      store.publishViewport(
        width: 100,
        height: 200,
        startX: 0,
        startY: 0,
        touchX: 50,
        touchY: 0,
        direction: PageDirection.next,
        isAnimationRunning: true,
      );

      // 结构态引用不变
      expect(identical(structural, store.model), isTrue);
      // viewport 独立更新
      expect(store.viewport.animationProgress, closeTo(0.5, 1e-6));
    });

    test('publishFrameSet 原子发布三页帧与槽位态', () {
      final store = ReaderRenderStateStore();
      final current = _page(1, 4);

      store.publishFrameSet(_set(
        store,
        current,
        previous: FrameSlot.ready(_frame(store, _page(1, 3))),
        next: FrameSlot.ready(_frame(store, _page(1, 5))),
      ));

      final set = store.frameSet;
      expect(set, isNotNull);
      expect(set!.current.page, same(current));
      expect(set.previous.frame!.identity.pageIndex, 3);
      expect(set.next.frame!.identity.pageIndex, 5);
      expect(set.sessionEpoch, store.sessionEpoch);
      expect(set.configFingerprint, 'fp');
      // 越界/失败/pending 语义互斥
      expect(set.previous.outOfRange, isFalse);
      expect(set.previous.loadFailed, isFalse);
    });

    test('槽位缺失必须带明确原因：越界/失败/pending 可区分', () {
      const outOfRange = FrameSlot.outOfRange();
      const failed = FrameSlot.failed();
      const pending = FrameSlot.pending();

      expect(outOfRange.outOfRange, isTrue);
      expect(outOfRange.frame, isNull);
      expect(failed.loadFailed, isTrue);
      expect(failed.frame, isNull);
      expect(pending.frame, isNull);
      expect(pending.outOfRange, isFalse);
      expect(pending.loadFailed, isFalse);
    });

    test('publishViewport 计算归一化动画进度', () {
      final store = ReaderRenderStateStore();

      store.publishViewport(
        width: 400,
        height: 800,
        startX: 0,
        startY: 0,
        touchX: 200,
        touchY: 0,
        direction: PageDirection.next,
        isAnimationRunning: true,
      );
      expect(store.viewport.animationProgress, closeTo(0.5, 1e-6));

      // 进度限制在 [0, 1]
      store.publishViewport(
        width: 100,
        height: 100,
        startX: 0,
        startY: 0,
        touchX: 200,
        touchY: 300,
        direction: PageDirection.prev,
        isAnimationRunning: true,
      );
      expect(store.viewport.animationProgress, 1.0);
    });

    test('相同页重发时 setRevision 递增', () {
      final store = ReaderRenderStateStore();
      final page = _page(0, 1);

      store.publishFrameSet(_set(store, page));
      final first = store.frameSet!;

      store.publishFrameSet(_set(store, page));
      final second = store.frameSet!;

      expect(second.setRevision, greaterThan(first.setRevision));
      expect(store.frameSet, same(second));
    });

    test('advanceSession 清空 frameSet、置 dirty 并取消待决手势', () {
      final store = ReaderRenderStateStore();
      store.publishFrameSet(_set(store, _page(0, 0)));
      store.registerPendingTurn(PageDirection.next, isTap: true);
      expect(store.dirty, isFalse);
      expect(store.pendingTurn, isNotNull);

      store.advanceSession(sessionEpoch: 7, configFingerprint: 'fp2');

      expect(store.frameSet, isNull);
      expect(store.sessionEpoch, 7);
      expect(store.configFingerprint, 'fp2');
      expect(store.dirty, isTrue);
      expect(store.pendingTurn, isNull);
    });

    test('publishFrameSet 清除 dirty 标记', () {
      final store = ReaderRenderStateStore();
      store.advanceSession(sessionEpoch: 1, configFingerprint: 'fp');
      expect(store.dirty, isTrue);

      store.publishFrameSet(_set(store, _page(0, 0)));
      expect(store.dirty, isFalse);
    });

    test('待决手势：注册 → 消费（同集合才可取）→ 取消', () {
      final store = ReaderRenderStateStore();
      final set = _set(store, _page(0, 0));
      // 消费要求 identical 当前发布集合：先发布 set
      store.publishFrameSet(set);

      // 未登记时消费返回 null
      expect(store.consumePendingTurn(set), isNull);

      final gesture =
          store.registerPendingTurn(PageDirection.next, isTap: true);
      expect(gesture.direction, PageDirection.next);
      expect(gesture.isTap, isTrue);
      expect(gesture.epoch, store.sessionEpoch);

      // 传入非当前集合 → 保留待决
      final other = _set(store, _page(0, 1));
      expect(store.consumePendingTurn(other), isNull);
      expect(store.pendingTurn, isNotNull);

      // 传入当前集合 → 取出并清除
      final consumed = store.consumePendingTurn(set);
      expect(consumed, isNotNull);
      expect(store.pendingTurn, isNull);

      // 再次消费为空
      expect(store.consumePendingTurn(set), isNull);
    });

    test('待决手势在会话推进后失效（epoch 不匹配即丢弃）', () {
      final store = ReaderRenderStateStore();
      store.registerPendingTurn(PageDirection.prev, isTap: false);

      store.advanceSession(sessionEpoch: 9, configFingerprint: 'fp2');
      expect(store.pendingTurn, isNull);

      // 重新登记后取消
      store.registerPendingTurn(PageDirection.prev, isTap: false);
      store.cancelPendingTurn('timeout');
      expect(store.pendingTurn, isNull);
    });

    test('model listener 收到结构态更新', () {
      final store = ReaderRenderStateStore();
      final received = <ReaderRenderModel>[];

      store.addModelListener(received.add);

      store.publishFrameSet(_set(store, _page(0, 0)));

      expect(received.length, 1);
      expect(received.first.frameSet, same(store.frameSet));

      store.removeModelListener(received.add);
    });

    test('viewport listener 不收到结构态更新', () {
      final store = ReaderRenderStateStore();
      var viewportCount = 0;

      store.addViewportListener((_) => viewportCount++);

      store.publishFrameSet(_set(store, _page(0, 0)));

      expect(viewportCount, 0);
    });

    test('model listener 不收到 viewport 更新', () {
      final store = ReaderRenderStateStore();
      var modelCount = 0;

      store.addModelListener((_) => modelCount++);

      store.publishViewport(
        width: 100,
        height: 100,
        startX: 0,
        startY: 0,
        touchX: 50,
        touchY: 0,
        direction: PageDirection.next,
        isAnimationRunning: true,
      );

      expect(modelCount, 0);
    });

    test('publishEmpty 发布无 frame 占位并通知 listener', () {
      final store = ReaderRenderStateStore();
      final received = <ReaderRenderModel>[];
      store.addModelListener(received.add);

      store.publishEmpty(isLoading: true, message: '正在打开书籍…');

      expect(store.frameSet, isNull);
      expect(store.model.isLoading, isTrue);
      expect(store.model.message, '正在打开书籍…');
      expect(received.length, 1);
    });

    test('dispose 清理所有 listener', () {
      final store = ReaderRenderStateStore();
      var modelCount = 0;
      var viewportCount = 0;

      store.addModelListener((_) => modelCount++);
      store.addViewportListener((_) => viewportCount++);

      store.dispose();

      store.publishFrameSet(_set(store, _page(0, 0)));
      store.publishViewport(
        width: 100,
        height: 100,
        startX: 0,
        startY: 0,
        touchX: 50,
        touchY: 0,
        direction: PageDirection.next,
        isAnimationRunning: false,
      );

      expect(modelCount, 0);
      expect(viewportCount, 0);
    });
  });
}
