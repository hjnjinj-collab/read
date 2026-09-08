import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/reader_provider.dart';
import '../../../../core/models/simple_models.dart';

/// A30：书内全文搜索对话框
///
/// 搜索计算全在 Rust 线程池（单次异步 FFI），本 UI 仅发起调用与渲染结果；
/// 结果点击跳转复用书签机制（章节 + 字符锚点，`jumpToSearchHit`）。
class BookSearchDialog extends ConsumerStatefulWidget {
  const BookSearchDialog({super.key});

  @override
  ConsumerState<BookSearchDialog> createState() => _BookSearchDialogState();
}

class _BookSearchDialogState extends ConsumerState<BookSearchDialog> {
  final _controller = TextEditingController();
  List<SearchHit>? _hits;
  bool _searching = false;
  String? _error;

  /// A30b：捕获 notifier 供 dispose 使用（dispose 中不再走 ref）
  late final ReaderNotifier _notifier =
      ref.read(readerProvider.notifier);

  @override
  void initState() {
    super.initState();
    // A30b 真机修复：查找只是查找——对话框存活期间冻结视口尺寸处理，
    // 软键盘弹出/收起动画不得触发背景内容重排；只有点击搜索结果
    // （jumpToSearchHit，先 pop 后跳转）才允许切换内容。
    _notifier.setViewportResizeFrozen(true);
  }

  @override
  void dispose() {
    // 解冻：键盘收起动画的中间尺寸经 provider 防抖收敛，最终值与
    // 冻结前一致则零重排（背景内容自始至终不动）
    _notifier.setViewportResizeFrozen(false);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _doSearch() async {
    final query = _controller.text.trim();
    if (query.isEmpty || _searching) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final hits = await ref.read(readerProvider.notifier).searchInBook(query);
      if (!mounted) return;
      setState(() {
        _hits = hits;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '搜索失败: $e';
        _searching = false;
      });
    }
  }

  /// 摘录高亮：命中词分段着色（锚定 [hit.matchOffsetInExcerpt]，
  /// 命中长度 = 搜索词长度——多简繁变体命中时以原词长度近似）
  List<TextSpan> _buildExcerptSpans(SearchHit hit, String query) {
    final matchLen = query.trim().length;
    final start = hit.matchOffsetInExcerpt.clamp(0, hit.excerpt.length);
    final end = (start + matchLen).clamp(start, hit.excerpt.length);
    return [
      TextSpan(text: hit.excerpt.substring(0, start)),
      TextSpan(
        text: hit.excerpt.substring(start, end),
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
      TextSpan(text: hit.excerpt.substring(end)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerProvider);
    final chapters = state.chapters;

    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('书内搜索')),
          IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: '输入关键词搜索全书',
                isDense: true,
                suffixIcon: IconButton(
                  tooltip: '搜索',
                  icon: const Icon(Icons.search),
                  onPressed: _searching ? null : _doSearch,
                ),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _doSearch(),
            ),
            const SizedBox(height: 8),
            if (_searching)
              const Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              )
            else if (_hits == null)
              const Expanded(
                child: Center(child: Text('输入关键词后回车搜索全书')),
              )
            else if (_hits!.isEmpty)
              const Expanded(child: Center(child: Text('未找到匹配内容')))
            else
              Expanded(
                child: ListView.separated(
                  itemCount: _hits!.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final hit = _hits![i];
                    final chapterTitle = hit.chapterIndex < chapters.length
                        ? chapters[hit.chapterIndex].title
                        : '第 ${hit.chapterIndex + 1} 章';
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.article_outlined, size: 18),
                      title: RichText(
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        text: TextSpan(
                          style: DefaultTextStyle.of(context).style,
                          children: _buildExcerptSpans(hit, _controller.text),
                        ),
                      ),
                      subtitle: Text(
                        chapterTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        ref
                            .read(readerProvider.notifier)
                            .jumpToSearchHit(hit);
                      },
                    );
                  },
                ),
              ),
          ],
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
