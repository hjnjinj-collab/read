import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shell/providers/shell_settings.dart';
import '../providers/reader_provider.dart';

/// 阅读视觉设置四页 sheet（对标 IA S2.4）
/// ① 形态与图标 ② 排版布局 ③ 背景主题 ④ 材质与顶栏
class ReaderVisualSettingsSheet extends ConsumerStatefulWidget {
  const ReaderVisualSettingsSheet({super.key});

  @override
  ConsumerState<ReaderVisualSettingsSheet> createState() =>
      _ReaderVisualSettingsSheetState();
}

class _ReaderVisualSettingsSheetState
    extends ConsumerState<ReaderVisualSettingsSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final h = MediaQuery.sizeOf(context).height;
    // 玻璃壳由外层 LiquidGlassSheet 提供（showLiquidGlassSheet）。
    // 此处只负责内容高度与控件；禁止再挂一层不透明/半透明白底，
    // 否则会盖住液态折射（观感像“没用到液态玻璃”）。
    return SizedBox(
      height: h * 0.6,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '阅读设置',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, color: scheme.onSurface),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          TabBar(
            controller: _tabCtrl,
            labelColor: scheme.primary,
            unselectedLabelColor: scheme.onSurfaceVariant,
            indicatorColor: scheme.primary,
            labelStyle: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600),
            tabs: const [
              Tab(text: '形态图标'),
              Tab(text: '排版布局'),
              Tab(text: '背景主题'),
              Tab(text: '材质顶栏'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabCtrl,
              // 各页自持 ListView：TabBarView 滑动时邻页 keep-alive，
              // 共享 ScrollController 会多重挂载断言。
              children: const [
                _FormIconPage(),
                _TypographyPage(),
                _BackgroundPage(),
                _MaterialPage(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── ① 形态与图标 ──

class _FormIconPage extends ConsumerWidget {
  const _FormIconPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shell = ref.watch(shellSettingsProvider);
    final n = ref.read(shellSettingsProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionTitle('菜单形态', scheme),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'traditional', label: Text('传统底栏')),
            ButtonSegment(value: 'floating', label: Text('悬浮图标')),
          ],
          selected: {shell.readerChromeMode},
          onSelectionChanged: (v) => n.setReaderChromeMode(v.first),
        ),
        const SizedBox(height: 24),
        _SectionTitle('图标风格', scheme),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('线性')),
            ButtonSegment(value: 1, label: Text('面性')),
            ButtonSegment(value: 2, label: Text('双色')),
          ],
          selected: const {1},
          onSelectionChanged: (v) {},
        ),
        const SizedBox(height: 24),
        _SectionTitle('每行个数', scheme),
        Slider(
          value: 5,
          min: 4,
          max: 6,
          divisions: 2,
          label: '5',
          onChanged: (v) {},
        ),
        _SectionTitle('行数', scheme),
        Slider(
          value: 1,
          min: 1,
          max: 2,
          divisions: 1,
          label: '1',
          onChanged: (v) {},
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          title: const Text('显示文字标签'),
          subtitle: const Text('图标下方显示中文名称'),
          value: true,
          onChanged: (v) {},
        ),
      ],
    );
  }
}

// ── ② 排版布局 ──

class _TypographyPage extends ConsumerStatefulWidget {
  const _TypographyPage();

  @override
  ConsumerState<_TypographyPage> createState() => _TypographyPageState();
}

class _TypographyPageState extends ConsumerState<_TypographyPage> {
  double _fontSize = 18;
  double _lineHeight = 1.5;
  double _paraSpacing = 1.0;
  bool _bold = true;
  bool _italic = true;
  bool _indent = true;
  int _indentChars = 2;
  bool _justify = false;
  bool _punctCompress = false;

  @override
  void initState() {
    super.initState();
    final n = ref.read(readerProvider.notifier);
    _fontSize = n.fontSize;
    _lineHeight = n.lineHeight;
    _bold = n.boldEnabled;
    _italic = n.italicEnabled;
    _paraSpacing = n.paragraphSpacingMultiplier;
    _indent = n.enableIndent;
    _indentChars = n.indentSizeChars;
    _justify = n.justify;
    _punctCompress = n.punctuationCompress;
  }

