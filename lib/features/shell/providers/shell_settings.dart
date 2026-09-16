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
    this.navBlurSigma = 12,
    this.navTintStrength = 0.38,
    this.glassMode = 'liquid',
  });

  final bool bookshelfGrid;
  final bool dynamicColor;

  /// system | light | dark
  final String themeMode;

  /// 自定义 seed（ARGB int）；null = 用 AppTheme.seed 松绿
  final int? seedArgb;

  /// 底栏玻璃模糊 sigma（0=关模糊只留着色；默认 12）
  final double navBlurSigma;

  /// 底栏色渗强度 0–1（primaryContainer 混入比例）
  final double navTintStrength;

  /// liquid = 液态折射（Impeller 实时；Skia 无 View 时自动退化为霜面）
  /// lite   = 毛玻璃霜面（无 shader / 无 capture，性能优先）
  final String glassMode;

  static const String storageKey = 'shell';

  bool get liteGlass => glassMode == 'lite';

  ThemeMode get resolvedThemeMode => switch (themeMode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

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

  static ShellSettings tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return const ShellSettings();
    try {
      final map = jsonDecode(raw);
      if (map is! Map<String, dynamic>) return const ShellSettings();
      return ShellSettings(
        bookshelfGrid: map['bookshelfGrid'] as bool? ?? true,
        dynamicColor: map['dynamicColor'] as bool? ?? false,
        themeMode: map['themeMode'] as String? ?? 'system',
        seedArgb: map['seedArgb'] as int?,
        navBlurSigma: (map['navBlurSigma'] as num?)?.toDouble() ?? 12,
        navTintStrength: (map['navTintStrength'] as num?)?.toDouble() ?? 0.38,
        glassMode: switch (map['glassMode'] as String?) {
          'lite' => 'lite',
          'liquid' => 'liquid',
          _ => 'liquid',
        },
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
        'navBlurSigma': navBlurSigma,
        'navTintStrength': navTintStrength,
        'glassMode': glassMode,
      });

  ShellSettings copyWith({
    bool? bookshelfGrid,
    bool? dynamicColor,
    String? themeMode,
    int? seedArgb,
    bool clearSeed = false,
    double? navBlurSigma,
    double? navTintStrength,
    String? glassMode,
  }) {
    return ShellSettings(
      bookshelfGrid: bookshelfGrid ?? this.bookshelfGrid,
      dynamicColor: dynamicColor ?? this.dynamicColor,
      themeMode: themeMode ?? this.themeMode,
      seedArgb: clearSeed ? null : (seedArgb ?? this.seedArgb),
      navBlurSigma: navBlurSigma ?? this.navBlurSigma,
      navTintStrength: navTintStrength ?? this.navTintStrength,
      glassMode: glassMode ?? this.glassMode,
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

  void setSeed(Color? color) {
    if (color == null) {
      if (state.seedArgb == null) return;
      _persist(state.copyWith(clearSeed: true));
      return;
    }
    if (state.seedArgb == color.toARGB32()) return;
    _persist(state.copyWith(seedArgb: color.toARGB32()));
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
}

final shellSettingsProvider =
    NotifierProvider<ShellSettingsNotifier, ShellSettings>(
  ShellSettingsNotifier.new,
);
