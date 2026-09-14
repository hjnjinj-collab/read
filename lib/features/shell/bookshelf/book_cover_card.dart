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

/// 电影海报书封：夹紧取色阴影 + 海报渐变 + 进度缎带
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
    with SingleTickerProviderStateMixin {
  CoverColors? _colors;
  File? _cover;
  bool _pressed = false;

  late final AnimationController _enterCtrl;
  late final Animation<double> _enter;

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
    Future.delayed(Duration(milliseconds: delayMs), () {
      if (mounted) _enterCtrl.forward();
    });
    _loadPalette();
  }

  @override
  void dispose() {
    _enterCtrl.dispose();
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

  @override
  Widget build(BuildContext context) {
    final colors = _colors ?? CoverPalette.synthetic(widget.book.title);
    final cover = _cover;
    final progress = _progressValue;
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
            // shape 统一驱动裁切与阴影圆角，避免 Ink 方角投影
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
                              shape:
                                  RoundedRectangleBorder(borderRadius: r),
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

                  // 海报层：顶光 + 底部主色 scrim
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          colors.posterHighlight.withValues(alpha: 0.14),
                          Colors.transparent,
                          colors.posterScrim.withValues(alpha: 0.5),
                          colors.posterScrim.withValues(alpha: 0.94),
                        ],
                        stops: const [0, 0.32, 0.7, 1],
                      ),
                    ),
                  ),

                  if (hasProgress)
                    Positioned(
                      top: 0,
                      right: 14,
                      child: _ProgressRibbon(
                        progress: progress,
                        color: colors.accent,
                      ),
                    ),

                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 20, 10, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
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
                          const SizedBox(height: 4),
                          Text(
                            hasProgress
                                ? '${(progress * 100).round()}%'
                                : '未读',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.86),
                              fontSize: 11,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
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

class _ProgressRibbon extends StatelessWidget {
  const _ProgressRibbon({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final h = 18.0 + progress * 42.0;
    return CustomPaint(
      size: Size(18, h),
      painter: _RibbonPainter(color: color),
    );
  }
}

class _RibbonPainter extends CustomPainter {
  _RibbonPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(w, 0)
      ..lineTo(w, h - 8)
      ..lineTo(w / 2, h)
      ..lineTo(0, h - 8)
      ..close();
    canvas.drawShadow(path, Colors.black, 3, false);
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(color, Colors.white, 0.12)!,
            color,
            Color.lerp(color, Colors.black, 0.22)!,
          ],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(covariant _RibbonPainter old) => old.color != color;
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
        subtitle,
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
