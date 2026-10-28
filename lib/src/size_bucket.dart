import 'dart:math' as math;
import 'dart:ui';

/// Fixed preview bucket: always produced first, ~5% of screen area.
/// Never a display target.
const xsTier = SizeTier(0.05);

/// A display size tier: an image of this tier occupies at most [areaRatio]
/// of the physical screen area.
class SizeTier {
  const SizeTier(this.areaRatio);
  final double areaRatio;

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

/// The set of display tiers, 2-4 thresholds ascending. The last entry is the
/// "everything larger" tier and also its target ratio (usually 1.0).
/// Default [0.2, 0.6, 1.0] = S < 20%, M < 60%, L >= 60% of screen area.
class BucketScheme {
  BucketScheme([this.ratios = const [0.2, 0.6, 1.0]]) {
    // Real checks (not assert): invalid schemes must fail in release too.
    if (ratios.length < 2 || ratios.length > 4) {
      throw ArgumentError.value(
        ratios,
        'bucketThresholds',
        'use 2-4 thresholds',
      );
    }
    for (var i = 1; i < ratios.length; i++) {
      if (ratios[i] <= ratios[i - 1]) {
        throw ArgumentError.value(
          ratios,
          'bucketThresholds',
          'must be strictly ascending',
        );
      }
    }
  }

  final List<double> ratios;
  int get count => ratios.length;

  /// Index of the tier for a widget of [widget] size on a [screen] size
  /// (both logical px): the first tier whose ratio exceeds the share of
  /// screen area the widget occupies.
  int resolve(Size widget, Size screen) {
    final ratio =
        (widget.width * widget.height) / (screen.width * screen.height);
    for (var i = 0; i < ratios.length; i++) {
      if (ratio < ratios[i]) return i;
    }
    return ratios.length - 1;
  }

  SizeTier operator [](int i) => SizeTier(ratios[i]);
}
