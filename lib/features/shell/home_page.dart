import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/database/app_database.dart';
import '../../core/ffi/book_service.dart' show CoverStore;
import '../../core/services/cover_palette.dart';
import '../../core/theme/app_icons.dart';
import '../../core/theme/app_theme.dart' show AppGlass;
import '../reader/presentation/providers/reader_provider.dart'
    show appDatabaseProvider;
import 'bookshelf/bookshelf_layout.dart';
import 'bookshelf/thin_continue_bar.dart';
import 'providers/shell_settings.dart';
import 'widgets/hero_slide.dart';
import 'widgets/shell_ambient.dart' show AmbientDir, ShellAmbient;
import 'widgets/top_scroll_blur.dart';

/// 切回首页 Tab 时递增，触发 Dashboard 入场动画重播。
final ValueNotifier<int> homeIntroTick = ValueNotifier(0);

/// 首页 Dashboard：Hero 轮换（首帧今日目标）→ 统计 → 折线 → 最近阅读。
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage>
    with SingleTickerProviderStateMixin {
  List<(Book, ReadingProgressData?)> _entries = [];
  bool _loading = true;
  int _heroIndex = 0;
  Timer? _heroTimer;
  double _scrollT = 0;
  late final AnimationController _introCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  static const _goalMinutes = 30;
  int get _todayMinutes => _entries.isEmpty ? 0 : 18;

  @override
  void initState() {
    super.initState();
    homeIntroTick.addListener(_onIntroTick);
    _load();
  }

  @override
  void dispose() {
    homeIntroTick.removeListener(_onIntroTick);
    _heroTimer?.cancel();
    _introCtrl.dispose();
    super.dispose();
  }

  void _replayIntro() {
    if (!mounted) return;
    final reduce = MediaQuery.disableAnimationsOf(context);
    setState(() => _heroIndex = 0);
    if (reduce) {
      _introCtrl.value = 1;
      return;
    }
    _introCtrl.forward(from: 0);
    // 进页先停在「今日目标」，等入场播完再开始轮换（避免与页切换/入场抢戏）
    _armHero(firstDelay: const Duration(milliseconds: 1800));
  }

  void _armHero({Duration firstDelay = const Duration(seconds: 6)}) {
    _heroTimer?.cancel();
    // 减弱动态：不自动轮换
    if (mounted && MediaQuery.disableAnimationsOf(context)) return;
    _heroTimer = Timer(firstDelay, () {
      if (!mounted || _entries.isEmpty) return;
      if (MediaQuery.disableAnimationsOf(context)) return;
      final n = 1 + math.min(2, _continueItems.length).toInt();
      if (n <= 1) return;
      setState(() => _heroIndex = (_heroIndex + 1) % n);
      _armHero(firstDelay: const Duration(seconds: 6));
    });
  }

  Future<void> _load() async {
    final db = ref.read(appDatabaseProvider);
    final books = await db.allBooksByLastRead();
    final progress = await Future.wait(
      books.map((b) => db.progressOf(b.filePath)),
    );
    final list = <(Book, ReadingProgressData?)>[
      for (var i = 0; i < books.length; i++) (books[i], progress[i]),
    ];
    if (!mounted) return;
    setState(() {
      _entries = list;
      _loading = false;
      _heroIndex = 0;
    });
    // 数据就绪后强制播放入场，避免 Tween 在首帧前结束
    _replayIntro();
  }

  void _onIntroTick() => _replayIntro();

  bool _onScrollNotification(ScrollNotification n) {
    if (n.depth != 0) return false;
    final metrics = n.metrics;
    if (metrics.axis != Axis.vertical) return false;
    // 与书架同源：约 56px 内完成顶栏滤镜显现
    final t = (metrics.pixels / 56.0).clamp(0.0, 1.0);
    if ((t - _scrollT).abs() < 0.01) return false;
    setState(() => _scrollT = t);
    return false;
  }

  List<(Book, ReadingProgressData?)> get _continueItems {
    final withP = _entries
        .where((e) => e.$2 != null && e.$2!.totalChapters > 0)
        .toList();
    return withP.isEmpty ? _entries.take(2).toList() : withP.take(2).toList();
  }

  void _openBook(Book book) {
    final idx = _entries.indexWhere((e) => e.$1.filePath == book.filePath);
    context.push('/reader', extra: {
      'filePath': book.filePath,
      'bookName': book.title,
      'shelfIndex': idx < 0 ? 0 : idx,
      'coverPath': CoverStore.fileOf(book.filePath)?.path,
    });
  }

  @override
  Widget build(BuildContext context) {
    final shell = ref.watch(shellSettingsProvider);
    final scheme = Theme.of(context).colorScheme;
    final pad = MediaQuery.paddingOf(context);
    // 与书架同几何：固定顶栏玻璃高度 + 内容顶隙
    final topGlass = pad.top + BookshelfLayout.headerContentH;
    final contentTop = topGlass + BookshelfLayout.contentTopGap;

    return Scaffold(
      extendBody: true,
      body: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: ShellAmbient(
                enabled: shell.ambientOn,
                dir: AmbientDir.parse(shell.ambientDir),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else
            Positioned.fill(
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScrollNotification,
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    contentTop,
                    16,
                    // 收底：只留底栏安全区，消掉最近阅读下大块空白
                    pad.bottom + 76,
                  ),
                  children: [
                    _heroCard(scheme),
                    const SizedBox(height: 12),
                    _statsRow(scheme),
                    const SizedBox(height: 12),
                    _chartCard(scheme),
                    const SizedBox(height: 14),
                    if (_entries.isNotEmpty) ...[
                      Text(
                        '最近阅读',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 168,
                        child: ListView.separated(
                          // 投影需要出界，默认 hardEdge 会裁掉
                          clipBehavior: Clip.none,
                          scrollDirection: Axis.horizontal,
                          itemCount: math.min(6, _entries.length),
                          separatorBuilder: (_, _) => const SizedBox(width: 8),
                          itemBuilder: (context, i) {
                            final (book, _) = _entries[i];
                            final cover = CoverStore.fileOf(book.filePath);
                            final pal = CoverPalette.cached(book.filePath) ??
                                CoverPalette.synthetic(book.title);
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
                              child: SizedBox(
                                width: 96,
                                child: InkWell(
                                  onTap: () => _openBook(book),
                                  borderRadius: BorderRadius.circular(12),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      DecoratedBox(
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(10),
                                          boxShadow: [
                                            BoxShadow(
                                              color: pal.shadowColor
                                                  .withValues(alpha: 0.55),
                                              blurRadius: 14,
                                              offset: const Offset(0, 8),
                                            ),
                                            BoxShadow(
                                              color: pal.dominant
                                                  .withValues(alpha: 0.28),
                                              blurRadius: 20,
                                              offset: const Offset(0, 12),
                                              spreadRadius: -2,
                                            ),
                                          ],
                                        ),
                                        child: ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(10),
                                          child: SizedBox(
                                            width: 92,
                                            // 120 + 4 + 文案 ≤ 列表 148 内容区，防 RenderFlex 溢出
                                            height: 120,
                                            child: cover != null
                                                ? Image.file(
                                                    cover,
                                                    fit: BoxFit.cover,
                                                    cacheWidth: 240,
                                                    gaplessPlayback: true,
                                                    errorBuilder:
                                                        (_, _, _) =>
                                                            ColoredBox(
                                                                color:
                                                                    pal.dark),
                                                  )
                                                : ColoredBox(color: pal.dark),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        book.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          // 顶栏渐变毛玻璃叠在内容上（书架同款）
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _buildHeader(),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final row = SafeArea(
      bottom: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 2, 16, 4 - 2 * _scrollT),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '首页',
            style: TextStyle.lerp(
              Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                  ),
              Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
              _scrollT,
            ),
          ),
        ),
      ),
    );
    return TopScrollBlurChrome(
      scrollT: _scrollT,
      headerContentH: BookshelfLayout.headerContentH,
      topBlurExtend: BookshelfLayout.topBlurExtend,
      child: row,
    );
  }

  Widget _heroCard(ColorScheme scheme) {
    final cont = _continueItems;
    final slides = <Widget>[
      _goalSlide(scheme),
      for (final e in cont.take(2)) _continueSlide(e),
    ];
    final i = _heroIndex.clamp(0, slides.length - 1);
    return Stack(
      children: [
        HeroSlideSwitcher(
          index: i,
          height: 152,
          radius: AppGlass.settingsCardRadius,
          child: slides[i],
        ),
        // 轮换圆点叠在块上（与书架一致：多帧才显示）
        if (slides.length > 1)
          Positioned(
            top: 10,
            right: 12,
            child: Row(
              children: List.generate(
                slides.length,
                (d) => Container(
                  width: d == i ? 14 : 6,
                  height: 6,
                  margin: const EdgeInsets.only(left: 4),
                  decoration: BoxDecoration(
                    color: d == i
                        ? Colors.white.withValues(alpha: 0.9)
                        : Colors.white.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _goalSlide(ColorScheme scheme) {
    final ratio = (_todayMinutes / _goalMinutes).clamp(0.0, 1.0);
    return DecoratedBox(
      key: const ValueKey('goal-slide'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary.withValues(alpha: 0.28),
            scheme.tertiary.withValues(alpha: 0.18),
            scheme.surfaceContainerHighest.withValues(alpha: 0.55),
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
        child: Row(
          children: [
            // M3 Expressive 异变进度环（year2023: false）
            SizedBox(
              width: 84,
              height: 84,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Theme(
                    data: Theme.of(context).copyWith(
                      progressIndicatorTheme: const ProgressIndicatorThemeData(
                        // 显式选用 2024 Expressive 异变环（year2023 将来默认 false）
                        // ignore: deprecated_member_use
                        year2023: false,
                      ),
                    ),
                    child: SizedBox(
                      width: 84,
                      height: 84,
                      child: CircularProgressIndicator(
                        value: ratio,
                        strokeWidth: 7,
                        trackGap: 6,
                        strokeCap: StrokeCap.round,
                        backgroundColor:
                            scheme.surface.withValues(alpha: 0.35),
                        valueColor: AlwaysStoppedAnimation(scheme.primary),
                      ),
                    ),
                  ),
                  Text(
                    '${(ratio * 100).round()}%',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '今日目标',
                    style: TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$_todayMinutes / $_goalMinutes 分钟',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '加载圈随进度异变 · 点按可调目标',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _continueSlide((Book, ReadingProgressData?) item) {
    return Align(
      alignment: Alignment.center,
      child: ThinContinueBar(
        book: item.$1,
        progress: item.$2,
        onTap: () => _openBook(item.$1),
      ),
    );
  }

  Widget _statsRow(ColorScheme scheme) {
    Widget stat(IconData icon, String lb, String val, String unit) {
      final target = double.tryParse(val) ?? 0;
      final isInt = !val.contains('.');
      return Expanded(
        child: _FrostChromeCard(
          scheme: scheme,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 16, color: scheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      lb,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                AnimatedBuilder(
                  animation: _introCtrl,
                  builder: (context, _) {
                    final v = target *
                        Curves.easeOutCubic.transform(_introCtrl.value);
                    final text =
                        isInt ? v.round().toString() : v.toStringAsFixed(1);
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          text,
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: 2, bottom: 3),
                          child: Text(
                            unit,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        stat(AppIcons.bookshelf, '读过', '${_entries.length}', '本'),
        const SizedBox(width: 8),
        stat(AppIcons.materialFx, '累计', '36.5', 'h'),
        const SizedBox(width: 8),
        stat(AppIcons.pageTint, '连续', '5', '天'),
      ],
    );
  }

  Widget _chartCard(ColorScheme scheme) {
    // 演示序列：无真实时长库时用固定趋势；有书则与本数弱相关
    final base = _entries.isEmpty
        ? <double>[0, 0, 0, 0, 0, 0, 0]
        : <double>[12, 28, 8, 35, 22, 41, _todayMinutes.toDouble()];
    final week = base.fold<double>(0, (a, b) => a + b);
    return _FrostChromeCard(
      scheme: scheme,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '近 7 日阅读',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      Text(
                        '分钟 · 折线趋势',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: week),
                  duration: const Duration(milliseconds: 700),
                  curve: Curves.easeOutCubic,
                  builder: (context, v, _) => Text(
                    '${v.round()}',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                ),
                Text(
                  ' 分钟',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 136,
              child: AnimatedBuilder(
                animation: _introCtrl,
                builder: (context, _) {
                  return CustomPaint(
                    painter: _WeekLinePainter(
                      values: base,
                      line: scheme.primary,
                      track: scheme.outlineVariant.withValues(alpha: 0.45),
                      drawT: Curves.easeOutCubic.transform(_introCtrl.value),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: const [
                _DayLabel('一'),
                _DayLabel('二'),
                _DayLabel('三'),
                _DayLabel('四'),
                _DayLabel('五'),
                _DayLabel('六'),
                _DayLabel('日', emphasize: true),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// chrome 卡：轻霜/tonal（对齐设置页），封面海报则用取色投影，不套霜
class _FrostChromeCard extends StatelessWidget {
  const _FrostChromeCard({required this.scheme, required this.child});
  final ColorScheme scheme;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppGlass.settingsCardRadius),
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.38),
        border: Border.all(
          color: AppGlass.floatRowRim(scheme).withValues(alpha: 0.6),
          width: 0.6,
        ),
      ),
      child: child,
    );
  }
}

class _DayLabel extends StatelessWidget {
  const _DayLabel(this.t, {this.emphasize = false});
  final String t;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      t,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: emphasize ? scheme.primary : scheme.onSurfaceVariant,
            fontWeight: emphasize ? FontWeight.w700 : FontWeight.w400,
          ),
    );
  }
}

class _WeekLinePainter extends CustomPainter {
  _WeekLinePainter({
    required this.values,
    required this.line,
    required this.track,
    this.drawT = 1,
  });

  final List<double> values;
  final Color line;
  final Color track;

  /// 0→1 描画进度（路径生长 + 点依次亮起）
  final double drawT;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final t = drawT.clamp(0.0, 1.0);
    final maxV = math.max(10.0, values.reduce(math.max));
    final n = values.length;
    final padX = 4.0;
    final padY = 8.0;
    final step = (size.width - padX * 2) / (n - 1);
    final pts = <Offset>[];
    for (var i = 0; i < n; i++) {
      final x = padX + i * step;
      final y = size.height -
          padY -
          (values[i] / maxV) * (size.height - padY * 2);
      pts.add(Offset(x, y));
    }

    final trackPaint = Paint()
      ..color = track
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(padX, size.height - 4),
      Offset(size.width - padX, size.height - 4),
      trackPaint,
    );

    // 按 drawT 生长路径
    final visible = (t * (n - 1)).clamp(0.0, (n - 1).toDouble());
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < n; i++) {
      final seg = (visible - (i - 1)).clamp(0.0, 1.0);
      if (seg <= 0) break;
      final from = pts[i - 1];
      final to = pts[i];
      final p = Offset.lerp(from, to, seg)!;
      path.lineTo(p.dx, p.dy);
    }
    final area = Path.from(path)
      ..lineTo(pts.first.dx + visible * step, size.height - 4)
      ..lineTo(pts.first.dx, size.height - 4)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [line.withValues(alpha: 0.35), line.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    for (var i = 0; i < n; i++) {
      final appear = ((visible - i) * 3).clamp(0.0, 1.0);
      if (appear <= 0) continue;
      final isToday = i == n - 1;
      if (isToday) {
        canvas.drawCircle(
          pts[i],
          8 * appear,
          Paint()..color = line.withValues(alpha: 0.2),
        );
      }
      canvas.drawCircle(
        pts[i],
        (isToday ? 4.5 : 3) * appear,
        Paint()..color = line.withValues(alpha: (isToday ? 1 : 0.55) * appear),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WeekLinePainter old) =>
      old.values != values ||
      old.line != line ||
      old.drawT != drawT;
}

/// 底栏实底态（减弱动态）用
class HomeSolidIcon extends StatelessWidget {
  const HomeSolidIcon({super.key});
  @override
  Widget build(BuildContext context) => const Icon(AppIcons.home);
}
