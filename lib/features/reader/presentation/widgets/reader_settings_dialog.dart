import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/models/simple_models.dart';
import '../../../../core/services/reader_font.dart';
import '../../../../core/services/font_provider.dart';
import '../providers/reader_provider.dart';
import '../providers/reader_settings.dart';

class ReaderSettingsDialog extends ConsumerStatefulWidget {
  const ReaderSettingsDialog({super.key});

  @override
  ConsumerState<ReaderSettingsDialog> createState() => _ReaderSettingsDialogState();
}

class _ReaderSettingsDialogState extends ConsumerState<ReaderSettingsDialog> {
  bool _removeDuplicateTitle = true;
  ChineseConvertType _chineseConvert = ChineseConvertType.none;
  final List<ReplaceRuleItem> _replaceRules = [];
  final TextEditingController _patternController = TextEditingController();
  final TextEditingController _replacementController = TextEditingController();

  // Content cleaning settings
  bool _removeHtmlTags = true;
  bool _removeAds = true;
  bool _reSegment = false; // A35-L1: 智能分段增强

  // A35-L2: 分段规则（内置 + 用户同模型）
  final List<SegmentRuleItem> _segmentRules = [];
  final TextEditingController _segPatternController = TextEditingController();
  int _segRuleAction = SegmentRuleItem.actionForceBreakAfter; // 新规则动作下拉

  // 字形样式开关
  bool _boldEnabled = true;
  bool _italicEnabled = true;

  // P6 字号/行距滑杆（即时生效：onChangedEnd 落地重排）
  double _fontSize = 18.0;
  double _lineHeight = 1.5;

  // 分页填充率（内容区利用率，TXT/EPUB 统一消费）
  double _pageFillThreshold = 1.0;

  // 注释显示开关
  bool _showComments = true;

  // A34.1：注释样式
  double _commentScale = 0.82;
  String _commentColorPreset = 'blueGray';

  static const List<({String key, String label, Color swatch})> _commentColorPresets = [
    (key: 'blueGray', label: '蓝灰', swatch: Color(0xFF5A6B7A)),
    (key: 'gray', label: '灰', swatch: Color(0xFF888888)),
    (key: 'sepia', label: '棕灰', swatch: Color(0xFF6B5A4A)),
  ];

  // M9-P4：段落格式设置
  bool _enableIndent = true;
  int _indentSizeChars = 2;
  double _paragraphSpacingMultiplier = 1.0;
  // M9 三选一已退役；字段保留以兼容持久化读入，恒写 0
  // M9.2：超长段切分阈值（字，用户可调）
  int _smartSplitThreshold = 50;
  int _aggressiveSplitThreshold = 100;

  // P2 两端对齐（EPUB 书内 justify 恒启用；TXT/Left 段跟随本开关）
  bool _justify = false;

  // P3 行尾标点压缩悬挂
  bool _punctuationCompress = false;

  // 坍塌动画样式（2026-09-04 P1 设置化：变更即时生效+落库，不经「应用设置」）
  double _collapseBlockSize = 36;
  double _collapseSlideDistance = 45;
  int _collapseShadowColorValue = 0xFF333630;

  /// 阴影色预设色板（首位 = 默认色）
  static const List<int> _collapseShadowPresets = [
    0xFF333630, // 深灰（默认）
    0xFF1A1A1A, // 近黑
    0xFF5D4037, // 棕
    0xFF37474F, // 蓝灰
    0xFF3E2723, // 深褐
  ];

  @override
  void initState() {
    super.initState();
    // 回读当前生效的配置：重开对话框必须显示真实状态，
    // 否则再次「应用」会用本地默认值覆盖用户此前的设置
    final n = ref.read(readerProvider.notifier);
    _removeDuplicateTitle = n.removeDuplicateTitle;
    _chineseConvert = n.chineseConvert;
    _replaceRules.addAll(n.replaceRules);
    _removeHtmlTags = n.removeHtmlTags;
    _removeAds = n.removeAds;
    _reSegment = n.reSegment; // A35-L1
    _segmentRules.addAll(n.segmentRules); // A35-L2
    _boldEnabled = n.boldEnabled;
    _italicEnabled = n.italicEnabled;
    _fontSize = n.fontSize;
    _lineHeight = n.lineHeight;
    _pageFillThreshold = n.pageFillThreshold;
    _showComments = n.showComments;
    _commentScale = n.commentScale;
    _commentColorPreset = n.commentColorPreset;
    _enableIndent = n.enableIndent;
    _indentSizeChars = n.indentSizeChars;
    _paragraphSpacingMultiplier = n.paragraphSpacingMultiplier;
    _smartSplitThreshold = n.smartSplitThreshold;
    _aggressiveSplitThreshold = n.aggressiveSplitThreshold;
    _justify = n.justify;
    _punctuationCompress = n.punctuationCompress;
    _collapseBlockSize = n.collapseStyle.blockSize;
    _collapseSlideDistance = n.collapseStyle.slideDistance;
    _collapseShadowColorValue = n.collapseStyle.shadowColorValue;
  }

