import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/core/theme/app_theme.dart';

/// flex_color_scheme 引擎冒烟：scheme 生成不抛、M3 角色齐全、
/// 深浅色同 tonal palette（M3 原则：同 seed 只取不同 tone）。
void main() {
  final seed = AppTheme.seed;

  test('AppTheme.light/dark 由 flex 引擎派生完整 M3 角色', () {
    final light = AppTheme.light();
    final dark = AppTheme.dark();

    // surfaceContainer 系列：FlexColorScheme 完整派生的核心角色
    expect(light.colorScheme.surfaceContainerLowest, isA<Color>());
    expect(light.colorScheme.surfaceContainerHighest, isNot(grayDefault));
    expect(dark.colorScheme.surfaceContainerLow, isA<Color>());

    // primary 由 seed 的 tonal palette 派生（light≈tone40 / dark≈tone80），
    // 不等于 seed 原色也不同于默认蓝，证明 seed 生效
    expect(light.colorScheme.primary, isNot(seed));
    expect(
      dark.colorScheme.primary.computeLuminance(),
      greaterThan(light.colorScheme.primary.computeLuminance()),
    );

    // _base 自定义保留：scaffold 背景 = surface 向 primary 的色渗
    expect(light.scaffoldBackgroundColor, isNot(Colors.white));
  });

  test('seedOverride 与 dynamicSeed 生效', () {
    const custom = Color(0xFF3D5A80);
    final themed = AppTheme.light(seedOverride: custom);
    final dynamicThemed = AppTheme.light(dynamicSeed: custom);
    // 同 seed → 同 primary（覆盖与壁纸路径同源）
    expect(themed.colorScheme.primary, dynamicThemed.colorScheme.primary);
    expect(themed.colorScheme.primary, isNot(AppTheme.light().colorScheme.primary));
  });
}

/// fromSeed 默认中性灰基准（seed 色相被中性化时才会撞上，松绿不会）
Color get grayDefault => const Color(0xFFF7F2FA);
