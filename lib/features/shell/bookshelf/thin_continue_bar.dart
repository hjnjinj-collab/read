import 'package:flutter/material.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/ffi/book_service.dart' show CoverStore;
import '../../../../core/theme/app_theme.dart' show AppGlass;

/// 书架薄续读条：书库网格上方的任务入口（非海报 Hero）。
/// 无阅读进度的书不触发本条（由调用方保证传入有效项）。
class ThinContinueBar extends StatelessWidget {
  const ThinContinueBar({
    super.key,
    required this.book,
    required this.progress,
    required this.onTap,
  });

  final Book book;
  final ReadingProgressData? progress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cover = CoverStore.fileOf(book.filePath);
    final p = progress;
    final hasP = p != null && p.totalChapters > 0;
    final pct = hasP
        ? ((p.chapterIndex + 1) / p.totalChapters).clamp(0.0, 1.0)
        : 0.0;
    final chapter = hasP ? '第 ${p.chapterIndex + 1}/${p.totalChapters} 章' : '继续阅读';

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppGlass.settingsCardRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 36,
                    height: 50,
                    child: cover != null
                        ? Image.file(
                            cover,
                            fit: BoxFit.cover,
                            cacheWidth: 120,
                            gaplessPlayback: true,
                            errorBuilder: (_, _, _) => _CoverFallback(
                              scheme: scheme,
                              title: book.title,
                            ),
                          )
                        : _CoverFallback(scheme: scheme, title: book.title),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        book.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        chapter,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                      if (hasP) ...[
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: pct,
                            minHeight: 3,
                            backgroundColor:
                                scheme.outlineVariant.withValues(alpha: 0.45),
                            valueColor:
                                AlwaysStoppedAnimation(scheme.primary),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.tonal(
                  onPressed: onTap,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    visualDensity: VisualDensity.compact,
                    textStyle: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  child: const Text('继续'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CoverFallback extends StatelessWidget {
  const _CoverFallback({required this.scheme, required this.title});

  final ColorScheme scheme;
  final String title;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: scheme.primary.withValues(alpha: 0.2),
      child: Center(
        child: Text(
          title.isEmpty ? '书' : title.characters.first,
          style: TextStyle(
            color: scheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
