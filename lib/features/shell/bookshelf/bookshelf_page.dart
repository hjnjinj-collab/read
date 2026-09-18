import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart' show listEquals;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
// 分段控件尚未进公开 barrel，与官方 example 一致从 src 引用
// ignore: implementation_imports
import 'package:liquid_glass_easy/src/widgets/components/liquid_glass_segmented.dart';

import '../../../core/database/app_database.dart';
import '../../../core/ffi/book_service.dart' show CoverStore;
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../reader/presentation/providers/reader_provider.dart'
    show appDatabaseProvider, bookServiceProvider;
import '../providers/shell_actions.dart';
import '../providers/shell_settings.dart';
import 'book_cover_card.dart';
import 'bookshelf_layout.dart';
import 'recent_hero_banner.dart';

/// 书架 Tab：紧凑顶栏 + 满铺封面网格 / 列表
class BookshelfPage extends ConsumerStatefulWidget {
  const BookshelfPage({super.key});

  @override
  ConsumerState<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends ConsumerState<BookshelfPage>
    with AutomaticKeepAliveClientMixin {
  late final AppDatabase _db;
  List<(Book, ReadingProgressData?)> _entries = [];
  bool _loading = true;
  bool _shellEnteredOnce = false;
  String? _highlightPath;
  Timer? _highlightTimer;
  Timer? _flipClearTimer;
  List<String> _prevOrder = const [];
  Map<String, int> _prevIndex = const {};
  bool _flipArmed = false;
  // 用 Notification 监听滚动：同一 controller 不能挂两个 ScrollView
  // （grid/list 切换 + AnimatedSwitcher 会双挂触发 Scrollbar 断言）
  double _scrollT = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _db = ref.read(appDatabaseProvider);
    _refresh(initial: true);
    // 底栏「添加书籍」→ 本页拉起文件选择（keep-alive，跨 Tab 也能收）
    ref.listenManual(importRequestProvider, (prev, next) {
      if (prev != null && next > prev) {
        _pickAndOpenBook();
      }
    });
  }

