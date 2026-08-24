import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/models/simple_models.dart';
import '../providers/reader_provider.dart';

class ReaderSettingsDialog extends ConsumerStatefulWidget {
  const ReaderSettingsDialog({super.key});

  @override
  ConsumerState<ReaderSettingsDialog> createState() => _ReaderSettingsDialogState();
}

class _ReaderSettingsDialogState extends ConsumerState<ReaderSettingsDialog> {
  bool _removeDuplicateTitle = true;
  bool _reSegment = false;
  ChineseConvertType _chineseConvert = ChineseConvertType.none;
  final List<ReplaceRuleItem> _replaceRules = [];
  final TextEditingController _patternController = TextEditingController();
  final TextEditingController _replacementController = TextEditingController();
  
  // Content cleaning settings
  bool _removeHtmlTags = true;
  bool _removeAds = true;
  bool _smartParagraph = true;

  // 字形样式开关
  bool _boldEnabled = true;
  bool _italicEnabled = true;

  @override
  void initState() {
    super.initState();
    // 回读当前生效的配置：重开对话框必须显示真实状态，
    // 否则再次「应用」会用本地默认值覆盖用户此前的设置
    final n = ref.read(readerProvider.notifier);
    _removeDuplicateTitle = n.removeDuplicateTitle;
    _reSegment = n.reSegment;
    _chineseConvert = n.chineseConvert;
    _replaceRules.addAll(n.replaceRules);
    _removeHtmlTags = n.removeHtmlTags;
    _removeAds = n.removeAds;
    _smartParagraph = n.smartParagraph;
    _boldEnabled = n.boldEnabled;
    _italicEnabled = n.italicEnabled;
  }

  @override
  void dispose() {
    _patternController.dispose();
    _replacementController.dispose();
    super.dispose();
  }

  void _addReplaceRule() {
    final pattern = _patternController.text.trim();
    final replacement = _replacementController.text;

    if (pattern.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入要替换的内容')),
      );
      return;
    }

