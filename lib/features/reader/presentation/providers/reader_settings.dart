import 'dart:convert';

import '../../../../core/models/simple_models.dart';
import '../widgets/page_turn/page_turn_types.dart';

/// 坍塌动画样式参数（2026-09-04 P1 设置化）
///
/// 仅坍塌模式消费；参数只影响 shader 采样方式，不改变页面内容——
/// 因此**不进入**页面快照缓存键（快照与动画参数解耦）。
class CollapseStyle {
  /// 方块边长（px，24~64）——越大颗粒越粗、块数越少
  final double blockSize;

  /// 向心滑移距离（px，0~80）——坍塌块被吸向点击点的距离
  final double slideDistance;

  /// 阴影颜色（ARGB int）——方向性立体感来源（底重顶轻）
  final int shadowColorValue;

  const CollapseStyle({
    required this.blockSize,
    required this.slideDistance,
    required this.shadowColorValue,
  });

  const CollapseStyle.defaults()
      : blockSize = 36,
        slideDistance = 45,
        shadowColorValue = 0xFF333630;

  factory CollapseStyle.tryParse(Object? raw) {
    if (raw is! Map<String, dynamic>) return CollapseStyle.defaults();
    return CollapseStyle(
      blockSize: _clampD(raw['blockSize'], 36, 24, 64),
      slideDistance: _clampD(raw['slideDistance'], 45, 0, 80),
      shadowColorValue:
          _clampI(raw['shadowColor'], 0xFF333630, 0xFF000000, 0xFFFFFFFF),
    );
  }

  Map<String, dynamic> toJson() => {
        'blockSize': blockSize,
        'slideDistance': slideDistance,
        'shadowColor': shadowColorValue,
      };

  static double _clampD(Object? v, double def, double lo, double hi) {
    final d = v is num ? v.toDouble() : def;
    return d.clamp(lo, hi);
  }

  static int _clampI(Object? v, int def, int lo, int hi) {
    final i = v is int ? v : def;
    return i.clamp(lo, hi);
  }
}

/// 阅读器持久化设置模型（2026-09-04 P1 设置持久化）
///
/// - 默认值 = 现行全部硬编码值（接入前后行为零变化）
/// - [tryParse] 逐字段安全提取：损坏 JSON / 缺键 / 未来新增键全部落默认，
///   永不抛异常（启动链路禁止崩溃源）
/// - 序列化由 ReaderNotifier._settingsJson() 从内存字段组装（单一来源），
///   本模型只负责「JSON → 类型化值」的解析侧
class ReaderSettings {
  final double fontSize;
  final double lineHeight;
  final double paddingHorizontal;
  final double paddingVertical;
  final double pageFillThreshold;

  final bool removeDuplicateTitle;
  final ChineseConvertType chineseConvert;
  final List<ReplaceRuleItem> replaceRules;
  final bool removeHtmlTags;
  final bool removeAds;
  final bool boldEnabled;
  final bool italicEnabled;
  final bool showComments;

  final bool enableIndent;
  final int indentSizeChars;
  final double paragraphSpacingMultiplier;
  final int reParagraphMode;
  final int smartSplitThreshold;
  final int aggressiveSplitThreshold;

  /// P2 两端对齐全局开关（EPUB 书内 justify 恒启用；TXT/Left 段跟随）
  final bool justify;

  /// P3 行尾标点压缩悬挂（判满失败且行尾可压缩标点折半宽能放下时收进行尾）
  final bool punctuationCompress;

  /// P6 自定义字体持久化（family 注册名；空 = 内置 ReaderSerif）
  final String customFontFamily;

  /// P6 字体持久化副本路径（应用目录内；空 = 无自定义字体）
  final String customFontPath;

  final PageTurnMode pageTurnMode;
  final PageTurnSpeed pageTurnSpeed;

  final CollapseStyle collapse;

  /// 阅读主题（'light' / 'dark'；色板定义在 ReaderTheme 预设）
  final String theme;

  const ReaderSettings({
    required this.fontSize,
    required this.lineHeight,
    required this.paddingHorizontal,
    required this.paddingVertical,
    required this.pageFillThreshold,
    required this.removeDuplicateTitle,
    required this.chineseConvert,
    required this.replaceRules,
    required this.removeHtmlTags,
    required this.removeAds,
    required this.boldEnabled,
    required this.italicEnabled,
    required this.showComments,
    required this.enableIndent,
    required this.indentSizeChars,
    required this.paragraphSpacingMultiplier,
    required this.reParagraphMode,
    required this.smartSplitThreshold,
    required this.aggressiveSplitThreshold,
    required this.justify,
    required this.punctuationCompress,
    required this.customFontFamily,
    required this.customFontPath,
    required this.pageTurnMode,
    required this.pageTurnSpeed,
    required this.collapse,
    required this.theme,
  });

