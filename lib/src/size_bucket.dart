import 'dart:math' as math;
import 'dart:ui';

/// Size bucket based on the share of screen area a widget occupies.
enum SizeBucket {
  s(0.2),
  m(0.6),
  l(1.0);

  const SizeBucket(this.areaRatio);

  /// Max fraction of the physical screen area an image of this bucket may hold.
  final double areaRatio;

  /// Buckets that are larger than (or equal to) this one, nearest first.
  List<SizeBucket> get sameOrLarger => values.sublist(index);

  /// Bucket for a widget of [widget] logical size on a [screen] logical size.
  static SizeBucket resolve(Size widget, Size screen) {
    final ratio =
        (widget.width * widget.height) / (screen.width * screen.height);
    if (ratio < s.areaRatio) return s;
    if (ratio < m.areaRatio) return m;
    return l;
  }

  /// Target size (physical px) for an image of [source] size: keeps aspect
  /// ratio, never upscales.
  Size targetSize(Size source, Size screenPx) {
    final targetArea = areaRatio * screenPx.width * screenPx.height;
    final scale = math.sqrt(targetArea / (source.width * source.height));
    if (scale >= 1) return source;
    return Size(
      (source.width * scale).roundToDouble().clamp(1, double.infinity),
      (source.height * scale).roundToDouble().clamp(1, double.infinity),
    );
  }
}
