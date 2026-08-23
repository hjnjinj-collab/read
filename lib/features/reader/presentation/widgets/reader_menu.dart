import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../providers/reader_provider.dart';
import 'chapter_list_dialog.dart';
import 'reader_settings_dialog.dart';

class ReaderMenu extends ConsumerWidget {
  final VoidCallback onClose;

  const ReaderMenu({
    Key? key,
    required this.onClose,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(readerProvider);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Chapter info
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      state.chapters.isNotEmpty
                          ? state.chapters[state.currentChapterIndex].title
                          : 'No chapter',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: onClose,
                  ),
                ],
              ),
            ),

            const Divider(height: 1),

            // Progress slider
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Row(
                children: [
                  const Icon(Icons.book, size: 20),
                  Expanded(
                    child: Slider(
                      value: state.currentPageIndex.toDouble(),
                      min: 0,
                      max: 100, // TODO: Calculate actual page count
                      onChanged: (value) {
                        // TODO: Jump to page
                      },
                    ),
                  ),
                  Text(
                    '${state.currentPageIndex + 1}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),

            const Divider(height: 1),

            // Font size control
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Row(
                children: [
                  const Text('Font Size:'),
                  const SizedBox(width: 16),
                  IconButton(
                    icon: const Icon(Icons.remove),
                    onPressed: () {
                      // TODO: Decrease font size
                    },
                  ),
                  const Text('18'),
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () {
                      // TODO: Increase font size
                    },
                  ),
                ],
              ),
            ),

            const Divider(height: 1),

            // Action buttons
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _MenuButton(
                    icon: Icons.list,
                    label: 'Chapters',
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (context) => const ChapterListDialog(),
                      );
                    },
                  ),
                  _MenuButton(
                    icon: Icons.bookmark,
                    label: 'Bookmarks',
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (context) => const BookmarkListDialog(),
                      );
                    },
                  ),
                  _MenuButton(
                    icon: Icons.settings,
                    label: 'Settings',
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (context) => const ReaderSettingsDialog(),
                      );
                    },
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

class _MenuButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _MenuButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// 书签列表对话框：添加（当前位置）、跳转、删除
///
/// 进度与书签共用「章节 + 章内字符锚点」机制，跨启动精确恢复。
class BookmarkListDialog extends ConsumerStatefulWidget {
  const BookmarkListDialog({super.key});

  @override
  ConsumerState<BookmarkListDialog> createState() => _BookmarkListDialogState();
}

class _BookmarkListDialogState extends ConsumerState<BookmarkListDialog> {
  late Future<List<Bookmark>> _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _future = ref.read(readerProvider.notifier).bookmarksForCurrentBook();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('书签')),
          IconButton(
            tooltip: '在当前位置添加书签',
            icon: const Icon(Icons.bookmark_add),
            onPressed: () async {
              await ref.read(readerProvider.notifier).addBookmark();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('书签已添加')),
                );
              }
              _reload();
            },
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 320,
        child: FutureBuilder<List<Bookmark>>(
          future: _future,
          builder: (context, snap) {
            final items = snap.data ?? const [];
            if (items.isEmpty) {
              return const Center(child: Text('暂无书签'));
            }
            return ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final m = items[i];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.bookmark, size: 18),
                  title: Text(
                    m.preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '第 ${m.chapterIndex + 1} 章',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () async {
                      await ref.read(readerProvider.notifier).deleteBookmark(m.id);
                      _reload();
                    },
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    ref.read(readerProvider.notifier).jumpToBookmark(m);
                  },
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
