import 'package:flutter/material.dart';

/// 顶栏 Hero 切换：**新帧从左入，旧帧从右出**。
/// 首页轮换与书架续读条共用；禁止双帧叠影（layout 只叠 previous + current）。
class HeroSlideSwitcher extends StatelessWidget {
  const HeroSlideSwitcher({
    super.key,
    required this.index,
    required this.child,
    this.height = 152,
    this.radius = 16,
    this.duration = const Duration(milliseconds: 450),
  });

  final int index;
  final Widget child;
  final double height;
  final double radius;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: AnimatedSwitcher(
          duration: duration,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, anim) {
            return _LeftInRightOut(animation: anim, child: child);
          },
          layoutBuilder: (currentChild, previousChildren) {
            return Stack(
              fit: StackFit.expand,
              children: [...previousChildren, ?currentChild],
            );
          },
          child: KeyedSubtree(key: ValueKey('hero-$index'), child: child),
        ),
      ),
    );
  }
}

class _LeftInRightOut extends StatelessWidget {
  const _LeftInRightOut({
    required this.animation,
    required this.child,
  });

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 入场（forward）：x -1 → 0；出场（reverse）：x 0 → +1
    final isExit = animation.status == AnimationStatus.reverse ||
        (animation.status == AnimationStatus.dismissed &&
            animation.value < 1);
    final Animation<Offset> offset = isExit
        ? Tween<Offset>(begin: Offset.zero, end: const Offset(1, 0)).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeInCubic),
          )
        : Tween<Offset>(begin: const Offset(-1, 0), end: Offset.zero).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
          );
    return SlideTransition(
      position: offset,
      child: FadeTransition(
        opacity: Tween<double>(begin: 0.2, end: 1).animate(animation),
        child: child,
      ),
    );
  }
}