  @override
  Widget build(BuildContext context) {
    final n = ref.read(readerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionTitle('正文', scheme),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.text_fields),
          title: const Text('字体'),
          subtitle: Text(n.customFontFamily.isEmpty
              ? 'Noto Sans CJK SC'
              : n.customFontFamily),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showFontSheet(context),
        ),
        _LiveSlider(
          label: '字号',
          value: _fontSize,
          min: 12,
          max: 32,
          unit: 'px',
          onChanged: (v) => setState(() => _fontSize = v),
          onChangeEnd: (v) => n.setFontSize(v),
        ),
        _LiveSlider(
          label: '行距',
          value: _lineHeight,
          min: 1.0,
          max: 2.0,
          unit: 'x',
          onChanged: (v) => setState(() => _lineHeight = v),
          onChangeEnd: (v) => n.setLineHeight(v),
        ),
        _LiveSlider(
          label: '段距',
          value: _paraSpacing,
          min: 0.5,
          max: 2.0,
          unit: 'x',
          onChanged: (v) => setState(() => _paraSpacing = v),
          onChangeEnd: (v) {},
        ),
        SwitchListTile(
          title: const Text('粗体'),
          value: _bold,
          onChanged: (v) => setState(() => _bold = v),
        ),
        SwitchListTile(
          title: const Text('斜体'),
          value: _italic,
          onChanged: (v) => setState(() => _italic = v),
        ),
        const SizedBox(height: 16),
        _SectionTitle('段落格式', scheme),
        SwitchListTile(
          title: const Text('首行缩进'),
          value: _indent,
          onChanged: (v) => setState(() => _indent = v),
        ),
        if (_indent)
          _LiveSlider(
            label: '缩进字符',
            value: _indentChars.toDouble(),
            min: 0,
            max: 4,
            unit: '',
            onChanged: (v) => setState(() => _indentChars = v.round()),
            onChangeEnd: (v) {},
          ),
        SwitchListTile(
          title: const Text('两端对齐'),
          value: _justify,
          onChanged: (v) => setState(() => _justify = v),
        ),
        SwitchListTile(
          title: const Text('标点压缩'),
          value: _punctCompress,
          onChanged: (v) => setState(() => _punctCompress = v),
        ),
        const SizedBox(height: 16),
        _SectionTitle('边距', scheme),
        _LiveSlider(
          label: '上边距',
          value: 24,
          min: 0,
          max: 64,
          unit: 'px',
          onChanged: (v) {},
          onChangeEnd: (v) {},
        ),
        _LiveSlider(
          label: '下边距',
          value: 24,
          min: 0,
          max: 64,
          unit: 'px',
          onChanged: (v) {},
          onChangeEnd: (v) {},
        ),
        _LiveSlider(
          label: '左边距',
          value: 20,
          min: 0,
          max: 48,
          unit: 'px',
          onChanged: (v) {},
          onChangeEnd: (v) {},
        ),
        _LiveSlider(
          label: '右边距',
          value: 20,
          min: 0,
          max: 48,
          unit: 'px',
          onChanged: (v) {},
          onChangeEnd: (v) {},
        ),
      ],
    );
  }

  void _showFontSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (context) => const _FontSelectSheet(),
    );
  }
}

// ── ③ 背景主题 ──

class _BackgroundPage extends ConsumerStatefulWidget {
  const _BackgroundPage();

  @override
  ConsumerState<_BackgroundPage> createState() => _BackgroundPageState();
}

class _BackgroundPageState extends ConsumerState<_BackgroundPage> {
  double _opacity = 1.0;
  bool _dark = false;

  @override
  void initState() {
    super.initState();
    _dark = ref.read(readerProvider.notifier).themeDark;
  }

  @override
  Widget build(BuildContext context) {
    final n = ref.read(readerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionTitle('日夜模式', scheme),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('日间')),
            ButtonSegment(value: true, label: Text('夜间')),
          ],
          selected: {_dark},
          onSelectionChanged: (v) {
            setState(() => _dark = v.first);
            n.setThemeDark(v.first);
          },
        ),
        const SizedBox(height: 24),
        _SectionTitle('背景色', scheme),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _ColorCard('日间', const Color(0xFFF5F0E8))),
            const SizedBox(width: 12),
            Expanded(child: _ColorCard('夜间', const Color(0xFF1A1A2E))),
          ],
        ),
        const SizedBox(height: 24),
        _SectionTitle('背景透明度', scheme),
        _LiveSlider(
          label: '透明度',
          value: _opacity,
          min: 0.0,
          max: 1.0,
          unit: '',
          onChanged: (v) => setState(() => _opacity = v),
          onChangeEnd: (v) {},
        ),
        const SizedBox(height: 24),
        _SectionTitle('内置背景图', scheme),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          children: [
            _BgGridItem('羊皮纸', const Color(0xFFF5E6C8)),
            _BgGridItem('亚麻', const Color(0xFFE8DCC8)),
            _BgGridItem('宣纸', const Color(0xFFF0EDE5)),
            _BgGridItem('夜空', const Color(0xFF0D1B2A)),
            _BgGridItem('深蓝', const Color(0xFF1B2838)),
            _BgGridItem('暖灰', const Color(0xFFE8E0D8)),
          ],
        ),
        const SizedBox(height: 24),
        _SectionTitle('预设主题', scheme),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: const [
            _ThemeChip('默认', true),
            _ThemeChip('护眼', false),
            _ThemeChip('夜间', false),
            _ThemeChip('羊皮纸', false),
          ],
        ),
      ],
    );
  }
}

