import 'package:flutter/widgets.dart';

/// Default loading view: a `shimmer`-style gradient sweep
/// (base -> highlight -> base sliding diagonally), so it reads as "loading"
/// rather than an empty box.
class ResponsiveImageSkeleton extends StatefulWidget {
  const ResponsiveImageSkeleton({
    super.key,
    this.baseColor = const Color(0xFFBDBDBD),
    this.highlightColor = const Color(0xFFFAFAFA),
    this.period = const Duration(milliseconds: 1500),
  });

  final Color baseColor;
  final Color highlightColor;
  final Duration period;

  @override
  State<ResponsiveImageSkeleton> createState() =>
      _ResponsiveImageSkeletonState();
}

class _ResponsiveImageSkeletonState extends State<ResponsiveImageSkeleton>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: widget.period)
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // size stays finite even under unbounded/intrinsic parents (which hand
    // out infinite constraints); a tight parent overrides it anyway.
    return CustomPaint(
      size: Size.zero,
      painter: _SkeletonPainter(_c, widget.baseColor, widget.highlightColor),
    );
  }
}

class _SkeletonPainter extends CustomPainter {
  _SkeletonPainter(this.t, this.base, this.highlight) : super(repaint: t);
  final Animation<double> t;
  final Color base;
  final Color highlight;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // Same as the `shimmer` package: a slightly diagonal base->highlight->base
    // gradient slid horizontally; edges clamp to base color so only the
    // highlight peak sweeps visibly.
    final dx = size.width * (2 * t.value - 1);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: const Alignment(-1.0, -0.3),
          end: const Alignment(1.0, 0.3),
          colors: [base, highlight, base],
          stops: const [0.35, 0.5, 0.65],
        ).createShader(Rect.fromLTWH(dx, 0, size.width, size.height)),
    );
  }

  @override
  bool shouldRepaint(_SkeletonPainter old) =>
      old.t != t || old.base != base || old.highlight != highlight;
}
