import 'package:flutter/foundation.dart';

import '../../../../core/models/simple_models.dart';
import '../widgets/page_turn/page_turn_types.dart';

/// PageFrame 体系（对齐 docs/PAGE_FRAME_PRECACHE_AND_TEXTURE_CONSISTENCY_PLAN.md）
///
/// 把「页面结构」与「页面依赖的图片资源」组织成带身份、版本与就绪状态的
/// 不可变页面帧；卷曲动画只允许使用同一批次中已准备好的前后页，动画完成后
/// 原子提交目标帧，从根上消除内容重复与前后闪烁。
///
/// 不变量映射：
/// - 4：[PageFrame.usableForAnimation] —— 资源就绪或稳定 failed 才可启动动画
/// - 5：[FrameIdentity] —— 页身份必须含章节（不能只用章节内 pageIndex）
/// - 6：[PageFrame.configFingerprint] —— 配置变更后旧指纹帧不可复用

/// 帧内资源聚合状态。
///
/// 注意：越界语义由 [FrameSlot.outOfRange] 承载（越界不存在页面帧），
/// 不进入本枚举。
enum FrameResourceState { pending, loading, ready, failed }

/// 页面身份：bookId + 章节索引 + 章内页号 + 字符锚点区间
@immutable
class FrameIdentity {
  final String bookId;
  final int chapterIndex;
  final int pageIndex;
  final int startCharIndex;
  final int endCharIndex;

  const FrameIdentity({
    required this.bookId,
    required this.chapterIndex,
    required this.pageIndex,
    required this.startCharIndex,
    required this.endCharIndex,
  });

  factory FrameIdentity.of(String bookId, PageInfo page) => FrameIdentity(
        bookId: bookId,
        chapterIndex: page.chapterIndex,
        pageIndex: page.pageIndex,
        startCharIndex: page.startCharIndex,
        endCharIndex: page.endCharIndex,
      );

  /// 跨进程稳定的身份串（诊断日志用）
  String get key =>
      '$bookId#$chapterIndex/$pageIndex[$startCharIndex-$endCharIndex]';

  /// 与可见页对齐判定：章节/页/锚点三元等价即视为同一逻辑页
  /// （同位置换新实例——FFI 重算——不视为内容变化）。
  /// bookId 由调用方（session 校验）负责，这里只比页内身份。
  bool matchesPage(PageInfo page) =>
      page.chapterIndex == chapterIndex &&
      page.pageIndex == pageIndex &&
      page.startCharIndex == startCharIndex;
}

/// 页面资源清单：背景图 + 全部图片 entry 的去重引用
@immutable
class ResourceManifest {
  final Set<String> hrefs;

  const ResourceManifest(this.hrefs);

  factory ResourceManifest.of(PageInfo page) {
    final hrefs = <String>{};
    final bg = page.backgroundHref;
    if (bg != null && bg.isNotEmpty) hrefs.add(bg);
    for (final entry in page.entries) {
      final href = entry.resourceHref;
      if (href != null && href.isNotEmpty) hrefs.add(href);
    }
    return ResourceManifest(hrefs);
  }

  factory ResourceManifest.ofAll(Iterable<PageInfo> pages) {
    final hrefs = <String>{};
    for (final page in pages) {
      hrefs.addAll(ResourceManifest.of(page).hrefs);
    }
    return ResourceManifest(hrefs);
  }

  bool get isEmpty => hrefs.isEmpty;
}

/// 页面帧：页面结构数据 + 资源依赖 + 就绪状态 + 批次身份
@immutable
class PageFrame {
  final FrameIdentity identity;

  /// 排版/内容处理配置指纹（单一来源 ReaderNotifier.layoutFingerprint）
  final String configFingerprint;

  /// 会话世代（换书/设置/窗口变化递增）
  final int sessionEpoch;

  /// 异步请求代际（同会话内的批次标记）
  final int requestGeneration;

  final PageInfo page;
  final ResourceManifest manifest;
  final FrameResourceState resourceState;

  const PageFrame({
    required this.identity,
    required this.configFingerprint,
    required this.sessionEpoch,
    required this.requestGeneration,
    required this.page,
    required this.manifest,
    required this.resourceState,
  });

  bool get frameReady => resourceState == FrameResourceState.ready;

  /// 不变量 4：图片全部 ready（或稳定 failed）才可用于动画。
  /// failed 是稳定终态（恒画占位），不构成随机跳变源。
  bool get usableForAnimation =>
      resourceState == FrameResourceState.ready ||
      resourceState == FrameResourceState.failed;
}

/// 邻居槽位：缺失必须有明确原因，永不静默置 null。
///
/// - [outOfRange]：章首无 prev / 末章无 next（结构性边界）
/// - [loadFailed]：FFI 或图片层异常（可由后续发布自愈）
/// - frame==null 且两者皆 false：pending（加载中/降级发布占位）
@immutable
class FrameSlot {
  final PageFrame? frame;
  final bool outOfRange;
  final bool loadFailed;

  const FrameSlot.ready(PageFrame this.frame)
      : outOfRange = false,
        loadFailed = false;

  const FrameSlot.outOfRange()
      : frame = null,
        outOfRange = true,
        loadFailed = false;

  const FrameSlot.failed()
      : frame = null,
        outOfRange = false,
        loadFailed = true;

  const FrameSlot.pending()
      : frame = null,
        outOfRange = false,
        loadFailed = false;
}

/// 一次原子提交的三页帧集合 + 会话/配置身份
@immutable
class FrameSet {
  /// 发布序号（store 侧单调递增）
  final int setRevision;

  final PageFrame current;
  final FrameSlot previous;
  final FrameSlot next;
  final String configFingerprint;
  final int sessionEpoch;

  const FrameSet({
    required this.setRevision,
    required this.current,
    required this.previous,
    required this.next,
    required this.configFingerprint,
    required this.sessionEpoch,
  });

  /// 集合身份：epoch + 指纹 + 当前页身份（诊断与批次校验用）
  String get id => '$sessionEpoch|$configFingerprint|${current.identity.key}';

  FrameSlot slotFor(PageDirection direction) =>
      direction == PageDirection.prev ? previous : next;
}

/// 待决手势：门控未满足时挂起的翻页意图（不变量 4 的等待载体）
@immutable
class PendingTurnGesture {
  final PageDirection direction;
  final bool isTap;
  final DateTime registeredAt;
  final int epoch;

  const PendingTurnGesture({
    required this.direction,
    required this.isTap,
    required this.registeredAt,
    required this.epoch,
  });
}

/// 手势门控三态结果（避免 null 歧义）
sealed class TargetFrameResult {
  const TargetFrameResult();
}

/// 目标帧就绪，可启动动画
class TargetReady extends TargetFrameResult {
  final PageFrame frame;
  const TargetReady(this.frame);
}

/// 目标不可用动画（越界 / 邻居加载失败）→ 无动画直翻保功能
class TargetOutOfRange extends TargetFrameResult {
  const TargetOutOfRange();
}

/// 目标未就绪（模型滞后 / 资源未就绪）→ 挂起等待重试
class TargetWait extends TargetFrameResult {
  const TargetWait();
}

/// 槽位态诊断串（日志用，不含正文）
String frameSlotTrace(FrameSlot slot) {
  if (slot.outOfRange) return 'out-of-range';
  if (slot.loadFailed) return 'failed';
  final frame = slot.frame;
  if (frame == null) return 'pending';
  return '${frame.identity.chapterIndex}/${frame.identity.pageIndex}'
      '#${identityHashCode(frame.page)}/${frame.resourceState.name}';
}
