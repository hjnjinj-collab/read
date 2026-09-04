import 'dart:collection';

import 'package:flutter/widgets.dart';

import '../ffi/rust_bridge.dart/api.dart' as rust_api;
// 故意不 import reader_font.dart：
// - 本服务在 ReaderFont.loadCustomFont 内被调用，循环 import 会破坏初始化顺序
// - 仅在初始化时读取 `ReaderFont.family` 静态字段，使用 const 兜底（启动后
//   configure() 会被 reader_provider 在字体变更时同步调用）
// 详见 reader_font.dart 顶部注释

/// M10-B：Dart 端 Skia 实测宽度服务
///
/// 背景：Rust layout 期间无法直接访问 Skia/HarfBuzz（rust 用 ttf-parser hmtx 估算
/// 字符宽度，结果与 Skia 整形后宽度不一致 → 左右边距视觉不对称）。
///
/// 解决：Dart 端用 TextPainter 测真实渲染宽度，批量回传给 Rust 共享
/// MeasureCache。Rust layout 二分搜索命中缓存时用 Skia 真实宽度做断行决策。
///
/// 设计：
/// - 单例（MeasureTextService.instance），进程内一份
/// - LRU 容量 50_000（与 Rust MEASURE_CACHE_CAPACITY 对齐）
/// - key = (fontFamily, fontSize, text) — text 必须与 Rust 查询的子串**逐字节一致**
/// - **首次 measure 异步 batch 注入 Rust**：批量测完后调 `feedTextWidths` FFI
/// - 字体切换：`ReaderFont.loadCustomFont` 调 `invalidateForFont(fontName)` 全清
class MeasureTextService {
  MeasureTextService._();
  static final MeasureTextService instance = MeasureTextService._();

  /// LRU 缓存
  final LinkedHashMap<_MeasureKey, double> _cache = LinkedHashMap();
  static const int _capacity = 50_000;

  /// 当前正在测量的字体（启动后由 reader_provider.configure() 同步）
  String _fontFamily = '';
  double _fontSize = 18.0;

  /// 待 flush 到 Rust 的批次（Dart 测完一组后批量回传）
  final List<rust_api.FfiTextWidth> _pending = <rust_api.FfiTextWidth>[];

  /// 设置当前测量参数（每次 font/fontSize 变更时调用）
  void configure({required String fontFamily, required double fontSize}) {
    _fontFamily = fontFamily;
    _fontSize = fontSize;
    // 字号/字体变更清空（Dart 端 key 改变，缓存全部失效）
    _cache.clear();
    _pending.clear();
  }

  /// 测量单条（命中缓存直接返回；未命中调 TextPainter 测宽）
  ///
  /// 返回的宽度单位为 px。TextPainter 用 minWidth: 0 / maxWidth: double.infinity
  /// 保证单行无约束排版（与 Skia 最终绘制走同一段内部 Paragraph）。
  double measure(String text) {
    final key = _MeasureKey(_fontFamily, _fontSize, text);
    final cached = _cache[key];
    if (cached != null) {
      // 命中：挪到 LRU 末尾（最近使用）
      _cache.remove(key);
      _cache[key] = cached;
      return cached;
    }

    // miss：用 TextPainter 测
    final width = _measureWithTextPainter(text);

    // 写 Dart 端 LRU
    if (_cache.length >= _capacity) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = width;

    // 加入待 flush 批次
    _pending.add(
      rust_api.FfiTextWidth(
        fontName: _fontFamily,
        fontSize: _fontSize,
        text: text,
        width: width,
      ),
    );
    return width;
  }

  /// 批量测量（一次性返回 [width0, ...]）
  List<double> measureAll(List<String> texts) {
    return texts.map(measure).toList(growable: false);
  }

