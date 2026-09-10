import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../../core/database/app_database.dart' show Note;
import '../../../../core/models/simple_models.dart';
import '../../../../core/services/measure_text_service.dart';
import '../../../../core/services/reader_font.dart';
import '../services/book_image_store.dart';
import '../diagnostics/reader_trace.dart';

class ReaderPageWidget extends StatefulWidget {
  final PageInfo pageInfo;

  /// 字形开关（纯绘制期过滤：粗/斜按用户设置应用，下划线恒应用）
  final bool applyBold;
  final bool applyItalic;

  /// TXT 章节标题加粗（粗体开关 && 非 EPUB；EPUB 章首行不加粗）
  final bool applyTitleBold;

  /// 排版基准（M7 与 Rust 同源：替换硬编码 18/1.5，保证绘制与断行一致）
  final double baseFontSize;
  final double baseLineHeight;

  /// A31: 当前章节的笔记列表（用于绘制高亮矩形）
  final List<Note> notes;

  const ReaderPageWidget({
    Key? key,
    required this.pageInfo,
    this.applyBold = true,
    this.applyItalic = true,
    this.applyTitleBold = false,
    this.baseFontSize = 18.0,
    this.baseLineHeight = 1.5,
    this.notes = const [],
  }) : super(key: key);

  @override
  State<ReaderPageWidget> createState() => _ReaderPageWidgetState();
}

class _ReaderPageWidgetState extends State<ReaderPageWidget> {
  /// 图片异步解码完成后的重绘信号（传给 CustomPainter.repaint）
  final ValueNotifier<int> _repaintTick = ValueNotifier<int>(0);

  @override
  void dispose() {
    _repaintTick.dispose();
    super.dispose();
  }

  void _onImageReady() {
    readerTrace('image.callback', {
      'page':
          '${widget.pageInfo.chapterIndex}/${widget.pageInfo.pageIndex}#${readerPageId(widget.pageInfo)}',
    });
    _repaintTick.value++;
    // 帧末重绘，避免在回调栈内直接标记
    SchedulerBinding.instance.scheduleFrame();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: PagePainter(
        widget.pageInfo,
        repaint: _repaintTick,
        onImageNeeded: _onImageReady,
        applyBold: widget.applyBold,
        applyItalic: widget.applyItalic,
        applyTitleBold: widget.applyTitleBold,
        baseFontSize: widget.baseFontSize,
        baseLineHeight: widget.baseLineHeight,
        notes: widget.notes,
      ),
      size: Size.infinite,
    );
  }
}

/// 页面绘制器：先画整页背景（EPUB 装饰页），再按 entries 绘制文本/图片
class PagePainter extends CustomPainter {
  final PageInfo pageInfo;
  final VoidCallback onImageNeeded;
  final bool applyBold;
  final bool applyItalic;
  final bool applyTitleBold;
  final double baseFontSize;
  final double baseLineHeight;

  /// A31: 当前章节的笔记列表（用于绘制高亮矩形）
  final List<Note> notes;

  /// 构造期捕获的主题版本号（2026-09-04 P1：切主题后 widget 重建 →
  /// 新 painter 携带新 revision → shouldRepaint 命中重绘）
  final int themeRevision = PageContentRenderer.themeRevision;

  // 纸色底常量已公开到 PageContentRenderer.paperColor（v16.9.3：快照同源使用）

