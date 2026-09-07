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
};

void readerTrace(String event, [Map<String, Object?> fields = const {}]) {
  if (!readerTraceVerbose && _frameNoiseEvents.contains(event)) return;
  final timestamp = DateTime.now().toIso8601String();
  final details = fields.entries
      .map((entry) => '${entry.key}=${entry.value}')
      .join(' ');
  final line =
      '[READER][$timestamp] $event${details.isEmpty ? '' : ' $details'}';
  print(line);
  // 文件双写（异步，失败静默——诊断通道不得影响功能）
  unawaited(_TraceFileSink.instance.write(line));
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
