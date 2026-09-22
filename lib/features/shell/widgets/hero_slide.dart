import 'package:flutter/material.dart';

/// 顶栏 Hero 切换：**新横幅自左推入，旧横幅被推出右侧**（两帧同时可见，连续推挤）。
/// 首页轮换与书架续读条共用；禁止闪烁（同一 Animation 双帧同步插值）。
class HeroSlideSwitcher extends StatefulWidget {
  const HeroSlideSwitcher({
    super.key,
    required this.index,
    required this.child,
    this.height = 152,
    this.radius = 16,
    this.duration = const Duration(milliseconds: 560),
  });

  final int index;
  final Widget child;
  final double height;
  final double radius;
  final Duration duration;

  @override
  State<HeroSlideSwitcher> createState() => _HeroSlideSwitcherState();
}

class _HeroSlideSwitcherState extends State<HeroSlideSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  Widget? _outgoing;
  Widget? _incoming;

  @override
  void initState() {
    super.initState();
    _incoming = widget.child;
    _ctrl.value = 1;
  }

  @override
  void didUpdateWidget(covariant HeroSlideSwitcher old) {
    super.didUpdateWidget(old);
    if (old.index == widget.index && old.child == widget.child) return;
    if (old.index == widget.index) {
      _incoming = widget.child;
      return;
    }
    // 减弱动态：直接换帧，不播推挤
    if (mounted && MediaQuery.disableAnimationsOf(context)) {
      _outgoing = null;
      _incoming = widget.child;
      _ctrl.value = 1;
      return;
    }
    _outgoing = _incoming;
    _incoming = widget.child;
    _ctrl.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      setState(() => _outgoing = null);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            final t = Curves.easeInOutCubic.transform(_ctrl.value);
            final w = MediaQuery.sizeOf(context).width;
            // 新：-w → 0；旧：0 → +w
            final inDx = (1 - t) * -w;
            final outDx = t * w;
            return Stack(
              fit: StackFit.expand,
              children: [
                if (_outgoing != null)
                  Transform.translate(
                    offset: Offset(outDx, 0),
                    child: Opacity(
                      opacity: (1 - t * 0.85).clamp(0.0, 1.0),
                      child: _outgoing,
                    ),
                  ),
                Transform.translate(
                  offset: Offset(inDx, 0),
                  child: Opacity(
                    opacity: t < 0.08 ? 0 : 1,
                    child: _incoming,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
