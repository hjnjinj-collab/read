import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/reader_provider.dart';

class ChapterListDialog extends ConsumerStatefulWidget {
  const ChapterListDialog({super.key});

  @override
  ConsumerState<ChapterListDialog> createState() => _ChapterListDialogState();
}

class _ChapterListDialogState extends ConsumerState<ChapterListDialog> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerProvider);
    final chapters = state.chapters;
    final currentIndex = state.currentChapterIndex;

    // Filter chapters based on search
    final filteredChapters = _searchQuery.isEmpty
        ? chapters
        : chapters.where((chapter) {
            return chapter.title.toLowerCase().contains(_searchQuery.toLowerCase());
          }).toList();

    // 嵌套目录缩进基准：以列表最小层级为 0（避免绝对 level 造成整体偏移）
    final minLevel = filteredChapters.isEmpty
        ? 1
        : filteredChapters.map((c) => c.level).reduce((a, b) => a < b ? a : b);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 40),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).primaryColor,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
            ),
            child: Row(
              children: [
                const Icon(Icons.list, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '章节目录 (${chapters.length}章)',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),

          // Search bar
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜索章节...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              onChanged: (value) {
                setState(() => _searchQuery = value);
              },
            ),
          ),

          // Chapter list
          Expanded(
            child: filteredChapters.isEmpty
                ? Center(
                    child: Text(
                      _searchQuery.isEmpty ? '暂无章节' : '未找到匹配的章节',
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 16,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: filteredChapters.length,
                    itemBuilder: (context, index) {
                      final chapter = filteredChapters[index];
                      final originalIndex = chapters.indexOf(chapter);
                      final isCurrentChapter = originalIndex == currentIndex;
                      // 嵌套层级缩进（每级 16px，上限 6 级）
                      final indent =
                          ((chapter.level - minLevel) * 16.0).clamp(0.0, 96.0);

                      return Padding(
                        padding: EdgeInsets.only(left: indent),
                        child: ListTile(
                        leading: SizedBox(
                          width: 40,
                          child: Center(
                            child: Text(
                              '${originalIndex + 1}',
                              style: TextStyle(
                                color: isCurrentChapter
                                    ? Theme.of(context).primaryColor
                                    : Colors.grey[600],
                                fontSize: 14,
                                fontWeight: isCurrentChapter ? FontWeight.w600 : FontWeight.normal,
                              ),
                            ),
                          ),
                        ),
                        title: Text(
                          chapter.title,
                          style: TextStyle(
                            color: isCurrentChapter
                                ? Theme.of(context).primaryColor
                                : Colors.black87,
                            fontWeight: isCurrentChapter ? FontWeight.w600 : FontWeight.normal,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: isCurrentChapter
                            ? Icon(
                                Icons.play_arrow,
                                color: Theme.of(context).primaryColor,
                              )
                            : null,
                        selected: isCurrentChapter,
                        selectedTileColor: Theme.of(context).primaryColor.withValues(alpha: 0.1),
                        onTap: () {
                          // Jump to selected chapter
                          ref.read(readerProvider.notifier).jumpTo(originalIndex, 0);
                          Navigator.of(context).pop();
                        },
                        ),
                      );
                    },
                  ),
          ),

          // Footer info
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(4)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.info_outline, size: 16, color: Colors.grey[600]),
                const SizedBox(width: 8),
                Text(
                  '当前: 第${currentIndex + 1}章',
                  style: TextStyle(
                    color: Colors.grey[600],
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
