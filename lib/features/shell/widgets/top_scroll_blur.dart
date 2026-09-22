import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart' show AppGlass;

/// 书架/首页共用顶栏：滚动显现的**滤镜色渐变模糊**。
///
/// 层序：模糊/雾在 `ClipRect` 内；前景 [child] 叠在最上（标题/尾控件）。
/// 静止（`scrollT < 0.02`）不叠模糊，避免暗色下「常显滤镜」。
/// 雾 α 与书架历史观感对齐（非设置页更实的那组）。
class TopScrollBlurChrome extends StatelessWidget {
  const TopScrollBlurChrome({
    super.key,
    required this.scrollT,
    required this.child,
    required this.headerContentH,
    required this.topBlurExtend,
  });

  /// 0 静止 → 1 滚动（约 56px 内完成显现）
  final double scrollT;

  /// 标题行（含 SafeArea/内边距），叠在模糊之上
  final Widget child;

  /// 标题带高度（不含系统 inset），与 BookshelfLayout.headerContentH 同源
  final double headerContentH;

  /// 模糊向下延伸的衰减带（只盖内容、不占布局）
  final double topBlurExtend;

  static const double blurEpsilon = 0.02;

  /// 与书架历史雾 α 一致
  static const List<double> _fogAlphas = [0.58, 0.48, 0.32, 0.16, 0.05, 0];
  static const List<double> _stops = [0, 0.22, 0.42, 0.62, 0.82, 1];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final disableBlur = MediaQuery.disableAnimationsOf(context);
    final topPad = MediaQuery.paddingOf(context).top;

    if (disableBlur) {
      return Material(
        color: scheme.surface,
        child: SizedBox(
          height: topPad + headerContentH,
          child: child,
        ),
      );
    }

    if (scrollT < blurEpsilon) {
      return SizedBox(
        height: topPad + headerContentH,
        child: child,
      );
    }

    final h = topPad + headerContentH + topBlurExtend;
    final fog = AppGlass.topTint(scheme);
    final fogA = scrollT;
    // 层序对齐 SettingsTopChrome：仅模糊/雾进 ClipRect，前景在之外之上，
    // 避免液态 trailing（growHeight）外溢被裁。
    return SizedBox(
      height: h,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ShaderMask(
                      shaderCallback: (rect) {
                        return LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white,
                            Colors.white.withValues(alpha: 0.92),
                            Colors.white.withValues(alpha: 0.72),
                            Colors.white.withValues(alpha: 0.40),
                            Colors.white.withValues(alpha: 0.14),
                            Colors.transparent,
                          ],
                          stops: _stops,
                        ).createShader(rect);
                      },
                      blendMode: BlendMode.dstIn,
                      child: BackdropFilter(
                        filter: ImageFilter.blur(
                          sigmaX: AppGlass.topBlurSigma,
                          sigmaY: AppGlass.topBlurSigma,
                        ),
                        child: ColoredBox(color: fog),
                      ),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            for (final a in _fogAlphas)
                              a == 0
                                  ? Colors.transparent
                                  : fog.withValues(alpha: a * fogA),
                          ],
                          stops: _stops,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: child,
          ),
        ],
      ),
    );
  }
}
