// M9.5 翻页会话（PageFlipSession）原子状态对象
//
// 替代 page_turn_composer 中散落的 8 个状态字段
// （_isActive / _holdingFinalFrame / _commitInFlight / _turnEndInFlight /
//   _settledFrame / _settledReleaseScheduled / _settledSafetyTimer / _turnController）
// 为单一不可变值对象，所有赋值通过 withXxx() 返回新实例。
//
// E1 范围（本 commit）：
// - 定义 PageFlipPhase 枚举 + PageFlipSession 值对象 + 不可变 setter 助手
// - 提供 `snapshotFromFlags` 工厂：从现存的散落 boolean 字段构造 Session
// - 提供诊断助手 `phaseFromFlags`：从 8 字段推断"应处相位"
// **不替换 page_turn_composer.dart 任何代码**——E1 是"工具就位"，
// 让 E2 在此基础上做"实际替换"。
//
// 设计动机（C/D 根因）：
// - page_turn_composer 现状用 _isActive/_holdingFinalFrame/_commitInFlight
//   三个 bool 字段描述相位，状态组合有 2^3=8 种，其中只有 3 种合法
//   （idle / dragging-or-animating / settled）；其余 5 种是 bug 来源
//   （如 _isActive=true && _holdingFinalFrame=true 同时出现 = commit 期
//   又被新拖拽激活 = C/D 根因的典型路径）。
// - 引入 phase enum + 不可变 Session 把"非法状态组合"在编译期消除。
//
// 后续子项：
// - E2：page_turn_composer 实际替换 8 字段为单一 _session，withXxx 调用
//   替代直接赋值，三态判断改为 session.phase 判断。
// - L：commit/取消/动画完成事件流从 Session API 暴露。
import 'package:flutter/widgets.dart';

import '../../../../../core/models/simple_models.dart';
import '../../providers/page_frame.dart';
import 'page_turn_controller.dart';
import 'page_turn_types.dart';

/// 翻页会话相位（仿 M3Reader idle/dragging/committing 扩展）
///
/// 5 个相位是互斥的：任意时刻仅一个为当前相位，**非法组合在编译期消除**。
enum PageFlipPhase {
  /// 无会话（初始 / 已 release 完成）
  idle,

  /// 用户正在拖拽（onDragStart 之后、onDragEnd 之前）
  dragging,

  /// 拖拽结束，自动播放动画中（_runAuto 中）
  animating,

  /// 动画完成，提交真实页码在途（_commitInFlight == true）
  committing,

  /// 提交完成，渲染定格帧（_holdingFinalFrame == true），
  /// 等 didUpdateWidget identity 匹配后撤定格 → idle
  settled,
}

/// 单次翻页会话的不可变状态对象
///
/// 字段语义一一对应原 page_turn_composer 的 8 个状态字段。
class PageFlipSession {
  /// 起始页（拖拽开始时的当前页）
  final PageInfo? sourcePage;

  /// 翻页方向
  final PageDirection direction;

  /// 目标帧（拖拽开始时从 render store 门控取出）
  final PageFrame? targetFrame;

  /// 当前相位
  final PageFlipPhase phase;

  /// 自动播放方向：true=正向翻完，false=回弹
  final bool autoIsTurn;

  /// 自动动画起始时的控制器进度
  final double autoFromProgress;

  /// 拖拽起手触点
  final Offset dragFirstTouch;

  /// 拖拽实时触点
  final Offset lastTouchLocal;

  /// 松手触点（自动播放插值起点）
  final Offset releaseTouch;

  /// 翻页提交后的定格帧
  final PageFrame? settledFrame;

  /// 定格释放是否已 postFrame 调度
  final bool settledReleaseScheduled;

  /// 翻页控制器引用（与 controller 生命周期解耦：setter 内部 stop+dispose）
  final PageTurnAnimationController? turnController;

  /// 尝试 ID：每次开始一次新翻页递增，旧 commit 重入检查使用
  final int attemptId;

  const PageFlipSession({
    required this.sourcePage,
    required this.direction,
    required this.targetFrame,
    required this.phase,
    required this.autoIsTurn,
    required this.autoFromProgress,
    required this.dragFirstTouch,
    required this.lastTouchLocal,
    required this.releaseTouch,
    required this.settledFrame,
    required this.settledReleaseScheduled,
    required this.turnController,
    required this.attemptId,
  });

  /// 工厂：空会话（idle phase）
  factory PageFlipSession.idle() => const PageFlipSession(
        sourcePage: null,
        direction: PageDirection.none,
        targetFrame: null,
        phase: PageFlipPhase.idle,
        autoIsTurn: true,
        autoFromProgress: 0,
        dragFirstTouch: Offset.zero,
        lastTouchLocal: Offset.zero,
        releaseTouch: Offset.zero,
        settledFrame: null,
        settledReleaseScheduled: false,
        turnController: null,
        attemptId: 0,
      );