  /// 默认设置 = 现行全部硬编码值
  factory ReaderSettings.defaults() => const ReaderSettings(
        fontSize: 18.0,
        lineHeight: 1.5,
        paddingHorizontal: 20.0,
        paddingVertical: 20.0,
        pageFillThreshold: 1.0, // A25：1.0 = 行级填满（旧视觉基线）
        removeDuplicateTitle: true,
        chineseConvert: ChineseConvertType.none,
        replaceRules: [],
        removeHtmlTags: true,
        removeAds: true,
        boldEnabled: true,
        italicEnabled: true,
        showComments: true,
        enableIndent: true,
        indentSizeChars: 2,
        paragraphSpacingMultiplier: 1.0,
        reParagraphMode: 1,
        smartSplitThreshold: 200,
        aggressiveSplitThreshold: 100,
        justify: false,
        punctuationCompress: false,
        customFontFamily: '',
        customFontPath: '',
        pageTurnMode: PageTurnMode.simulation,
        pageTurnSpeed: PageTurnSpeed.medium,
        collapse: CollapseStyle.defaults(),
        theme: 'light',
      );

  /// 安全解析：损坏 JSON / 缺键 / 类型不符逐字段落默认，永不抛
  factory ReaderSettings.tryParse(String? rawJson) {
    if (rawJson == null || rawJson.isEmpty) return ReaderSettings.defaults();
    try {
      final j = jsonDecode(rawJson);
      if (j is! Map<String, dynamic>) return ReaderSettings.defaults();
      return ReaderSettings(
        fontSize: _d(j, 'fontSize', 18.0),
        lineHeight: _d(j, 'lineHeight', 1.5),
        paddingHorizontal: _d(j, 'paddingHorizontal', 20.0),
        paddingVertical: _d(j, 'paddingVertical', 20.0),
        pageFillThreshold: _d(j, 'pageFillThreshold', 1.0),
        removeDuplicateTitle: _b(j, 'removeDuplicateTitle', true),
        chineseConvert: _e(
            ChineseConvertType.values, j['chineseConvert'], ChineseConvertType.none),
        replaceRules: _rules(j['replaceRules']),
        removeHtmlTags: _b(j, 'removeHtmlTags', true),
        removeAds: _b(j, 'removeAds', true),
        boldEnabled: _b(j, 'boldEnabled', true),
        italicEnabled: _b(j, 'italicEnabled', true),
        showComments: _b(j, 'showComments', true),
        enableIndent: _b(j, 'enableIndent', true),
        indentSizeChars: _i(j, 'indentSizeChars', 2),
        paragraphSpacingMultiplier: _d(j, 'paragraphSpacingMultiplier', 1.0),
        reParagraphMode: _i(j, 'reParagraphMode', 1),
        smartSplitThreshold: _i(j, 'smartSplitThreshold', 200),
        aggressiveSplitThreshold: _i(j, 'aggressiveSplitThreshold', 100),
        justify: _b(j, 'justify', false),
        punctuationCompress: _b(j, 'punctuationCompress', false),
        customFontFamily: _s(j, 'customFontFamily', ''),
        customFontPath: _s(j, 'customFontPath', ''),
        pageTurnMode:
            _e(PageTurnMode.values, j['pageTurnMode'], PageTurnMode.simulation),
        pageTurnSpeed:
            _e(PageTurnSpeed.values, j['pageTurnSpeed'], PageTurnSpeed.medium),
        collapse: CollapseStyle.tryParse(j['collapse']),
        theme: j['theme'] == 'dark' ? 'dark' : 'light',
      );
    } catch (_) {
      return ReaderSettings.defaults();
    }
  }

  // ── 安全提取助手（类型不符/缺键 → 默认）──

  static double _d(Map<String, dynamic> j, String k, double def) =>
      j[k] is num ? (j[k] as num).toDouble() : def;
  static int _i(Map<String, dynamic> j, String k, int def) =>
      j[k] is int ? j[k] as int : def;
  static bool _b(Map<String, dynamic> j, String k, bool def) =>
      j[k] is bool ? j[k] as bool : def;

  /// P6：字符串安全提取（非 String 或空串视为缺省——空串用于"无自定义字体"）
  static String _s(Map<String, dynamic> j, String k, String def) =>
      j[k] is String ? j[k] as String : def;

  static T _e<T extends Enum>(List<T> values, Object? raw, T def) {
    if (raw is String) {
      for (final v in values) {
        if (v.name == raw) return v;
      }
    }
    return def;
  }

  static List<ReplaceRuleItem> _rules(Object? raw) {
    if (raw is! List) return const [];
    final out = <ReplaceRuleItem>[];
    for (final item in raw) {
      if (item is! Map<String, dynamic>) continue;
      final pattern = item['pattern'];
      final replacement = item['replacement'];
      if (pattern is! String || replacement is! String) continue;
      out.add(ReplaceRuleItem(
        pattern: pattern,
        replacement: replacement,
        isRegex: item['isRegex'] is bool ? item['isRegex'] as bool : false,
        enabled: item['enabled'] is bool ? item['enabled'] as bool : true,
      ));
    }
    return out;
  }
}
