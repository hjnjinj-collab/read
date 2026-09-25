import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 阅读器翻页诊断日志。
///
/// 使用 print 而不是 debugPrint，保证 Windows CMD 中按事件顺序立即可见。
/// 运行时可用 `flutter run -d windows` 或直接启动 Debug exe 观察 `[READER]` 行。
///
/// A28 排障：每帧/每次绘制触发的噪声事件默认抑制（[_frameNoiseEvents]），
/// 仅保留生命周期与错误事件；定位渲染细节时置 [readerTraceVerbose] = true
/// 全量输出。
///
/// A28 文件日志：真机排障无法直接看控制台，[readerTrace] 同步双写文件
/// （`<appDocuments>/reader_trace.log`，启动时轮转上一会话到 .old），
/// 菜单栏「日志导出」按钮经 [readTraceLogs] + FilePicker SAF 导出。
bool readerTraceVerbose = false;

/// 每帧/每次绘制/高频循环触发的噪声事件（默认抑制）
const Set<String> _frameNoiseEvents = {
  // 每帧绘制
  'page.paint',
  'curl.paint.frame',
  'ripple.paint.frame',
  'collapse.paint.frame',
  'curl.paint.content',
  'ripple.paint.slow',
  'collapse.paint.slow',
  'viewport.mismatch',
  'viewport.mismatch.idle',
  'paint.geometry.first',
  // 每图每帧
  'image.hit',
  'image.callback',
  'image.evict',
  // 每次发布/门控调用
  'render.publish',
  'render.publish.empty',
  'turn.gate.ready',
  // 翻页调试期遗留的高频事件（默认关闭；排障开 verbose）
  'turn.gate.wait',
  'turn.queued',
  'turn.queued.run',
  'turn.start',
  'turn.end',
  'turn.end.swallowed',
  'turn.drop',
  'turn.drop.busy',
  'turn.wait',
  'turn.snapshot',
  'turn.takeover',
  'turn.takeover.commit',
  'turn.aborted',
  'turn.pending.retry',
  'turn.pending.timeout',
  'turn.drag-end.pending',
  'turn.drag-end.deferred',
  'commit.enter',
  'commit.pageDone',
  'commit.prewarmStart',
  'commit.prewarmDone',
  'commit.exception',
  'turn.commit',
  'frame.commit',
  'frame.commit.degraded',
  'frame.neighbors.ready',
  'frame.resources.ready',
  'frame.resources.monitor.ready',
  'page.load.start',
  'page.load.commit',
  'image.prewarm.start',
  'image.prewarm.ready',
  'image.predict.start',
  'image.predict.ready',
  'image.request',
  'image.bytes',
  'image.gate.wait',
};

void readerTrace(String event, [Map<String, Object?> fields = const {}]) {
  final isNoise = !readerTraceVerbose && _frameNoiseEvents.contains(event);
  final timestamp = DateTime.now().toIso8601String();
  final details = fields.entries
      .map((entry) => '${entry.key}=${entry.value}')
      .join(' ');
  final line =
      '[READER][$timestamp] $event${details.isEmpty ? '' : ' $details'}';
  // 控制台：噪声默认不打；文件/环形缓冲**始终记录**（导出/Bug 页可回溯）
  if (!isNoise) {
    print(line);
  }
  TraceRingBuffer.instance.add(
    time: DateTime.now(),
    event: event,
    fields: fields,
  );
  unawaited(_TraceFileSink.instance.write(line));
}

/// 日志事件（Bug 收集页）
class TraceEvent {
  TraceEvent({
    required this.time,
    required this.event,
    required this.fields,
  });

  final DateTime time;
  final String event;
  final Map<String, Object?> fields;

  String get line {
    final details =
        fields.entries.map((e) => '${e.key}=${e.value}').join(' ');
    return details.isEmpty ? event : '$event $details';
  }

  /// 简单分级：error/exception/fail → error；warn → warn；其余 info
  String get level {
    final e = event.toLowerCase();
    if (e.contains('error') ||
        e.contains('exception') ||
        e.contains('fail') ||
        e.contains('reject')) {
      return 'error';
    }
    if (e.contains('warn') ||
        e.contains('drop') ||
        e.contains('timeout') ||
        e.contains('stale')) {
      return 'warn';
    }
    return 'info';
  }
}

/// 内存环形日志：保留最近 [window]（默认 15 分钟）且不超过 [maxEvents]。
/// 用户可手动清空；短窗 + 条数上限，避免长会话吃内存。
class TraceRingBuffer {
  TraceRingBuffer._();
  static final TraceRingBuffer instance = TraceRingBuffer._();

  /// 安全上限（15 分钟内正常远低于此）
  static const int maxEvents = 1500;

  /// 最长回溯 15 分钟
  static const Duration window = Duration(minutes: 15);

  /// 内置过滤分类：关键字匹配事件名/字段
  static const Map<String, String> categories = {
    'all': '',
    'read': 'openBook page.load page.paint render session',
    'turn': 'turn frame.commit commit. curl ripple collapse',
    'page': 'page.load page.next page.previous page.adopt layout fp-reload',
    'image': 'image.',
    'error': '', // 由 level 过滤
  };

  final List<TraceEvent> _events = [];
  final List<void Function()> _listeners = [];