// ── ④ 材质与顶栏 ──

class _MaterialPage extends ConsumerStatefulWidget {
  const _MaterialPage();

  @override
  ConsumerState<_MaterialPage> createState() => _MaterialPageState();
}

class _MaterialPageState extends ConsumerState<_MaterialPage> {
  double _blur = 12;
  double _tint = 0.38;
  bool _lgMotion = true;

  @override
  void initState() {
    super.initState();
    final shell = ref.read(shellSettingsProvider);
    _blur = shell.navBlurSigma;
    _tint = shell.navTintStrength;
    _lgMotion = shell.lgMotionOn;
  }

  @override
  Widget build(BuildContext context) {
    final shell = ref.watch(shellSettingsProvider);
    final n = ref.read(shellSettingsProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionTitle('渲染材质', scheme),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'liquid', label: Text('液态玻璃')),
            ButtonSegment(value: 'lite', label: Text('毛玻璃')),
          ],
          selected: {shell.glassMode},
          onSelectionChanged: (v) => n.setGlassMode(v.first),
        ),
        const SizedBox(height: 16),
        _LiveSlider(
          label: '模糊强度',
          value: _blur,
          min: 0,
          max: 48,
          unit: '',
          onChanged: (v) => setState(() => _blur = v),
          onChangeEnd: (v) => n.setNavBlurSigma(v),
        ),
        _LiveSlider(
          label: '色渗强度',
          value: _tint,
          min: 0,
          max: 1,
          unit: '%',
          onChanged: (v) => setState(() => _tint = v),
          onChangeEnd: (v) => n.setNavTintStrength(v),
        ),
        SwitchListTile(
          title: const Text('果冻效应'),
          subtitle: const Text('滑杆/开关/分段形变鼓动'),
          value: _lgMotion,
          onChanged: (v) {
            setState(() => _lgMotion = v);
            n.setLgMotionOn(v);
          },
        ),
        const SizedBox(height: 24),
        _SectionTitle('顶栏', scheme),
        SwitchListTile(
          title: const Text('合并按钮'),
          subtitle: const Text('返回/更多合并为一个胶囊'),
          value: false,
          onChanged: (v) {},
        ),
        SwitchListTile(
          title: const Text('标题胶囊'),
          subtitle: const Text('书名显示在胶囊内'),
          value: false,
          onChanged: (v) {},
        ),
      ],
    );
  }
}

// ── 字体选择 sheet ──

class _FontSelectSheet extends ConsumerWidget {
  const _FontSelectSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(readerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '选择字体',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.text_fields),
            title: const Text('Noto Sans CJK SC（内置）'),
            trailing: n.customFontFamily.isEmpty
                ? const Icon(Icons.check, color: Colors.green)
                : null,
            onTap: () async {
              await n.resetToBuiltinFont();
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
          ListTile(
            leading: const Icon(Icons.folder_open),
            title: const Text('选择本地字体文件'),
            subtitle: const Text('支持 .ttf / .otf / .ttc'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final picked = await _pickFont(context);
              if (picked != null && context.mounted) {
                Navigator.of(context).pop();
              }
            },
          ),
        ],
      ),
    );
  }

  Future<dynamic> _pickFont(BuildContext context) async {
    // 复用 FontProvider 的字体选择逻辑
    // ignore: avoid_print
    print('[font-sheet] pick font');
    return null;
  }
}

// ── 共用组件 ──

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, this.scheme);
  final String title;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) => Text(
        title,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: scheme.primary,
        ),
      );
}

class _LiveSlider extends StatelessWidget {
  const _LiveSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.unit,
    required this.onChanged,
    required this.onChangeEnd,
  });
  final String label;
  final double value;
  final double min;
  final double max;
  final String unit;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final display =
        unit == '%' ? '${(value * 100).round()}%' : '${value.toStringAsFixed(1)}$unit';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label：$display'),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ],
      ),
    );
  }
}

class _ColorCard extends StatelessWidget {
  const _ColorCard(this.label, this.color);
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        height: 64,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: color.computeLuminance() > 0.5
                  ? Colors.black87
                  : Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
}

class _BgGridItem extends StatelessWidget {
  const _BgGridItem(this.label, this.color);
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: Colors.grey.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color.computeLuminance() > 0.5
                  ? Colors.black54
                  : Colors.white70,
            ),
          ),
        ),
      );
}

class _ThemeChip extends StatelessWidget {
  const _ThemeChip(this.label, this.selected);
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) => FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) {},
      );
}
