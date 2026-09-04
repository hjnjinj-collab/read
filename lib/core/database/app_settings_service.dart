import 'dart:async';

import 'app_database.dart';

/// 应用设置 KV 服务（2026-09-04 P1 设置持久化地基）
///
/// - **原始 JSON 通道**：本服务只管「键 → JSON 字符串」的存取与防抖，
///   类型安全与默认值兜底由各域的设置模型承担（如 ReaderSettings）——
///   分层上避免 core 依赖 features。
/// - **启动预加载**：main() 中 `load()` 一次读全表进内存快照，此后
///   `raw()` 为同步零开销读取（ReaderNotifier.build() 保持同步构造）。
/// - **写穿 + 防抖**：`save()` 先更新内存快照（写入方立刻可读回），
///   100ms trailing 防抖合并高频写入（未来字号滑杆类）后落库。
///
/// 用法：
/// ```dart
/// // main() 启动序列：
/// final db = AppDatabase();
/// await AppSettingsService.instance.load(db);
/// // ProviderScope(overrides: [appDatabaseProvider.overrideWithValue(db)])
///
/// // 读取（同步）：
/// final raw = AppSettingsService.instance.raw('reader');
/// // 写入（防抖落库）：
/// AppSettingsService.instance.save('reader', jsonEncode(map));
/// ```
class AppSettingsService {
  AppSettingsService._();

  static final AppSettingsService instance = AppSettingsService._();

  AppDatabase? _db;

  /// 内存快照（load 后可用；save 即时更新——写入方立刻可读回）
  final Map<String, String> _cache = {};

  /// 防抖待写集（合并同 key 高频写入）
  final Map<String, String> _dirty = {};
  Timer? _flushTimer;
  Future<void> _flushing = Future.value();

  /// 启动时读全表进内存（单行 KV 查询，正常 <10ms）
  Future<void> load(AppDatabase db) async {
    _db = db;
    try {
      final rows = await db.allSettings();
      _cache
        ..clear()
        ..addEntries([for (final r in rows) MapEntry(r.key, r.value)]);
    } catch (e) {
      // 读失败不阻塞启动：全部回默认（各域模型兜底）
      _cache.clear();
    }
  }

  /// 同步读取原始 JSON（未加载/无值返回 null）
  String? raw(String key) => _cache[key];

  /// 写入（更新内存快照 + 100ms trailing 防抖落库，fire-and-forget）
  void save(String key, String jsonValue) {
    _cache[key] = jsonValue;
    _dirty[key] = jsonValue;
    _flushTimer ??= Timer(const Duration(milliseconds: 100), _flush);
  }

  void _flush() {
    _flushTimer = null;
    if (_dirty.isEmpty || _db == null) return;
    final db = _db!;
    final batch = Map<String, String>.of(_dirty);
    _dirty.clear();
    _flushing = _flushing.then((_) async {
      for (final entry in batch.entries) {
        try {
          await db.upsertSetting(entry.key, entry.value);
        } catch (_) {
          // 落库失败不崩溃：下次写入会重试覆盖
        }
      }
    });
  }

  /// 强制落库（退出/测试用；常规路径依赖防抖即可）
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    _flush();
    await _flushing;
  }
}
