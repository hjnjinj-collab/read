import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:liquid_glass_easy/src/widgets/components/liquid_glass_segmented.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../core/theme/app_theme.dart' show AppGlass;
import '../../../../core/theme/reader_menu_icons.dart';
import '../../../shell/providers/shell_settings.dart';
import '../diagnostics/reader_trace.dart';

/// Bug 收集 / 日志回溯页。
///
/// - 时间窗 15s / 2min / 15min（环形缓冲）
/// - 内置分类：阅读 / 翻页 / 分页 / 图片 / 错误
/// - 级别：全部 / 错误 / 警告 / 信息
/// - 导出（复制全部）· 手动清空
/// - 过滤控件用液态形变分段（与壳层 morph 同语言）
class BugLogPage extends ConsumerStatefulWidget {
  const BugLogPage({super.key});

  @override
  ConsumerState<BugLogPage> createState() => _BugLogPageState();
}

class _BugLogPageState extends ConsumerState<BugLogPage> {
  static const _windowLabels = ['15 秒', '2 分', '15 分'];
  static const _windowValues = [
    Duration(seconds: 15),
    Duration(minutes: 2),
    Duration(minutes: 15),
  ];
  static const _catLabels = ['全部', '阅读', '翻页', '分页', '图片', '错误'];
  static const _catKeys = ['all', 'read', 'turn', 'page', 'image', 'error'];
  static const _levelLabels = ['全部', '错误', '警告', '信息'];
  static const _levelKeys = ['all', 'error', 'warn', 'info'];

  int _winIndex = 1;
  int _catIndex = 0;
  int _levelIndex = 0;
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
    final cat = _catKeys[_catIndex];
    final level = cat == 'error' ? 'error' : _levelKeys[_levelIndex];
    final rows = TraceRingBuffer.instance.query(
      within: _windowValues[_winIndex],
      category: cat,
      keyword: _kwCtrl.text,
      level: level,
    );
    setState(() => _rows = rows.reversed.toList());
  }

  Future<void> _export() async {
    // 导出为日志文件（应用文档目录），并复制路径提示
    final text = await readTraceLogs() ??
        _rows.map((e) => '[${e.time.toIso8601String()}] ${e.line}').join('\n');
    try {
      final dir = await getApplicationDocumentsDirectory();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final file = File('${dir.path}/bug_log_$stamp.log');
      await file.writeAsString(text, flush: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已导出：${file.path}'),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      // 退回剪贴板
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('写文件失败，已复制到剪贴板：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shell = ref.watch(shellSettingsProvider);
    final lgMotion = shell.lgMotionOn;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题 + 导出 / 清空
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Row(
            children: [
              ReaderMenuGlyph(
                line: ReaderMenuIcons.lineRank,
                fill: ReaderMenuIcons.fillRank,
                style: shell.readerIconStyle,
                size: 18,
                color: scheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                '日志回溯',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${_rows.length} 条',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary,
                  ),
                ),
              ),
              const Spacer(),
              // 导出：主操作，液态胶囊
              _MorphAction(
                label: '导出',
                icon: Icons.ios_share_outlined,
                lgMotion: lgMotion,
                onTap: _export,
              ),
              const SizedBox(width: 8),
              _MorphAction(
                label: '清空',
                icon: Icons.delete_sweep_outlined,
                lgMotion: lgMotion,
                onTap: () {
                  TraceRingBuffer.instance.clear();
                  _reload();
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            children: [
              _FilterRow(
                label: '时间',
                child: _MorphSegmented(
                  labels: _windowLabels,
                  index: _winIndex,
                  lgMotion: lgMotion,
                  onChanged: (i) {
                    setState(() => _winIndex = i);
                    _reload();
                  },
                ),
              ),
              _FilterRow(
                label: '分类',
                child: _MorphSegmented(
                  labels: _catLabels,
                  index: _catIndex,
                  lgMotion: lgMotion,
                  onChanged: (i) {
                    setState(() {
                      _catIndex = i;
                      // 错误分类：级别锁「错误」
                      if (_catKeys[i] == 'error') _levelIndex = 1;
                    });
                    _reload();
                  },
                ),
              ),
              if (_catKeys[_catIndex] != 'error')
                _FilterRow(
                  label: '级别',
                  child: _MorphSegmented(
                    labels: _levelLabels,
                    index: _levelIndex,
                    lgMotion: lgMotion,
                    onChanged: (i) {
                      setState(() => _levelIndex = i);
                      _reload();
                    },
                  ),
                ),
              _FilterRow(
                label: '搜索',
                child: TextField(
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
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onChanged: (_) => _reload(),
                ),
              ),
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
                ],
              ),
              const SizedBox(height: 4),
              const Divider(height: 1),
              if (_rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: Text(
                      '暂无匹配日志',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                )
              else
                for (final e in _rows) _LogTile(e: e),
            ],
          ),
        ),
      ],
    );
  }
}

