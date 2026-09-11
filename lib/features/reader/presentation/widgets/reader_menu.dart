import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../diagnostics/reader_trace.dart';
import '../providers/reader_provider.dart';
import '../widgets/page_turn/page_turn_types.dart';
import 'chapter_list_dialog.dart';
import 'book_search_dialog.dart';
import 'reader_settings_dialog.dart';

class ReaderMenu extends ConsumerWidget {
  final VoidCallback onClose;
  final PageTurnMode? pageTurnMode;
  final ValueChanged<PageTurnMode>? onPageTurnModeChanged;

  /// 2026-09-03: 翻页速度三档（快/中/慢，当前作用于水波纹动画时长）
  final PageTurnSpeed? pageTurnSpeed;
  final ValueChanged<PageTurnSpeed>? onPageTurnSpeedChanged;

  /// 2026-09-04 P1 暗黑主题：当前是否暗色 + 切换回调
  final bool? themeDark;
  final VoidCallback? onToggleTheme;

  const ReaderMenu({
    Key? key,
    required this.onClose,
    this.pageTurnMode,
    this.onPageTurnModeChanged,
    this.pageTurnSpeed,
    this.onPageTurnSpeedChanged,
    this.themeDark,
    this.onToggleTheme,
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
                    // 2026-09-04 P1 暗黑主题：阅读内容区明暗切换
                    //（菜单/对话框保持系统亮色样式，见动画架构文档）
                    tooltip: themeDark == true ? '切回亮色' : '切换暗色',
                    icon: Icon(
                      themeDark == true
                          ? Icons.light_mode
                          : Icons.dark_mode,
                      size: 22,
                    ),
                    onPressed: onToggleTheme,
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
              child: Builder(
                builder: (context) {
                  final notifier = ref.read(readerProvider.notifier);
                  final pageCount = state.currentChapterPageCount;
                  final maxIndex = (pageCount - 1).clamp(0, 1 << 30).toDouble();
                  final current = state.currentPageIndex
                      .clamp(0, maxIndex.toInt())
                      .toDouble();
                  return Row(
                    children: [
                      const Icon(Icons.book, size: 20),
                      Expanded(
                        child: Slider(
                          value: pageCount <= 0 ? 0 : current,
                          min: 0,
                          max: pageCount <= 0 ? 1 : maxIndex,
                          onChanged: pageCount <= 0
                              ? null
                              : (value) {
                                  // 拖动中不跳页，松手再跳（避免连发 FFI）
                                },
                          onChangeEnd: pageCount <= 0
                              ? null
                              : (value) {
                                  notifier.jumpToPage(value.round());
                                },
                        ),
                      ),
                      Text(
                        pageCount <= 0
                            ? '${state.currentPageIndex + 1}'
                            : '${state.currentPageIndex + 1}/$pageCount',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  );
                },
              ),
            ),

            const Divider(height: 1),

            // Font size control
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Builder(
                builder: (context) {
                  final notifier = ref.read(readerProvider.notifier);
                  final size = notifier.fontSize.round();
                  return Row(
                    children: [
                      const Text('字号:'),
                      const SizedBox(width: 16),
                      IconButton(
                        icon: const Icon(Icons.remove),
                        onPressed: size <= 10
                            ? null
                            : () => notifier.setFontSize((size - 1).toDouble()),
                      ),
                      Text('$size'),
                      IconButton(
                        icon: const Icon(Icons.add),
                        onPressed: size >= 40
                            ? null
                            : () => notifier.setFontSize((size + 1).toDouble()),
                      ),
                    ],
                  );
                },
              ),
            ),

            const Divider(height: 1),

            // P5: 翻页模式选择 (2026-09-03: 添加水波纹选项)
            if (onPageTurnModeChanged != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: Row(
                  children: [
                    const Icon(Icons.swap_horiz, size: 20),
                    const SizedBox(width: 12),
                    const Text('翻页方式:', style: TextStyle(fontSize: 14)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _PageTurnModeChip(
                              label: '卷曲',
                              mode: PageTurnMode.simulation,
                              currentMode: pageTurnMode ?? PageTurnMode.simulation,
                              onSelected: onPageTurnModeChanged!,
                            ),
                            const SizedBox(width: 8),
                            _PageTurnModeChip(
                              label: '水波纹',
                              mode: PageTurnMode.ripple,
                              currentMode: pageTurnMode ?? PageTurnMode.simulation,
                              onSelected: onPageTurnModeChanged!,
                            ),
                            const SizedBox(width: 8),
                            _PageTurnModeChip(
                              label: '坍塌',
                              mode: PageTurnMode.collapse,
                              currentMode: pageTurnMode ?? PageTurnMode.simulation,
                              onSelected: onPageTurnModeChanged!,
                            ),
                            const SizedBox(width: 8),
                            _PageTurnModeChip(
                              label: '滚动',
                              mode: PageTurnMode.verticalScroll,
                              currentMode: pageTurnMode ?? PageTurnMode.simulation,
                              onSelected: onPageTurnModeChanged!,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            const Divider(height: 1),

            // 2026-09-03: 翻页速度选择（快/中/慢三档）
            if (onPageTurnSpeedChanged != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: Row(
                  children: [
                    const Icon(Icons.speed, size: 20),
                    const SizedBox(width: 12),
                    const Text('翻页速度:', style: TextStyle(fontSize: 14)),
                    const SizedBox(width: 12),
                    for (final speed in PageTurnSpeed.values) ...[
                      if (speed != PageTurnSpeed.values.first)
                        const SizedBox(width: 8),
                      _PageTurnSpeedChip(
                        speed: speed,
                        currentSpeed: pageTurnSpeed ?? PageTurnSpeed.medium,
                        onSelected: onPageTurnSpeedChanged!,
                      ),
                    ],
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
                    icon: Icons.search,
                    label: '搜索',
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (context) => const BookSearchDialog(),
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
                    icon: Icons.highlight,
                    label: '笔记',
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (context) => const NoteListDialog(),
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
                  _MenuButton(
                    icon: Icons.receipt_long,
                    label: '日志导出',
                    onTap: () => _exportTraceLogs(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A28 排障：导出阅读器诊断日志（FilePicker SAF，无需存储权限）
  Future<void> _exportTraceLogs(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final content = await readTraceLogs();
    if (content == null || content.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('暂无日志')));
      return;
    }
    try {
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-');
      // file_picker 12.x：纯静态 API，bytes 经 SAF 写出（无需存储权限）
      final result = await FilePicker.saveFile(
        fileName: 'reader_trace_$ts.log',
        bytes: Uint8List.fromList(utf8.encode(content)),
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(result != null ? '日志已导出' : '已取消导出'),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导出失败: $e')));
    }
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

/// A31: 笔记列表对话框：查看、跳转、删除、编辑备注
class NoteListDialog extends ConsumerStatefulWidget {
  const NoteListDialog({super.key});

  @override
  ConsumerState<NoteListDialog> createState() => _NoteListDialogState();
}

class _NoteListDialogState extends ConsumerState<NoteListDialog> {
  late Future<List<NoteListItem>> _future;

  static const _colorDots = [
    Color(0xFFFFD54F),
    Color(0xFF81C784),
    Color(0xFF64B5F6),
    Color(0xFFF48FB1),
    Color(0xFFE53935),
  ];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _future = ref.read(readerProvider.notifier).loadNotesWithPages();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('笔记'),
      content: SizedBox(
        width: double.maxFinite,
        height: 360,
        child: FutureBuilder<List<NoteListItem>>(
          future: _future,
          builder: (context, snap) {
            final items = snap.data ?? const [];
            if (items.isEmpty) {
              return const Center(child: Text('暂无笔记\n长按文字可添加'));
            }
            return ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final item = items[i];
                final n = item.note;
                final colorDot = _colorDots[n.colorIndex.clamp(0, 4)];
                final pageLabel =
                    item.pageIndex != null ? ' · 第 ${item.pageIndex! + 1} 页' : '';
                return ListTile(
                  dense: true,
                  leading: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: colorDot,
                      shape: BoxShape.circle,
                    ),
                  ),
                  title: Text(
                    n.excerpt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    [
                      '第 ${n.chapterIndex + 1} 章$pageLabel',
                      if (n.note != null && n.note!.isNotEmpty) '备注: ${n.note}',
                    ].join(' · '),
                    style: const TextStyle(fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        tooltip: '复制',
                        onPressed: () async {
                          final buf = StringBuffer(n.excerpt);
                          if (n.note != null && n.note!.isNotEmpty) {
                            buf.write('\n${n.note}');
                          }
                          await Clipboard.setData(
                            ClipboardData(text: buf.toString()),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('已复制到剪贴板'),
                                duration: Duration(seconds: 1),
                              ),
                            );
                          }
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit, size: 18),
                        tooltip: '编辑备注',
                        onPressed: () => _editNote(n),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        onPressed: () async {
                          await ref.read(readerProvider.notifier).deleteNote(n.id);
                          _reload();
                        },
                      ),
                    ],
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    ref.read(readerProvider.notifier).jumpToNote(n);
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

  Future<void> _editNote(Note note) async {
    final controller = TextEditingController(text: note.note ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑备注'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.yellow.shade50,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                note.excerpt.length > 50
                    ? '${note.excerpt.substring(0, 50)}…'
                    : note.excerpt,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: '输入备注…',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null) return;
    await ref.read(readerProvider.notifier).updateNoteText(note.id, result);
    _reload();
  }
}

class _PageTurnModeChip extends StatelessWidget {
  final String label;
  final PageTurnMode mode;
  final PageTurnMode currentMode;
  final ValueChanged<PageTurnMode> onSelected;

  const _PageTurnModeChip({
    required this.label,
    required this.mode,
    required this.currentMode,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = mode == currentMode;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => onSelected(mode),
    );
  }
}

/// 2026-09-03: 翻页速度选择 chip（快/中/慢）
class _PageTurnSpeedChip extends StatelessWidget {
  final PageTurnSpeed speed;
  final PageTurnSpeed currentSpeed;
  final ValueChanged<PageTurnSpeed> onSelected;

  const _PageTurnSpeedChip({
    required this.speed,
    required this.currentSpeed,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = speed == currentSpeed;
    return ChoiceChip(
      label: Text(speed.label),
      selected: isSelected,
      onSelected: (_) => onSelected(speed),
    );
  }
}