  @override
  void dispose() {
    _patternController.dispose();
    _replacementController.dispose();
    _segPatternController.dispose();
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

  // ── A35-L2: 分段规则管理 ──

  /// 添加用户分段规则（正则 + 动作下拉）
  void _addSegmentRule() {
    final pattern = _segPatternController.text.trim();
    if (pattern.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入分段规则正则')),
      );
      return;
    }
    // 正则语法预校验
    try {
      RegExp(pattern);
    } on FormatException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('正则语法错误: ${e.message}')),
      );
      return;
    }
    setState(() {
      _segmentRules.add(SegmentRuleItem(
        id: 'user:${DateTime.now().millisecondsSinceEpoch}',
        pattern: pattern,
        action: _segRuleAction,
        enabled: true,
        isRegex: true,
      ));
      _segPatternController.clear();
    });
  }

  void _removeSegmentRule(int index) {
    setState(() => _segmentRules.removeAt(index));
  }

  void _toggleSegmentRule(int index) {
    setState(() {
      _segmentRules[index] =
          _segmentRules[index].copyWith(enabled: !_segmentRules[index].enabled);
    });
  }

  /// 收集输入框中尚未添加的分段规则（防静默丢失）
  void _collectPendingSegmentRule() {
    final pattern = _segPatternController.text.trim();
    if (pattern.isEmpty) return;
    try {
      RegExp(pattern);
    } on FormatException {
      return;
    }
    _segmentRules.add(SegmentRuleItem(
      id: 'user:${DateTime.now().millisecondsSinceEpoch}',
      pattern: pattern,
      action: _segRuleAction,
      enabled: true,
      isRegex: true,
    ));
    _segPatternController.clear();
  }

  /// 坍塌动画参数变更：即时生效（写 notifier → 防抖落库），不经「应用设置」
  /// ——动画样式是即时可感知的视觉参数，整体提交模式反而打断调参手感
  void _updateCollapse({double? blockSize, double? slideDistance, int? shadowColor}) {
    setState(() {
      if (blockSize != null) _collapseBlockSize = blockSize;
      if (slideDistance != null) _collapseSlideDistance = slideDistance;
      if (shadowColor != null) _collapseShadowColorValue = shadowColor;
    });
    ref.read(readerProvider.notifier).setCollapseStyle(CollapseStyle(
          blockSize: _collapseBlockSize,
          slideDistance: _collapseSlideDistance,
          shadowColorValue: _collapseShadowColorValue,
        ));
  }

  Future<void> _applySettings() async {
    // 先收编输入框里未添加的规则，再统一应用：
    // 更新选项 → 失效缓存 → 带锚点重载当前页（即时生效，保持进度）
    _collectPendingRule();
    _collectPendingSegmentRule(); // A35-L2

    // 2026-09-02 优化：显示 loading 进度提示
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(),
      ),
    );

    try {
      await ref.read(readerProvider.notifier).applyContentProcessingSettings(
        removeDuplicateTitle: _removeDuplicateTitle,
        chineseConvert: _chineseConvert,
        replaceRules: List.of(_replaceRules),
        removeHtmlTags: _removeHtmlTags,
        removeAds: _removeAds,
        reSegment: _reSegment, // A35-L1
        segmentRules: List.of(_segmentRules), // A35-L2
        boldEnabled: _boldEnabled,
        italicEnabled: _italicEnabled,
        pageFillThreshold: _pageFillThreshold,
        showComments: _showComments,
        commentScale: _commentScale,
        commentColorPreset: _commentColorPreset,
        enableIndent: _enableIndent,
        indentSizeChars: _indentSizeChars,
        paragraphSpacingMultiplier: _paragraphSpacingMultiplier,
        reParagraphMode: 0, // M9 三选一退役，恒 None
        smartSplitThreshold: _smartSplitThreshold,
        aggressiveSplitThreshold: _aggressiveSplitThreshold,
        justify: _justify,
        punctuationCompress: _punctuationCompress,
      );

      if (!mounted) return;
      
      // 关闭 loading 对话框
      Navigator.of(context).pop();
      
      // 显示成功提示
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('设置已应用（替换规则 ${_replaceRules.length} 条）')),
      );
      
      // 关闭设置对话框
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      
      // 关闭 loading 对话框
      Navigator.of(context).pop();
      
      // 显示错误提示
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('设置应用失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // A30b：不做 viewInsets 布局——本设备 insets 上报不可靠（会报≈整屏
    // 高度，把对话框挤扁）。键盘悬浮只遮住设置列表下半部，滚动可达
    // 任何输入框。
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
                // 字体选择（M9 字体架构：内置 Noto Sans CJK SC + 用户可选）
                _buildSectionHeader('字体'),
                const SizedBox(height: 8),
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey[300]!),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.text_fields),
                        title: const Text('当前字体'),
                        subtitle: Text(
                          ReaderFont.displayName,
                          style: const TextStyle(
                            fontFamily: 'ReaderSerif',
                            fontSize: 14,
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.folder_open),
                        title: const Text('选择本地字体文件'),
                        subtitle: const Text(
                          '支持 .ttf / .otf / .ttc（从设备存储），立即生效并持久化',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          // P6：字体文件复制到应用目录 + 持久化，重启自动恢复
                          final picked =
                              await FontProvider.pickAndLoadCustomFont(context);
                          if (picked != null) {
                            ref.read(readerProvider.notifier).setCustomFont(
                                  fontFamily: picked.fontName,
                                  fontFilePath: picked.persistedPath,
                                );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                      '${picked.displayLabel} 已切换并持久化'),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            }
                            setState(() {}); // 刷新显示名
                          }
                        },
                      ),
                      const Divider(height: 1),
                      // P6：恢复内置字体（仅在当前使用自定义字体时可用）
                      ListTile(
                        leading: const Icon(Icons.restore),
                        title: const Text('恢复内置字体'),
                        enabled: ref
                            .read(readerProvider.notifier)
                            .customFontFamily
                            .isNotEmpty,
                        onTap: () async {
                          await ref
                              .read(readerProvider.notifier)
                              .resetToBuiltinFont();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('已恢复内置 Noto Sans CJK SC'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          }
                          setState(() {}); // 刷新显示名
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // P6 字号/行距滑杆（拖动改显示、松手落地重排——避免逐帧全量排版）
                _buildSliderTile(
                  label: '字号：${_fontSize.round()}',
                  hint: '正文字号（像素）',
                  value: _fontSize,
                  min: 12,
                  max: 32,
                  divisions: 20,
                  onChanged: (value) => setState(() => _fontSize = value),
                  onChangedEnd: (value) {
                    ref.read(readerProvider.notifier).setFontSize(value);
                  },
                ),
                _buildSliderTile(
                  label: '行距：${_lineHeight.toStringAsFixed(2)}',
                  hint: '行高倍率（相对字号）',
                  value: _lineHeight,
                  min: 1.0,
                  max: 2.0,
                  divisions: 20,
                  onChanged: (value) => setState(() => _lineHeight = value),
                  onChangedEnd: (value) {
                    ref.read(readerProvider.notifier).setLineHeight(value);
                  },
                ),
                const SizedBox(height: 16),
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
                  subtitle: '合并软换行：超过阈值后在句末标点处分段，引号自动吸附（TXT/EPUB）',
                  value: _reSegment,
                  onChanged: (value) {
                    setState(() => _reSegment = value);
                  },
                ),
                if (_reSegment)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '分段阈值：$_smartSplitThreshold 字',
                          style: const TextStyle(fontSize: 14),
                        ),
                        const Text(
                          '超过该长度的段落在强语气标点处切开（默认 50）',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        Slider(
                          value: _smartSplitThreshold
                              .clamp(5, 200)
                              .toDouble(),
                          min: 5,
                          max: 200,
                          divisions: 39,
                          label: '$_smartSplitThreshold',
                          onChanged: (value) {
                            setState(
                                () => _smartSplitThreshold = value.round());
                          },
                        ),
                      ],
                    ),
                  ),
                ..._buildSegmentRulesSection(), // A35-L2: 分段规则管理

                const SizedBox(height: 24),

                // Basic settings section
                _buildSectionHeader('基础设置'),
                const SizedBox(height: 8),
                _buildSwitchTile(
                  title: '去除重复标题',
                  subtitle: '删除章节内容开头与章名相同的重复标题（仅 TXT；EPUB 页内标题恒保留）',
                  value: _removeDuplicateTitle,
                  onChanged: (value) {
                    setState(() => _removeDuplicateTitle = value);
                  },
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '分页填充率：${(_pageFillThreshold * 100).round()}%',
                        style: const TextStyle(fontSize: 14),
                      ),
                      const Text(
                        '控制每页内容的填充程度（TXT/EPUB 统一生效）；100% 填满整页（孤行寡行保护自动挂起），越低页底预留越多',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      Slider(
                        value: _pageFillThreshold,
                        min: 0.50,
                        max: 1.00,
                        divisions: 50, // A25c：1% 步进（可选 98%/99% 等细粒度）
                        label: '${(_pageFillThreshold * 100).round()}%',
                        onChanged: (value) {
                          setState(() => _pageFillThreshold = value);
                        },
                      ),
                    ],
                  ),
                ),
                _buildSwitchTile(
                  title: '显示注释',
                  subtitle: '章末注/脚注等注释段落以较小字显示；关闭后仅保留正文引用点按',
                  value: _showComments,
                  onChanged: (value) {
                    setState(() => _showComments = value);
                  },
                ),
                if (_showComments) ...[
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '注释颜色',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final p in _commentColorPresets)
                              ChoiceChip(
                                label: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 12,
                                      height: 12,
                                      decoration: BoxDecoration(
                                        color: p.swatch,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(p.label),
                                  ],
                                ),
                                selected: _commentColorPreset == p.key,
                                onSelected: (_) {
                                  setState(() => _commentColorPreset = p.key);
                                },
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '注释字号倍率 ${(_commentScale * 100).round()}%',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade700,
                          ),
                        ),
                        Slider(
                          value: _commentScale,
                          min: 0.70,
                          max: 1.00,
                          divisions: 30,
                          label: '${(_commentScale * 100).round()}%',
                          onChanged: (v) {
                            setState(() => _commentScale = v);
                          },
                        ),
                      ],
                    ),
                  ),
                ],

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

                // 坍塌动画 section（2026-09-04 P1 设置化：即时生效+持久化，
                // 仅坍塌模式消费；水波纹/卷曲/滚动不受影响）
                _buildSectionHeader('坍塌动画'),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '方块大小：${_collapseBlockSize.round()}px',
                        style: const TextStyle(fontSize: 14),
                      ),
                      const Text(
                        '值越大颗粒感越粗、方块数量越少',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      Slider(
                        value: _collapseBlockSize,
                        min: 24,
                        max: 64,
                        divisions: 8,
                        label: '${_collapseBlockSize.round()}px',
                        onChanged: (v) =>
                            _updateCollapse(blockSize: v),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '向心滑移：${_collapseSlideDistance.round()}px',
                        style: const TextStyle(fontSize: 14),
                      ),
                      const Text(
                        '坍塌方块被吸向点击点的距离',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      Slider(
                        value: _collapseSlideDistance,
                        min: 0,
                        max: 80,
                        divisions: 16,
                        label: '${_collapseSlideDistance.round()}px',
                        onChanged: (v) =>
                            _updateCollapse(slideDistance: v),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '阴影颜色',
                        style: TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          for (final color in _collapseShadowPresets)
                            Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: InkWell(
                                onTap: () => _updateCollapse(shadowColor: color),
                                borderRadius: BorderRadius.circular(20),
                                child: Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: Color(color),
                                    shape: BoxShape.circle,
                                    border: _collapseShadowColorValue == color
                                        ? Border.all(
                                            color: Colors.blue,
                                            width: 3,
                                          )
                                        : Border.all(
                                            color: Colors.grey[400]!,
                                            width: 1,
                                          ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                // M9-P4：段落格式 section（首行缩进/重新分段）
                _buildSectionHeader('段落格式'),
                const SizedBox(height: 8),
                _buildSwitchTile(
                  title: '启用首行缩进',
                  subtitle: '段落首行自动添加缩进空格',
                  value: _enableIndent,
                  onChanged: (value) {
                    setState(() => _enableIndent = value);
                  },
                ),
                if (_enableIndent)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '缩进大小：$_indentSizeChars 字符',
                          style: const TextStyle(fontSize: 14),
                        ),
                        const Text(
                          '每段首行缩进的字符数',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        Slider(
                          value: _indentSizeChars.toDouble(),
                          min: 0,
                          max: 4,
                          divisions: 4,
                          label: '$_indentSizeChars',
                          onChanged: (value) {
                            setState(() => _indentSizeChars = value.round());
                          },
                        ),
                      ],
                    ),
                  ),
                _buildSwitchTile(
                  title: '两端对齐',
                  subtitle: '行内字符微调使左右边缘对齐（EPUB 书内 justify 恒启用）',
                  value: _justify,
                  onChanged: (value) {
                    setState(() => _justify = value);
                  },
                ),
                _buildSwitchTile(
                  title: '标点压缩',
                  subtitle: '行尾标点悬挂出右缘，挤出更多排版空间',
                  value: _punctuationCompress,
                  onChanged: (value) {
                    setState(() => _punctuationCompress = value);
                  },
                ),
                // 统一智能分段后：M9「不处理/智能/强制」三选一已退役，
                // 重分段统一由「内容净化 · 智能分段」总开关 + 阈值 + 规则控制。

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

  /// A35-L2: 分段规则管理区块
  ///
  /// 内置规则（不可删，仅开关）+ 用户正则规则（完整增删改）。
  /// 规则随「应用设置」统一提交（applyContentProcessingSettings）。
  List<Widget> _buildSegmentRulesSection() {
    final builtins = _segmentRules.where((r) => r.isBuiltin).toList();
    final users = _segmentRules.where((r) => !r.isBuiltin).toList();

    return [
      _buildSectionHeader('分段规则'),
      const SizedBox(height: 4),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          '智能分段开启时生效：软换行合并为段落，超过 $_smartSplitThreshold 字后在句末标点（。！？…）处切分，引号未闭合自动吸附；无终结构时按次级标点/硬上限兜底切开',
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ),
      const SizedBox(height: 8),

      // 内置规则列表（开关）
      ...builtins.asMap().entries.map((entry) {
        final globalIndex = _segmentRules.indexOf(entry.value);
        final rule = entry.value;
        return SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          title: Text(
            SegmentRuleItem.builtinLabel(rule.id),
            style: TextStyle(
              fontSize: 14,
              color: rule.enabled ? Colors.black87 : Colors.grey,
            ),
          ),
          subtitle: const Text(
            '内置规则',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
          value: rule.enabled,
          onChanged: (_) => _toggleSegmentRule(globalIndex),
        );
      }),

      const SizedBox(height: 12),

      // 用户规则添加输入
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
              '添加自定义分段规则（正则，按行匹配）',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _segPatternController,
              decoration: const InputDecoration(
                labelText: '正则表达式',
                hintText: r'例如：^——.*$（分割线独立成段）',
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              value: _segRuleAction,
              decoration: const InputDecoration(
                labelText: '动作',
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              items: const [
                DropdownMenuItem(
                  value: SegmentRuleItem.actionForceBreakAfter,
                  child: Text('行后分段（匹配行后强制断开）'),
                ),
                DropdownMenuItem(
                  value: SegmentRuleItem.actionForceBreakBefore,
                  child: Text('行前分段（匹配行前强制断开）'),
                ),
                DropdownMenuItem(
                  value: SegmentRuleItem.actionKeepIndependent,
                  child: Text('独立成段（匹配行单独成段）'),
                ),
                DropdownMenuItem(
                  value: SegmentRuleItem.actionMergeWithPrev,
                  child: Text('强制合并（该行永不切分）'),
                ),
              ],
              onChanged: (v) => setState(() => _segRuleAction = v ?? 0),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton.icon(
                onPressed: _addSegmentRule,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加规则'),
                style: ElevatedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                ),
              ),
            ),
          ],
        ),
      ),

      const SizedBox(height: 12),

      // 用户规则列表
      if (users.isEmpty)
        Container(
          padding: const EdgeInsets.all(16),
          alignment: Alignment.center,
          child: Text(
            '暂无自定义分段规则',
            style: TextStyle(color: Colors.grey[600], fontSize: 13),
          ),
        )
      else
        ...users.map((rule) {
          final globalIndex = _segmentRules.indexOf(rule);
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              dense: true,
              leading: Checkbox(
                value: rule.enabled,
                onChanged: (_) => _toggleSegmentRule(globalIndex),
              ),
              title: Text(
                rule.pattern,
                style: TextStyle(
                  fontSize: 13,
                  decoration:
                      rule.enabled ? null : TextDecoration.lineThrough,
                  color: rule.enabled ? null : Colors.grey,
                ),
              ),
              subtitle: Text(
                SegmentRuleItem.actionLabel(rule.action),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete, color: Colors.red, size: 20),
                onPressed: () => _removeSegmentRule(globalIndex),
              ),
            ),
          );
        }),
    ];
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: Colors.black87,      ),
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

  /// P6：滑杆 tile（label 显示当前值；onChanged 拖动中仅更新显示，
  /// onChangedEnd 松手才落地——避免拖动期逐帧触发全量重排）
  Widget _buildSliderTile({
    required String label,
    required String hint,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangedEnd,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey[300]!),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          const SizedBox(height: 4),
          Text(
            hint,
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
            onChangeEnd: onChangedEnd,
          ),
        ],
      ),
    );
  }
}
