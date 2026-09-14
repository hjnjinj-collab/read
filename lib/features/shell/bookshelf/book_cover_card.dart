import 'package:flutter/material.dart';

import '../../../../core/ffi/book_service.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_icons.dart';

/// 岛屿书封卡（网格模式签名元素）
class BookCoverCard extends StatelessWidget {
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

  double? get _progressValue {
    final p = progress;
    if (p == null || p.totalChapters <= 0) return null;
    final v = (p.chapterIndex + 1) / p.totalChapters;
    return v.clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cover = cachedCoverFor(book.filePath);
    final progressValue = _progressValue;

    return Card(
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Hero(
                tag: 'cover:${book.filePath}',
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(12),
                  ),
                  child: cover != null
                      ? Image.file(
                          cover,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              _PlaceholderCover(scheme: scheme),
                        )
                      : _PlaceholderCover(scheme: scheme),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 36,
                    child: Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            height: 1.25,
                          ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (progressValue != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: progressValue,
                        minHeight: 3,
                        backgroundColor: scheme.surfaceContainerHighest,
                        color: scheme.primary,
                      ),
                    )
                  else
                    SizedBox(
                      height: 3,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          width: 16,
                          height: 3,
                          decoration: BoxDecoration(
                            color: scheme.outlineVariant,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaceholderCover extends StatelessWidget {
  const _PlaceholderCover({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.surfaceContainerHighest,
            scheme.surfaceContainerHigh,
          ],
        ),
      ),
      child: Center(
        child: Icon(
          AppIcons.emptyBook,
          size: 36,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

/// 列表模式行（非岛屿，常规 ListTile 密度）
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

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: SizedBox(
        width: 44,
        height: 66,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: coverPath != null
              ? Image.file(
                  coverPath,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _ListPlaceholder(scheme: scheme),
                )
              : _ListPlaceholder(scheme: scheme),
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

class _ListPlaceholder extends StatelessWidget {
  const _ListPlaceholder({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Icon(
        AppIcons.emptyBook,
        size: 22,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
      ),
    );
  }
}