  bool _onScrollNotification(ScrollNotification n) {
    if (n.depth != 0) return false;
    final metrics = n.metrics;
    if (metrics.axis != Axis.vertical) return false;
    // 0→1：标题压缩 / 顶栏滤镜显现区间（约 56px）
    final t = (metrics.pixels / 56.0).clamp(0.0, 1.0);
    if ((t - _scrollT).abs() < 0.01) return false;
    setState(() => _scrollT = t);
    return false;
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _flipClearTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool initial = false}) async {
    final books = await _db.allBooksByLastRead();
    final progress = await Future.wait(
      books.map((b) => _db.progressOf(b.filePath)),
    );
    if (!mounted) return;
    final entries = <(Book, ReadingProgressData?)>[
      for (var i = 0; i < books.length; i++) (books[i], progress[i]),
    ];
    final order = [for (final b in books) b.filePath];
    final oldIndex = <String, int>{
      for (var i = 0; i < _prevOrder.length; i++) _prevOrder[i]: i,
    };
    final orderChanged = !initial &&
        _prevOrder.isNotEmpty &&
        !listEquals(order, _prevOrder);
    setState(() {
      _entries = entries;
      _prevIndex = oldIndex;
      _prevOrder = order;
      _flipArmed = orderChanged &&
          !MediaQuery.disableAnimationsOf(context);
      if (initial) _loading = false;
    });
    if (_flipArmed) {
      _flipClearTimer?.cancel();
      _flipClearTimer = Timer(
        AppMotion.reorderDuration + const Duration(milliseconds: 40),
        () {
          if (mounted) setState(() => _flipArmed = false);
        },
      );
    }
    if (initial) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // 只读封面文件 + sidecar，不取色
        CoverStore.preload(order);
        // 后台预热最近 3 本 parse 会话：重启后常用书打开时可复用会话
        // + 命中磁盘热分页，首屏接近热缓存
        _warmRecentSessions(order.take(3).toList());
      });
    }
  }

  /// 后台 parse 最近书籍（不打开阅读页）；失败静默
  Future<void> _warmRecentSessions(List<String> paths) async {
    if (paths.isEmpty) return;
    final svc = ref.read(bookServiceProvider);
    // 与 openBook 同口径的净化（smart 恒开；简繁默认 none——用户改设置后
    // 首次打开会 miss 热缓存并重算，仍优于冷 parse）
    final opts = svc.buildCleaningOptions(
      removeHtmlTags: true,
      removeAds: true,
      smartParagraph: true,
      traditionalized: false,
      simplified: false,
    );
    for (final p in paths) {
      try {
        await svc.parseTxtFileAsync(p, null, cleaningOptions: opts);
      } catch (_) {
        // 预热失败不影响书架
      }
    }
  }

  /// 网格槽位左上角（与 GridView padding/gap/aspect 一致）
  Offset _gridOrigin(
    int index, {
    required int cols,
    required double cellW,
    required double cellH,
  }) {
    return BookshelfLayout.cellOrigin(
      index,
      cols: cols,
      cellW: cellW,
      cellH: cellH,
    );
  }

  /// 列表行顶（leading 高 66 + 上下 padding 12，分隔线 1）
  double _listRowTop(int index) => index * (66 + 12 + 1);

  Future<void> _openBook(Book book) async {
    final shelfIndex =
        _entries.indexWhere((e) => e.$1.filePath == book.filePath);
    await _db.touchLastRead(book.filePath);
    if (!mounted) return;
    await context.push('/reader', extra: {
      'filePath': book.filePath,
      'bookName': book.title,
      // push 缩放起点：当前书槽位（从哪来）；pop 固定落首位（去哪）
      'shelfIndex': shelfIndex < 0 ? 0 : shelfIndex,
      // 转场叠层用封面（小尺寸先像封面，放大后再露阅读页）
      'coverPath': CoverStore.fileOf(book.filePath)?.path,
    });
    if (!mounted) return;
    // 先 FLIP 让位，动画结束后再点亮描边，避免与位移叠在一起看不清
    await _refresh();
    await Future<void>.delayed(
      AppMotion.reorderDuration + const Duration(milliseconds: 40),
    );
    if (!mounted) return;
    _highlightTimer?.cancel();
    setState(() => _highlightPath = book.filePath);
    _highlightTimer = Timer(const Duration(milliseconds: 1600), () {
      if (!mounted) return;
      setState(() => _highlightPath = null);
    });
  }

  Future<void> _removeBook(Book book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('移出《${book.title}》？'),
        content: const Text('将同时删除该书进度与书签。文件本身不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _db.deleteBook(book.filePath);
    await _db.deleteProgress(book.filePath);
    await _db.deleteBookmarks(book.filePath);
    await _db.deleteNotes(book.filePath);
    _refresh();
  }

  String _subtitle(Book book, ReadingProgressData? progress) {
    final parts = <String>[];
    if (progress != null && progress.totalChapters > 0) {
      parts.add('第 ${progress.chapterIndex + 1}/${progress.totalChapters} 章');
    } else {
      parts.add('未读');
    }
    final t = book.lastReadAt ?? book.addedAt;
    parts.add('${t.year}-${_two(t.month)}-${_two(t.day)} '
        '${_two(t.hour)}:${_two(t.minute)}');
    return parts.join(' · ');
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  Future<void> _pickAndOpenBook() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'epub'],
      );
      if (files.isEmpty || files.first.path == null) return;
      final filePath = files.first.path!;
      final fileName = files.first.name;
      final bookName = fileName.contains('.')
          ? fileName.substring(0, fileName.lastIndexOf('.'))
          : fileName;
      if (!mounted) return;
      await context.push('/reader', extra: {
        'filePath': filePath,
        'bookName': bookName,
      });
      if (mounted) _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开文件失败：$e')),
        );
      }
    }
  }

  int _columnsForWidth(double width) =>
      BookshelfLayout.columnsForWidth(width);

  Widget _buildHeader(BuildContext context, ShellSettings shell,
      ShellSettingsNotifier notifier, ColorScheme scheme) {
    final disableBlur = MediaQuery.disableAnimationsOf(context);
    final topPad = MediaQuery.paddingOf(context).top;

    final row = SafeArea(
      bottom: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 2, 8, 4 - 2 * _scrollT),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 滚动压缩：headline → titleLarge
                  Text(
                    '书架',
                    style: TextStyle.lerp(
                      Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                          ),
                      Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                      _scrollT,
                    ),
                  ),
                  // 副标题随滚动淡出；接近透明时移出布局，
                  // 否则占位会把标题与右侧按钮错位
                  if (!_loading && _entries.isNotEmpty && _scrollT < 0.85)
                    Opacity(
                      opacity: ((0.85 - _scrollT) / 0.85).clamp(0.0, 1.0),
                      child: Text(
                        '${_entries.length} 本',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                ],
              ),
            ),
            // 液态分段：选中玻璃胶囊滑动 + 途中外鼓形变
            // 顶栏用 secondary 渗色 + 描边，与底栏 primary 渗区分
            Builder(
              builder: (context) {
                final idle = _scrollT < 0.02;
                return LiquidGlassSegmented(
                  segments: const ['网格', '列表'],
                  selectedIndex: shell.bookshelfGrid ? 0 : 1,
                  onChanged: (i) {
                    final grid = i == 0;
                    if (grid != shell.bookshelfGrid) {
                      setState(() => _scrollT = 0);
                    }
                    notifier.setBookshelfGrid(grid);
                  },
                  width: 96,
                  height: 40,
                  segmentBuilder: (context, i, selected, color) {
                    return Icon(
                      i == 0 ? AppIcons.grid : AppIcons.list,
                      size: 18,
                      color: color,
                    );
                  },
                  style: LiquidGlassStyle(
                    shape: LiquidGlassShape.continuousRoundedRectangle(
                      cornerRadius: 20,
                      borderWidth: idle ? 1.35 : 1.1,
                      borderColor: AppGlass.chromeBorder(
                        scheme,
                        alpha: idle
                            ? (scheme.brightness == Brightness.light
                                ? 0.55
                                : 0.40)
                            : 0.28,
                      ),
                    ),
                    appearance: LiquidGlassAppearance(
                      // secondary 色调（非 container）+ 描边
                      color: AppGlass.chromeGlass(scheme, strength: 0.45),
                      blur: LiquidGlassBlur(
                        sigmaX: idle ? 0 : 8,
                        sigmaY: idle ? 0 : 8,
                      ),
                    ),
                  ),
                  pillStyle: LiquidGlassSegmentedPillStyle(
                    glass: true,
                    animated: true,
                    growHeight: 10,
                    glassStyle: LiquidGlassStyle(
                      appearance: LiquidGlassAppearance(
                        color: scheme.primary.withValues(alpha: 0.28),
                        blur: const LiquidGlassBlur(sigmaX: 2, sigmaY: 2),
                      ),
                    ),
                  ),
                  labelStyle: LiquidGlassSegmentedLabelStyle(
                    selectedColor: scheme.primary,
                    unselectedColor: scheme.onSurfaceVariant,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );

    if (disableBlur) {
      return Material(color: scheme.surface, child: row);
    }

    // 静止：只画标题行，不叠模糊（避免暗色下「常显滤镜」）
    // 高度只包标题行，避免 tight 约束把 Row 垂直居中、下压与横幅重叠
    if (_scrollT < 0.02) {
      return SizedBox(
        height: topPad + BookshelfLayout.headerContentH,
        child: row,
      );
    }

    // 全宽渐变模糊：Blur + ShaderMask；雾色随 _scrollT 浮现主色 tint
    // 向下延伸 topBlurExtend，衰减带盖住内容顶部，范围更长
    final h = topPad + BookshelfLayout.headerContentH + BookshelfLayout.topBlurExtend;
    final fog = AppGlass.topTint(scheme);
    final fogA = _scrollT; // 0 静止 → 1 滚动
    return SizedBox(
      height: h,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 背景层不抢事件，衰减带下方内容可滚
            IgnorePointer(
              child: ShaderMask(
                shaderCallback: (rect) {
                  return LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white,
                      Colors.white.withValues(alpha: 0.92),
                      Colors.white.withValues(alpha: 0.72),
                      Colors.white.withValues(alpha: 0.40),
                      Colors.white.withValues(alpha: 0.14),
                      Colors.transparent,
                    ],
                    // 顶栏区保持强模糊，延伸带缓慢衰减
                    stops: const [0, 0.22, 0.42, 0.62, 0.82, 1],
                  ).createShader(rect);
                },
                blendMode: BlendMode.dstIn,
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: AppGlass.topBlurSigma,
                    sigmaY: AppGlass.topBlurSigma,
                  ),
                  // 子色与雾色同源（topTint）：有模糊、退场时不会闪白
                  child: ColoredBox(color: fog),
                ),
              ),
            ),
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      fog.withValues(alpha: 0.58 * fogA),
                      fog.withValues(alpha: 0.48 * fogA),
                      fog.withValues(alpha: 0.32 * fogA),
                      fog.withValues(alpha: 0.16 * fogA),
                      fog.withValues(alpha: 0.05 * fogA),
                      Colors.transparent,
                    ],
                    stops: const [0, 0.22, 0.42, 0.62, 0.82, 1],
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.topCenter,
              child: row,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final shell = ref.watch(shellSettingsProvider);
    final shellNotifier = ref.read(shellSettingsProvider.notifier);
    final width = MediaQuery.sizeOf(context).width;
    // 悬浮底栏高度约 64 + 边距；内容可滚入其下，末尾略留空避免贴死
    final bottomPad = MediaQuery.paddingOf(context).bottom + 96;
    final scheme = Theme.of(context).colorScheme;
    final topPad = MediaQuery.paddingOf(context).top;
    // 仅顶栏玻璃高度；Hero 在滚动区内，随内容上下移动
    final topGlass = topPad + BookshelfLayout.headerContentH;
    final contentTop = topGlass + BookshelfLayout.contentTopGap;
    final showHero = !_loading && _entries.isNotEmpty;

    late final Widget content;
    if (_loading) {
      content = const Center(child: CircularProgressIndicator());
    } else if (_entries.isEmpty) {
      content = _EmptyShelf(onImport: _pickAndOpenBook);
    } else if (shell.bookshelfGrid) {
      final cols = _columnsForWidth(width);
      final padH = BookshelfLayout.padH;
      final gap = BookshelfLayout.gap;
      final cellW = BookshelfLayout.cellWidth(width, cols);
      final cellH = BookshelfLayout.cellHeight(cellW);
      content = CustomScrollView(
        key: const ValueKey('grid'),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(padH, contentTop, padH, 0),
            sliver: SliverToBoxAdapter(
              child: showHero
                  ? RecentHeroBanner(
                      books: _entries,
                      onTap: _openBook,
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(padH, BookshelfLayout.contentTopGap, padH, bottomPad),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                mainAxisSpacing: gap,
                crossAxisSpacing: gap,
                childAspectRatio: BookshelfLayout.childAspectRatio,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final (book, progress) = _entries[index];
                  final highlighted = _highlightPath == book.filePath;
                  Widget card = BookCoverCard(
                    key: ValueKey(book.filePath),
                    book: book,
                    progress: progress,
                    staggerIndex: index,
                    animateEnter: !_shellEnteredOnce,
                    highlighted: highlighted,
                    onTap: () => _openBook(book),
                    onLongPress: () => _removeBook(book),
                  );
                  final old = _flipArmed ? _prevIndex[book.filePath] : null;
                  final Offset begin;
                  if (old != null && old != index) {
                    begin = _gridOrigin(old,
                            cols: cols, cellW: cellW, cellH: cellH) -
                        _gridOrigin(index,
                            cols: cols, cellW: cellW, cellH: cellH);
                  } else {
                    begin = Offset.zero;
                  }
                  return _FlipSlot(
                    key: ValueKey('flip-${book.filePath}'),
                    begin: begin,
                    child: card,
                  );
                },
                childCount: _entries.length,
              ),
            ),
          ),
        ],
      );
      if (!_shellEnteredOnce) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _shellEnteredOnce = true);
        });
      }
    } else {
      content = CustomScrollView(
        key: const ValueKey('list'),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              BookshelfLayout.padH,
              contentTop,
              BookshelfLayout.padH,
              0,
            ),
            sliver: SliverToBoxAdapter(
              child: showHero
                  ? RecentHeroBanner(books: _entries, onTap: _openBook)
                  : const SizedBox.shrink(),
            ),
          ),
          SliverList.separated(
            itemCount: _entries.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
            itemBuilder: (context, index) {
              final (book, progress) = _entries[index];
              Widget tile = BookListTile(
                key: ValueKey(book.filePath),
                book: book,
                subtitle: _subtitle(book, progress),
                onTap: () => _openBook(book),
                onRemove: () => _removeBook(book),
              );
              final old = _flipArmed ? _prevIndex[book.filePath] : null;
              final Offset begin = (old != null && old != index)
                  ? Offset(0, _listRowTop(old) - _listRowTop(index))
                  : Offset.zero;
              return _FlipSlot(
                key: ValueKey('flip-${book.filePath}'),
                begin: begin,
                child: tile,
              );
            },
          ),
          SliverToBoxAdapter(child: SizedBox(height: bottomPad)),
        ],
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 88),
        child: _SpringImportFab(onPressed: _pickAndOpenBook),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScrollNotification,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0, 0.04),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  );
                },
                child: content,
              ),
            ),
          ),
          // 顶栏渐变毛玻璃叠在内容上，滚动时封面/横幅从下穿入
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _buildHeader(context, shell, shellNotifier, scheme),
          ),
        ],
      ),
    );
  }
}

