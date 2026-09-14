import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/ffi/book_service.dart';
import '../../../../core/services/cover_palette.dart';
import '../../../../core/theme/app_icons.dart';
import '../../../../core/theme/app_theme.dart';

/// 书封统一圆角（阴影 / 裁切 / Hero 必须同源）
const double kCoverRadius = 12;

/// 电影海报书封：夹紧取色 + 圆环进度 + 格式/剩余章徽标
class BookCoverCard extends StatefulWidget {
  const BookCoverCard({
    super.key,
    required this.book,
    required this.progress,
    required this.onTap,
    required this.onLongPress,
    this.staggerIndex = 0,
  });

  final Book book;
  final ReadingProgressData? progress;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final int staggerIndex;

  @override
  State<BookCoverCard> createState() => _BookCoverCardState();
}

class _BookCoverCardState extends State<BookCoverCard>
    with TickerProviderStateMixin {
  CoverColors? _colors;
  File? _cover;
  bool _pressed = false;

  late final AnimationController _enterCtrl;
  late final Animation<double> _enter;
  late final AnimationController _ringCtrl;

  @override
  void initState() {
    super.initState();
    _cover = cachedCoverFor(widget.book.filePath);
    final delayMs = math.min(widget.staggerIndex, AppMotion.staggerMaxItems) *
        AppMotion.staggerStep.inMilliseconds;
    _enterCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _enter = CurvedAnimation(parent: _enterCtrl, curve: AppMotion.enter);
    _ringCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    Future.delayed(Duration(milliseconds: delayMs), () {
      if (!mounted) return;
      _enterCtrl.forward();
      _ringCtrl.forward();
    });
    _loadPalette();
  }

  @override
  void dispose() {
    _enterCtrl.dispose();
    _ringCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPalette() async {
    final cover = _cover;
    if (cover == null || !cover.existsSync()) {
      if (mounted) {
        setState(() => _colors = CoverPalette.synthetic(widget.book.title));
      }
      return;
    }
    final colors = CoverPalette.cached(cover.path) ??
        await CoverPalette.extractFromFile(cover);
    if (!mounted) return;
    setState(() {
      _colors = colors ?? CoverPalette.synthetic(widget.book.title);
    });
  }

  double get _progressValue {
    final p = widget.progress;
    if (p == null || p.totalChapters <= 0) return 0;
    return ((p.chapterIndex + 1) / p.totalChapters).clamp(0.0, 1.0);
  }

  int? get _remainingChapters {
    final p = widget.progress;
    if (p == null || p.totalChapters <= 0) return null;
    final left = p.totalChapters - (p.chapterIndex + 1);
    return left < 0 ? 0 : left;
  }

  String get _fileType {
    final path = widget.book.filePath;
    final i = path.lastIndexOf('.');
    if (i < 0 || i == path.length - 1) return 'BOOK';
    return path.substring(i + 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final colors = _colors ?? CoverPalette.synthetic(widget.book.title);
    final cover = _cover;
    final progress = _progressValue;
    final remaining = _remainingChapters;
    final hasProgress =
        widget.progress != null && (widget.progress?.totalChapters ?? 0) > 0;
    final radius = BorderRadius.circular(kCoverRadius);
    final scale = _pressed ? 0.96 : 1.0;

    final imageChild = cover != null
        ? Image.file(
            cover,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            errorBuilder: (_, _, _) =>
                _PosterFallback(title: widget.book.title, colors: colors),
          )
        : _PosterFallback(title: widget.book.title, colors: colors);

    return FadeTransition(
      opacity: _enter,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.06), end: Offset.zero)
            .animate(_enter),
        child: AnimatedScale(
          scale: scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Material(
            shape: RoundedRectangleBorder(borderRadius: radius),
            clipBehavior: Clip.antiAlias,
            elevation: _pressed ? 2 : 6,
            shadowColor: colors.shadowColor.withValues(alpha: 0.55),
            surfaceTintColor: Colors.transparent,
            color: colors.dark,
            child: InkWell(
              onTap: widget.onTap,
              onLongPress: widget.onLongPress,
              onHighlightChanged: (v) => setState(() => _pressed = v),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (cover != null)
                    Hero(
                      tag: 'cover:${widget.book.filePath}',
                      flightShuttleBuilder:
                          (context, animation, direction, from, to) {
                        return AnimatedBuilder(
                          animation: animation,
                          builder: (context, child) {
                            final r = BorderRadius.circular(
                              Tween(begin: kCoverRadius, end: 4.0)
                                  .animate(animation)
                                  .value,
                            );
                            return Material(
                              color: Colors.transparent,
                              shape: RoundedRectangleBorder(borderRadius: r),
                              clipBehavior: Clip.antiAlias,
                              child: child,
                            );
                          },
                          child: Image.file(cover, fit: BoxFit.cover),
                        );
                      },
                      child: imageChild,
                    )
                  else
                    Hero(
                      tag: 'cover:${widget.book.filePath}',
                      child: imageChild,
                    ),

                  // 顶光（轻，不抢底部弥漫）
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          colors.posterHighlight.withValues(alpha: 0.22),
                          Colors.transparent,
                        ],
                        stops: const [0, 0.4],
                      ),
                    ),
                  ),
                  // 提取色弥漫：自底部涌起 → 中部厚 → 顶部消散
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          colors.dominant.withValues(alpha: 0.95),
                          Color.lerp(colors.dominant, colors.vibrant, 0.45)!
                              .withValues(alpha: 0.82),
                          colors.vibrant.withValues(alpha: 0.58),
                          colors.dominant.withValues(alpha: 0.32),
                          colors.dominant.withValues(alpha: 0.1),
                          Colors.transparent,
                        ],
                        stops: const [0, 0.16, 0.34, 0.55, 0.75, 0.92],
                      ),
                    ),
                  ),
                  // 仅轻压保证白字可读，不洗掉弥漫色
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.22),
                          Colors.black.withValues(alpha: 0.06),
                          Colors.transparent,
                        ],
                        stops: const [0, 0.28, 0.52],
                      ),
                    ),
                  ),

                  // 文件类型徽标
                  Positioned(
                    top: 8,
                    left: 8,
                    child: _TypeBadge(label: _fileType, color: colors.accent),
                  ),

                  // 剩余章节徽标
                  if (remaining != null && hasProgress)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: _RemainBadge(
                        remaining: remaining,
                        color: colors.accent,
                      ),
                    ),

                  // 圆环进度（右下角叠在封面上）
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: _RingProgress(
                      progress: hasProgress ? progress : 0,
                      hasProgress: hasProgress,
                      color: colors.accent,
                      listenable: _ringCtrl,
                    ),
                  ),

                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Padding(
                      // 给右下角圆环留出空间
                      padding: const EdgeInsets.fromLTRB(10, 20, 56, 10),
                      child: Text(
                        widget.book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                          letterSpacing: 0.1,
                          shadows: [
                            Shadow(color: Colors.black87, blurRadius: 6),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 文件类型徽标（TXT / EPUB）
class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: color.withValues(alpha: 0.65),
          width: 0.8,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.95),
          fontSize: 9,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

/// 剩余章节徽标
class _RemainBadge extends StatelessWidget {
  const _RemainBadge({required this.remaining, required this.color});

  final int remaining;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final label = remaining == 0 ? '已读完' : '剩 $remaining 章';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 叠在封面上的精致圆环进度：细弧 + 光晕 + 毛玻璃底盘
class _RingProgress extends StatelessWidget {
  const _RingProgress({
    required this.progress,
    required this.hasProgress,
    required this.color,
    required this.listenable,
  });

  final double progress;
  final bool hasProgress;
  final Color color;
  final Animation<double> listenable;

  @override
  Widget build(BuildContext context) {
    const size = 46.0;
    return AnimatedBuilder(
      animation: listenable,
      builder: (context, _) {
        final t = Curves.easeOutCubic.transform(listenable.value);
        final value = hasProgress ? (progress * t).clamp(0.0, 1.0) : 0.0;
        return SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _RingPainter(
              progress: value,
              color: color,
              indeterminate: !hasProgress,
              t: t,
            ),
            child: Center(
              child: hasProgress
                  ? Text(
                      '${(progress * 100 * t).round()}%',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        height: 1,
                        letterSpacing: -0.2,
                        fontFeatures: [FontFeature.tabularFigures()],
                        shadows: [
                          Shadow(color: Colors.black54, blurRadius: 3),
                        ],
                      ),
                    )
                  : Text(
                      '新',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.9),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        height: 1,
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.color,
    required this.indeterminate,
    required this.t,
  });

  final double progress;
  final Color color;
  final bool indeterminate;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 3.5;

    // 毛玻璃底盘
    final disc = Paint()
      ..color = Colors.black.withValues(alpha: 0.42)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.5);
    canvas.drawCircle(center, size.width / 2, disc);

    // 内描边
    canvas.drawCircle(
      center,
      radius + 1.2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7
        ..color = Colors.white.withValues(alpha: 0.18),
    );

    // 轨道
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.2);
    canvas.drawCircle(center, radius, track);

    if (indeterminate) {
      // 未读：一段旋转的短弧（用 t 做进场）
      final sweep = 1.2 * t;
      final start = -1.57 + t * 2.2;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4
          ..strokeCap = StrokeCap.round
          ..color = Colors.white.withValues(alpha: 0.55),
      );
      return;
    }

    if (progress <= 0) return;

    // 进度光晕
    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -1.57,
      6.283 * progress,
      false,
      glow,
    );

    // 进度弧
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: -1.57,
        endAngle: -1.57 + 6.283,
        colors: [
          Color.lerp(color, Colors.white, 0.25)!,
          color,
          Color.lerp(color, Colors.white, 0.15)!,
        ],
        stops: const [0, 0.55, 1],
        transform: const GradientRotation(-1.57),
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -1.57,
      6.283 * progress,
      false,
      arc,
    );

    // 端点小球
    final angle = -1.57 + 6.283 * progress;
    final tip = Offset(
      center.dx + radius * math.cos(angle),
      center.dy + radius * math.sin(angle),
    );
    canvas.drawCircle(
      tip,
      2.2,
      Paint()..color = Color.lerp(color, Colors.white, 0.4)!,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.t != t ||
      old.indeterminate != indeterminate;
}

