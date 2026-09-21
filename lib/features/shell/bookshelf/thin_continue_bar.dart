import 'package:flutter/material.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/ffi/book_service.dart' show CoverStore;
import '../../../../core/services/cover_palette.dart';
import '../../../../core/theme/app_theme.dart' show AppGlass;

/// 书架顶条：海报取色底 + 小封面 + 继续阅读 + **真按钮**（非纯文字）。
/// 视觉语言对齐旧 `RecentHeroBanner`，高度更克制，适合作书库顶任务条。
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
    final chapter =
        hasP ? '第 ${p.chapterIndex + 1}/${p.totalChapters} 章' : '继续阅读';

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: colors.dark,
        borderRadius: BorderRadius.circular(AppGlass.settingsCardRadius),
        clipBehavior: Clip.antiAlias,
        elevation: 3,
        shadowColor: colors.shadowColor.withValues(alpha: 0.4),
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 108,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 海报底：封面图（有则铺）
                if (cover != null)
                  Positioned.fill(
                    child: Image.file(
                      cover,
                      fit: BoxFit.cover,
                      cacheWidth: 720,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) =>
                          DecoratedBox(decoration: _posterDeco(colors)),
                    ),
                  )
                else
                  Positioned.fill(
                    child: DecoratedBox(decoration: _posterDeco(colors)),
                  ),
                // 左侧重色保字 + 底部取色
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          Colors.black.withValues(alpha: 0.62),
                          Colors.black.withValues(alpha: 0.28),
                          Colors.black.withValues(alpha: 0.08),
                        ],
                        stops: const [0, 0.55, 1],
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          colors.dominant.withValues(alpha: 0.45),
                          colors.vibrant.withValues(alpha: 0.12),
                          Colors.transparent,
                        ],
                        stops: const [0, 0.4, 0.85],
                      ),
                    ),
                  ),
                ),
                // 内容
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                  child: Row(
                    children: [
                      // 小封面
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 48,
                          height: 68,
                          child: cover != null
                              ? Image.file(
                                  cover,
                                  fit: BoxFit.cover,
                                  cacheWidth: 160,
                                  gaplessPlayback: true,
                                  errorBuilder: (_, _, _) => _CoverFallback(
                                    colors: colors,
                                    title: book.title,
                                  ),
                                )
                              : _CoverFallback(
                                  colors: colors,
                                  title: book.title,
                                ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '继续阅读',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.75),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 1.1,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              book.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                height: 1.2,
                                shadows: [
                                  Shadow(color: Colors.black54, blurRadius: 6),
                                ],
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              chapter,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.82),
                                fontSize: 12,
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
                                      Colors.white.withValues(alpha: 0.22),
                                  valueColor: AlwaysStoppedAnimation(
                                    Color.lerp(
                                      colors.accent,
                                      Colors.white,
                                      0.35,
                                    )!,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 真按钮：补旧版「只有文字」的缺口
                      FilledButton(
                        onPressed: onTap,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white.withValues(alpha: 0.92),
                          foregroundColor: colors.dark,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          textStyle: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                          ),
                        ),
                        child: const Text('继续'),
                      ),
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

  BoxDecoration _posterDeco(CoverColors colors) {
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [colors.dark, colors.dominant.withValues(alpha: 0.85)],
      ),
    );
  }
}

class _CoverFallback extends StatelessWidget {
  const _CoverFallback({required this.colors, required this.title});

  final CoverColors colors;
  final String title;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.dominant, colors.dark],
        ),
      ),
      child: Center(
        child: Text(
          title.isEmpty ? '书' : title.characters.first,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.9),
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
      ),
    );
  }
}
