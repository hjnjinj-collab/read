// M9.5-E1 PageFlipSession 单元测试
//
// 验证：
// - 5 相位推断（从 8 散落字段）
// - 不可变 setter 语义（旧引用不随新实例变化）
// - acceptsNewGesture / isActive / isHoldingFinal / isCommitting 查询助手
//
// 不测试 controller stop/dispose（需真 AnimationController，E2 替换时跑集成测）
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/features/reader/presentation/widgets/page_turn/page_flip_session.dart';
import 'package:legado_flutter/features/reader/presentation/widgets/page_turn/page_turn_types.dart';

void main() {
  group('PageFlipSession 5 相位推断', () {
    test('idle：无任何标志置位', () {
      final phase = PageFlipSession.phaseFromFlags(
        isActive: false,
        holdingFinalFrame: false,
        commitInFlight: false,
        controllerAnimating: false,
        settledFrame: null,
      );
      expect(phase, PageFlipPhase.idle);
    });

    test('dragging：isActive=true，无 commit/settled/animation', () {
      final phase = PageFlipSession.phaseFromFlags(
        isActive: true,
        holdingFinalFrame: false,
        commitInFlight: false,
        controllerAnimating: false,
        settledFrame: null,
      );
      expect(phase, PageFlipPhase.dragging);
    });

    test('animating：isActive=true + controllerAnimating=true', () {
      final phase = PageFlipSession.phaseFromFlags(
        isActive: true,
        holdingFinalFrame: false,
        commitInFlight: false,
        controllerAnimating: true,
        settledFrame: null,
      );
      expect(phase, PageFlipPhase.animating);
    });

    test('committing：commitInFlight=true 优先于其他', () {
      // 即使 isActive=true 也不能覆盖 committing
      final phase = PageFlipSession.phaseFromFlags(
        isActive: true,
        holdingFinalFrame: true,
        commitInFlight: true,
        controllerAnimating: false,
        settledFrame: null,
      );
      expect(phase, PageFlipPhase.committing);
    });

    test('settled：holdingFinalFrame=true + settledFrame=null 退化到 idle', () {
      // 非法组合：holdingFinalFrame=true 但 settledFrame=null
      // 推断逻辑不报 settled，保守回退到 idle
      final phase = PageFlipSession.phaseFromFlags(
        isActive: false,
        holdingFinalFrame: true,
        commitInFlight: false,
        controllerAnimating: false,
        settledFrame: null,
      );
      expect(phase, PageFlipPhase.idle);
    });

    test('非法组合优先级：commit > 其它', () {
      // 8 字段全 true 时应给出唯一合法相位
      final phase = PageFlipSession.phaseFromFlags(
        isActive: true,
        holdingFinalFrame: true,
        commitInFlight: true,
        controllerAnimating: true,
        settledFrame: null,
      );
      expect(phase, PageFlipPhase.committing);
    });
  });

  group('PageFlipSession 不可变 setter', () {
    test('withPhase 返回新实例，旧实例 phase 不变', () {
      final s1 = PageFlipSession.idle();
      final s2 = s1.withPhase(PageFlipPhase.dragging);
      expect(s1.phase, PageFlipPhase.idle);
      expect(s2.phase, PageFlipPhase.dragging);
      expect(identical(s1, s2), isFalse);
    });

    test('withDirection 保留其他字段', () {
      final s1 = PageFlipSession.idle().withDragTouch(
        const Offset(10, 20),
        const Offset(15, 25),
      );
      final s2 = s1.withDirection(PageDirection.next);
      expect(s2.direction, PageDirection.next);
      expect(s2.dragFirstTouch, const Offset(10, 20));
      expect(s2.lastTouchLocal, const Offset(15, 25));
    });

    test('withDragTouch 同时更新起手/实时触点', () {
      final s1 = PageFlipSession.idle();
      final s2 = s1.withDragTouch(
        const Offset(100, 200),
        const Offset(110, 210),
      );
      expect(s2.dragFirstTouch, const Offset(100, 200));
      expect(s2.lastTouchLocal, const Offset(110, 210));
    });

    test('withRelease 更新松手触点+自动播放参数', () {
      final s1 = PageFlipSession.idle();
      final s2 = s1.withRelease(
        const Offset(50, 60),
        false, // autoIsTurn
        0.3, // autoFromProgress
      );
      expect(s2.releaseTouch, const Offset(50, 60));
      expect(s2.autoIsTurn, isFalse);
      expect(s2.autoFromProgress, 0.3);
    });

    test('withAttemptId 用于 commit 重入检查', () {
      final s1 = PageFlipSession.idle();
      final s2 = s1.withAttemptId(7);
      expect(s2.attemptId, 7);
      // 旧实例 attemptId 仍为 0（不可变）
      expect(s1.attemptId, 0);
    });

    test('chain 多 setter 链式调用结果稳定', () {
      final s = PageFlipSession.idle()
          .withPhase(PageFlipPhase.dragging)
          .withDirection(PageDirection.next)
          .withAttemptId(3)
          .withDragTouch(const Offset(1, 2), const Offset(3, 4));
      expect(s.phase, PageFlipPhase.dragging);
      expect(s.direction, PageDirection.next);
      expect(s.attemptId, 3);
      expect(s.dragFirstTouch, const Offset(1, 2));
      expect(s.lastTouchLocal, const Offset(3, 4));
    });
  });

  group('PageFlipSession 查询助手', () {
    test('acceptsNewGesture 仅在 idle 接受', () {
      final idle = PageFlipSession.idle();
      expect(idle.acceptsNewGesture, isTrue);
      expect(idle.isActive, isFalse);
      expect(idle.isHoldingFinal, isFalse);
      expect(idle.isCommitting, isFalse);

      final dragging = idle.withPhase(PageFlipPhase.dragging);
      expect(dragging.acceptsNewGesture, isFalse);
      expect(dragging.isActive, isTrue);

      final settled = idle.withPhase(PageFlipPhase.settled);
      expect(settled.acceptsNewGesture, isFalse);
      expect(settled.isHoldingFinal, isTrue);

      final committing = idle.withPhase(PageFlipPhase.committing);
      expect(committing.acceptsNewGesture, isFalse);
      expect(committing.isCommitting, isTrue);
    });

    test('isControllerAnimating 委托 turnController（null 安全）', () {
      final s = PageFlipSession.idle();
      expect(s.isControllerAnimating, isFalse);
    });
  });

  group('PageFlipSession.idle 工厂', () {
    test('所有字段归零', () {
      final s = PageFlipSession.idle();
      expect(s.sourcePage, isNull);
      expect(s.direction, PageDirection.none);
      expect(s.targetFrame, isNull);
      expect(s.phase, PageFlipPhase.idle);
      expect(s.autoIsTurn, isTrue);
      expect(s.autoFromProgress, 0.0);
      expect(s.dragFirstTouch, Offset.zero);
      expect(s.lastTouchLocal, Offset.zero);
      expect(s.releaseTouch, Offset.zero);
      expect(s.settledFrame, isNull);
      expect(s.settledReleaseScheduled, isFalse);
      expect(s.turnController, isNull);
      expect(s.attemptId, 0);
    });
  });
}