  /// 工厂：从 8 散落字段构造当前 Session 快照（E1 诊断/E2 迁移用）
  ///
  /// 不持有原字段引用——纯粹快照，避免"原字段改 → Session 变"误导。
  /// E2 替换 8 字段后此工厂可删除。
  factory PageFlipSession.snapshotFromFlags({
    required PageInfo? sourcePage,
    required PageDirection direction,
    required PageFrame? targetFrame,
    required bool isActive,
    required bool holdingFinalFrame,
    required bool commitInFlight,
    required bool turnEndInFlight,
    required PageFrame? settledFrame,
    required bool settledReleaseScheduled,
    required PageTurnAnimationController? turnController,
    required bool autoIsTurn,
    required double autoFromProgress,
    required Offset dragFirstTouch,
    required Offset lastTouchLocal,
    required Offset releaseTouch,
    required int attemptId,
  }) {
    return PageFlipSession(
      sourcePage: sourcePage,
      direction: direction,
      targetFrame: targetFrame,
      // 三态 → 5 相位映射：commit 优先于 settled 优先于 animating 优先于 dragging
      phase: PageFlipSession._phaseFromFlags(
        isActive: isActive,
        holdingFinalFrame: holdingFinalFrame,
        commitInFlight: commitInFlight,
        controllerAnimating: turnController?.isAnimating == true,
        settledFrame: settledFrame,
      ),
      autoIsTurn: autoIsTurn,
      autoFromProgress: autoFromProgress,
      dragFirstTouch: dragFirstTouch,
      lastTouchLocal: lastTouchLocal,
      releaseTouch: releaseTouch,
      settledFrame: settledFrame,
      settledReleaseScheduled: settledReleaseScheduled,
      turnController: turnController,
      attemptId: attemptId,
    );
  }

  /// 5 相位推断（私有；外部应使用 snapshotFromFlags）
  static PageFlipPhase _phaseFromFlags({
    required bool isActive,
    required bool holdingFinalFrame,
    required bool commitInFlight,
    required bool controllerAnimating,
    required PageFrame? settledFrame,
  }) {
    if (commitInFlight) return PageFlipPhase.committing;
    if (holdingFinalFrame && settledFrame != null) {
      return PageFlipPhase.settled;
    }
    if (controllerAnimating) return PageFlipPhase.animating;
    if (isActive) return PageFlipPhase.dragging;
    return PageFlipPhase.idle;
  }

  /// 诊断助手：从 8 散落字段直接推断"应处相位"
  /// E1 用于 build 入口 trace 一次诊断；E2 替换后此助手可删除。
  static PageFlipPhase phaseFromFlags({
    required bool isActive,
    required bool holdingFinalFrame,
    required bool commitInFlight,
    required bool controllerAnimating,
    required PageFrame? settledFrame,
  }) {
    return _phaseFromFlags(
      isActive: isActive,
      holdingFinalFrame: holdingFinalFrame,
      commitInFlight: commitInFlight,
      controllerAnimating: controllerAnimating,
      settledFrame: settledFrame,
    );
  }

  // ── 查询助手 ──

  /// 是否处于"非 idle"（C/D 根因的双重 commit 主要因旧 commit 仍
  /// 处于非 idle 时未拦截新手势）
  bool get isActive =>
      phase != PageFlipPhase.idle;

  /// 是否可接受新手势（与原 `!_isActive && !_holdingFinalFrame &&
  /// !_commitInFlight` 语义等价）
  bool get acceptsNewGesture => phase == PageFlipPhase.idle;

  /// 是否持有定格帧
  bool get isHoldingFinal => phase == PageFlipPhase.settled;

  /// 是否在 commit 提交在途
  bool get isCommitting => phase == PageFlipPhase.committing;

  /// 控制器是否正在动画
  bool get isControllerAnimating =>
      turnController?.isAnimating == true;

  // ── 不可变 setter：每次返回新实例 ──
  //
  // E1 仅定义 API 不调用；E2 在 page_turn_composer 替换原赋值点时使用。

  PageFlipSession withPhase(PageFlipPhase next) => PageFlipSession(
        sourcePage: sourcePage,
        direction: direction,
        targetFrame: targetFrame,
        phase: next,
        autoIsTurn: autoIsTurn,
        autoFromProgress: autoFromProgress,
        dragFirstTouch: dragFirstTouch,
        lastTouchLocal: lastTouchLocal,
        releaseTouch: releaseTouch,
        settledFrame: settledFrame,
        settledReleaseScheduled: settledReleaseScheduled,
        turnController: turnController,
        attemptId: attemptId,
      );

