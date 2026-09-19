import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color, ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../../core/database/app_settings_service.dart';
import '../../../core/theme/app_theme.dart' show AppTheme;

/// 壳层偏好：布局 / 动态取色 / 主题色 / 明暗 / 玻璃 / 底栏模糊
@immutable
class ShellSettings {
  const ShellSettings({
    this.bookshelfGrid = true,
    this.dynamicColor = false,
    this.themeMode = 'system',
    this.seedArgb,
    this.seedSource = 'preset',
    this.navBlurSigma = 12,
    this.navTintStrength = 0.38,
    this.glassMode = 'liquid',
    this.pageTintOn = true,
    this.pageTintLight = 0.35,
    this.pageTintDark = 0.0,
    this.ambientOn = true,
    this.ambientDir = 'tlbr',
    this.frostOn = true,
    this.frostDir = 'tlbr',
    this.frostStyle = 'unified',
    this.frostRowPadV = 20,
    this.frostGradA,
    this.frostGradB,
    this.frostGradDepth = 1.0,
    this.lgMotionOn = true,
  });

  final bool bookshelfGrid;
  final bool dynamicColor;

  /// system | light | dark
  final String themeMode;

  /// 自定义 seed（ARGB int）；null = 用 AppTheme.seed 松绿
  final int? seedArgb;

  /// 主题色来源：preset = 预置 chips；palette = 调色板；picker = 自定义取色。
  /// 仅在 dynamicColor 关闭时有意义——动态取色开启时覆盖一切。
  final String seedSource;

  /// 底栏玻璃模糊 sigma（0=关模糊只留着色；默认 12）
  final double navBlurSigma;

  /// 底栏色渗强度 0–1（primaryContainer 混入比例）
  final double navTintStrength;

  /// liquid = 液态折射（Impeller 实时；Skia 无 View 时自动退化为霜面）
  /// lite   = 毛玻璃霜面（无 shader / 无 capture，性能优先）
  final String glassMode;

  /// 整页均匀主色**色渗**开关（pageSurface）；关则强制 0
  final bool pageTintOn;

  /// 浅色页底主色混入 0–0.35（整页均匀色相）
  final double pageTintLight;

  /// 深色页底主色混入 0–0.40（黑底偏主色夜灰）
  final double pageTintDark;

  /// **斜向双息渐变**开关（ShellAmbient，叠在色渗之上）
  final bool ambientOn;

  /// 渐变方向：
  /// tlbr | trbl | top | bottom | left | right
  final String ambientDir;

  /// 设置根页霜层渐变开关
  final bool frostOn;

  /// 设置根页霜层渐变方向（同 ambientDirs 枚举）
  final String frostDir;

  /// 霜层方案：unified = 整组连续渐变（默认）；slice = 每栏切片
  final String frostStyle;

  /// 设置根页子栏上下 padding（控制每栏高度，左右不变）
  final double frostRowPadV;

  /// 霜层渐变起点颜色（ARGB int）；null = 跟随 scheme.primary
  final int? frostGradA;

  /// 霜层渐变终点颜色（ARGB int）；null = 跟随 scheme.tertiary
  final int? frostGradB;

  /// 霜层渐变整体深度倍率 0.3–1.8（默认 1.0）；调 alpha 而非换色
  final double frostGradDepth;

  /// 液态玻璃果冻/形变效果开关（滑杆 squash、分段鼓动等）
  final bool lgMotionOn;

  static const List<String> ambientDirs = [
    'tlbr',
    'trbl',
    'top',
    'bottom',
    'left',
    'right',
  ];

  static const String storageKey = 'shell';

  bool get liteGlass => glassMode == 'lite';