  PagePainter(
    this.pageInfo, {
    required ValueNotifier<int> repaint,
    required this.onImageNeeded,
    this.applyBold = true,
    this.applyItalic = true,
    this.applyTitleBold = false,
    this.baseFontSize = 18.0,
    this.baseLineHeight = 1.5,
    this.notes = const [],
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    readerTrace('page.paint', {
      'page': '${pageInfo.chapterIndex}/${pageInfo.pageIndex}',
      'pageId': readerPageId(pageInfo),
      'entries': pageInfo.entries.length,
      'fingerprint': readerPageFingerprint([
        ...pageInfo.entries
            .take(3)
            .map((entry) => entry.text ?? entry.resourceHref ?? ''),
        pageInfo.backgroundHref ?? '',
      ]),
      'summary': readerPageSummary(pageInfo.entries),
    });
    canvas.drawRect(Offset.zero & size, Paint()..color = PageContentRenderer.paperColor);
    PageContentRenderer.paintPage(
      canvas,
      pageInfo,
      size: size,
      onImageNeeded: onImageNeeded,
      applyBold: applyBold,
      applyItalic: applyItalic,
      applyTitleBold: applyTitleBold,
      baseFontSize: baseFontSize,
      baseLineHeight: baseLineHeight,
      notes: notes,
    );
    // M12 修复：paint 后同步 flush（阻塞式），确保下一页 layout 时能命中 cache
    // ignore: unawaited_futures
    MeasureTextService.instance.flushToRust();
  }

  @override
  bool shouldRepaint(PagePainter oldDelegate) {
    final repaint =
        oldDelegate.pageInfo != pageInfo ||
        oldDelegate.applyBold != applyBold ||
        oldDelegate.applyItalic != applyItalic ||
        oldDelegate.applyTitleBold != applyTitleBold ||
        oldDelegate.baseFontSize != baseFontSize ||
        oldDelegate.baseLineHeight != baseLineHeight ||
        oldDelegate.notes != notes ||
        // 2026-09-04 P1 暗黑主题：静态主题切换感知（构造期捕获版本号比对）
        oldDelegate.themeRevision != themeRevision;
    return repaint;
  }
}

/// 阅读主题色板（2026-09-04 P1 暗黑主题）
///
/// 只覆盖**阅读内容区**（纸张/正文/注释/占位/表格线框/Scaffold 背景）；
/// 菜单与对话框保持系统亮色样式（MVP 范围，后续可扩展）。
class ReaderTheme {
  final String name;

  /// 纸色底（页面渲染 / 翻页快照 / 各 Painter 同源）
  final Color paperColor;

  /// 正文默认文字色（entry.color 未指定时）
  final Color textColor;

  /// 本章说灰字
  final Color commentColor;

  /// 图片解码占位块
  final Color placeholderColor;

  /// 表格单元格线框
  final Color tableFrameColor;

  /// 阅读页 Scaffold 背景（SafeArea 外区域）
  final Color scaffoldColor;

  /// 纸背底色（卷曲翻页背面镜像底，正面纸色加深）
  final Color paperBackColor;

  const ReaderTheme({
    required this.name,
    required this.paperColor,
    required this.textColor,
    required this.commentColor,
    required this.placeholderColor,
    required this.tableFrameColor,
    required this.scaffoldColor,
    required this.paperBackColor,
  });

  static const ReaderTheme light = ReaderTheme(
    name: 'light',
    paperColor: Color(0xFFF5F1E8),
    textColor: Colors.black,
    commentColor: Color(0xFF888888),
    placeholderColor: Color(0xFFDDDDDD),
    tableFrameColor: Color(0xFF999999),
    scaffoldColor: Color(0xFFF5F5DC),
    paperBackColor: Color(0xFFE9E3D5),
  );

  static const ReaderTheme dark = ReaderTheme(
    name: 'dark',
    paperColor: Color(0xFF1E1E1E),
    textColor: Color(0xFFCCCCCC),
    commentColor: Color(0xFF6E6E6E),
    placeholderColor: Color(0xFF3C3C3C),
    tableFrameColor: Color(0xFF555555),
    scaffoldColor: Color(0xFF121212),
    paperBackColor: Color(0xFF262626),
  );
}

/// 页面内容渲染器：供 PagePainter 与翻页动画 CurlPainter 共用
///
/// 从 PagePainter 提取的纯绘制逻辑——给定画布与页面数据直接绘制，
/// 不持有任何 Widget 状态。动画期间目标页未挂载为 Widget，由本渲染器
/// 按帧绘制到裁切区域内（对齐 legado Android 每帧直绘的做法）。
class PageContentRenderer {
  /// 当前阅读主题（2026-09-04 P1 暗黑主题：静态可变，启动/切换时赋值）
  static ReaderTheme theme = ReaderTheme.light;

  /// 主题版本号：每次切主题递增——PagePainter.shouldRepaint 以此感知
  /// 静态主题变化（painter 无法监听静态字段，经构造期捕获值比对）
  static int themeRevision = 0;

  /// 纸色底（正式页面渲染与翻页快照共用，v16.9.3 公开化）
  /// 2026-09-04 P1: const → getter，跟随当前主题（调用点无需改动）
  static Color get paperColor => theme.paperColor;