  PageFlipSession withDirection(PageDirection next) => PageFlipSession(
        sourcePage: sourcePage,
        direction: next,
        targetFrame: targetFrame,
        phase: phase,
        autoIsTurn: autoIsTurn,
        autoFromProgress: autoFromProgress,
        dragFirstTouch: dragFirstTouch,
        lastTouchLocal: lastTouchLocal,
        releaseTouch: releaseTouch,
        settledFrame: settledFrame,
        settledReleaseScheduled: settledReleaseScheduled,
        turnController: turnController,
        attemptId: attemptId,
      );

  PageFlipSession withTarget(PageFrame? next) => PageFlipSession(
        sourcePage: sourcePage,
        direction: direction,
        targetFrame: next,
        phase: phase,
        autoIsTurn: autoIsTurn,
        autoFromProgress: autoFromProgress,
        dragFirstTouch: dragFirstTouch,
        lastTouchLocal: lastTouchLocal,
        releaseTouch: releaseTouch,
        settledFrame: settledFrame,
        settledReleaseScheduled: settledReleaseScheduled,
        turnController: turnController,
        attemptId: attemptId,
      );

  PageFlipSession withController(PageTurnAnimationController? next) {
    // 旧控制器在 setter 内部停掉并释放——避免"dispose 在用控制器"
    // （C 根因的常见引入点）。
    final old = turnController;
    if (old != null && !identical(old, next)) {
      old.stop();
      old.dispose();
    }
    return PageFlipSession(
      sourcePage: sourcePage,
      direction: direction,
      targetFrame: targetFrame,
      phase: phase,
      autoIsTurn: autoIsTurn,
      autoFromProgress: autoFromProgress,
      dragFirstTouch: dragFirstTouch,
      lastTouchLocal: lastTouchLocal,
      releaseTouch: releaseTouch,
      settledFrame: settledFrame,
      settledReleaseScheduled: settledReleaseScheduled,
      turnController: next,
      attemptId: attemptId,
    );
  }

  PageFlipSession withDragTouch(Offset first, Offset last) => PageFlipSession(
        sourcePage: sourcePage,
        direction: direction,
        targetFrame: targetFrame,
        phase: phase,
        autoIsTurn: autoIsTurn,
        autoFromProgress: autoFromProgress,
        dragFirstTouch: first,
        lastTouchLocal: last,
        releaseTouch: releaseTouch,
        settledFrame: settledFrame,
        settledReleaseScheduled: settledReleaseScheduled,
        turnController: turnController,
        attemptId: attemptId,
      );

  PageFlipSession withRelease(Offset touch, bool autoIsTurn,
          double autoFromProgress) =>
      PageFlipSession(
        sourcePage: sourcePage,
        direction: direction,
        targetFrame: targetFrame,
        phase: phase,
        autoIsTurn: autoIsTurn,
        autoFromProgress: autoFromProgress,
        dragFirstTouch: dragFirstTouch,
        lastTouchLocal: lastTouchLocal,
        releaseTouch: touch,
        settledFrame: settledFrame,
        settledReleaseScheduled: settledReleaseScheduled,
        turnController: turnController,
        attemptId: attemptId,
      );

  PageFlipSession withSettledFrame(PageFrame? next) => PageFlipSession(
        sourcePage: sourcePage,
        direction: direction,
        targetFrame: targetFrame,
        phase: phase,
        autoIsTurn: autoIsTurn,
        autoFromProgress: autoFromProgress,
        dragFirstTouch: dragFirstTouch,
        lastTouchLocal: lastTouchLocal,
        releaseTouch: releaseTouch,
        settledFrame: next,
        settledReleaseScheduled: settledReleaseScheduled,
        turnController: turnController,
        attemptId: attemptId,
      );

  PageFlipSession withSettledReleaseScheduled(bool scheduled) =>
      PageFlipSession(
        sourcePage: sourcePage,
        direction: direction,
        targetFrame: targetFrame,
        phase: phase,
        autoIsTurn: autoIsTurn,
        autoFromProgress: autoFromProgress,
        dragFirstTouch: dragFirstTouch,
        lastTouchLocal: lastTouchLocal,
        releaseTouch: releaseTouch,
        settledFrame: settledFrame,
        settledReleaseScheduled: scheduled,
        turnController: turnController,
        attemptId: attemptId,
      );

  PageFlipSession withAttemptId(int id) => PageFlipSession(
        sourcePage: sourcePage,
        direction: direction,
        targetFrame: targetFrame,
        phase: phase,
        autoIsTurn: autoIsTurn,
        autoFromProgress: autoFromProgress,
        dragFirstTouch: dragFirstTouch,
        lastTouchLocal: lastTouchLocal,
        releaseTouch: releaseTouch,
        settledFrame: settledFrame,
        settledReleaseScheduled: settledReleaseScheduled,
        turnController: turnController,
        attemptId: id,
      );
}
