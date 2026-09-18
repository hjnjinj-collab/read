import 'package:flutter/material.dart';

/// 页底渐变方向（可设置）。
enum AmbientDir {
  /// 左上 primary → 右下 tertiary（默认斜向）
  tlbr,
  /// 右上 tertiary → 左下 primary
  trbl,
  /// 纵向：上 primary → 下 tertiary
  top,
  /// 纵向：上 tertiary → 下 primary
  bottom,
  /// 横向：左 primary → 右 tertiary
  left,
  /// 横向：左 tertiary → 右 primary
  right;

  static AmbientDir parse(String raw) => AmbientDir.values.firstWhere(
        (e) => e.name == raw,
        orElse: () => AmbientDir.tlbr,
      );

  String get label => switch (this) {
        AmbientDir.tlbr => '左上↘右下',
        AmbientDir.trbl => '右上↘左下',
        AmbientDir.top => '从上到下',
        AmbientDir.bottom => '从下到上',
        AmbientDir.left => '从左到右',
        AmbientDir.right => '从右到左',
      };

  /// 渐变起止对齐（页底 / 霜层共用）
  (Alignment, Alignment) get alignment => switch (this) {
        AmbientDir.tlbr => (Alignment.topLeft, Alignment.bottomRight),
        AmbientDir.trbl => (Alignment.topRight, Alignment.bottomLeft),
        AmbientDir.top => (Alignment.topCenter, Alignment.bottomCenter),
        AmbientDir.bottom => (Alignment.bottomCenter, Alignment.topCenter),
        AmbientDir.left => (Alignment.centerLeft, Alignment.centerRight),
        AmbientDir.right => (Alignment.centerRight, Alignment.centerLeft),
      };
}

/// 壳层页面底：与主题 [ThemeData.scaffoldBackgroundColor] 同源
/// （色渗 pageTint → AppTheme.pageSurface），可选叠 **双息渐变**。
///
/// - 色渗：整页均匀 lerp primary（主题层，开关 `pageTintOn`）
/// - 渐变：primary ⊕ tertiary 双息，方向由 [AmbientDir] 配置
/// - [enabled]==false 时只铺 base 色
///
/// 禁止在子组件里再调 AppTheme.pageSurface(scheme)——会忽略用户比例。
class ShellAmbient extends StatelessWidget {
  const ShellAmbient({
    super.key,
    required this.child,
    this.enabled = true,
    this.dir = AmbientDir.tlbr,
  });

  final Widget child;

  /// false = 关闭渐变，只用色渗 base
  final bool enabled;

  final AmbientDir dir;

  static double _liftA(Brightness b) => b == Brightness.light ? 0.16 : 0.10;
  static double _liftB(Brightness b) => b == Brightness.light ? 0.14 : 0.09;

  static (Alignment, Alignment) _align(AmbientDir dir) => switch (dir) {
        AmbientDir.tlbr => (Alignment.topLeft, Alignment.bottomRight),
        AmbientDir.trbl => (Alignment.topRight, Alignment.bottomLeft),
        AmbientDir.top => (Alignment.topCenter, Alignment.bottomCenter),
        AmbientDir.bottom => (Alignment.bottomCenter, Alignment.topCenter),
        AmbientDir.left => (Alignment.centerLeft, Alignment.centerRight),
        AmbientDir.right => (Alignment.centerRight, Alignment.centerLeft),
      };

  /// 页底装饰：与 [build] / 设置 Backdrop 同源。
  static BoxDecoration decoration(
    BuildContext context, {
    bool enabled = true,
    AmbientDir dir = AmbientDir.tlbr,
  }) {
    final theme = Theme.of(context);
    final base = theme.scaffoldBackgroundColor;
    if (!enabled) return BoxDecoration(color: base);

    final scheme = theme.colorScheme;
    final b = scheme.brightness;
    final a = Color.lerp(base, scheme.primary, _liftA(b))!;
    final z = Color.lerp(base, scheme.tertiary, _liftB(b))!;
    final (begin, end) = _align(dir);
    // 左/右向：两端强、中弱，避免读成竖条色渗
    final colors = dir == AmbientDir.left || dir == AmbientDir.right
        ? [a, base, z]
        : [a, base, z];
    return BoxDecoration(
      gradient: LinearGradient(
        begin: begin,
        end: end,
        colors: colors,
        stops: const [0, 0.45, 1],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: decoration(context, enabled: enabled, dir: dir),
      child: child,
    );
  }
}
