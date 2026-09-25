import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../../../core/services/font_provider.dart';
import '../../../../core/services/reader_font.dart';
import '../../../../core/theme/app_theme.dart' show AppGlass;
import '../../../../core/theme/reader_menu_icons.dart';
import '../../../../core/theme/shell_glass_style.dart';
import '../../../shell/providers/shell_settings.dart';
import '../providers/reader_provider.dart';
import 'reader_page_widget.dart' show PageContentRenderer;

/// 阅读视觉设置四页 sheet（对标 IA S2.4）
/// ① 形态与图标 ② 排版布局 ③ 背景主题 ④ 材质与顶栏
class ReaderVisualSettingsSheet extends ConsumerStatefulWidget {
  const ReaderVisualSettingsSheet({super.key});

  @override
  ConsumerState<ReaderVisualSettingsSheet> createState() =>
      _ReaderVisualSettingsSheetState();
}

class _SheetTabItem {
  const _SheetTabItem({
    required this.label,
    required this.line,
    required this.fill,
  });
  final String label;
  final IconData line;
  final IconData fill;
}

const _sheetTabs = <_SheetTabItem>[
  _SheetTabItem(
    label: '形态图标',
    line: ReaderMenuIcons.lineForm,
    fill: ReaderMenuIcons.fillForm,
  ),
  _SheetTabItem(
    label: '排版布局',
    line: ReaderMenuIcons.lineType,
    fill: ReaderMenuIcons.fillType,
  ),
  _SheetTabItem(
    label: '背景主题',
    line: ReaderMenuIcons.lineBg,
    fill: ReaderMenuIcons.fillBg,
  ),
  _SheetTabItem(
    label: '材质顶栏',
    line: ReaderMenuIcons.lineMaterial,
    fill: ReaderMenuIcons.fillMaterial,
  ),
];