  void add({
    required DateTime time,
    required String event,
    Map<String, Object?> fields = const {},
  }) {
    _events.add(TraceEvent(time: time, event: event, fields: fields));
    if (_events.length > maxEvents) {
      _events.removeRange(0, _events.length - maxEvents);
    }
    final cutoff = DateTime.now().subtract(window);
    while (_events.isNotEmpty && _events.first.time.isBefore(cutoff)) {
      _events.removeAt(0);
    }
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  void addListener(void Function() fn) => _listeners.add(fn);
  void removeListener(void Function() fn) => _listeners.remove(fn);

  /// 查询：时间窗 + 内置分类/关键字 + 级别
  List<TraceEvent> query({
    Duration? within,
    String? category,
    String? keyword,
    String? level,
  }) {
    final cutoff = DateTime.now().subtract(within ?? window);
    final kw = keyword?.trim().toLowerCase();
    final cat = category ?? 'all';
    final catTokens = categories[cat]
            ?.split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty)
            .toList() ??
        const <String>[];
    return _events.where((e) {
      if (e.time.isBefore(cutoff)) return false;
      if (level != null && level != 'all' && e.level != level) return false;
      // 内置分类：事件名前缀命中任一 token
      if (cat != 'all' && cat != 'error' && catTokens.isNotEmpty) {
        final ev = e.event.toLowerCase();
        if (!catTokens.any(ev.contains)) return false;
      }
      if (kw != null && kw.isNotEmpty) {
        final hay = '${e.event} ${e.line}'.toLowerCase();
        if (!hay.contains(kw)) return false;
      }
      return true;
    }).toList();
  }

  void clear() {
    _events.clear();
    for (final l in List.of(_listeners)) {
      l();
    }
  }
}

// ── 文件日志 sink（A28 真机排障）──────────────────────────────────

/// 文件日志单例：始终开启，与控制台同源同过滤。
/// - 启动首次写入时轮转：上一会话 reader_trace.log → reader_trace.old.log
/// - 2MB 上限防无限增长（超过后静默停写）
/// - 所有 IO 异常静默吞掉：日志失败绝不能影响阅读功能
class _TraceFileSink {
  _TraceFileSink._();
  static final _TraceFileSink instance = _TraceFileSink._();

  static const int _maxBytes = 2 * 1024 * 1024;

  File? _file;
  IOSink? _sink;
  Future<void>? _initFuture;
  int _bytes = 0;

  Future<void> _ensureInit() {
    _initFuture ??= _doInit();
    return _initFuture!;
  }

  Future<void> _doInit() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/reader_trace.log');
      final old = File('${dir.path}/reader_trace.old.log');
      if (await file.exists()) {
        if (await old.exists()) {
          await old.delete();
        }
        await file.rename(old.path);
      }
      _file = file;
      _sink = file.openWrite(mode: FileMode.append);
      _bytes = 0;
    } catch (_) {
      _file = null;
      _sink = null; // 文件日志不可用 → 仅控制台
    }
  }

  Future<void> write(String line) async {
    await _ensureInit();
    final sink = _sink;
    if (sink == null || _bytes > _maxBytes) return;
    try {
      sink.writeln(line);
      _bytes += line.length + 1;
    } catch (_) {}
  }

  Future<void> flush() async {
    try {
      await _sink?.flush();
    } catch (_) {}
  }

  /// 读取全部日志（上次会话 .old + 本次），供导出
  Future<String?> readAll() async {
    await flush();
    try {
      final old = File('${_file?.parent.path}/reader_trace.old.log');
      final buffer = StringBuffer();
      if (await old.exists()) {
        buffer.writeln('===== 上一会话 (reader_trace.old.log) =====');
        buffer.writeln(await old.readAsString());
      }
      if (_file != null && await _file!.exists()) {
        buffer.writeln('===== 本次会话 (reader_trace.log) =====');
        buffer.writeln(await _file!.readAsString());
      }
      final content = buffer.toString();
      return content.isEmpty ? null : content;
    } catch (_) {
      return null;
    }
  }
}

/// 导出用：读取全部日志文本（上一会话 + 本次）；null = 暂无日志
Future<String?> readTraceLogs() => _TraceFileSink.instance.readAll();

int readerObjectId(Object? value) =>
    value == null ? 0 : identityHashCode(value);

int readerPageId(Object? page) => readerObjectId(page);

/// 轻量页面内容指纹，仅用于确认 Painter 实际收到的页面是否变化。
/// 不输出正文，避免 CMD 日志泄露整章内容。
int readerPageFingerprint(Iterable<String> values) {
  var hash = 17;
  for (final value in values) {
    for (final codeUnit in value.codeUnits) {
      hash = (hash * 31 + codeUnit) & 0x7fffffff;
    }
    hash = (hash * 31 + 1) & 0x7fffffff;
  }
  return hash;
}

String readerPageSummary(Iterable<dynamic> entries) {
  var textCount = 0;
  var imageCount = 0;
  final sample = <String>[];
  for (final entry in entries) {
    if (entry.resourceHref != null) {
      imageCount++;
    } else if (entry.text != null) {
      textCount++;
      if (sample.length < 2) sample.add(entry.text as String);
    }
  }
  return 'text=$textCount image=$imageCount sampleHash=${readerPageFingerprint(sample)}';
}
