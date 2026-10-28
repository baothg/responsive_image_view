import 'package:flutter/widgets.dart';

/// Default loading view: a base block that pulses while a bright band
/// sweeps across, so it reads as "loading" rather than an empty box.
class ResponsiveImageSkeleton extends StatefulWidget {
  const ResponsiveImageSkeleton({
    super.key,
    this.baseColor = const Color(0xFFCDCDCD),
    this.highlightColor = const Color(0xFFFFFFFF),
  });

  final Color baseColor;
  final Color highlightColor;

  @override
  State<ResponsiveImageSkeleton> createState() =>
      _ResponsiveImageSkeletonState();
}

class _ResponsiveImageSkeletonState extends State<ResponsiveImageSkeleton>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

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
    final pulse =
        0.55 + 0.35 * (t.value < 0.5 ? t.value * 2 : (1 - t.value) * 2);
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()..color = base.withAlpha((base.a * pulse).round()),
    );
    final bandW = size.width * 0.6;
    final x = -bandW + (size.width + bandW) * t.value;
    canvas.drawRect(
      Rect.fromLTWH(x, 0, bandW, size.height),
      Paint()
        ..shader = LinearGradient(
          colors: [
            highlight.withAlpha(0),
            highlight.withAlpha(140),
            highlight.withAlpha(0),
          ],
        ).createShader(Rect.fromLTWH(x, 0, bandW, size.height)),
    );
  }

  @override
  bool shouldRepaint(_SkeletonPainter old) => true;
}