/// FLIP 位移：从旧槽位滑到新槽位，无回弹/缩放。
/// 始终挂在卡片外（key 稳定），避免包装/卸下造成封面 State remount。
class _FlipSlot extends StatefulWidget {
  const _FlipSlot({
    super.key,
    required this.begin,
    required this.child,
  });

  /// 相对终态的起点偏移；[Offset.zero] 表示不重排
  final Offset begin;
  final Widget child;

  @override
  State<_FlipSlot> createState() => _FlipSlotState();
}

class _FlipSlotState extends State<_FlipSlot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late Animation<Offset> _offset;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: AppMotion.reorderDuration,
    );
    _bindOffset(widget.begin);
    if (widget.begin == Offset.zero) {
      _ctrl.value = 1;
    } else {
      _ctrl.forward();
    }
  }

  void _bindOffset(Offset begin) {
    _offset = Tween<Offset>(begin: begin, end: Offset.zero).animate(
      CurvedAnimation(parent: _ctrl, curve: AppMotion.reorder),
    );
  }

  @override
  void didUpdateWidget(covariant _FlipSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.begin == oldWidget.begin) return;
    if (widget.begin == Offset.zero) {
      // 本轮重排结束：直接落到终态
      _ctrl.value = 1;
      _bindOffset(Offset.zero);
      return;
    }
    _bindOffset(widget.begin);
    _ctrl.forward(from: 0);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _offset,
      builder: (context, child) {
        final o = _offset.value;
        if (o == Offset.zero) return child!;
        return Transform.translate(offset: o, child: child);
      },
      child: widget.child,
    );
  }
}

