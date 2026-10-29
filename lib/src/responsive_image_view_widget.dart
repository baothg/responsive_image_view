import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'image_hub.dart';
import 'skeleton.dart';

/// Network image that is downloaded once, downscaled to a size bucket
/// (S/M/L, by screen area share) and cached on disk.
class ResponsiveImageView extends StatefulWidget {
  const ResponsiveImageView(
    this.url, {
    super.key,
    this.width,
    this.height,
    this.fit,
    this.alignment = Alignment.center,
    this.placeholder,
    this.errorBuilder,
    this.onLoaded,
    this.urlRefresher,
    this.cacheKey,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final WidgetBuilder? placeholder;

  /// Builds the error state. Call [retry] (e.g. from a button) to reload the image.
  final Widget Function(BuildContext context, Object error, VoidCallback retry)?
  errorBuilder;

  /// Called once per (url, size) after the target image's first frame has
  /// been decoded — including when served from cache. Not called for the
  /// XS preview, and not again on rebuilds. Useful for e.g. deleting a
  /// local temp photo only after its uploaded network copy renders.
  final void Function(File file)? onLoaded;

  /// Called when the url looks expired (401/403/404/410) to obtain a fresh one.
  final Future<String?> Function(String expiredUrl)? urlRefresher;

  /// Overrides the default cache identity (url without signing query params).
  final String? cacheKey;

  /// Tunes download/resize concurrency, size limits, quality and disk cache.
  /// Must be called before the first [ResponsiveImageView] is built.
  /// [skeletonBaseColor]/[skeletonHighlightColor] style the default skeleton
  /// (per-widget override via [placeholder]).
  /// [bucketThresholds] sets the display tiers: 2-4 ascending ratios of
  /// screen area; the last is the "everything larger" tier (usually 1.0).
  /// The XS preview tier is fixed at 5% and is always produced first.
  static void configure({
    int maxDownloads = 6,
    int maxProcessing = 2,
    int maxDownloadBytes = 30 * 1024 * 1024,
    int maxPixels = 100 * 1000 * 1000,
    int quality = 80,
    Duration cacheMaxAge = const Duration(days: 30),
    int cacheMaxBytes = 300 * 1024 * 1024,
    List<double> bucketThresholds = const [0.2, 0.6, 1.0],
    Color skeletonBaseColor = const Color(0xFFBDBDBD),
    Color skeletonHighlightColor = const Color(0xFFFAFAFA),
  }) => ImageHub.configure(
    maxDownloads: maxDownloads,
    maxProcessing: maxProcessing,
    maxDownloadBytes: maxDownloadBytes,
    maxPixels: maxPixels,
    quality: quality,
    cacheMaxAge: cacheMaxAge,
    cacheMaxBytes: cacheMaxBytes,
    bucketThresholds: bucketThresholds,
    skeletonBaseColor: skeletonBaseColor,
    skeletonHighlightColor: skeletonHighlightColor,
  );

  @override
  State<ResponsiveImageView> createState() => _ResponsiveImageViewState();
}

class _ResponsiveImageViewState extends State<ResponsiveImageView> {
  ImageRequest? _request;
  StreamSubscription<(String, File)>? _sub;
  String? _sourceId;
  int? _tier;
  String? _retriedFor;
  String? _loadedFor;
  File? _file;
  File? _preview;
  String? _xsId;
  Object? _error;

  @override
  void dispose() {
    _request?.cancel();
    unawaited(_sub?.cancel());
    super.dispose();
  }

  void _ensureLoaded(int tier, Size screenPx) {
    final source = widget.cacheKey ?? widget.url;
    final id = '$source|t$tier';
    if (_loadedFor == id) return;
    _loadedFor = id;
    _request?.cancel();
    _request = null;
    if (_sourceId != source) {
      _file = null;
      _preview = null;
    }
    _sourceId = source;
    _tier = tier;
    _error = null;
    final hub = ImageHub.instance;
    final cached = hub.peek(widget.url, tier, cacheKey: widget.cacheKey);
    if (cached != null) {
      _file = cached;
      return;
    }
    _preview ??= hub.peekXs(widget.url, cacheKey: widget.cacheKey);
    _xsId = '${ImageHub.keyOf(widget.url, widget.cacheKey)}_xs';
    _sub ??= hub.events.listen((e) {
      if (mounted && _file == null && e.$1 == _xsId) {
        setState(() => _preview = e.$2);
      }
    });
    final req = _request = ImageHub.instance.request(
      widget.url,
      tier,
      screenPx,
      cacheKey: widget.cacheKey,
      refresher: widget.urlRefresher,
    );
    req.future.then(
      (f) {
        if (mounted && _request == req) setState(() => _file = f);
      },
      onError: (Object e) {
        if (mounted && _request == req && !isCancelled(e)) {
          setState(() => _error = e);
        }
      },
    );
  }

  Future<void> _retry() async {
    final tier = _tier;
    if (!mounted || tier == null) return;
    await ImageHub.instance.invalidate(
      widget.url,
      tier,
      cacheKey: widget.cacheKey,
    );
    if (!mounted) return;
    setState(() {
      _file = null;
      _error = null;
      _retriedFor = null;
      _loadedFor = null;
    });
  }

  String? _notifiedFor;

  void _notifyLoaded() {
    final f = _file;
    if (f == null || _notifiedFor == _loadedFor) return;
    _notifiedFor = _loadedFor;
    // ignore: avoid_print
    final cb = widget.onLoaded;
    if (cb == null) return;
    scheduleMicrotask(() {
      if (mounted && _file == f) cb(f);
    });
  }

  void _onFileError() {
    if (_retriedFor == _loadedFor) return;
    _retriedFor = _loadedFor;
    final tier = _tier!;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ImageHub.instance.invalidate(
        widget.url,
        tier,
        cacheKey: widget.cacheKey,
      );
      if (!mounted) return;
      setState(() {
        _file = null;
        _loadedFor = null;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final w = widget.width, h = widget.height;
    final screenPx = screen * dpr;
    // Known size: resolve right here in build (no extra frame, and a cached
    // image shows immediately). Unknown size: measure after layout.
    if (w != null && h != null) {
      _ensureLoaded(
        ImageHub.instance.scheme.resolve(Size(w, h), screen),
        screenPx,
      );
    }
    return _MeasuredSize(
      enabled: w == null || h == null,
      onSize: (size) {
        if (!mounted) return;
        final realW = w ?? (size.width > 0 ? size.width : screen.width);
        final realH = h ?? (size.height > 0 ? size.height : screen.height);
        // Runs outside build, so state changes must trigger a rebuild.
        setState(
          () => _ensureLoaded(
            ImageHub.instance.scheme.resolve(Size(realW, realH), screen),
            screenPx,
          ),
        );
      },
      child: SizedBox(
        width: w,
        height: h,
        child: () {
          if (_file != null) {
            return Image.file(
              _file!,
              width: w,
              height: h,
              fit: widget.fit,
              alignment: widget.alignment,
              cacheWidth: ((w ?? screen.width) * dpr).round(),
              gaplessPlayback: true,
              frameBuilder: (ctx, child, frame, _) {
                // ignore: avoid_print
                if (frame != null) _notifyLoaded();
                return child;
              },
              errorBuilder: (ctx, e, _) {
                _onFileError();
                return widget.errorBuilder?.call(ctx, e, _retry) ??
                    const SizedBox.shrink();
              },
            );
          }
          if (_error != null && widget.errorBuilder != null) {
            return widget.errorBuilder!(context, _error!, _retry);
          }
          if (_preview != null) {
            return Image.file(
              _preview!,
              width: w,
              height: h,
              fit: widget.fit,
              alignment: widget.alignment,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) {
                // Broken/deleted preview: drop it and fall back to skeleton.
                unawaited(
                  ImageHub.instance.invalidateXs(
                    widget.url,
                    cacheKey: widget.cacheKey,
                  ),
                );
                if (mounted) setState(() => _preview = null);
                return const SizedBox.shrink();
              },
            );
          }
          return widget.placeholder?.call(context) ??
              ResponsiveImageSkeleton(
                baseColor: ImageHub.instance.skeletonBaseColor,
                highlightColor: ImageHub.instance.skeletonHighlightColor,
              );
        }(),
      ),
    );
  }
}

class _MeasuredSize extends StatefulWidget {
  const _MeasuredSize({
    required this.enabled,
    required this.onSize,
    required this.child,
  });
  final bool enabled;
  final ValueChanged<Size> onSize;
  final Widget child;

  @override
  State<_MeasuredSize> createState() => _MeasuredSizeState();
}

class _MeasuredSizeState extends State<_MeasuredSize> {
  Size? _last;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = context.findRenderObject();
      final size = box is RenderBox && box.hasSize ? box.size : null;
      if (size != null && size != _last) {
        _last = size;
        widget.onSize(size);
      }
    });
    return widget.child;
  }
}