  ThemeMode get resolvedThemeMode => switch (themeMode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  /// 当前生效的主题色来源：动态取色优先，其余回落 seedSource
  String get effectiveSeedSource => dynamicColor ? 'dynamic' : seedSource;

  /// 动态取色优先；否则自定义 seed；否则默认松绿
  Color get effectiveSeed {
    if (seedArgb != null) return Color(seedArgb!);
    return AppTheme.seed;
  }

  /// 把 glassMode 写进 liquid_glass_easy 全局引擎开关（须在首个 Lens 前调用）。
  /// Windows Impeller OpenGLES 上液态 shader 易把进程拉崩，桌面强制 lite。
  void applyGlassEngine() {
    final forceLite = liteGlass || Platform.isWindows;
    LiquidGlassEngine.liteGlassOnSkia = forceLite;
    LiquidGlassEngine.liteGlassOnImpeller = forceLite;
  }

  static String _migrateSeedSource(String? raw, int? seedArgb) {
    switch (raw) {
      case 'preset':
      case 'palette':
      case 'picker':
        return raw!;
    }
    if (seedArgb == null) return 'preset';
    final inPalette =
        AppTheme.palettePresets.any((c) => c.toARGB32() == seedArgb);
    return inPalette ? 'palette' : 'picker';
  }

  static ShellSettings tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return const ShellSettings();
    try {
      final map = jsonDecode(raw);
      if (map is! Map<String, dynamic>) return const ShellSettings();
      final seedArgb = map['seedArgb'] as int?;
      return ShellSettings(
        bookshelfGrid: map['bookshelfGrid'] as bool? ?? true,
        dynamicColor: map['dynamicColor'] as bool? ?? false,
        themeMode: map['themeMode'] as String? ?? 'system',
        seedArgb: seedArgb,
        // 旧数据无 seedSource：按色值能否命中调色板推断 palette/picker
        seedSource: _migrateSeedSource(map['seedSource'] as String?, seedArgb),
        navBlurSigma: (map['navBlurSigma'] as num?)?.toDouble() ?? 12,
        navTintStrength: (map['navTintStrength'] as num?)?.toDouble() ?? 0.38,
        glassMode: switch (map['glassMode'] as String?) {
          'lite' => 'lite',
          'liquid' => 'liquid',
          _ => 'liquid',
        },
        pageTintOn: map['pageTintOn'] as bool? ?? true,
        pageTintLight:
            (map['pageTintLight'] as num?)?.toDouble() ?? 0.35,
        pageTintDark: (map['pageTintDark'] as num?)?.toDouble() ?? 0.0,
        ambientOn: map['ambientOn'] as bool? ?? true,
        ambientDir: switch (map['ambientDir'] as String?) {
          'tlbr' || 'trbl' || 'top' || 'bottom' || 'left' || 'right' =>
            map['ambientDir'] as String,
          _ => 'tlbr',
        },
        frostOn: map['frostOn'] as bool? ?? true,
        frostDir: switch (map['frostDir'] as String?) {
          'tlbr' || 'trbl' || 'top' || 'bottom' || 'left' || 'right' =>
            map['frostDir'] as String,
          _ => 'tlbr',
        },
        frostStyle: switch (map['frostStyle'] as String?) {
          'unified' || 'slice' => map['frostStyle'] as String,
          _ => 'unified',
        },
        frostRowPadV:
            (map['frostRowPadV'] as num?)?.toDouble() ?? 20,
        frostGradA: map['frostGradA'] as int?,
        frostGradB: map['frostGradB'] as int?,
        frostGradDepth:
            (map['frostGradDepth'] as num?)?.toDouble() ?? 1.0,
        lgMotionOn: map['lgMotionOn'] as bool? ?? true,
      );
    } catch (_) {
      return const ShellSettings();
    }
  }

  String encode() => jsonEncode({
        'bookshelfGrid': bookshelfGrid,
        'dynamicColor': dynamicColor,
        'themeMode': themeMode,
        'seedArgb': seedArgb,
        'seedSource': seedSource,
        'navBlurSigma': navBlurSigma,
        'navTintStrength': navTintStrength,
        'glassMode': glassMode,
        'pageTintOn': pageTintOn,
        'pageTintLight': pageTintLight,
        'pageTintDark': pageTintDark,
        'ambientOn': ambientOn,
        'ambientDir': ambientDir,
        'frostOn': frostOn,
        'frostDir': frostDir,
        'frostStyle': frostStyle,
        'frostRowPadV': frostRowPadV,
        'frostGradA': frostGradA,
        'frostGradB': frostGradB,
        'frostGradDepth': frostGradDepth,
        'lgMotionOn': lgMotionOn,
      });

  ShellSettings copyWith({
    bool? bookshelfGrid,
    bool? dynamicColor,
    String? themeMode,
    int? seedArgb,
    String? seedSource,
    double? navBlurSigma,
    double? navTintStrength,
    String? glassMode,
    bool? pageTintOn,
    double? pageTintLight,
    double? pageTintDark,
    bool? ambientOn,
    String? ambientDir,
    bool? frostOn,
    String? frostDir,
    String? frostStyle,
    double? frostRowPadV,
    int? frostGradA,
    bool clearFrostGradA = false,
    int? frostGradB,
    bool clearFrostGradB = false,
    double? frostGradDepth,
    bool? lgMotionOn,
  }) {
    return ShellSettings(
      bookshelfGrid: bookshelfGrid ?? this.bookshelfGrid,
      dynamicColor: dynamicColor ?? this.dynamicColor,
      themeMode: themeMode ?? this.themeMode,
      seedArgb: seedArgb ?? this.seedArgb,
      seedSource: seedSource ?? this.seedSource,
      navBlurSigma: navBlurSigma ?? this.navBlurSigma,
      navTintStrength: navTintStrength ?? this.navTintStrength,
      glassMode: glassMode ?? this.glassMode,
      pageTintOn: pageTintOn ?? this.pageTintOn,
      pageTintLight: pageTintLight ?? this.pageTintLight,
      pageTintDark: pageTintDark ?? this.pageTintDark,
      ambientOn: ambientOn ?? this.ambientOn,
      ambientDir: ambientDir ?? this.ambientDir,
      frostOn: frostOn ?? this.frostOn,
      frostDir: frostDir ?? this.frostDir,
      frostStyle: frostStyle ?? this.frostStyle,
      frostRowPadV: frostRowPadV ?? this.frostRowPadV,
      frostGradA:
          clearFrostGradA ? null : (frostGradA ?? this.frostGradA),
      frostGradB:
          clearFrostGradB ? null : (frostGradB ?? this.frostGradB),
      frostGradDepth: frostGradDepth ?? this.frostGradDepth,
      lgMotionOn: lgMotionOn ?? this.lgMotionOn,
    );
  }
}

