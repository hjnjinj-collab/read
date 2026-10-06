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
  final bool reSegment; // A35-L1: 智能分段增强
  final List<SegmentRuleItem> segmentRules; // A35-L2: 分段规则
  final bool boldEnabled;
  final bool italicEnabled;
  final bool showComments;

  /// A34.1：注释字号倍率（0.70–1.00，默认 0.82）
  final double commentScale;

  /// A34.1：注释颜色预设键（blueGray / gray / sepia）
  final String commentColorPreset;

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

  /// 用户字距（px；叠加在 justify letterGap 之上，绘制层）
  final double letterSpacing;

  /// 章节标题字号倍率（isChapterStart 行；1.0 = 跟随引擎 fontScale）
  final double titleScale;

  /// 顶栏书名显隐（页眉）
  final bool showHeader;

  /// 底栏页码/进度显隐（页脚）
  final bool showFooter;

  /// 日间纸色（ARGB int；null = 默认 ReaderTheme.light.paperColor）
  final int? lightPaperColor;

  /// 夜间纸色（ARGB int；null = 默认 ReaderTheme.dark.paperColor）
  final int? darkPaperColor;

  /// 背景透明度 0–1（纸色相对 scaffold 的不透明度）
  final double bgOpacity;

  /// 内置背景预设键（parchment/linen/xuan/night/deepBlue/warmGray/''）
  final String bgPreset;

  /// 图片纸色适配（漫画白边 / PDF 纸白 → 纸色；默认开）
  final bool imagePaperTint;

  /// 纸色适配强度 0–1
  final double imagePaperTintStrength;

  /// 内置背景图预设 id（'' = 纯色纸；'custom' = 用户壁纸）
  final String bgImagePreset;

  /// 用户自定义壁纸路径（空 = 未设）
  final String bgCustomPath;

  /// 背景图纸色蒙版强度 0–1（默认 0.35）
  final double bgScrimStrength;

  /// 音量键翻页（默认关，避免抢媒体音量）
  final bool volumePageTurn;

  /// 正文文字色（ARGB int；null = 主题默认）
  /// 日/夜独立：light = 日间正文色，dark = 夜间正文色
  final int? lightTextColor;
  final int? darkTextColor;

  /// 强调/注释色（ARGB int；null = 主题默认）
  final int? accentColor;

  /// 明暗：light / dark / auto（跟随系统）
  final String themeMode;

  /// 正文字重：300 细 / 400 常规 / 500 中 / 700 粗
  final int bodyFontWeight;

  /// 用户自定义主题预设（最近若干套，可命名）
  final List<UserThemePreset> userThemes;

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
    required this.reSegment, // A35-L1
    required this.segmentRules, // A35-L2
    required this.boldEnabled,
    required this.italicEnabled,
    required this.showComments,
    required this.commentScale,
    required this.commentColorPreset,
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
    required this.letterSpacing,
    required this.titleScale,
    required this.showHeader,
    required this.showFooter,
    required this.lightPaperColor,
    required this.darkPaperColor,
    required this.bgOpacity,
    required this.bgPreset,
    required this.imagePaperTint,
    required this.imagePaperTintStrength,
    required this.bgImagePreset,
    this.bgCustomPath = '',
    this.bgScrimStrength = 0.35,
    this.volumePageTurn = false,
    required this.lightTextColor,
    required this.darkTextColor,
    required this.accentColor,
    required this.themeMode,
    required this.bodyFontWeight,
    required this.userThemes,
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
        reSegment: false, // A35-L1: 默认关闭，用户按需开启
        segmentRules: [], // A35-L2: 默认空规则列表
        boldEnabled: true,
        italicEnabled: false,
        showComments: true,
        commentScale: 0.82,
        commentColorPreset: 'blueGray',
        enableIndent: true,
        indentSizeChars: 2,
        paragraphSpacingMultiplier: 1.0,
        reParagraphMode: 0, // 统一后 M9 三选一退役，恒 None
        smartSplitThreshold: 50, // 统一智能分段默认阈值
        aggressiveSplitThreshold: 100,
        justify: false,
        punctuationCompress: false,
        customFontFamily: '',
        customFontPath: '',
        pageTurnMode: PageTurnMode.simulation,
        pageTurnSpeed: PageTurnSpeed.medium,
        collapse: CollapseStyle.defaults(),
        theme: 'light',
        letterSpacing: 0.0,
        titleScale: 1.15,
        showHeader: true,
        showFooter: true,
        lightPaperColor: null,
        darkPaperColor: null,
        bgOpacity: 1.0,
        bgPreset: '',
        imagePaperTint: true,
        imagePaperTintStrength: 1.0,
        bgImagePreset: '',
        bgCustomPath: '',
        bgScrimStrength: 0.35,
        volumePageTurn: false,
        lightTextColor: null,
        darkTextColor: null,
        accentColor: null,
        themeMode: 'auto',
        bodyFontWeight: 400,
        userThemes: [],
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
        reSegment: _b(j, 'reSegment', false), // A35-L1
        segmentRules: _segmentRules(j['segmentRules']), // A35-L2
        boldEnabled: _b(j, 'boldEnabled', true),
        italicEnabled: _b(j, 'italicEnabled', true),
        showComments: _b(j, 'showComments', true),
        commentScale: _d(j, 'commentScale', 0.82).clamp(0.70, 1.00),
        commentColorPreset: _s(j, 'commentColorPreset', 'blueGray'),
        enableIndent: _b(j, 'enableIndent', true),
        indentSizeChars: _i(j, 'indentSizeChars', 2),
        paragraphSpacingMultiplier: _d(j, 'paragraphSpacingMultiplier', 1.0),
        // M9 三选一退役：读入忽略，恒 None（仅缩进）
        reParagraphMode: 0,
        // 迁移：旧默认 200（M9 滑杆）→ 统一引擎默认 50；用户显式改过的其它值保留
        smartSplitThreshold: () {
          final v = _i(j, 'smartSplitThreshold', 50);
          return v == 200 ? 50 : v;
        }(),
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
        letterSpacing: _d(j, 'letterSpacing', 0.0).clamp(-2.0, 8.0),
        titleScale: _d(j, 'titleScale', 1.15).clamp(1.0, 1.8),
        showHeader: _b(j, 'showHeader', true),
        showFooter: _b(j, 'showFooter', true),
        lightPaperColor: j['lightPaperColor'] is int
            ? j['lightPaperColor'] as int
            : null,
        darkPaperColor:
            j['darkPaperColor'] is int ? j['darkPaperColor'] as int : null,
        bgOpacity: _d(j, 'bgOpacity', 1.0).clamp(0.15, 1.0),
        bgPreset: _s(j, 'bgPreset', ''),
        imagePaperTint: j['imagePaperTint'] is bool
            ? j['imagePaperTint'] as bool
            : true,
        imagePaperTintStrength: () {
          final v = j['imagePaperTintStrength'];
          if (v is num) return v.toDouble().clamp(0.0, 1.0);
          return 1.0;
        }(),
        bgImagePreset: j['bgImagePreset'] is String
            ? j['bgImagePreset'] as String
            : '',
        bgCustomPath: _s(j, 'bgCustomPath', ''),
        bgScrimStrength: _d(j, 'bgScrimStrength', 0.35).clamp(0.0, 1.0),
        volumePageTurn: _b(j, 'volumePageTurn', false),
        lightTextColor: j['lightTextColor'] is int
            ? j['lightTextColor'] as int
            : (j['textColor'] is int ? j['textColor'] as int : null),
        darkTextColor: j['darkTextColor'] is int
            ? j['darkTextColor'] as int
            : (j['textColor'] is int ? j['textColor'] as int : null),
        accentColor: j['accentColor'] is int ? j['accentColor'] as int : null,
        themeMode: switch (j['themeMode']) {
          'light' || 'dark' || 'auto' => j['themeMode'] as String,
          // 旧字段 theme 迁移
          _ => j['theme'] == 'dark'
              ? 'dark'
              : j['theme'] == 'light'
                  ? 'light'
                  : 'auto',
        },
        bodyFontWeight: () {
          final v = _i(j, 'bodyFontWeight', 400);
          return (v == 300 || v == 500 || v == 700) ? v : 400;
        }(),
        userThemes: _userThemes(j['userThemes']),
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

  /// A35-L2: 分段规则安全解析
  static List<SegmentRuleItem> _segmentRules(Object? raw) {
    if (raw is! List) return const [];
    final out = <SegmentRuleItem>[];
    for (final item in raw) {
      if (item is! Map<String, dynamic>) continue;
      final id = item['id'];
      if (id is! String) continue;
      out.add(SegmentRuleItem(
        id: id,
        pattern: item['pattern'] is String ? item['pattern'] as String : '',
        action: item['action'] is int ? item['action'] as int : 0,
        enabled: item['enabled'] is bool ? item['enabled'] as bool : true,
        isBuiltin: item['isBuiltin'] is bool ? item['isBuiltin'] as bool : false,
        isRegex: item['isRegex'] is bool ? item['isRegex'] as bool : false,
      ));
    }
    return out;
  }

  static List<UserThemePreset> _userThemes(Object? raw) {
    if (raw is! List) return const [];
    final out = <UserThemePreset>[];
    for (final item in raw) {
      if (item is! Map<String, dynamic>) continue;
      final t = UserThemePreset.tryParse(item);
      if (t != null) out.add(t);
    }
    return out;
  }
}