  /// 绘制背景与 entries（不含纸色底——调用方按需自绘）
  static void paintPage(
    Canvas canvas,
    PageInfo pageInfo, {
    required Size size,
    required VoidCallback onImageNeeded,
    bool applyBold = true,
    bool applyItalic = true,
    bool applyTitleBold = false,
    double baseFontSize = 18.0,
    double baseLineHeight = 1.5,
    List<Note> notes = const [],
  }) {
    // P0- 防回归/根因定位：绘制层首次进入时输出 entry.x + canvas 当前
    // 变换矩阵 + 调用栈。若 entry.x=20 但视觉贴左边，必有 canvas 平移
    // 在绘制前介入（curl 镜像残留、SafeArea 二次切边等）。静态节流：
    // 同一页面身份仅输出一次。
    _tracePaintGeometry(
      pageInfo,
      size,
      canvas,
      baseFontSize: baseFontSize,
      baseLineHeight: baseLineHeight,
    );
    // 整页背景：严格按 CSS background-size 语义绘制——
    // - cover/缺省：等比铺满窗口、溢出部分按 background-position 锚点裁切
    // - contain：完整显示
    // - stretch（100% 100%）：拉伸铺满
    // 不做任何桌面端替代策略（用户定论：样式表怎么写就怎么显示）
    final bgHref = pageInfo.backgroundHref;
    if (bgHref != null) {
      final bg = BookImageStore.instance.get(bgHref);
      if (bg != null) {
        _paintBackground(canvas, bg, Offset.zero & size, pageInfo);
      } else {
        BookImageStore.instance.ensureLoaded(bgHref, onImageNeeded);
      }
    }

    // A31: 笔记高亮矩形（绘制在文字下方，按 colorIndex 色板）
    if (notes.isNotEmpty) {
      _paintNoteHighlights(canvas, pageInfo, notes,
          baseFontSize: baseFontSize, baseLineHeight: baseLineHeight);
    }

    for (final entry in pageInfo.entries) {
      final href = entry.resourceHref;
      if (href != null) {
        final image = BookImageStore.instance.get(href);
        if (image != null) {
          // paintImage 按目标矩形拉伸——布局引擎已折算好等比尺寸
          paintImage(
            canvas: canvas,
            rect: Rect.fromLTWH(entry.x, entry.y, entry.width, entry.height),
            image: image,
            fit: BoxFit.fill,
          );
        } else {
          // 阶段3优化：根据加载状态显示不同的占位
          final rect = Rect.fromLTWH(
            entry.x,
            entry.y,
            entry.width,
            entry.height,
          );
          final imageState = BookImageStore.instance.state(href);
          _drawImagePlaceholder(canvas, rect, imageState, theme);
          BookImageStore.instance.ensureLoaded(href, onImageNeeded);
        }
        continue;
      }

      // 表格单元格线框：细灰描边（不填充；几何由布局引擎折算）
      if (entry.isTableFrame) {
        canvas.drawRect(
          Rect.fromLTWH(entry.x, entry.y, entry.width, entry.height),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.0
            ..color = theme.tableFrameColor,
        );
        continue;
      }

      final text = entry.text;
      if (text == null || text.isEmpty) continue;
      final baseColor = entry.isComment
          ? theme.commentColor
          : (_parseHexColor(entry.color) ?? theme.textColor);
      final baseScale = entry.fontScale ?? 1.0;
      // TXT 章节标题加粗（与 EPUB 行内粗体同一开关；TextSpan 子段
      // 未显式设置时继承父级，segments 分支无需重复判断）
      final baseStyle = TextStyle(
        color: baseColor,
        fontSize: baseFontSize * baseScale,
        height: baseLineHeight,
        fontFamily: ReaderFont.family,
        fontWeight: (applyTitleBold && entry.isChapterStart)
            ? FontWeight.w700
            : null,
        // P2 两端对齐：行内字符间隙（0=无操作）。注意此处仅绘制样式——
        // MeasureTextService 测量样式恒不带 gap（否则带隙行宽灌入
        // Rust MeasureCache 会污染断行基准）
        letterSpacing: entry.letterGap,
      );

      final TextSpan textSpan;
      if (entry.segments.isEmpty) {
        textSpan = TextSpan(text: text, style: baseStyle);
      } else {
        // 行内富文本：分段覆盖样式，间隙回填默认样式
        final children = <InlineSpan>[];
        var cursor = 0;
        for (final seg in entry.segments) {
          final s = seg.start.clamp(0, text.length);
          final e = seg.end.clamp(s, text.length);
          if (s > cursor) {
            children.add(TextSpan(text: text.substring(cursor, s)));
          }
          if (e > s) {
            children.add(
              TextSpan(
                text: text.substring(s, e),
                style: TextStyle(
                  color: _parseHexColor(seg.color) ?? baseColor,
                  fontSize: baseFontSize * (seg.fontScale ?? baseScale),
                  height: baseLineHeight,
                  fontFamily: ReaderFont.family,
                  // 合成粗/斜体（绘制期，不参与 Rust 断行测量）；
                  // null 时继承行级默认
                  fontWeight: (seg.bold && applyBold) ? FontWeight.w700 : null,
                  fontStyle: (seg.italic && applyItalic)
                      ? FontStyle.italic
                      : null,
                  decoration: seg.underline ? TextDecoration.underline : null,
                  // P2 justify 拉丁词保护段：Some(0) 压制该区间拉伸；
                  // null 继承行级 letterGap
                  letterSpacing: seg.letterSpacing ?? entry.letterGap,
                ),
              ),
            );
            cursor = e;
          }
        }
        if (cursor < text.length) {
          children.add(TextSpan(text: text.substring(cursor)));
        }
        textSpan = TextSpan(style: baseStyle, children: children);
      }

      final textPainter = TextPainter(
        text: textSpan,
        textAlign: TextAlign.left,
        textDirection: TextDirection.ltr,
      );

      // M10-B：注入 Skia 实测宽度到 MeasureTextService。
      // 配置服务用 baseStyle 的 fontSize/family（与绘制一致），
      // 测整行 text（含 segments 覆盖样式）→ 与最终 paint 走同一 Paragraph 测量
      MeasureTextService.instance.configure(
        fontFamily: baseStyle.fontFamily ?? ReaderFont.family,
        fontSize: baseStyle.fontSize ?? 18.0,
      );
      // M12 必修2：喂入所有 char-boundary 前缀（而非仅完整 line），
      // 让 Rust 二分搜索 `text[..mid]` 在 cache 命中后用 Skia 实测宽度。
      MeasureTextService.instance.feedPageTextsWithPrefixes(text);
      // 仍然测完整 line（保留完整 line 的 cache 条目供后续 layout 用）
      MeasureTextService.instance.measure(text);

      // M7：恒定无约束排版——消灭「Rust 测窄 → TextPainter 二次换行 →
      // 与下一行重叠/页尾截断」（内容跨页丢失重复的直接来源）
      textPainter.layout(minWidth: 0, maxWidth: double.infinity);
      final naturalWidth = textPainter.maxIntrinsicWidth;

      if (naturalWidth <= entry.width * 1.02 || entry.width <= 0) {
        // 正常或轻微超宽（≤2%，epsilon 已把概率压到极低）：原样绘制，
        // 几 px 渗入右 padding 无感知，保字形保真
        textPainter.paint(canvas, Offset(entry.x, entry.y));
      } else {
        // 显著超宽（粗体合成/窄列等残余场景）：该行整体等比缩放，
        // 宁可字形略小也不丢字
        final s = entry.width / naturalWidth;
        canvas.save();
        canvas.translate(entry.x, entry.y);
        canvas.scale(s);
        textPainter.paint(canvas, Offset.zero);
        canvas.restore();
      }
    }
  }