class _ReaderVisualSettingsSheetState
    extends ConsumerState<ReaderVisualSettingsSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;
  late final PageController _pageCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 4, vsync: this)
      ..addListener(() {
        if (mounted && !_tabCtrl.indexIsChanging) setState(() {});
      });
    _pageCtrl = PageController();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _pageCtrl.dispose();
    super.dispose();
  }

  void _goTab(int i) {
    if (_tabCtrl.index == i && _pageCtrl.page?.round() == i) return;
    final ms = MediaQuery.disableAnimationsOf(context) ? 0 : 450;
    _tabCtrl.animateTo(
      i,
      duration: Duration(milliseconds: ms),
      curve: Curves.easeOutCubic,
    );
    _pageCtrl.animateToPage(
      i,
      duration: Duration(milliseconds: ms),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final h = MediaQuery.sizeOf(context).height;
    final iconStyle = ref.watch(shellSettingsProvider).readerIconStyle;
    // 玻璃壳由外层 LiquidGlassSheet 提供。此处只负责内容。
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
                  onPressed: () => Navigator.of(context).pop(),
                  icon: ReaderMenuGlyph(
                    line: ReaderMenuIcons.lineClose,
                    fill: ReaderMenuIcons.fillClose,
                    style: iconStyle,
                    size: 22,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: _GlassTabBar(
              controller: _tabCtrl,
              tabs: _sheetTabs,
              iconStyle: iconStyle,
              onTap: _goTab,
            ),
          ),
          Expanded(
            child: PageView.builder(
              controller: _pageCtrl,
              itemCount: 4,
              onPageChanged: (i) {
                _tabCtrl.animateTo(
                  i,
                  duration: Duration(
                    milliseconds:
                        MediaQuery.disableAnimationsOf(context) ? 0 : 280,
                  ),
                  curve: Curves.easeOutCubic,
                );
                setState(() {});
              },
              itemBuilder: (context, i) {
                final pages = const [
                  _FormIconPage(),
                  _TypographyPage(),
                  _BackgroundPage(),
                  _MaterialPage(),
                ];
                // 视差滑移 + 轻微缩放（禁止 Opacity 包玻璃；只用 Transform）
                return AnimatedBuilder(
                  animation: _pageCtrl,
                  builder: (context, child) {
                    final page = _pageCtrl.hasClients
                        ? (_pageCtrl.page ?? i.toDouble())
                        : i.toDouble();
                    final t = (page - i).clamp(-1.0, 1.0);
                    return Transform.translate(
                      offset: Offset(t * 28, 0),
                      child: Transform.scale(
                        scale: 1 - t.abs() * 0.05,
                        child: child,
                      ),
                    );
                  },
                  child: pages[i],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 液态色板顶栏：滑动 restPillTint 胶囊 + Iconsax 三档图标。
/// 禁止 Material TabBar 的指示条/字色（与玻璃壳不搭）。
class _GlassTabBar extends StatelessWidget {
  const _GlassTabBar({
    required this.controller,
    required this.tabs,
    required this.iconStyle,
    required this.onTap,
  });

  final TabController controller;
  final List<_SheetTabItem> tabs;
  final int iconStyle;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final light = scheme.brightness == Brightness.light;
    final rim = Colors.white.withValues(alpha: light ? 0.45 : 0.24);
    final t = tabs.length;
    // 胶囊滑动：0.28s easeOutBack，选中态带轻微上浮
    final offset = controller.animation ??
        AlwaysStoppedAnimation<double>(controller.index.toDouble());

    return SizedBox(
      height: 56,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth / t;
          return Stack(
            children: [
              // 滑动胶囊（跟手）
              AnimatedBuilder(
                animation: offset,
                builder: (context, _) {
                  final i = offset.value.clamp(0.0, (t - 1).toDouble());
                  return Positioned(
                    left: i * w + 3,
                    top: 4,
                    bottom: 4,
                    width: w - 6,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppGlass.restPillTint(scheme),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: rim, width: 1),
                        boxShadow: [
                          BoxShadow(
                            color: scheme.primary.withValues(alpha: 0.16),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              Row(
                children: [
                  for (var i = 0; i < t; i++)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onTap(i),
                        child: AnimatedBuilder(
                          animation: offset,
                          builder: (context, _) {
                            final sel = 1.0 -
                                (offset.value - i).abs().clamp(0.0, 1.0);
                            return _TabCell(
                              item: tabs[i],
                              selected: controller.index == i,
                              selectT: sel,
                              iconStyle: iconStyle,
                            );
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TabCell extends StatelessWidget {
  const _TabCell({
    required this.item,
    required this.selected,
    required this.iconStyle,
    this.selectT = 0,
  });

  final _SheetTabItem item;
  final bool selected;
  final int iconStyle;

  /// 0–1 连续选中度（跟手插值）
  final double selectT;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 与菜单圆键同一白字/主色语言
    final t = selectT.clamp(0.0, 1.0);
    final fg = Color.lerp(
      scheme.onSurfaceVariant,
      scheme.primary,
      t,
    )!;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutBack,
      transform: Matrix4.identity()
        ..translateByDouble(0.0, -2.0 * t, 0.0, 1.0)
        ..scaleByDouble(1.0 + 0.06 * t, 1.0 + 0.06 * t, 1.0, 1.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ReaderMenuGlyph(
            line: item.line,
            fill: item.fill,
            style: t > 0.55 ? iconStyle : 0,
            size: 20 + 2 * t,
            color: fg,
            duotoneAccent: scheme.tertiary.withValues(alpha: 0.45),
          ),
          const SizedBox(height: 2),
          Text(
            item.label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: t > 0.55 ? FontWeight.w700 : FontWeight.w500,
              color: fg,
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
        _SectionTitle('菜单形态', scheme,
            line: ReaderMenuIcons.lineForm, fill: ReaderMenuIcons.fillForm),
        const SizedBox(height: 8),
        _GlassSegmented<String>(
          items: const [
            ('traditional', '传统底栏'),
            ('floating', '悬浮图标'),
          ],
          icons: const [
            (ReaderMenuIcons.lineModeTraditional,
                ReaderMenuIcons.fillModeTraditional),
            (ReaderMenuIcons.lineModeFloating,
                ReaderMenuIcons.fillModeFloating),
          ],
          value: shell.readerChromeMode,
          onChanged: (v) => n.setReaderChromeMode(v),
        ),
        const SizedBox(height: 24),
        _SectionTitle('图标风格', scheme,
            line: ReaderMenuIcons.lineIconStyle,
            fill: ReaderMenuIcons.fillIconStyle),
        const SizedBox(height: 8),
        _GlassSegmented<int>(
          items: const [
            (0, '线性'),
            (1, '面性'),
            (2, '双色'),
          ],
          icons: const [
            (ReaderMenuIcons.lineIconStyle, ReaderMenuIcons.lineIconStyle),
            (ReaderMenuIcons.fillIconStyle, ReaderMenuIcons.fillIconStyle),
            (ReaderMenuIcons.lineIconStyle, ReaderMenuIcons.fillIconStyle),
          ],
          value: shell.readerIconStyle,
          onChanged: (v) => n.setReaderIconStyle(v),
        ),
        const SizedBox(height: 24),
        _SectionTitle('每行个数', scheme,
            line: ReaderMenuIcons.lineGrid, fill: ReaderMenuIcons.fillGrid),
        _LiveSlider(
          label: '每行',
          value: shell.readerIconItemsPerRow.toDouble(),
          min: 4,
          max: 6,
          unit: '',
          divisions: 2,
          onChanged: (v) => n.setReaderIconItemsPerRow(v.round()),
          onChangeEnd: (v) => n.setReaderIconItemsPerRow(v.round()),
        ),
        _SectionTitle('行数', scheme,
            line: ReaderMenuIcons.lineRows, fill: ReaderMenuIcons.fillRows),
        _LiveSlider(
          label: '行',
          value: shell.readerIconRowCount.toDouble(),
          min: 1,
          max: 2,
          unit: '',
          divisions: 1,
          onChanged: (v) => n.setReaderIconRowCount(v.round()),
          onChangeEnd: (v) => n.setReaderIconRowCount(v.round()),
        ),
        const SizedBox(height: 8),
        _GlassSwitchRow(
          line: ReaderMenuIcons.lineShowText,
          fill: ReaderMenuIcons.fillShowText,
          title: '显示文字标签',
          subtitle: '图标下方显示中文名称',
          value: shell.readerIconShowText,
          onChanged: (v) => n.setReaderIconShowText(v),
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
  /// 子页签：0 字体 / 1 正文 / 2 颜色 / 3 布局
  int _sub = 0;
  double _fontSize = 18;
  double _lineHeight = 1.5;
  double _paraSpacing = 1.0;
  double _letterSpacing = 0.0;
  double _titleScale = 1.15;
  bool _showHeader = true;
  bool _showFooter = true;
  bool _italic = true;
  int _bodyWeight = 400;
  bool _indent = true;
  int _indentChars = 2;
  bool _justify = false;
  bool _punctCompress = false;
  double _padH = 20;
  double _padV = 20;
  int? _textColor;
  int? _accentColor;

  @override
  void initState() {
    super.initState();
    final n = ref.read(readerProvider.notifier);
    _fontSize = n.fontSize;
    _lineHeight = n.lineHeight;
    _italic = n.italicEnabled;
    _bodyWeight = n.bodyFontWeight;
    _paraSpacing = n.paragraphSpacingMultiplier;
    _letterSpacing = n.letterSpacing;
    _titleScale = n.titleScale;
    _showHeader = n.showHeader;
    _showFooter = n.showFooter;
    _indent = n.enableIndent;
    _indentChars = n.indentSizeChars;
    _justify = n.justify;
    _punctCompress = n.punctuationCompress;
    _padH = n.paddingHorizontal;
    _padV = n.paddingVertical;
    _textColor = n.textColor;
    _accentColor = n.accentColor;
  }

  void _applyPadPreset(double v, double h) {
    setState(() {
      _padV = v;
      _padH = h;
    });
    ref.read(readerProvider.notifier).setPadding(vertical: v, horizontal: h);
  }

  @override
  Widget build(BuildContext context) {
    final n = ref.read(readerProvider.notifier);
    ref.watch(readerProvider);
    final scheme = Theme.of(context).colorScheme;
    final disable = MediaQuery.disableAnimationsOf(context);
    return Column(
      children: [
        // 子页签：玻璃胶囊 + 独立图标；与主 Tab 拉开间距，避免贴在一起像重复
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: _GlassSegmented<int>(
            items: const [
              (0, '字体'),
              (1, '正文'),
              (2, '颜色'),
              (3, '布局'),
            ],
            icons: const [
              (ReaderMenuIcons.lineTabFont, ReaderMenuIcons.fillTabFont),
              (ReaderMenuIcons.lineTabBody, ReaderMenuIcons.fillTabBody),
              (ReaderMenuIcons.lineTabColor, ReaderMenuIcons.fillTabColor),
              (ReaderMenuIcons.lineTabLayout, ReaderMenuIcons.fillTabLayout),
            ],
            value: _sub,
            onChanged: (v) => setState(() => _sub = v),
          ),
        ),
        // ClipRect：切换时新旧页只在内容区内滑移，禁止叠到页签/别的区
        Expanded(
          child: ClipRect(
            child: AnimatedSwitcher(
              duration: Duration(milliseconds: disable ? 0 : 300),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, anim) {
                // 只 Transform：Fade 会隔离玻璃控件
                return SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.22, 0),
                    end: Offset.zero,
                  ).animate(anim),
                  child: child,
                );
              },
              layoutBuilder: (currentChild, previousChildren) {
                // 只保留当前页：旧页立即卸载，避免叠影（ClipRect + 滑入）
                return currentChild ?? const SizedBox.expand();
              },
              child: KeyedSubtree(
                key: ValueKey(_sub),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: switch (_sub) {
                    0 => _fontSection(n, scheme),
                    1 => _bodySection(n, scheme),
                    2 => _colorSection(n, scheme),
                    _ => _layoutSection(n, scheme),
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── 字体：字体 + 字号 + 粗斜体 ──
  List<Widget> _fontSection(ReaderNotifier n, ColorScheme scheme) => [
        _SectionTitle('字体', scheme,
            line: ReaderMenuIcons.lineType, fill: ReaderMenuIcons.fillType),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: ReaderMenuGlyph(
            line: ReaderMenuIcons.lineType,
            fill: ReaderMenuIcons.fillType,
            style: refIconStyleOf(context),
            size: 22,
            color: scheme.primary,
          ),
          title: const Text('字体'),
          subtitle: Text(ReaderFont.displayName),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showFontSheet(context),
        ),
        _LiveSlider(
          label: '字号',
          value: _fontSize,
          min: 12,
          max: 32,
          unit: 'px',
          iconLine: ReaderMenuIcons.lineSize,
          iconFill: ReaderMenuIcons.fillSize,
          onChanged: (v) => setState(() => _fontSize = v),
          onChangeEnd: (v) => n.setFontSize(v),
        ),
        const SizedBox(height: 10),
        _SectionTitle('字重', scheme,
            line: ReaderMenuIcons.lineTitle, fill: ReaderMenuIcons.fillTitle),
        const SizedBox(height: 6),
        _GlassSegmented<int>(
          items: const [
            (300, '细体'),
            (400, '常规'),
            (500, '中等'),
            (700, '粗体'),
          ],
          value: _bodyWeight,
          onChanged: (v) {
            setState(() {
              _bodyWeight = v;
            });
            n.setBodyFontWeight(v);
          },
        ),
        const SizedBox(height: 8),
        _GlassSwitchRow(
          line: ReaderMenuIcons.lineTitle,
          fill: ReaderMenuIcons.fillTitle,
          title: '斜体',
          subtitle: '倾斜正文与标题',
          value: _italic,
          onChanged: (v) {
            setState(() => _italic = v);
            n.setItalicEnabled(v);
          },
        ),
      ];

  // ── 正文：间距 / 段落格式 ──
  List<Widget> _bodySection(ReaderNotifier n, ColorScheme scheme) => [
        _SectionTitle('间距', scheme,
            line: ReaderMenuIcons.lineRows, fill: ReaderMenuIcons.fillRows),
        _LiveSlider(
          label: '行距',
          value: _lineHeight,
          min: 1.0,
          max: 2.0,
          unit: 'x',
          iconLine: ReaderMenuIcons.lineRows,
          iconFill: ReaderMenuIcons.fillRows,
          onChanged: (v) => setState(() => _lineHeight = v),
          onChangeEnd: (v) => n.setLineHeight(v),
        ),
        _LiveSlider(
          label: '段距',
          value: _paraSpacing,
          min: 0.5,
          max: 2.0,
          unit: 'x',
          iconLine: ReaderMenuIcons.lineForm,
          iconFill: ReaderMenuIcons.fillForm,
          onChanged: (v) => setState(() => _paraSpacing = v),
          onChangeEnd: (v) => n.setParagraphSpacing(v),
        ),
        _LiveSlider(
          label: '字距',
          value: _letterSpacing,
          min: -2,
          max: 8,
          unit: 'px',
          iconLine: ReaderMenuIcons.lineLetter,
          iconFill: ReaderMenuIcons.fillLetter,
          // 拖动即生效（只改绘制 letterSpacing，不触碰 fontFamily）
          onChanged: (v) {
            setState(() => _letterSpacing = v);
            PageContentRenderer.userLetterSpacing = v.clamp(-2.0, 8.0);
            PageContentRenderer.themeRevision++;
          },
          onChangeEnd: (v) => n.setLetterSpacing(v),
        ),
        const SizedBox(height: 12),
        _SectionTitle('段落格式', scheme,
            line: ReaderMenuIcons.lineForm, fill: ReaderMenuIcons.fillForm),
        _GlassSwitchRow(
          line: ReaderMenuIcons.lineForm,
          fill: ReaderMenuIcons.fillForm,
          title: '首行缩进',
          value: _indent,
          onChanged: (v) {
            setState(() => _indent = v);
            n.setEnableIndent(v);
          },
        ),
        if (_indent)
          _LiveSlider(
            label: '缩进字符',
            value: _indentChars.toDouble(),
            min: 0,
            max: 4,
            unit: '',
            iconLine: ReaderMenuIcons.lineLetter,
            iconFill: ReaderMenuIcons.fillLetter,
            onChanged: (v) => setState(() => _indentChars = v.round()),
            onChangeEnd: (v) => n.setIndentSizeChars(v.round()),
          ),
        _GlassSwitchRow(
          line: ReaderMenuIcons.lineType,
          fill: ReaderMenuIcons.fillType,
          title: '两端对齐',
          value: _justify,
          onChanged: (v) {
            setState(() => _justify = v);
            n.setJustify(v);
          },
        ),
        _GlassSwitchRow(
          line: ReaderMenuIcons.lineLetter,
          fill: ReaderMenuIcons.fillLetter,
          title: '标点压缩',
          value: _punctCompress,
          onChanged: (v) {
            setState(() => _punctCompress = v);
            n.setPunctuationCompress(v);
          },
        ),
      ];

  // ── 颜色：正文色 / 强调色 ──
  List<Widget> _colorSection(ReaderNotifier n, ColorScheme scheme) {
    const presets = <(String, Color)>[
      ('默认', Color(0xFF000000)),
      ('暖灰', Color(0xFF3E3A36)),
      ('墨绿', Color(0xFF1F3D2B)),
      ('深蓝', Color(0xFF1A2744)),
      ('绛紫', Color(0xFF4A2545)),
      ('夜白', Color(0xFFD8D4CC)),
    ];
    return [
      _SectionTitle('正文颜色', scheme,
          line: ReaderMenuIcons.lineTextColor,
          fill: ReaderMenuIcons.fillTextColor),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (label, color) in presets)
            _ColorCard(
              label,
              color,
              selected: _textColor == color.toARGB32(),
              onTap: () {
                setState(() => _textColor = color.toARGB32());
                n.setTextColor(color.toARGB32());
              },
            ),
          _ColorCard(
            '主题默认',
            scheme.onSurface,
            selected: _textColor == null,
            onTap: () {
              setState(() => _textColor = null);
              n.setTextColor(null);
            },
          ),
        ],
      ),
      const SizedBox(height: 20),
      _SectionTitle('强调 / 注释', scheme,
          line: ReaderMenuIcons.lineAccent, fill: ReaderMenuIcons.fillAccent),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _ColorCard('灰', const Color(0xFF888888),
              selected: _accentColor == const Color(0xFF888888).toARGB32(),
              onTap: () {
            setState(() => _accentColor = const Color(0xFF888888).toARGB32());
            n.setAccentColor(const Color(0xFF888888).toARGB32());
          }),
          _ColorCard('蓝灰', const Color(0xFF5A6B7A),
              selected: _accentColor == const Color(0xFF5A6B7A).toARGB32(),
              onTap: () {
            setState(() => _accentColor = const Color(0xFF5A6B7A).toARGB32());
            n.setAccentColor(const Color(0xFF5A6B7A).toARGB32());
          }),
          _ColorCard('茶褐', const Color(0xFF6B5A4A),
              selected: _accentColor == const Color(0xFF6B5A4A).toARGB32(),
              onTap: () {
            setState(() => _accentColor = const Color(0xFF6B5A4A).toARGB32());
            n.setAccentColor(const Color(0xFF6B5A4A).toARGB32());
          }),
          _ColorCard('主题默认', scheme.onSurfaceVariant,
              selected: _accentColor == null, onTap: () {
            setState(() => _accentColor = null);
            n.setAccentColor(null);
          }),
        ],
      ),
    ];
  }

  // ── 布局：标题 / 页眉页脚 / 边距（预设收拢）──
  List<Widget> _layoutSection(ReaderNotifier n, ColorScheme scheme) => [
        _SectionTitle('标题', scheme,
            line: ReaderMenuIcons.lineTitle, fill: ReaderMenuIcons.fillTitle),
        _LiveSlider(
          label: '标题字号',
          value: _titleScale,
          min: 1.0,
          max: 1.8,
          unit: 'x',
          iconLine: ReaderMenuIcons.lineTitle,
          iconFill: ReaderMenuIcons.fillTitle,
          onChanged: (v) {
            setState(() => _titleScale = v);
            PageContentRenderer.titleScale = v.clamp(1.0, 1.8);
            PageContentRenderer.themeRevision++;
          },
          onChangeEnd: (v) => n.setTitleScale(v),
        ),
        const SizedBox(height: 12),
        _SectionTitle('页眉 / 页脚', scheme,
            line: ReaderMenuIcons.lineHeader, fill: ReaderMenuIcons.fillHeader),
        _GlassSwitchRow(
          line: ReaderMenuIcons.lineHeader,
          fill: ReaderMenuIcons.fillHeader,
          title: '页眉',
          subtitle: '顶栏显示书名',
          value: _showHeader,
          onChanged: (v) {
            setState(() => _showHeader = v);
            n.setShowHeader(v);
          },
        ),
        _GlassSwitchRow(
          line: ReaderMenuIcons.lineFooter,
          fill: ReaderMenuIcons.fillFooter,
          title: '页脚',
          subtitle: '底栏显示页码',
          value: _showFooter,
          onChanged: (v) {
            setState(() => _showFooter = v);
            n.setShowFooter(v);
          },
        ),
        const SizedBox(height: 12),
        _SectionTitle('边距', scheme,
            line: ReaderMenuIcons.lineGrid, fill: ReaderMenuIcons.fillGrid),
        const SizedBox(height: 8),
        // 预设优先，避免四向滑杆把页面撑爆
        _GlassSegmented<String>(
          items: const [
            ('narrow', '窄'),
            ('std', '标准'),
            ('wide', '宽'),
          ],
          value: _padV <= 12
              ? 'narrow'
              : _padV >= 36
                  ? 'wide'
                  : 'std',
          onChanged: (v) {
            if (v == 'narrow') _applyPadPreset(8, 12);
            if (v == 'std') _applyPadPreset(20, 20);
            if (v == 'wide') _applyPadPreset(40, 28);
          },
        ),
        const SizedBox(height: 8),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(
            '精细调节  ·  上下 ${_padV.round()} / 左右 ${_padH.round()}',
            style: TextStyle(
              fontSize: 13,
              color: scheme.onSurfaceVariant,
            ),
          ),
          children: [
            _LiveSlider(
              label: '上下边距',
              value: _padV,
              min: 0,
              max: 64,
              unit: 'px',
              iconLine: ReaderMenuIcons.lineHeader,
              iconFill: ReaderMenuIcons.fillHeader,
              onChanged: (v) => setState(() => _padV = v),
              onChangeEnd: (v) => n.setPadding(vertical: v),
            ),
            _LiveSlider(
              label: '左右边距',
              value: _padH,
              min: 0,
              max: 48,
              unit: 'px',
              iconLine: ReaderMenuIcons.lineGrid,
              iconFill: ReaderMenuIcons.fillGrid,
              onChanged: (v) => setState(() => _padH = v),
              onChangeEnd: (v) => n.setPadding(horizontal: v),
            ),
          ],
        ),
      ];

  void _showFontSheet(BuildContext context) {
    // 与设置主 sheet 同源液态玻璃；禁止默认黑底 ModalBottomSheet
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      clipBehavior: Clip.none,
      builder: (sheetCtx) {
        final scheme = Theme.of(sheetCtx).colorScheme;
        final shell = ProviderScope.containerOf(sheetCtx)
            .read(shellSettingsProvider);
        final blur =
            shell.readerSheetBlurOn ? shell.readerSheetBlurSigma : 0.0;
        return LiquidGlassSheet(
          anchor: LiquidGlassSheetAnchor.attached,
          grabber: true,
          style: shellFrostLiquidStyle(
            scheme,
            navBlur: blur,
            navTint: shell.navTintStrength,
            radius: 28,
            strength: 1,
          ),
          foregroundColor: scheme.onSurface,
          child: const _FontSelectSheet(),
        );
      },
    );
  }
}

// ── ③ 背景主题 ──

/// 内置背景预设（纸色对：日/夜）
class _BgPreset {
  const _BgPreset(this.key, this.label, this.light, this.dark);
  final String key;
  final String label;
  final Color light;
  final Color dark;
}

const _bgPresets = <_BgPreset>[
  _BgPreset('parchment', '羊皮纸', Color(0xFFF5E6C8), Color(0xFF2A2418)),
  _BgPreset('linen', '亚麻', Color(0xFFE8DCC8), Color(0xFF242018)),
  _BgPreset('xuan', '宣纸', Color(0xFFF0EDE5), Color(0xFF1C1C1C)),
  _BgPreset('night', '夜空', Color(0xFF1A2744), Color(0xFF0D1B2A)),
  _BgPreset('deepBlue', '深蓝', Color(0xFF1B2838), Color(0xFF0B1520)),
  _BgPreset('warmGray', '暖灰', Color(0xFFE8E0D8), Color(0xFF2A2A2A)),
];

class _BackgroundPage extends ConsumerStatefulWidget {
  const _BackgroundPage();

  @override
  ConsumerState<_BackgroundPage> createState() => _BackgroundPageState();
}

class _BackgroundPageState extends ConsumerState<_BackgroundPage> {
  double _opacity = 1.0;
  bool _dark = false;
  Color? _lightPaper;
  Color? _darkPaper;
  String _preset = '';

  @override
  void initState() {
    super.initState();
    final n = ref.read(readerProvider.notifier);
    _dark = n.themeDark;
    _opacity = n.bgOpacity;
    _lightPaper = n.lightPaperColor != null ? Color(n.lightPaperColor!) : null;
    _darkPaper = n.darkPaperColor != null ? Color(n.darkPaperColor!) : null;
    _preset = n.bgPreset;
  }

  void _applyPreset(_BgPreset p) {
    setState(() {
      _preset = p.key;
      _lightPaper = p.light;
      _darkPaper = p.dark;
    });
    ref.read(readerProvider.notifier).setBgPreset(
          p.key,
          light: p.light.toARGB32(),
          dark: p.dark.toARGB32(),
        );
  }

  /// 取色器：自定义日/夜纸色（flex_color_picker）
  Future<void> _pickPaperColor(
    BuildContext context,
    ReaderNotifier n, {
    required bool isDark,
  }) async {
    final current = isDark
        ? (_darkPaper ?? const Color(0xFF1E1E1E))
        : (_lightPaper ?? const Color(0xFFF5F1E8));
    final picked = await showColorPickerDialog(
      context,
      current,
      pickersEnabled: const {
        ColorPickerType.both: true,
        ColorPickerType.primary: true,
        ColorPickerType.accent: true,
        ColorPickerType.bw: true,
        ColorPickerType.custom: true,
        ColorPickerType.wheel: true,
      },
      enableShadesSelection: true,
      enableTonalPalette: true,
    );
    if (!mounted) return;
    setState(() {
      if (isDark) {
        _darkPaper = picked;
      } else {
        _lightPaper = picked;
      }
      _preset = '';
    });
    n.setPaperColor(
      light: (_lightPaper ?? const Color(0xFFF5F1E8)).toARGB32(),
      dark: (_darkPaper ?? const Color(0xFF1E1E1E)).toARGB32(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final n = ref.read(readerProvider.notifier);
    ref.watch(readerProvider); // 我的主题列表/纸色变更后刷新
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionTitle('日夜模式', scheme,
            line: ReaderMenuIcons.lineDay, fill: ReaderMenuIcons.fillDay),
        const SizedBox(height: 8),
        _GlassSegmented<bool>(
          items: const [
            (false, '日间'),
            (true, '夜间'),
          ],
          value: _dark,
          onChanged: (v) {
            setState(() => _dark = v);
            n.setThemeDark(v);
          },
        ),
        const SizedBox(height: 24),
        _SectionTitle('背景色', scheme,
            line: ReaderMenuIcons.lineBg, fill: ReaderMenuIcons.fillBg),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _ColorCard(
                '日间 · 取色',
                _lightPaper ?? const Color(0xFFF5F1E8),
                onTap: () => _pickPaperColor(context, n, isDark: false),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ColorCard(
                '夜间 · 取色',
                _darkPaper ?? const Color(0xFF1E1E1E),
                onTap: () => _pickPaperColor(context, n, isDark: true),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '点色卡打开取色器；预设格快速换纸色',
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        _SectionTitle('背景透明度', scheme,
            line: ReaderMenuIcons.lineOpacity,
            fill: ReaderMenuIcons.fillOpacity),
        _LiveSlider(
          label: '透明度',
          value: _opacity,
          min: 0.15,
          max: 1.0,
          unit: '',
          onChanged: (v) => setState(() => _opacity = v),
          onChangeEnd: (v) => n.setBgOpacity(v),
        ),
        const SizedBox(height: 24),
        _SectionTitle('内置背景图', scheme,
            line: ReaderMenuIcons.linePreset, fill: ReaderMenuIcons.fillPreset),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          children: [
            for (final p in _bgPresets)
              _BgGridItem(
                p.label,
                _dark ? p.dark : p.light,
                selected: _preset == p.key,
                onTap: () => _applyPreset(p),
              ),
          ],
        ),
        const SizedBox(height: 24),
        _SectionTitle('预设主题', scheme,
            line: ReaderMenuIcons.lineTheme, fill: ReaderMenuIcons.fillTheme),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _ThemeChip(
              '默认',
              _preset == '' && _lightPaper == null,
              onSelected: (_) {
                setState(() {
                  _preset = '';
                  _lightPaper = null;
                  _darkPaper = null;
                  _dark = false;
                });
                n.setPaperColor(light: null, dark: null);
                n.setThemeDark(false);
              },
            ),
            _ThemeChip(
              '护眼',
              _preset == 'parchment',
              onSelected: (_) {
                _applyPreset(_bgPresets[0]);
                setState(() => _dark = false);
                n.setThemeDark(false);
              },
            ),
            _ThemeChip(
              '夜间',
              _preset == 'night',
              onSelected: (_) {
                _applyPreset(_bgPresets[3]);
                setState(() => _dark = true);
                n.setThemeDark(true);
              },
            ),
            _ThemeChip(
              '羊皮纸',
              _preset == 'parchment' && _dark,
              onSelected: (_) {
                _applyPreset(_bgPresets[0]);
                setState(() => _dark = true);
                n.setThemeDark(true);
              },
            ),
          ],
        ),
        const SizedBox(height: 24),
        _SectionTitle('我的主题', scheme,
            line: ReaderMenuIcons.lineTheme, fill: ReaderMenuIcons.fillTheme),
        const SizedBox(height: 8),
        Text(
          '把当前日/夜纸色与文字色存成命名主题（最多 8 套）',
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _saveThemeDialog(context, n),
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('保存当前为主题'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (n.userThemes.isEmpty)
          Text(
            '暂无自定义主题',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in n.userThemes)
                InputChip(
                  label: Text(t.dark ? '${t.name} · 夜' : '${t.name} · 日'),
                  onPressed: () {
                    n.applyUserTheme(t);
                    setState(() {
                      _dark = t.dark;
                      _lightPaper = Color(t.lightPaper);
                      _darkPaper = Color(t.darkPaper);
                      _opacity = t.bgOpacity;
                      _preset = t.bgPreset;
                    });
                  },
                  onDeleted: () {
                    n.deleteUserTheme(t.name);
                    setState(() {});
                  },
                ),
            ],
          ),
      ],
    );
  }

  Future<void> _saveThemeDialog(
      BuildContext context, ReaderNotifier n) async {
    final ctrl = TextEditingController(text: '主题${n.userThemes.length + 1}');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('保存主题'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '主题名称',
            hintText: '例如：羊皮纸夜读',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    n.saveUserTheme(name);
    if (mounted) setState(() {});
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
        _SectionTitle('渲染材质', scheme,
            line: ReaderMenuIcons.lineMaterial,
            fill: ReaderMenuIcons.fillMaterial),
        const SizedBox(height: 8),
        _GlassSegmented<String>(
          items: const [
            ('liquid', '液态玻璃'),
            ('lite', '毛玻璃'),
          ],
          value: shell.glassMode,
          onChanged: (v) => n.setGlassMode(v),
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
        _GlassSwitchRow(
          line: ReaderMenuIcons.lineTheme,
          fill: ReaderMenuIcons.fillTheme,
          title: '果冻效应',
          subtitle: '滑杆/开关/分段形变鼓动',
          value: _lgMotion,
          onChanged: (v) {
            setState(() => _lgMotion = v);
            n.setLgMotionOn(v);
          },
        ),
        const SizedBox(height: 24),
        _SectionTitle('设置 Sheet 材质', scheme,
            line: ReaderMenuIcons.lineBlur, fill: ReaderMenuIcons.fillBlur),
        const SizedBox(height: 4),
        _GlassSwitchRow(
          line: ReaderMenuIcons.lineBlur,
          fill: ReaderMenuIcons.fillBlur,
          title: '轻模糊',
          subtitle: '仅本设置弹层；若正文缩放/发虚请关掉',
          value: shell.readerSheetBlurOn,
          onChanged: (v) => n.setReaderSheetBlurOn(v),
        ),
        if (shell.readerSheetBlurOn)
          _LiveSlider(
            label: '模糊强度',
            value: shell.readerSheetBlurSigma,
            min: 0,
            max: 16,
            unit: '',
            // 拖动即写：Consumer 包着 GlassSheet，强度实时作用本弹层
            onChanged: (v) => n.setReaderSheetBlurSigma(v),
            onChangeEnd: (v) => n.setReaderSheetBlurSigma(v),
          ),
        const SizedBox(height: 24),
        _SectionTitle('顶栏', scheme,
            line: ReaderMenuIcons.lineBack, fill: ReaderMenuIcons.fillBack),
        _GlassSwitchRow(
          line: ReaderMenuIcons.lineMerge,
          fill: ReaderMenuIcons.fillMerge,
          title: '合并按钮',
          subtitle: '返回/更多合并为一个胶囊（默认分开）',
          value: shell.readerTopMergeButtons,
          onChanged: (v) => n.setReaderTopMergeButtons(v),
        ),
        _GlassSwitchRow(
          line: ReaderMenuIcons.linePill,
          fill: ReaderMenuIcons.fillPill,
          title: '标题胶囊',
          subtitle: '书名显示在胶囊内',
          value: shell.readerTopTitlePill,
          onChanged: (v) => n.setReaderTopTitlePill(v),
        ),
      ],
    );
  }
}

// ── 字体选择 sheet ──

class _FontSelectSheet extends ConsumerStatefulWidget {
  const _FontSelectSheet();

  @override
  ConsumerState<_FontSelectSheet> createState() => _FontSelectSheetState();
}

class _FontSelectSheetState extends ConsumerState<_FontSelectSheet> {
  List<PickedFont> _saved = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final list = await FontProvider.listPersistedFonts();
    if (!mounted) return;
    setState(() {
      _saved = list;
      _loading = false;
    });
  }

  Future<void> _apply(PickedFont font) async {
    final n = ref.read(readerProvider.notifier);
    final ok = await FontProvider.loadFromPersistedPath(font);
    if (!mounted) return;
    if (ok == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${font.displayLabel} 加载失败')),
      );
      return;
    }
    n.setCustomFont(
      fontFamily: ok.fontName,
      fontFilePath: ok.persistedPath,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${ok.displayLabel} 已切换'),
        duration: const Duration(seconds: 2),
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final n = ref.read(readerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final iconStyle = refIconStyleOf(context);
    final current = n.customFontFamily;
    return Container(
      padding: const EdgeInsets.all(16),
      child: Theme(
        // 液态玻璃上不要 Material ListTile 默认色块
        data: Theme.of(context).copyWith(
          listTileTheme: const ListTileThemeData(
            tileColor: Colors.transparent,
            iconColor: null,
          ),
        ),
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
          const SizedBox(height: 8),
          Text(
            '当前：${ReaderFont.displayName}',
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant,
              fontFamily: ReaderFont.family,
            ),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  tileColor: Colors.transparent,
                  leading: ReaderMenuGlyph(
                    line: ReaderMenuIcons.lineType,
                    fill: ReaderMenuIcons.fillType,
                    style: iconStyle,
                    size: 22,
                    color: scheme.primary,
                  ),
                  title: const Text('Noto Sans CJK SC（内置）'),
                  trailing: current.isEmpty
                      ? Icon(Icons.check, color: scheme.primary)
                      : null,
                  onTap: () async {
                    await n.resetToBuiltinFont();
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_saved.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    child: Text(
                      '暂无已导入字体，从下方选择文件',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  for (final f in _saved)
                    ListTile(
                      leading: ReaderMenuGlyph(
                        line: ReaderMenuIcons.lineLetter,
                        fill: ReaderMenuIcons.fillLetter,
                        style: iconStyle,
                        size: 22,
                        color: scheme.onSurfaceVariant,
                      ),
                      title: Text(f.displayLabel),
                      subtitle: Text(
                        f.fontName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: current == f.fontName
                          ? Icon(Icons.check, color: scheme.primary)
                          : null,
                      onTap: () => _apply(f),
                    ),
                ListTile(
                  leading: ReaderMenuGlyph(
                    line: ReaderMenuIcons.lineGrid,
                    fill: ReaderMenuIcons.fillGrid,
                    style: iconStyle,
                    size: 22,
                    color: scheme.onSurfaceVariant,
                  ),
                  title: const Text('选择本地字体文件'),
                  subtitle: const Text('支持 .ttf / .otf / .ttc'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final picked =
                        await FontProvider.pickAndLoadCustomFont(context);
                    if (picked != null) {
                      n.setCustomFont(
                        fontFamily: picked.fontName,
                        fontFilePath: picked.persistedPath,
                      );
                      await _reload();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content:
                                Text('${picked.displayLabel} 已切换并持久化'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                        Navigator.of(context).pop();
                      }
                    }
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

// ── 共用组件 ──

/// 分区标题：可选 Iconsax 图标 + 主色文案（与设置页 header 同语言）。
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, this.scheme, {this.line, this.fill});
  final String title;
  final ColorScheme scheme;
  final IconData? line;
  final IconData? fill;

  @override
  Widget build(BuildContext context) {
    final iconStyle = refIconStyleOf(context);
    final text = Text(
      title,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w700,
        color: scheme.primary,
      ),
    );
    if (line == null || fill == null) return text;
    return Row(
      children: [
        ReaderMenuGlyph(
          line: line!,
          fill: fill!,
          style: iconStyle,
          size: 18,
          color: scheme.primary,
          duotoneAccent: scheme.tertiary.withValues(alpha: 0.45),
        ),
        const SizedBox(width: 6),
        text,
      ],
    );
  }
}

/// 分区头取当前图标风格（sheet 内轻量读取，避免每处传参）。
int refIconStyleOf(BuildContext context) {
  final container =
      ProviderScope.containerOf(context, listen: true);
  return container.read(shellSettingsProvider).readerIconStyle;
}

/// 玻璃开关行：图标 + 标题/副文案 + **液态开关**（与壳层 SettingSwitchRow 同源）。
class _GlassSwitchRow extends ConsumerWidget {
  const _GlassSwitchRow({
    required this.title,
    this.subtitle,
    required this.line,
    required this.fill,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String? subtitle;
  final IconData line;
  final IconData fill;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final shell = ref.read(shellSettingsProvider);
    final iconStyle = refIconStyleOf(context);
    final layout = shell.lgMotionOn
        ? const LiquidGlassSwitchLayout()
        : const LiquidGlassSwitchLayout(
            thumbWidth: 37,
            thumbHeight: 24,
            expandedThumbWidth: 37,
            expandedThumbHeight: 24,
          );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
      child: Row(
        children: [
          ReaderMenuGlyph(
            line: line,
            fill: fill,
            style: iconStyle,
            size: 22,
            color: scheme.primary,
            duotoneAccent: scheme.tertiary.withValues(alpha: 0.45),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          LiquidGlassSwitch(
            value: value,
            onChanged: onChanged,
            activeColor: value
                ? AppGlass.switchTrackOn(scheme)
                : AppGlass.switchTrackOff(scheme),
            inactiveColor: AppGlass.switchTrackOff(scheme),
            thumbColor: value
                ? AppGlass.switchThumbOn(scheme)
                : AppGlass.switchThumbOff(scheme),
            layout: layout,
            reserveSwellRoom: false,
          ),
        ],
      ),
    );
  }
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
    this.divisions,
    this.iconLine,
    this.iconFill,
  });
  final String label;
  final double value;
  final double min;
  final double max;
  final String unit;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final int? divisions;
  final IconData? iconLine;
  final IconData? iconFill;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final display =
        unit == '%' ? '${(value * 100).round()}%' : '${value.toStringAsFixed(1)}$unit';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (iconLine != null && iconFill != null) ...[
                ReaderMenuGlyph(
                  line: iconLine!,
                  fill: iconFill!,
                  style: refIconStyleOf(context),
                  size: 16,
                  color: scheme.primary,
                  duotoneAccent: scheme.tertiary.withValues(alpha: 0.45),
                ),
                const SizedBox(width: 6),
              ],
              Text('$label：$display'),
            ],
          ),
          // 纯绘制玻璃轨：与阅读 chrome / 设置页同一 AppGlass 色板
          _GlassTrackSlider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
            onChangedEnd: onChangeEnd,
            activeColor: scheme.primary,
            inactiveColor: AppGlass.sliderTrackInactive(scheme),
            thumbColor: AppGlass.sliderThumb(scheme),
          ),
        ],
      ),
    );
  }
}

/// 液态色板分段（restPillTint 选中 + 白描边）。
/// 阅读页禁 BF：纯 DecoratedBox，对齐壳层 pill / 传统形态切换钮。
class _GlassSegmented<T> extends StatelessWidget {
  const _GlassSegmented({
    required this.items,
    required this.value,
    required this.onChanged,
    this.icons,
  });

  final List<(T, String)> items;
  final T value;
  final ValueChanged<T> onChanged;

  /// 可选图标对 (line, fill)，与 [items] 等长
  final List<(IconData, IconData)?>? icons;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final light = scheme.brightness == Brightness.light;
    final rim = Colors.white.withValues(alpha: light ? 0.45 : 0.24);
    final iconStyle = refIconStyleOf(context);
    return Row(
      children: [
        for (var i = 0; i < items.length; i++)
          Builder(builder: (context) {
            final (v, label) = items[i];
            final selected = v == value;
            final iconPair = (icons != null && i < icons!.length)
                ? icons![i]
                : null;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(v),
                  child: AnimatedContainer(
                    duration: Duration(
                      milliseconds: MediaQuery.disableAnimationsOf(context)
                          ? 0
                          : 280,
                    ),
                    curve: Curves.easeOutBack,
                    transform: Matrix4.identity()
                      ..translateByDouble(
                        0.0,
                        selected ? -3.0 : 0.0,
                        0.0,
                        1.0,
                      )
                      ..scaleByDouble(
                        selected ? 1.03 : 1.0,
                        selected ? 1.03 : 1.0,
                        1.0,
                        1.0,
                      ),
                    decoration: BoxDecoration(
                      color: selected
                          ? scheme.primary.withValues(alpha: 0.42)
                          : Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: selected
                            ? Colors.white.withValues(alpha: 0.75)
                            : rim,
                        width: selected ? 1.5 : 1.0,
                      ),
                      boxShadow: [
                        if (selected)
                          BoxShadow(
                            color: scheme.primary.withValues(alpha: 0.28),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      child: Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (iconPair != null) ...[
                              ReaderMenuGlyph(
                                line: iconPair.$1,
                                fill: iconPair.$2,
                                style: selected ? iconStyle : 0,
                                size: 16,
                                color: selected
                                    ? Colors.white
                                    : Colors.white.withValues(alpha: 0.72),
                                duotoneAccent:
                                    Colors.white.withValues(alpha: 0.40),
                              ),
                              const SizedBox(width: 6),
                            ],
                            Text(
                              label,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                // 选中：亮字 + 描边加粗，暗玻璃上一眼可辨
                                color: selected
                                    ? Colors.white
                                    : Colors.white.withValues(alpha: 0.72),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
      ],
    );
  }
}

/// 纯绘制滑轨（禁止 LiquidGlassSlider：内挂 BF → 正文缩放）。
class _GlassTrackSlider extends StatelessWidget {
  const _GlassTrackSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.onChangedEnd,
    required this.activeColor,
    required this.inactiveColor,
    required this.thumbColor,
    this.divisions,
  });

  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangedEnd;
  final Color activeColor;
  final Color inactiveColor;
  final Color thumbColor;
  final int? divisions;

  @override
  Widget build(BuildContext context) {
    double emit(double t) {
      var v = min + t.clamp(0.0, 1.0) * (max - min);
      if (divisions != null && divisions! > 0) {
        final step = (max - min) / divisions!;
        v = min + ((v - min) / step).round() * step;
      }
      return v.clamp(min, max);
    }

    final t = ((value - min) / (max - min)).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 240.0;
        const thumbW = 28.0;
        const thumbH = 18.0;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) {
            onChanged(emit(d.localPosition.dx / w));
          },
          onHorizontalDragEnd: (_) => onChangedEnd(value),
          onTapDown: (d) {
            final v = emit(d.localPosition.dx / w);
            onChanged(v);
            onChangedEnd(v);
          },
          child: SizedBox(
            width: w,
            height: 44,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Positioned(
                  left: thumbW / 2,
                  right: thumbW / 2,
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: inactiveColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Positioned(
                  left: thumbW / 2,
                  child: Container(
                    height: 4,
                    width: ((w - thumbW) * t)
                        .clamp(0.0, (w - thumbW).clamp(0.0, double.infinity)),
                    decoration: BoxDecoration(
                      color: activeColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Positioned(
                  left: (thumbW / 2 + (w - thumbW) * t - thumbW / 2)
                      .clamp(0.0, (w - thumbW).clamp(0.0, double.infinity)),
                  child: Container(
                    width: thumbW,
                    height: thumbH,
                    decoration: BoxDecoration(
                      color: thumbColor,
                      borderRadius: BorderRadius.circular(thumbH / 2),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.45),
                        width: 1.2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ColorCard extends StatelessWidget {
  const _ColorCard(this.label, this.color, {this.onTap, this.selected = false});
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: 64,
          width: 88,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.white.withValues(alpha: 0.3),
              width: selected ? 2.2 : 1,
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
        ),
      );
}

class _BgGridItem extends StatelessWidget {
  const _BgGridItem(this.label, this.color,
      {this.selected = false, this.onTap});
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey.withValues(alpha: 0.3),
              width: selected ? 2 : 1,
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
        ),
      );
}

class _ThemeChip extends StatelessWidget {
  const _ThemeChip(this.label, this.selected, {this.onSelected});
  final String label;
  final bool selected;
  final ValueChanged<bool>? onSelected;

  @override
  Widget build(BuildContext context) => FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: onSelected ?? (_) {},
      );
}