class _PosterFallback extends StatelessWidget {
  const _PosterFallback({required this.title, required this.colors});

  final String title;
  final CoverColors colors;

  @override
  Widget build(BuildContext context) {
    final glyph = title.isEmpty ? '书' : title.characters.first;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.vibrant, colors.dark],
        ),
      ),
      child: Center(
        child: Text(
          glyph,
          style: TextStyle(
            fontSize: 48,
            fontWeight: FontWeight.w800,
            color: Colors.white.withValues(alpha: 0.92),
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// 列表模式行
class BookListTile extends StatelessWidget {
  const BookListTile({
    super.key,
    required this.book,
    required this.subtitle,
    required this.onTap,
    required this.onRemove,
  });

  final Book book;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  String get _fileType {
    final path = book.filePath;
    final i = path.lastIndexOf('.');
    if (i < 0 || i == path.length - 1) return 'BOOK';
    return path.substring(i + 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final coverPath = cachedCoverFor(book.filePath);
    final colors = CoverPalette.synthetic(book.title);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: SizedBox(
        width: 44,
        height: 66,
        child: Material(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
          ),
          clipBehavior: Clip.antiAlias,
          elevation: 3,
          shadowColor: colors.shadowColor.withValues(alpha: 0.5),
          color: colors.dark,
          child: coverPath != null
              ? Image.file(
                  coverPath,
                  fit: BoxFit.cover,
                  width: 44,
                  height: 66,
                  errorBuilder: (_, _, _) =>
                      _ListSpine(colors: colors, title: book.title),
                )
              : _ListSpine(colors: colors, title: book.title),
        ),
      ),
      title: Text(
        book.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleSmall,
      ),
      subtitle: Text(
        '$_fileType · $subtitle',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
      ),
      trailing: IconButton(
        icon: const Icon(AppIcons.remove, size: 18),
        tooltip: '移出书架',
        onPressed: onRemove,
      ),
      onTap: onTap,
    );
  }
}

class _ListSpine extends StatelessWidget {
  const _ListSpine({required this.colors, required this.title});

  final CoverColors colors;
  final String title;

  @override
  Widget build(BuildContext context) {
    final glyph = title.isEmpty ? '书' : title.characters.first;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.vibrant, colors.dark],
        ),
      ),
      child: Center(
        child: Text(
          glyph,
          style: TextStyle(
            color: CoverPalette.onColor(colors.dominant),
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