    setState(() {
      _replaceRules.add(ReplaceRuleItem(
        pattern: pattern,
        replacement: replacement,
        isRegex: false,
        enabled: true,
      ));
      _patternController.clear();
      _replacementController.clear();
    });
  }

  void _removeReplaceRule(int index) {
    setState(() {
      _replaceRules.removeAt(index);
    });
  }

  void _toggleRuleEnabled(int index) {
    setState(() {
      _replaceRules[index] = _replaceRules[index].copyWith(
        enabled: !_replaceRules[index].enabled,
      );
    });
  }

  /// 收集输入框中尚未点「添加规则」的内容为一条规则
  ///
  /// 否则用户填完直接点「应用设置」会静默丢失规则。
  void _collectPendingRule() {
    final pattern = _patternController.text.trim();
    if (pattern.isEmpty) return;

    _replaceRules.add(ReplaceRuleItem(
      pattern: pattern,
      replacement: _replacementController.text,
      isRegex: false,
      enabled: true,
    ));
    _patternController.clear();
    _replacementController.clear();
  }

  Future<void> _applySettings() async {
    // 先收编输入框里未添加的规则，再统一应用：
    // 更新选项 → 失效缓存 → 带锚点重载当前页（即时生效，保持进度）
    _collectPendingRule();
    await ref.read(readerProvider.notifier).applyContentProcessingSettings(
      removeDuplicateTitle: _removeDuplicateTitle,
      reSegment: _reSegment,
      chineseConvert: _chineseConvert,
      replaceRules: List.of(_replaceRules),
      removeHtmlTags: _removeHtmlTags,
      removeAds: _removeAds,
      smartParagraph: _smartParagraph,
      boldEnabled: _boldEnabled,
      italicEnabled: _italicEnabled,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('设置已应用（替换规则 ${_replaceRules.length} 条）')),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
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
                const Icon(Icons.tune, color: Colors.white),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    '内容处理设置',
                    style: TextStyle(
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

          // Settings content
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Content cleaning section
                _buildSectionHeader('内容净化'),
                const SizedBox(height: 8),
                _buildSwitchTile(
                  title: '清理 HTML 标签',
                  subtitle: '移除内容中的 <p>、<div>、<br> 等 HTML 标签',
                  value: _removeHtmlTags,
                  onChanged: (value) {
                    setState(() => _removeHtmlTags = value);
                  },
                ),
                _buildSwitchTile(
                  title: '移除广告内容',
                  subtitle: '自动识别并删除常见广告模式',
                  value: _removeAds,
                  onChanged: (value) {
                    setState(() => _removeAds = value);
                  },
                ),
                _buildSwitchTile(
                  title: '智能分段',
                  subtitle: '自动优化段落间距，提升阅读体验',
                  value: _smartParagraph,
                  onChanged: (value) {
                    setState(() => _smartParagraph = value);
                  },
                ),

                const SizedBox(height: 24),

                // Basic settings section
                _buildSectionHeader('基础设置'),
                const SizedBox(height: 8),
                _buildSwitchTile(
                  title: '去除重复标题',
                  subtitle: '自动删除章节内容开头的重复标题',
                  value: _removeDuplicateTitle,
                  onChanged: (value) {
                    setState(() => _removeDuplicateTitle = value);
                  },
                ),
                _buildSwitchTile(
                  title: '智能重新分段',
                  subtitle: '优化段落分割，改善阅读体验',
                  value: _reSegment,
                  onChanged: (value) {
                    setState(() => _reSegment = value);
                  },
                ),

                const SizedBox(height: 24),

                // 字形样式 section（EPUB 行内粗斜体；TXT 章节标题加粗）
                _buildSectionHeader('字形样式'),
                const SizedBox(height: 8),
                _buildSwitchTile(
                  title: '还原粗体',
                  subtitle:
                      '原书 b/strong 等标记以粗体显示（TXT 为章节标题加粗）',
                  value: _boldEnabled,
                  onChanged: (value) {
                    setState(() => _boldEnabled = value);
                  },
                ),
                _buildSwitchTile(
                  title: '还原斜体',
                  subtitle: '原书 i/em 等标记以斜体显示（仅 EPUB 生效）',
                  value: _italicEnabled,
                  onChanged: (value) {
                    setState(() => _italicEnabled = value);
                  },
                ),

                const SizedBox(height: 24),

                // Chinese conversion section
                _buildSectionHeader('简繁转换'),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey[300]!),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    children: ChineseConvertType.values.map((type) {
                      return ListTile(
                        title: Text(type.label),
                        leading: Radio<ChineseConvertType>(
                          value: type,
                          groupValue: _chineseConvert,
                          onChanged: (value) {
                            setState(() => _chineseConvert = value!);
                          },
                        ),
                        onTap: () {
                          setState(() => _chineseConvert = type);
                        },
                      );
                    }).toList(),
                  ),
                ),

                const SizedBox(height: 24),

                // Replace rules section
                _buildSectionHeader('替换规则'),
                const SizedBox(height: 8),
                
                // Add rule input
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey[50],
                    border: Border.all(color: Colors.grey[300]!),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '添加新规则',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _patternController,
                        decoration: const InputDecoration(
                          labelText: '要替换的文本',
                          hintText: '例如：主角',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _replacementController,
                        decoration: const InputDecoration(
                          labelText: '替换为',
                          hintText: '例如：李明',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerRight,
                        child: ElevatedButton.icon(
                          onPressed: _addReplaceRule,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('添加规则'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // Rules list
                if (_replaceRules.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(24),
                    alignment: Alignment.center,
                    child: Text(
                      '暂无替换规则',
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                  )
                else
                  ..._replaceRules.asMap().entries.map((entry) {
                    final index = entry.key;
                    final rule = entry.value;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: Checkbox(
                          value: rule.enabled,
                          onChanged: (_) => _toggleRuleEnabled(index),
                        ),
                        title: Text(
                          '${rule.pattern} → ${rule.replacement}',
                          style: TextStyle(
                            decoration: rule.enabled ? null : TextDecoration.lineThrough,
                            color: rule.enabled ? null : Colors.grey,
                          ),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete, color: Colors.red),
                          onPressed: () => _removeReplaceRule(index),
                        ),
                      ),
                    );
                  }).toList(),
              ],
            ),
          ),

          // Footer buttons
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(4)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _applySettings,
                    child: const Text('应用设置'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: Colors.black87,
      ),
    );
  }

  Widget _buildSwitchTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey[300]!),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SwitchListTile(
        title: Text(title),
        subtitle: Text(
          subtitle,
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}