  /// M12 必修2：喂入 line text 的**所有 char-boundary 前缀**子串
  ///
  /// **背景**：Rust `find_longest_fit` 二分搜索查 `text[..mid]`（前缀子串），
  /// Dart 仅喂入完整 line 文本——cache key 集合**不相交**，命中率 ≈0%。
  /// 本方法把完整 line 的所有 prefix 也喂入 MeasureCache + Dart 端 LRU，
  /// 让 Rust 二分搜索命中 cache（cache 命中 = Skia 实测宽度）。
  ///
  /// 性能：一行 O(N) 次测量，单字符 ~30μs × N 字符；
  /// 30 字符行 ≈ 0.9ms × 25 行/page ≈ 22ms 首翻延迟——可接受。
  /// 后续翻页 cache 命中 → 0ms。
  ///
  /// 调用方应在 `paintPage` 每个文本 entry 处调用一次。
  void feedPageTextsWithPrefixes(String text) {
    if (text.isEmpty) return;
    // M12 修复：改用 substring 而非 characters，确保与 Rust 的 text[..mid] 对齐
    // Rust: text[..mid] → UTF-8 字节边界子串
    // Dart characters: grapheme clusters（可能与 UTF-8 byte offset 不对齐）
    for (int i = 1; i <= text.length; i++) {
      // 确保在 char boundary（避免 UTF-16 surrogate pair 中间截断）
      if (i < text.length && _isLowSurrogate(text.codeUnitAt(i))) {
        continue; // 跳过 surrogate pair 的后半部分
      }
      measure(text.substring(0, i));
    }
  }

  /// 判断是否是 UTF-16 低位代理项（surrogate pair 的后半部分）
  static bool _isLowSurrogate(int codeUnit) {
    return codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;
  }

  /// 实际测宽：构造 TextPainter 跑一次 layout，取 maxIntrinsicWidth
  double _measureWithTextPainter(String text) {
    if (text.isEmpty) return 0.0;
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: _fontFamily.isEmpty ? null : _fontFamily,
          fontSize: _fontSize,
        ),
      ),
      textAlign: TextAlign.left,
      textDirection: TextDirection.ltr,
    )..layout(minWidth: 0, maxWidth: double.infinity);
    final width = tp.maxIntrinsicWidth;
    tp.dispose();
    return width;
  }

  /// 把累积的待 flush 批次一次性写入 Rust MeasureCache
  ///
  /// 调用时机：
  /// - 阅读器当前页加载后（Dart 测了本章若干子串宽）
  /// - 切换字号/字体后（缓存清空，但本批数据可保留）
  ///
  /// 返回：(flush 成功条数, 当前 Dart 缓存大小)
  Future<(int, int)> flushToRust() async {
    if (_pending.isEmpty) return (0, _cache.length);
    final batch = List<rust_api.FfiTextWidth>.from(_pending);
    _pending.clear();
    final n = await rust_api.feedTextWidths(widths: batch);
    return (n.toInt(), _cache.length);
  }

  /// 切换字体后清空（ReaderFont.loadCustomFont 调用）
  Future<void> invalidateForFont(String fontName) async {
    _cache.clear();
    _pending.clear();
    // 让 Rust 侧也清（保险起见）
    await rust_api.clearMeasureCache();
    configure(fontFamily: fontName, fontSize: _fontSize);
  }

  /// 当前 Dart 端缓存条目数（诊断用）
  int get cacheLength => _cache.length;
}

/// M10-B：缓存 key
///
/// 与 Rust MeasureCache::make_key 一致：font_name + font_size_bits + text
/// Dart 端不用 hash（直接用 text 字符串即可，避免 hash 碰撞检测）
class _MeasureKey {
  final String fontFamily;
  final double fontSize;
  final String text;
  const _MeasureKey(this.fontFamily, this.fontSize, this.text);

  @override
  bool operator ==(Object other) =>
      other is _MeasureKey &&
      other.fontFamily == fontFamily &&
      other.fontSize == fontSize &&
      other.text == text;

  @override
  int get hashCode => Object.hash(fontFamily, fontSize, text);
}

/// M10-B：PagePainter 注入扩展
///
/// PagePainter 收到 PageInfo.entries 后，对每条文本 entry 调一次
/// `MeasureTextService.instance.measure(text)`，把 Dart Skia 实测宽度
/// 写入 Dart 端 LRU + Rust MeasureCache。这样 Rust layout 下一次调用
/// 时会命中缓存，二分搜索用 Skia 真实宽度做断行。
extension MeasureFeedOnPaint on MeasureTextService {
  /// PagePainter 注入入口：测当前页所有文本 entry（不去重）
  void feedPageTexts(Iterable<String> texts) {
    for (final t in texts) {
      measure(t);
    }
  }
}