class ShellSettingsNotifier extends Notifier<ShellSettings> {
  @override
  ShellSettings build() {
    return ShellSettings.tryParse(
      AppSettingsService.instance.raw(ShellSettings.storageKey),
    );
  }

  void _persist(ShellSettings next) {
    state = next;
    AppSettingsService.instance.save(ShellSettings.storageKey, next.encode());
  }

  void setBookshelfGrid(bool value) {
    if (state.bookshelfGrid == value) return;
    _persist(state.copyWith(bookshelfGrid: value));
  }

  void setDynamicColor(bool value) {
    if (state.dynamicColor == value) return;
    _persist(state.copyWith(dynamicColor: value));
  }

  void setThemeMode(String mode) {
    if (state.themeMode == mode) return;
    _persist(state.copyWith(themeMode: mode));
  }

  /// 应用一个主题色并记录来源；动态取色开着时自动让位（关闭），单次持久化
  void applySeed(Color color, {required String source}) {
    final argb = color.toARGB32();
    if (!state.dynamicColor &&
        state.seedArgb == argb &&
        state.seedSource == source) {
      return;
    }
    _persist(
      state.copyWith(
        dynamicColor: false,
        seedArgb: argb,
        seedSource: source,
      ),
    );
  }

  void setNavBlurSigma(double value) {
    final v = value.clamp(0.0, 48.0);
    if ((state.navBlurSigma - v).abs() < 0.5) return;
    _persist(state.copyWith(navBlurSigma: v));
  }

  void setNavTintStrength(double value) {
    final v = value.clamp(0.0, 1.0);
    if ((state.navTintStrength - v).abs() < 0.02) return;
    _persist(state.copyWith(navTintStrength: v));
  }

  void setGlassMode(String mode) {
    final m = mode == 'lite' ? 'lite' : 'liquid';
    if (state.glassMode == m) return;
    final next = state.copyWith(glassMode: m);
    next.applyGlassEngine();
    _persist(next);
  }

  void setPageTintOn(bool value) {
    if (state.pageTintOn == value) return;
    _persist(state.copyWith(pageTintOn: value));
  }

  void setPageTintLight(double value) {
    final v = value.clamp(0.0, 0.60);
    if ((state.pageTintLight - v).abs() < 0.005) return;
    _persist(state.copyWith(pageTintLight: v));
  }

  void setPageTintDark(double value) {
    final v = value.clamp(0.0, 0.40);
    if ((state.pageTintDark - v).abs() < 0.005) return;
    _persist(state.copyWith(pageTintDark: v));
  }

  void setAmbientOn(bool value) {
    if (state.ambientOn == value) return;
    _persist(state.copyWith(ambientOn: value));
  }

  void setAmbientDir(String dir) {
    final d = ShellSettings.ambientDirs.contains(dir) ? dir : 'tlbr';
    if (state.ambientDir == d) return;
    _persist(state.copyWith(ambientDir: d));
  }

  void setFrostOn(bool value) {
    if (state.frostOn == value) return;
    _persist(state.copyWith(frostOn: value));
  }

  void setFrostDir(String dir) {
    final d = ShellSettings.ambientDirs.contains(dir) ? dir : 'tlbr';
    if (state.frostDir == d) return;
    _persist(state.copyWith(frostDir: d));
  }

  void setFrostStyle(String style) {
    final s = style == 'slice' ? 'slice' : 'unified';
    if (state.frostStyle == s) return;
    _persist(state.copyWith(frostStyle: s));
  }

  void setFrostRowPadV(double value) {
    final v = value.clamp(8.0, 36.0);
    if ((state.frostRowPadV - v).abs() < 0.5) return;
    _persist(state.copyWith(frostRowPadV: v));
  }

  void setFrostGradA(Color? color) {
    if (color == null) {
      if (state.frostGradA == null) return;
      _persist(state.copyWith(clearFrostGradA: true));
      return;
    }
    if (state.frostGradA == color.toARGB32()) return;
    _persist(state.copyWith(frostGradA: color.toARGB32()));
  }

  void setFrostGradB(Color? color) {
    if (color == null) {
      if (state.frostGradB == null) return;
      _persist(state.copyWith(clearFrostGradB: true));
      return;
    }
    if (state.frostGradB == color.toARGB32()) return;
    _persist(state.copyWith(frostGradB: color.toARGB32()));
  }

  void setFrostGradDepth(double value) {
    final v = value.clamp(0.3, 1.8);
    if ((state.frostGradDepth - v).abs() < 0.02) return;
    _persist(state.copyWith(frostGradDepth: v));
  }

  void setLgMotionOn(bool value) {
    if (state.lgMotionOn == value) return;
    _persist(state.copyWith(lgMotionOn: value));
  }
}

final shellSettingsProvider =
    NotifierProvider<ShellSettingsNotifier, ShellSettings>(
  ShellSettingsNotifier.new,
);