class _EmptyShelf extends StatelessWidget {
  const _EmptyShelf({required this.onImport});

  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final top = MediaQuery.paddingOf(context).top + BookshelfLayout.headerContentH;
    return Padding(
      padding: EdgeInsets.fromLTRB(32, top + 48, 32, 100),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: scheme.primary.withValues(alpha: 0.2),
              ),
            ),
            child: Icon(
              AppIcons.emptyBook,
              size: 42,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '书架是空的',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            '从文件导入 TXT 或 EPUB，开始阅读',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onImport,
            icon: const Icon(AppIcons.importFile),
            label: const Text('导入书籍'),
          ),
        ],
      ),
    );
  }
}

/// 弹簧 FAB：按下缩放回弹 + 阴影随压感变化
class _SpringImportFab extends StatefulWidget {
  const _SpringImportFab({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_SpringImportFab> createState() => _SpringImportFabState();
}

class _SpringImportFabState extends State<_SpringImportFab>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onPressed();
      },
      child: AnimatedScale(
        scale: _pressed ? 0.88 : 1.0,
        duration: Duration(milliseconds: _pressed ? 90 : 220),
        curve: _pressed ? Curves.easeOut : AppMotion.springOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withValues(
                  alpha: _pressed ? 0.15 : 0.28,
                ),
                blurRadius: _pressed ? 6 : 14,
                offset: Offset(0, _pressed ? 2 : 6),
              ),
            ],
          ),
          child: Icon(
            AppIcons.add,
            color: scheme.onPrimaryContainer,
            size: 28,
          ),
        ),
      ),
    );
  }
}
