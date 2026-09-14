import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/ffi/book_service.dart';
import '../../../../core/services/cover_palette.dart';
import '../../../../core/theme/app_icons.dart';

/// 满铺书封卡：封面铺满 + 底部 scrim 书名，像书架上的一本书。
class BookCoverCard extends StatefulWidget {
  const BookCoverCard({
    super.key,
    required this.book,
    required this.progress,
    required this.onTap,
    required this.onLongPress,
  });

  final Book book;
  final ReadingProgressData? progress;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<BookCoverCard> createState() => _BookCoverCardState();
}

class _BookCoverCardState extends State<BookCoverCard> {
  Color? _dominant;
  File? _cover;
  bool _paletteDone = false;

  @override
  void initState() {
    super.initState();
    _cover = cachedCoverFor(widget.book.filePath);
    _loadPalette();
  }

  @override
  void didUpdateWidget(covariant BookCoverCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.book.filePath != widget.book.filePath) {
      _cover = cachedCoverFor(widget.book.filePath);
      _paletteDone = false;
      _dominant = null;
      _loadPalette();
    }
  }

  Future<void> _loadPalette() async {
    final cover = _cover;
    if (cover == null || !cover.existsSync()) {
      if (mounted) {
        setState(() {
          _dominant = CoverPalette.spineColorFor(widget.book.title);
          _paletteDone = true;
        });
      }
      return;
    }
    final cached = CoverPalette.cached(cover.path);
    Color? color = cached;
    color ??= await CoverPalette.extractFromFile(cover);
    if (!mounted) return;
    setState(() {
      _dominant = color ?? CoverPalette.spineColorFor(widget.book.title);
      _paletteDone = true;
    });
  }

  double? get _progressValue {
    final p = widget.progress;
    if (p == null || p.totalChapters <= 0) return null;
    return ((p.chapterIndex + 1) / p.totalChapters).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cover = _cover;
    final accent = _dominant ?? scheme.surfaceContainerHigh;
    final progressValue = _progressValue;
    final title = widget.book.title;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        borderRadius: BorderRadius.circular(10),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 底色：无封面时用书脊色渐变
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color.lerp(accent, Colors.white, 0.15)!,
                        Color.lerp(accent, Colors.black, 0.25)!,
                      ],
                    ),
                  ),
                ),
                if (cover != null)
                  Hero(
                    tag: 'cover:${widget.book.filePath}',
                    child: Image.file(
                      cover,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          _SpineFallback(title: title, accent: accent),
                    ),
                  )
                else
                  Hero(
                    tag: 'cover:${widget.book.filePath}',
                    child: _SpineFallback(title: title, accent: accent),
                  ),
                // 底部 scrim + 书名
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0),
                          Colors.black.withValues(alpha: 0.72),
                        ],
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 20, 8, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              height: 1.25,
                              shadows: [
                                Shadow(
                                  color: Colors.black54,
                                  blurRadius: 4,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(1.5),
                            child: LinearProgressIndicator(
                              value: progressValue ?? 0,
                              minHeight: 2.5,
                              backgroundColor: Colors.white24,
                              color: progressValue == null
                                  ? Colors.transparent
                                  : Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (!_paletteDone)
                  const Positioned(
                    top: 8,
                    right: 8,
                    child: SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Colors.white70,
                      ),
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

class _SpineFallback extends StatelessWidget {
  const _SpineFallback({required this.title, required this.accent});

  final String title;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final glyph = title.isEmpty ? '书' : title.characters.first;
    final on = CoverPalette.onColor(accent);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(accent, Colors.white, 0.12)!,
            Color.lerp(accent, Colors.black, 0.2)!,
          ],
        ),
      ),
      child: Center(
        child: Text(
          glyph,
          style: TextStyle(
            fontSize: 42,
            fontWeight: FontWeight.w700,
            color: on.withValues(alpha: 0.88),
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
    final spine = CoverPalette.spineColorFor(book.title);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: SizedBox(
        width: 44,
        height: 66,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: coverPath != null
              ? Image.file(
                  coverPath,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _ListSpine(spine: spine, title: book.title),
                )
              : _ListSpine(spine: spine, title: book.title),
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
  const _ListSpine({required this.spine, required this.title});

  final Color spine;
  final String title;

  @override
  Widget build(BuildContext context) {
    final glyph = title.isEmpty ? '书' : title.characters.first;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(spine, Colors.white, 0.1)!,
            Color.lerp(spine, Colors.black, 0.2)!,
          ],
        ),
      ),
      child: Center(
        child: Text(
          glyph,
          style: TextStyle(
            color: CoverPalette.onColor(spine),
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
