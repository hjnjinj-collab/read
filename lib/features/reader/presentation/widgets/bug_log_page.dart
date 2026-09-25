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
    ('15 分', Duration(minutes: 15)),
    ('30 分', Duration(minutes: 30)),
    ('60 分', Duration(minutes: 60)),
  ];
  static const _levels = ['all', 'error', 'warn', 'info'];

  int _winIndex = 1; // 默认 30 分钟
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
    // 节流：帧末刷新
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reload();
    });
  }

  void _reload() {
    final rows = TraceRingBuffer.instance.query(
      within: _windows[_winIndex].$2,
      keyword: _kwCtrl.text,
      level: _level,
    );
    setState(() => _rows = rows.reversed.toList()); // 新→旧
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
              // 时间窗 + 级别
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
                  const SizedBox(width: 4),
                  for (final lv in _levels)
                    ChoiceChip(
                      label: Text(switch (lv) {
                        'all' => '全部',
                        'error' => '错误',
                        'warn' => '警告',
                        _ => '信息',
                      }),
                      selected: _level == lv,
                      onSelected: (_) {
                        setState(() => _level = lv);
                        _reload();
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _kwCtrl,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '过滤关键字（事件名 / 字段）',
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
                    '环形缓冲 · 最多 60 分钟 / 4000 条',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
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