/// 用户自定义阅读主题（可命名；日/夜纸色 + 文字/强调色 + 透明度）
class UserThemePreset {
  final String name;
  final bool dark;
  final int lightPaper;
  final int darkPaper;
  final int? lightTextColor;
  final int? darkTextColor;
  final int? accentColor;
  final double bgOpacity;
  final String bgPreset;

  const UserThemePreset({
    required this.name,
    required this.dark,
    required this.lightPaper,
    required this.darkPaper,
    this.lightTextColor,
    this.darkTextColor,
    this.accentColor,
    this.bgOpacity = 1.0,
    this.bgPreset = '',
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'dark': dark,
        'lightPaper': lightPaper,
        'darkPaper': darkPaper,
        'lightTextColor': lightTextColor,
        'darkTextColor': darkTextColor,
        'accentColor': accentColor,
        'bgOpacity': bgOpacity,
        'bgPreset': bgPreset,
      };

  static UserThemePreset? tryParse(Map<String, dynamic> j) {
    final name = j['name'];
    if (name is! String || name.isEmpty) return null;
    final lp = j['lightPaper'];
    final dp = j['darkPaper'];
    if (lp is! int || dp is! int) return null;
    return UserThemePreset(
      name: name,
      dark: j['dark'] == true,
      lightPaper: lp,
      darkPaper: dp,
      lightTextColor: j['lightTextColor'] is int
          ? j['lightTextColor'] as int
          : (j['textColor'] is int ? j['textColor'] as int : null),
      darkTextColor: j['darkTextColor'] is int
          ? j['darkTextColor'] as int
          : (j['textColor'] is int ? j['textColor'] as int : null),
      accentColor: j['accentColor'] is int ? j['accentColor'] as int : null,
      bgOpacity: j['bgOpacity'] is num
          ? (j['bgOpacity'] as num).toDouble().clamp(0.15, 1.0)
          : 1.0,
      bgPreset: j['bgPreset'] is String ? j['bgPreset'] as String : '',
    );
  }
}