  /// `#rgb`/`#rrggbb` 十六进制色解析（非法形态返回 null 回落主题色）
  static Color? _parseHexColor(String? hex) {
    if (hex == null) return null;
    var h = hex.replaceFirst('#', '');
    if (h.length == 3) {
      h = h.split('').map((c) => c + c).join();
    }
    if (h.length != 6) return null;
    final v = int.tryParse('ff$h', radix: 16);
    return v == null ? null : Color(v);
  }

  /// A31: 绘制笔记高亮矩形（按 colorIndex 色板，垫在文字下方）
  ///
  /// 色板：0=黄色/1=绿色/2=蓝色/3=粉色/4=直线（下划线）
  static void _paintNoteHighlights(
    Canvas canvas,
    PageInfo pageInfo,
    List<Note> notes, {
    required double baseFontSize,
    required double baseLineHeight,
  }) {
    const highlightColors = [
      Color(0x66FFD54F), // 黄色
      Color(0x6681C784), // 绿色
      Color(0x6664B5F6), // 蓝色
      Color(0x66F48FB1), // 粉色
    ];

    for (final note in notes) {
      final colorIndex = note.colorIndex.clamp(0, 4);
      final isUnderline = colorIndex == 4;
      final color = isUnderline
          ? const Color(0xFFE53935) // 直线用红色
          : highlightColors[colorIndex];

      for (final entry in pageInfo.entries) {
        final text = entry.text;
        if (text == null || !entry.hasCharRange) continue;
        final overlapStart = note.startCharOffset.clamp(
          entry.startCharIndex!,
          entry.endCharIndex!,
        );
        final overlapEnd = note.endCharOffset.clamp(
          entry.startCharIndex!,
          entry.endCharIndex!,
        );
        if (overlapStart >= overlapEnd) continue;

        // 构建 TextPainter 获取选区 boxes
        final baseStyle = TextStyle(
          fontSize: baseFontSize * (entry.fontScale ?? 1.0),
          height: baseLineHeight,
          fontFamily: ReaderFont.family,
          letterSpacing: entry.letterGap,
        );
        final textPainter = TextPainter(
          text: TextSpan(text: text, style: baseStyle),
          textDirection: TextDirection.ltr,
        )..layout(minWidth: 0, maxWidth: double.infinity);

        final localStart = overlapStart - entry.startCharIndex!;
        final localEnd = overlapEnd - entry.startCharIndex!;
        // Flutter TextPainter.getBoxesForSelection 返回选区矩形列表
        final boxes = textPainter.getBoxesForSelection(
          TextSelection(
            baseOffset: localStart.clamp(0, text.length),
            extentOffset: localEnd.clamp(0, text.length),
          ),
        );
        textPainter.dispose();

        for (final box in boxes) {
          final rect = Rect.fromLTRB(
            entry.x + box.left,
            entry.y + box.top,
            entry.x + box.right,
            entry.y + box.bottom,
          );
          if (isUnderline) {
            // 直线模式：底部横线
            canvas.drawLine(
              Offset(rect.left, rect.bottom - 2),
              Offset(rect.right, rect.bottom - 2),
              Paint()
                ..color = color
                ..strokeWidth = 2.0,
            );
          } else {
            // 高亮矩形
            canvas.drawRect(
              rect,
              Paint()..color = color,
            );
          }
        }
      }
    }
  }

