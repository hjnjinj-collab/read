import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/database/app_database.dart';
import '../../core/ffi/book_service.dart' show CoverStore;
import '../../core/theme/app_icons.dart';
import '../../core/theme/app_theme.dart' show AppGlass;
import '../reader/presentation/providers/reader_provider.dart'
    show appDatabaseProvider;
import 'bookshelf/thin_continue_bar.dart';
import 'providers/shell_settings.dart';
import 'widgets/shell_ambient.dart' show AmbientDir, ShellAmbient;

/// 首页 Dashboard：Hero 轮换（首帧今日目标）→ 统计 → 折线 → 最近阅读。
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  List<(Book, ReadingProgressData?)> _entries = [];
  bool _loading = true;
  int _heroIndex = 0;

  static const _goalMinutes = 30;
  int get _todayMinutes => _entries.isEmpty ? 0 : 18;

  @override
  void initState() {
    super.initState();
    _load();
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
    _armHero();
  }

  void _armHero() {
    Future.delayed(const Duration(seconds: 4), () {
      if (!mounted || _entries.isEmpty) return;
      final n = 1 + math.min(2, _continueItems.length).toInt();
      setState(() => _heroIndex = (_heroIndex + 1) % math.max(1, n));
      _armHero();
    });
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
            ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                pad.top + 12,
                16,
                pad.bottom + 96,
              ),
              children: [
                Text(
                  '首页',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 12),
                _heroCard(scheme),
                const SizedBox(height: 12),
                _statsRow(scheme),
                const SizedBox(height: 12),
                _chartCard(scheme),
                const SizedBox(height: 12),
                if (_entries.isNotEmpty) ...[
                  Text(
                    '最近阅读',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 118,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: math.min(6, _entries.length),
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, i) {
                        final (book, _) = _entries[i];
                        final cover = CoverStore.fileOf(book.filePath);
                        return SizedBox(
                          width: 72,
                          child: InkWell(
                            onTap: () => _openBook(book),
                            borderRadius: BorderRadius.circular(12),
                            child: Column(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: SizedBox(
                                    width: 64,
                                    height: 88,
                                    child: cover != null
                                        ? Image.file(
                                            cover,
                                            fit: BoxFit.cover,
                                            cacheWidth: 160,
                                            gaplessPlayback: true,
                                            errorBuilder: (_, _, _) =>
                                                ColoredBox(
                                              color: scheme.primary
                                                  .withValues(alpha: 0.2),
                                            ),
                                          )
                                        : ColoredBox(
                                            color: scheme.primary
                                                .withValues(alpha: 0.2),
                                          ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  book.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }

  Widget _heroCard(ColorScheme scheme) {
    final cont = _continueItems;
    final showGoalFirst = true;
    final slides = <Widget>[
      if (showGoalFirst) _goalSlide(scheme),
      for (final e in cont.take(2)) _continueSlide(e, scheme),
    ];
    final i = _heroIndex.clamp(0, slides.isEmpty ? 0 : slides.length - 1);
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppGlass.settingsCardRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    i == 0 ? '今日目标' : '继续阅读',
                    style: TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                Row(
                  children: List.generate(
                    slides.length,
                    (d) => Container(
                      width: d == i ? 14 : 6,
                      height: 6,
                      margin: const EdgeInsets.only(left: 4),
                      decoration: BoxDecoration(
                        color: d == i
                            ? scheme.primary
                            : scheme.outlineVariant.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 320),
              child: KeyedSubtree(
                key: ValueKey('hero-$i'),
                child: slides.isEmpty
                    ? const SizedBox(height: 72)
                    : slides[i],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _goalSlide(ColorScheme scheme) {
    final ratio = (_todayMinutes / _goalMinutes).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            height: 72,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 72,
                  height: 72,
                  child: CircularProgressIndicator(
                    value: ratio,
                    strokeWidth: 6,
                    backgroundColor:
                        scheme.outlineVariant.withValues(alpha: 0.45),
                    valueColor: AlwaysStoppedAnimation(scheme.primary),
                    strokeCap: StrokeCap.round,
                  ),
                ),
                Text(
                  '${(ratio * 100).round()}%',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$_todayMinutes / $_goalMinutes 分钟',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  '今日阅读目标',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _continueSlide((Book, ReadingProgressData?) item, ColorScheme scheme) {
    // 复用海报风续读条（与书架顶条同语言）
    return ThinContinueBar(
      book: item.$1,
      progress: item.$2,
      onTap: () => _openBook(item.$1),
    );
  }

  Widget _statsRow(ColorScheme scheme) {
    Widget stat(String lb, String val, String unit) {
      return Expanded(
        child: Card(
          elevation: 0,
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppGlass.settingsCardRadius),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  lb,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      val,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 2, bottom: 3),
                      child: Text(
                        unit,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        stat('读过', '${_entries.length}', '本'),
        const SizedBox(width: 8),
        stat('累计', '36.5', 'h'),
        const SizedBox(width: 8),
        stat('连续', '5', '天'),
      ],
    );
  }

  Widget _chartCard(ColorScheme scheme) {
    // 演示序列：无真实时长库时用固定趋势；有书则与本数弱相关
    final base = _entries.isEmpty
        ? <double>[0, 0, 0, 0, 0, 0, 0]
        : <double>[12, 28, 8, 35, 22, 41, _todayMinutes.toDouble()];
    final week = base.fold<double>(0, (a, b) => a + b);
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppGlass.settingsCardRadius),
      ),
      clipBehavior: Clip.antiAlias,
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
                Text(
                  '${week.round()}',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w800,
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
              height: 120,
              child: CustomPaint(
                painter: _WeekLinePainter(
                  values: base,
                  line: scheme.primary,
                  track: scheme.outlineVariant.withValues(alpha: 0.45),
                ),
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
  });

  final List<double> values;
  final Color line;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
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

    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    final area = Path.from(path)
      ..lineTo(pts.last.dx, size.height - 4)
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
    for (var i = 0; i < pts.length; i++) {
      final isToday = i == n - 1;
      if (isToday) {
        canvas.drawCircle(
          pts[i],
          8,
          Paint()..color = line.withValues(alpha: 0.2),
        );
      }
      canvas.drawCircle(
        pts[i],
        isToday ? 4.5 : 3,
        Paint()..color = line.withValues(alpha: isToday ? 1 : 0.55),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WeekLinePainter old) =>
      old.values != values || old.line != line;
}

/// 底栏实底态（减弱动态）用
class HomeSolidIcon extends StatelessWidget {
  const HomeSolidIcon({super.key});
  @override
  Widget build(BuildContext context) => const Icon(AppIcons.home);
}