/// 过滤行：左侧短标签 + 右侧控件
class _FilterRow extends StatelessWidget {
  const _FilterRow({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 36,
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// 液态形变分段（胶囊 morph + 果冻，与壳层同语言）
class _MorphSegmented extends StatelessWidget {
  const _MorphSegmented({
    required this.labels,
    required this.index,
    required this.onChanged,
    required this.lgMotion,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;
  final bool lgMotion;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final light = scheme.brightness == Brightness.light;
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: LiquidGlassSegmented(
        segments: labels,
        selectedIndex: index.clamp(0, labels.length - 1),
        onChanged: onChanged,
        width: double.infinity,
        height: 40,
        padding: 4,
        style: LiquidGlassStyle(
          shape: LiquidGlassShape.continuousRoundedRectangle(
            cornerRadius: 18,
            borderWidth: 1.0,
            borderColor: Colors.white.withValues(
              alpha: light ? 0.42 : 0.24,
            ),
            lightIntensity: 1.0,
          ),
          appearance: LiquidGlassAppearance(
            color: Colors.transparent,
            blur: const LiquidGlassBlur(sigmaX: 0, sigmaY: 0),
            shadow: null,
          ),
          refraction: const LiquidGlassRefraction(
            distortion: 0.05,
            distortionWidth: 14,
            chromaticAberration: 0.001,
          ),
        ),
        pillStyle: LiquidGlassSegmentedPillStyle(
          glass: lgMotion,
          animated: true,
          growHeight: lgMotion ? 6 : 0,
          glassStyle: LiquidGlassStyle(
            appearance: LiquidGlassAppearance(
              color: Colors.transparent,
              blur: const LiquidGlassBlur(sigmaX: 1.5, sigmaY: 1.5),
              shadow: null,
            ),
            refraction: const LiquidGlassRefraction(
              distortion: 0.08,
              distortionWidth: 12,
            ),
          ),
          restStyle: LiquidGlassStyle(
            appearance: LiquidGlassAppearance(
              color: AppGlass.restPillTint(scheme),
            ),
          ),
        ),
        labelStyle: LiquidGlassSegmentedLabelStyle(
          selectedColor: scheme.primary,
          unselectedColor: scheme.onSurfaceVariant,
          fontSize: 12,
          selectedFontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 液态形变操作钮（导出 / 清空）
class _MorphAction extends StatelessWidget {
  const _MorphAction({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.lgMotion,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool lgMotion;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedScale(
        scale: 1,
        duration: Duration(milliseconds: lgMotion ? 160 : 0),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppGlass.restPillTint(scheme),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.white.withValues(
                alpha: scheme.brightness == Brightness.light ? 0.42 : 0.24,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: scheme.primary),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.e});
  final TraceEvent e;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (e.level) {
      'error' => scheme.error,
      'warn' => scheme.tertiary,
      _ => scheme.onSurfaceVariant,
    };
    final t = e.time;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
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
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}  '
        '${e.fields.isEmpty ? '' : e.fields.entries.map((x) => '${x.key}=${x.value}').join(' ')}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: color),
      ),
    );
  }
}
