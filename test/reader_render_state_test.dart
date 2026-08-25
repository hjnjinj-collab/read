import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/models/simple_models.dart';
import 'package:legado_flutter/features/reader/presentation/providers/reader_render_state.dart';
import 'package:legado_flutter/features/reader/presentation/widgets/page_turn/page_turn_types.dart';

void main() {
  group('ReaderRenderStateStore', () {
    test('viewport 更新不替换结构态 model', () {
      final store = ReaderRenderStateStore();
      store.publishStructure(
        currentPage: const PageInfo(
          pageIndex: 0,
          startCharIndex: 0,
          endCharIndex: 100,
        ),
        durPageIndex: 0,
      );
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

    test('publishStructure 快照三页数据', () {
      final store = ReaderRenderStateStore();
      final current = const PageInfo(
        pageIndex: 4,
        startCharIndex: 400,
        endCharIndex: 500,
      );

      store.publishStructure(
        previousPage: const PageInfo(
          pageIndex: 3,
          startCharIndex: 300,
          endCharIndex: 400,
        ),
        currentPage: current,
        nextPage: const PageInfo(
          pageIndex: 5,
          startCharIndex: 500,
          endCharIndex: 600,
        ),
        durPageIndex: 4,
        isLoading: true,
        message: '加载中…',
      );

      final model = store.model;
      expect(model.durPageIndex, 4);
      expect(model.currentPage?.page, same(current));
      expect(model.previousPage?.page.pageIndex, 3);
      expect(model.nextPage?.page.pageIndex, 5);
      expect(model.isLoading, isTrue);
      expect(model.message, '加载中…');
    });

    test('publishViewport 计算归一化动画进度', () {
      final store = ReaderRenderStateStore();

      // 水平 50% 进度
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

    test('相同 PageInfo 实例重发时 revision 递增', () {
      final store = ReaderRenderStateStore();
      final page = const PageInfo(
        pageIndex: 1,
        startCharIndex: 0,
        endCharIndex: 100,
      );

      store.publishStructure(currentPage: page, durPageIndex: 1);
      final first = store.model.currentPage!;

      // 同一实例再发一次
      store.publishStructure(currentPage: page, durPageIndex: 1);
      final second = store.model.currentPage!;

      expect(identical(page, second.page), isTrue);
      expect(second.revision, greaterThan(first.revision));
      expect(first == second, isFalse); // 不同 ReaderRenderPage
    });

    test('publishStructure 快照选择区间', () {
      final store = ReaderRenderStateStore();
      const start = ReaderTextPosition(
        relativePage: 0,
        lineIndex: 2,
        columnIndex: 5,
      );
      const end = ReaderTextPosition(
        relativePage: 0,
        lineIndex: 2,
        columnIndex: 10,
      );

      store.publishStructure(
        currentPage: const PageInfo(
          pageIndex: 0,
          startCharIndex: 0,
          endCharIndex: 100,
        ),
        selectionStart: start,
        selectionEnd: end,
      );

      final selection = store.model.selection;
      expect(selection, isNotNull);
      expect(selection!.start.lineIndex, 2);
      expect(selection.end.columnIndex, 10);

      // 后续发布不带选择 → 清除
      store.publishStructure(
        currentPage: const PageInfo(
          pageIndex: 1,
          startCharIndex: 100,
          endCharIndex: 200,
        ),
      );
      expect(store.model.selection, isNull);
    });

    test('model listener 收到结构态更新', () {
      final store = ReaderRenderStateStore();
      final received = <ReaderRenderModel>[];

      store.addModelListener(received.add);

      store.publishStructure(
        currentPage: const PageInfo(
          pageIndex: 0,
          startCharIndex: 0,
          endCharIndex: 100,
        ),
      );

      expect(received.length, 1);
      expect(received.first.currentPage?.page.pageIndex, 0);

      store.removeModelListener(received.add);
    });

    test('viewport listener 不收到结构态更新', () {
      final store = ReaderRenderStateStore();
      var viewportCount = 0;

      store.addViewportListener((_) => viewportCount++);

      store.publishStructure(
        currentPage: const PageInfo(
          pageIndex: 0,
          startCharIndex: 0,
          endCharIndex: 100,
        ),
      );

      // viewport listener 不应被结构态更新触发
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

      // model listener 不应被 viewport 更新触发
      expect(modelCount, 0);
    });

    test('dispose 清理所有 listener', () {
      final store = ReaderRenderStateStore();
      var modelCount = 0;
      var viewportCount = 0;

      store.addModelListener((_) => modelCount++);
      store.addViewportListener((_) => viewportCount++);

      store.dispose();

      store.publishStructure(
        currentPage: const PageInfo(
          pageIndex: 0,
          startCharIndex: 0,
          endCharIndex: 100,
        ),
      );
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
