import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Standalone vsync for the shared shimmer driver — a skeleton's own
/// SingleTickerProvider is not needed when the controller is shared.
class _SharedTicker extends TickerProvider {
  const _SharedTicker();

  @override
  Ticker createTicker(TickerCallback onTick) => Ticker(onTick);
}

/// One ticker for every default-period skeleton instead of one
/// AnimationController per widget — dozens of visible skeletons in a list
/// would otherwise keep a ticker each. Created lazily on first use and
/// disposed when the last skeleton detaches; all users share the same
/// sweep phase, like a single `shimmer` ancestor.
class _SharedShimmer {
  _SharedShimmer._();

  static AnimationController? _controller;
  static int _users = 0;

  static Animation<double> acquire(Duration period) {
    _users++;
    return _controller ??= AnimationController(
        vsync: const _SharedTicker(),
        duration: period,
      )
      ..repeat();
  }

  static void release() {
    if (_users > 0 && --_users == 0) {
      _controller?.dispose();
      _controller = null;
    }
  }
}

/// Default loading view: a `shimmer`-style gradient sweep
/// (base -> highlight -> base sliding diagonally), so it reads as "loading"
/// rather than an empty box.
class ResponsiveImageSkeleton extends StatefulWidget {
  const ResponsiveImageSkeleton({
    super.key,
    this.baseColor = const Color(0xFFBDBDBD),
    this.highlightColor = const Color(0xFFFAFAFA),
    this.period = defaultPeriod,
  });

  /// Skeletons using this period share a single animation ticker.
  static const defaultPeriod = Duration(milliseconds: 1500);

  final Color baseColor;
  final Color highlightColor;
  final Duration period;

  @override
  State<ResponsiveImageSkeleton> createState() =>
      _ResponsiveImageSkeletonState();
}

class _ResponsiveImageSkeletonState extends State<ResponsiveImageSkeleton>
    with SingleTickerProviderStateMixin {
  Animation<double> _t = const AlwaysStoppedAnimation<double>(0);
  AnimationController? _own;
  bool _shared = false;

  @override
  void initState() {
    super.initState();
    _attach(widget.period);
  }

  void _attach(Duration period) {
    if (period == ResponsiveImageSkeleton.defaultPeriod) {
      _shared = true;
      _t = _SharedShimmer.acquire(period);
    } else {
      _shared = false;
      _own = AnimationController(vsync: this, duration: period)..repeat();
      _t = _own!;
    }
  }

  void _detach() {
    if (_shared) {
      _SharedShimmer.release();
      _shared = false;
    } else {
      _own?.dispose();
      _own = null;
    }
  }

  @override
  void didUpdateWidget(covariant ResponsiveImageSkeleton old) {
    super.didUpdateWidget(old);
    if (old.period != widget.period) {
      _detach();
      _attach(widget.period);
    }
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // size stays finite even under unbounded/intrinsic parents (which hand
    // out infinite constraints); a tight parent overrides it anyway.
    return CustomPaint(
      size: Size.zero,
      // Repaints every tick — keep it in its own layer so it does not
      // invalidate neighboring paint work.
      willChange: true,
      painter: _SkeletonPainter(_t, widget.baseColor, widget.highlightColor),
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
