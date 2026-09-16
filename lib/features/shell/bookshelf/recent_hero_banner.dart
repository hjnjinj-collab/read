import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/ffi/book_service.dart' show CoverStore;
import '../../../../core/services/cover_palette.dart';
import 'bookshelf_layout.dart';

/// 书架顶部常驻 Hero：最近阅读封面轮换（最多 3 本）
class RecentHeroBanner extends StatefulWidget {
  const RecentHeroBanner({
    super.key,
    required this.books,
    required this.onTap,
  });

  /// 已按 lastRead 降序，取前 3
  final List<(Book, ReadingProgressData?)> books;
  final void Function(Book book) onTap;

  @override
  State<RecentHeroBanner> createState() => _RecentHeroBannerState();
}

class _RecentHeroBannerState extends State<RecentHeroBanner> {
  Timer? _timer;
  int _index = 0;
  int _fadeKey = 0;

  @override
  void initState() {
    super.initState();
    _armTimer();
  }

  @override
  void didUpdateWidget(covariant RecentHeroBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.books.length != oldWidget.books.length ||
        (widget.books.isNotEmpty &&
            oldWidget.books.isNotEmpty &&
            widget.books.first.$1.filePath != oldWidget.books.first.$1.filePath)) {
      _index = 0;
      _fadeKey++;
      _armTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _armTimer() {
    _timer?.cancel();
    final n = widget.books.length.clamp(0, 3);
    if (n <= 1) return;
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted) return;
      setState(() {
        _index = (_index + 1) % n;
        _fadeKey++;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.books.take(3).toList();
    if (list.isEmpty) return const SizedBox.shrink();
    final i = _index.clamp(0, list.length - 1);
    final (book, progress) = list[i];
    final cover = CoverStore.fileOf(book.filePath);
    final colors = CoverPalette.cached(book.filePath) ??
        (cover != null
            ? CoverPalette.loadSidecar(book.filePath, cover)
            : null) ??
        CoverPalette.synthetic(book.title);
    final p = progress;
    final hasP = p != null && p.totalChapters > 0;
    final pct = hasP
        ? ((p.chapterIndex + 1) / p.totalChapters).clamp(0.0, 1.0)
        : 0.0;

    return Padding(
      // 水平边距由外层 SliverPadding 统一，避免与网格双倍缩进
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: colors.dark,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        elevation: 3,
        shadowColor: colors.shadowColor.withValues(alpha: 0.45),
        child: InkWell(
          onTap: () => widget.onTap(book),
          child: SizedBox(
            height: BookshelfLayout.heroBannerH,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 封面底图
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 480),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, anim) {
                    return FadeTransition(
                      opacity: anim,
                      child: ScaleTransition(
                        scale: Tween(begin: 1.04, end: 1.0).animate(anim),
                        child: child,
                      ),
                    );
                  },
                  child: KeyedSubtree(
                    key: ValueKey('hero-bg-$_fadeKey-${book.filePath}'),
                    child: cover != null
                        ? Image.file(
                            cover,
                            fit: BoxFit.cover,
                            width: double.infinity,
                            height: double.infinity,
                            cacheWidth: 720,
                            gaplessPlayback: true,
                            errorBuilder: (_, _, _) =>
                                _HeroFallback(colors: colors, title: book.title),
                          )
                        : _HeroFallback(colors: colors, title: book.title),
                  ),
                ),
                // 左侧重色块保字 + 底部提取色
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        Colors.black.withValues(alpha: 0.55),
                        Colors.black.withValues(alpha: 0.2),
                        Colors.transparent,
                      ],
                      stops: const [0, 0.45, 0.75],
                    ),
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        colors.dominant.withValues(alpha: 0.55),
                        colors.vibrant.withValues(alpha: 0.2),
                        Colors.transparent,
                      ],
                      stops: const [0, 0.35, 0.7],
                    ),
                  ),
                ),
                // 文案
                Positioned(
                  left: 16,
                  right: 120,
                  bottom: 16,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '继续阅读',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.75),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                          shadows: [
                            Shadow(color: Colors.black54, blurRadius: 8),
                          ],
                        ),
                      ),
                      if (hasP) ...[
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: pct,
                            minHeight: 3,
                            backgroundColor:
                                Colors.white.withValues(alpha: 0.22),
                            valueColor: AlwaysStoppedAnimation(
                              Color.lerp(colors.accent, Colors.white, 0.35)!,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '第 ${p.chapterIndex + 1}/${p.totalChapters} 章',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // 右侧小封面 + 指示点
                Positioned(
                  right: 14,
                  bottom: 14,
                  child: Column(
                    children: [
                      Container(
                        width: 52,
                        height: 78,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.35),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: cover != null
                              ? Image.file(
                                  cover,
                                  fit: BoxFit.cover,
                                  cacheWidth: 104,
                                  gaplessPlayback: true,
                                  errorBuilder: (_, _, _) => ColoredBox(
                                    color: colors.vibrant,
                                  ),
                                )
                              : ColoredBox(color: colors.vibrant),
                        ),
                      ),
                      if (list.length > 1) ...[
                        const SizedBox(height: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var d = 0; d < list.length; d++)
                              Container(
                                width: d == i ? 14 : 6,
                                height: 6,
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 2),
                                decoration: BoxDecoration(
                                  color: d == i
                                      ? Colors.white
                                      : Colors.white
                                          .withValues(alpha: 0.4),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroFallback extends StatelessWidget {
  const _HeroFallback({required this.colors, required this.title});

  final CoverColors colors;
  final String title;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.vibrant, colors.dark],
        ),
      ),
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 24),
          child: Text(
            title.isEmpty ? '书' : title.characters.first,
            style: TextStyle(
              fontSize: 64,
              fontWeight: FontWeight.w800,
              color: Colors.white.withValues(alpha: 0.2),
            ),
          ),
        ),
      ),
    );
  }
}
