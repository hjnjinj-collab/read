import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/reader_menu_icons.dart';
import '../../../shell/providers/shell_settings.dart';
import '../diagnostics/reader_trace.dart';

/// Bug 收集 / 日志回溯页（设置 sheet 第 5 页）。
///
/// 数据源：[TraceRingBuffer]（readerTrace 内存环形，默认 60 分钟）。
/// 过滤：时间窗 / 级别 / 关键字（事件名或字段）。
class BugLogPage extends ConsumerStatefulWidget {
  const BugLogPage({super.key});

  @override
  ConsumerState<BugLogPage> createState() => _BugLogPageState();
}

class _BugLogPageState extends ConsumerState<BugLogPage> {
  static const _windows = <(String, Duration)>[
    ('15 秒', Duration(seconds: 15)),
    ('2 分', Duration(minutes: 2)),
    ('15 分', Duration(minutes: 15)),
  ];

  /// 内置过滤分类（对应 TraceRingBuffer.categories）
  static const _cats = <(String, String)>[
    ('all', '全部'),
    ('read', '阅读'),
    ('turn', '翻页'),
    ('page', '分页'),
    ('image', '图片'),
    ('error', '错误'),
  ];

  static const _levels = ['all', 'error', 'warn', 'info'];

  int _winIndex = 1; // 默认 2 分钟
  String _category = 'all';
  String _level = 'all';
  final _kwCtrl = TextEditingController();
  List<TraceEvent> _rows = const [];
  bool _autoRefresh = true;

  @override
  void initState() {
    super.initState();
    _reload();
    TraceRingBuffer.instance.addListener(_onRing);
  }

  @override
  void dispose() {
    TraceRingBuffer.instance.removeListener(_onRing);
    _kwCtrl.dispose();
    super.dispose();
  }

  void _onRing() {
    if (!mounted || !_autoRefresh) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reload();
    });
  }

  void _reload() {
    // 分类=error 时自动走 error 级别
    final level = _category == 'error' ? 'error' : _level;
    final rows = TraceRingBuffer.instance.query(
      within: _windows[_winIndex].$2,
      category: _category,
      keyword: _kwCtrl.text,
      level: level,
    );
    setState(() => _rows = rows.reversed.toList());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final iconStyle =
        ref.watch(shellSettingsProvider).readerIconStyle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 过滤条
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ReaderMenuGlyph(
                    line: ReaderMenuIcons.lineRank,
                    fill: ReaderMenuIcons.fillRank,
                    style: iconStyle,
                    size: 18,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '日志回溯 · ${_rows.length} 条',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '导出全部日志',
                    icon: const Icon(Icons.copy_all_outlined, size: 18),
                    onPressed: () async {
                      final text = await readTraceLogs();
                      if (text == null) return;
                      await Clipboard.setData(ClipboardData(text: text));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('日志已复制到剪贴板'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                  ),
                  IconButton(
                    tooltip: '清空内存缓冲',
                    icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                    onPressed: () {
                      TraceRingBuffer.instance.clear();
                      _reload();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // 时间窗
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (var i = 0; i < _windows.length; i++)
                    ChoiceChip(
                      label: Text(_windows[i].$1),
                      selected: _winIndex == i,
                      onSelected: (_) {
                        setState(() => _winIndex = i);
                        _reload();
                      },
                    ),
                ],
              ),
              const SizedBox(height: 6),
              // 内置分类：阅读 / 翻页 / 分页 / 图片 / 错误
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final (key, label) in _cats)
                    ChoiceChip(
                      label: Text(label),
                      selected: _category == key,
                      onSelected: (_) {
                        setState(() {
                          _category = key;
                          // 错误分类锁定 error 级
                          if (key == 'error') _level = 'error';
                        });
                        _reload();
                      },
                    ),
                  if (_category != 'error') ...[
                    const SizedBox(width: 4),
                    for (final lv in _levels)
                      ChoiceChip(
                        label: Text(switch (lv) {
                          'all' => '级别·全部',
                          'error' => '级别·错误',
                          'warn' => '级别·警告',
                          _ => '级别·信息',
                        }),
                        selected: _level == lv,
                        onSelected: (_) {
                          setState(() => _level = lv);
                          _reload();
                        },
                      ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _kwCtrl,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '补充关键字（可选）',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: _kwCtrl.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 16),
                          onPressed: () {
                            _kwCtrl.clear();
                            _reload();
                          },
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onChanged: (_) => _reload(),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Switch(
                    value: _autoRefresh,
                    onChanged: (v) => setState(() => _autoRefresh = v),
                  ),
                  Text(
                    '自动刷新',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '环形 · 最多 15 分钟',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () {
                      TraceRingBuffer.instance.clear();
                      _reload();
                    },
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('清空'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _rows.isEmpty
              ? Center(
                  child: Text(
                    '暂无匹配日志',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              : ListView.builder(
                  itemCount: _rows.length,
                  itemBuilder: (context, i) {
                    final e = _rows[i];
                    final color = switch (e.level) {
                      'error' => scheme.error,
                      'warn' => scheme.tertiary,
                      _ => scheme.onSurfaceVariant,
                    };
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        switch (e.level) {
                          'error' => Icons.error_outline,
                          'warn' => Icons.warning_amber_outlined,
                          _ => Icons.info_outline,
                        },
                        size: 18,
                        color: color,
                      ),
                      title: Text(
                        e.event,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      subtitle: Text(
                        '${e.time.hour.toString().padLeft(2, '0')}:'
                        '${e.time.minute.toString().padLeft(2, '0')}:'
                        '${e.time.second.toString().padLeft(2, '0')}  '
                        '${e.fields.isEmpty ? '' : e.fields.entries.map((x) => '${x.key}=${x.value}').join(' ')}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: color),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