  /// 几何诊断静态节流（同一 pageId 仅首次输出）
  static final Set<int> _tracedGeometryPageIds = <int>{};

  static void _tracePaintGeometry(
    PageInfo pageInfo,
    Size size,
    Canvas canvas, {
    required double baseFontSize,
    required double baseLineHeight,
  }) {
    final id = readerPageId(pageInfo);
    if (_tracedGeometryPageIds.contains(id)) return;
    _tracedGeometryPageIds.add(id);
    // M10-B 偏右根因诊断：实测绘制端每行 Skia 渲染宽度 vs Rust 硬编码
    // content_width。TextLine.width 是 content_width（非字形实测宽）。
    //
    // M10-B 修复后预期：
    // - skiaW ≈ rustW（差异 ≤ 1px），因为 Rust layout 期间通过 MeasureCache 用了
    //   Dart TextPainter 实测宽度做二分搜索断行
    // - 仍存在 ≤ 1px 偏差是 Skia subpixel 像素对齐导致，可接受
    // - 若 diff > 2px 出现 → MeasureCache 没命中（Dart 没测量过这条字符串，
    //   Rust 回退到 ttf-parser 估算；常见于翻页第一帧 + 缓存预热窗口期）
    //
    // 历史背景（M7 修复前）：Skia 与 Rust ab_glyph advance 不一致，行实际右缘
    // = x + Skia宽 会吃掉右侧 padding → 视觉「内容偏右」。此 trace 沿用，命名
    // 仍为 paint.geometry.first 兼容既有 log 解析。
    final paintLines = <String>[];
    var sampled = 0;
    for (final e in pageInfo.entries) {
      if (e.text == null || e.text!.isEmpty) continue;
      final tp = TextPainter(
        text: TextSpan(
          text: e.text,
          style: TextStyle(
            fontSize: baseFontSize * (e.fontScale ?? 1.0),
            height: baseLineHeight,
            fontFamily: ReaderFont.family,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(minWidth: 0, maxWidth: double.infinity);
      paintLines.add(
        'x=${e.x.toStringAsFixed(1)} chars=${e.text!.length} '
        'skiaW=${tp.width.toStringAsFixed(1)} rustW=${e.width.toStringAsFixed(1)} '
        'rightEdge=${(e.x + tp.width).toStringAsFixed(1)}',
      );
      sampled++;
      if (sampled >= 3) break;
    }
    final m = canvas.getTransform();
    readerTrace('paint.geometry.first', {
      'pageId': id,
      'page': '${pageInfo.chapterIndex}/${pageInfo.pageIndex}',
      'canvasSize': '${size.width}x${size.height}',
      'font': ReaderFont.family,
      if (paintLines.isNotEmpty) 'paintLines': paintLines.join(' | '),
      'matrix': '${m[0]},${m[1]} | ${m[4]},${m[5]} | tx=${m[12]},ty=${m[13]}',
    });
  }

  /// 背景铺放：严格 CSS background-size 语义 + position 锚点
  static void _paintBackground(
    Canvas canvas,
    ui.Image image,
    Rect rect,
    PageInfo pageInfo,
  ) {
    final mode = pageInfo.backgroundSize;

    // stretch：拉伸铺满（允许变形，对应 background-size:100% 100%）
    if (mode == 'stretch') {
      paintImage(canvas: canvas, rect: rect, image: image, fit: BoxFit.fill);
      return;
    }

    // cover/contain 共用：fit 由模式决定，锚点由 position 关键字决定
    // （"bottom center" → 底边对齐；"left top" → 左上对齐；缺省居中）
    final pos = pageInfo.backgroundPosition ?? '';
    final x = pos.contains('left') ? -1.0 : (pos.contains('right') ? 1.0 : 0.0);
    final y = pos.contains('top') ? -1.0 : (pos.contains('bottom') ? 1.0 : 0.0);
    paintImage(
      canvas: canvas,
      rect: rect,
      image: image,
      fit: mode == 'contain' ? BoxFit.contain : BoxFit.cover,
      alignment: Alignment(x, y),
      filterQuality: FilterQuality.medium,
    );
  }

  /// 阶段3优化：根据图片加载状态绘制占位符
  /// 
  /// - loading: 浅灰圆角块 + 旋转加载指示器
  /// - failed: 深灰圆角块 + 错误图标（×）
  /// - null（未请求）: 浅灰圆角块（兜底）
  static void _drawImagePlaceholder(
    Canvas canvas,
    Rect rect,
    BookImageState? state,
    ReaderTheme theme,
  ) {
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(6));
    
    if (state == BookImageState.loading) {
      // 加载中：浅灰背景 + 深灰圆环指示器
      canvas.drawRRect(rrect, Paint()..color = theme.placeholderColor);
      
      final center = rect.center;
      final radius = (rect.width < rect.height ? rect.width : rect.height) / 6;
      if (radius > 4) {  // 只在足够大的占位框内绘制指示器
        // 绘制圆环（3/4圆弧）
        final paint = Paint()
          ..color = theme.placeholderColor.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..strokeCap = StrokeCap.round;

        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          -1.57, // 从顶部开始（-π/2）
          4.71,  // 绘制 3/4 圆（3π/2）
          false,
          paint,
        );
      }
    } else if (state == BookImageState.failed) {
      // 失败：深灰背景 + 错误标记（×）
      canvas.drawRRect(
        rrect,
        Paint()..color = theme.placeholderColor.withValues(alpha: 0.7),
      );
      
      final center = rect.center;
      final size = (rect.width < rect.height ? rect.width : rect.height) / 4;
      if (size > 6) {  // 只在足够大的占位框内绘制错误标记
        final paint = Paint()
          ..color = theme.placeholderColor.withValues(alpha: 0.4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..strokeCap = StrokeCap.round;

        // 绘制 × 号
        canvas.drawLine(
          Offset(center.dx - size / 2, center.dy - size / 2),
          Offset(center.dx + size / 2, center.dy + size / 2),
          paint,
        );
        canvas.drawLine(
          Offset(center.dx + size / 2, center.dy - size / 2),
          Offset(center.dx - size / 2, center.dy + size / 2),
          paint,
        );
      }
    } else {
      // 未请求或其他状态：简单浅灰占位框
      canvas.drawRRect(rrect, Paint()..color = theme.placeholderColor);
    }
  }
}
