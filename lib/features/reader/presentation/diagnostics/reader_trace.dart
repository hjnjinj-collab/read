/// 阅读器翻页诊断日志。
///
/// 使用 print 而不是 debugPrint，保证 Windows CMD 中按事件顺序立即可见。
/// 运行时可用 `flutter run -d windows` 或直接启动 Debug exe 观察 `[READER]` 行。
void readerTrace(String event, [Map<String, Object?> fields = const {}]) {
  final timestamp = DateTime.now().toIso8601String();
  final details = fields.entries
      .map((entry) => '${entry.key}=${entry.value}')
      .join(' ');
  print('[READER][$timestamp] $event${details.isEmpty ? '' : ' $details'}');
}

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
