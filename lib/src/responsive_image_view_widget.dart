import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

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
    this.showOriginalImage = false,
    this.urlRefresher,
    this.cacheKey,
    this.urlResolver,
  }) : assert(
         url != '' || urlResolver == null || cacheKey != null,
         'urlResolver without a url requires cacheKey as the cache identity',
       );

  /// Variant that resolves the network url lazily — only when the disk
  /// cache misses. [urlResolver] is therefore never invoked for cached
  /// images (e.g. an S3 object key whose signed url has expired but whose
  /// content is still cached).
  const ResponsiveImageView.lazy({
    super.key,
    required this.cacheKey,
    required this.urlResolver,
    this.width,
    this.height,
    this.fit,
    this.alignment = Alignment.center,
    this.placeholder,
    this.errorBuilder,
    this.onLoaded,
    this.showOriginalImage = false,
    this.urlRefresher,
  }) : url = '';

  final String url;

  /// Resolves a url on demand; invoked only when a download is actually
  /// needed. With [cacheKey] set, cache hits never call it. When
  /// [urlRefresher] is absent it also serves as the 401/403 fallback.
  final FutureOr<String?> Function()? urlResolver;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final WidgetBuilder? placeholder;

  /// Builds the error state. Call [retry] (e.g. from a button) to reload the image.
  final Widget Function(BuildContext context, Object error, VoidCallback retry)?
  errorBuilder;

  /// Called once per (url, size) after the target image's first frame has
  /// been decoded — including when served from cache. For SVG it fires once
  /// the file has been parsed/compiled for display. Not called for the XS
  /// preview, and not again on rebuilds. Useful for e.g. deleting a local
  /// temp photo only after its uploaded network copy renders.
  final void Function(File file)? onLoaded;

  /// Called when the url is rejected for auth/expiry (401/403) to obtain a
  /// fresh one. Missing resources (404/410) never reach this callback —
  /// they surface as [ImageNotFoundException] in [errorBuilder].
  final Future<String?> Function(String expiredUrl)? urlRefresher;

  /// Downloads and displays the untouched original file instead of a
  /// resized bucket, decoded at native resolution (sharp at any zoom level
  /// — e.g. inside InteractiveViewer; memory is still bounded by
  /// [maxPixels]). Progressive display still applies: skeleton, then the
  /// best cached preview (largest bucket variant, else XS), then the
  /// original. The original is cached as a single file — no bucket variants
  /// are produced — and can serve as the resize source for later requests.
  final bool showOriginalImage;

  /// Overrides the default cache identity (url without signing query params).
  final String? cacheKey;

  /// Tunes download/resize concurrency, size limits, quality and disk cache.
  /// [maxAttempts] is the total tries per download (network/5xx retries and
  /// at most one [urlRefresher] call each).
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
    int maxAttempts = 3,
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
    maxAttempts: maxAttempts,
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
  String? _previewVariant;
  Size? _lastScreenPx;
  bool _svg = false;
  _SvgLoader? _svgLoader;
  String? _keyPrefix;
  Object? _error;
  String? _resolvedUrl;
  Future<String?>? _resolving;
  Size? _measuredSize;

  /// Preview quality rank: xs < b0 < b1 < ... — a produced variant only
  /// replaces the current preview when it is larger.
  static int _variantRank(String? v) {
    if (v == null) return -2;
    if (v == 'xs') return -1;
    return v.startsWith('b') ? (int.tryParse(v.substring(1)) ?? -2) : -2;
  }

  @override
  void didUpdateWidget(covariant ResponsiveImageView old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url ||
        old.cacheKey != widget.cacheKey ||
        old.urlResolver != widget.urlResolver ||
        old.showOriginalImage != widget.showOriginalImage) {
      _resolvedUrl = null;
      _resolving = null;
      _loadedFor = null;
      // Known-size widgets re-resolve inside the next build; for measured
      // sizes onSize only fires on size change, so re-trigger with the
      // tier/screenPx captured the last time it ran.
      final tier = _tier, px = _lastScreenPx;
      if (tier != null && px != null) _ensureLoaded(tier, px);
    }
  }

  @override
  void dispose() {
    _request?.cancel();
    unawaited(_sub?.cancel());
    super.dispose();
  }

  void _ensureLoaded(int tier, Size screenPx) {
    final source = widget.cacheKey ?? widget.url;
    final original = widget.showOriginalImage;
    final id = original ? '$source|org' : '$source|t$tier';
    if (_loadedFor == id) return;
    _loadedFor = id;
    _request?.cancel();
    _request = null;
    if (_sourceId != source) {
      _file = null;
      _preview = null;
      _previewVariant = null;
      _svg = false;
      _svgLoader = null;
      _resolvedUrl = null;
      _resolving = null;
    }
    _sourceId = source;
    _tier = tier;
    _lastScreenPx = screenPx;
    _error = null;
    final hub = ImageHub.instance;
    final cached = original
        ? hub.peekOriginal(widget.url, cacheKey: widget.cacheKey)
        : hub.peek(widget.url, tier, cacheKey: widget.cacheKey);
    if (cached != null) {
      _file = cached.file;
      _svg = cached.svg;
      return;
    }
    if (_preview == null) {
      // Largest already-cached variant (bN, else xs) as the preview.
      final pv = hub.peekBestPreview(widget.url, cacheKey: widget.cacheKey);
      _preview = pv?.file;
      _previewVariant = pv?.variant;
    }
    _keyPrefix = '${ImageHub.keyOf(widget.url, widget.cacheKey)}_';
    _sub ??= hub.events.listen((e) {
      final prefix = _keyPrefix;
      if (!mounted || _file != null || prefix == null) return;
      if (!e.$1.startsWith(prefix)) return;
      final variant = e.$1.substring(prefix.length);
      // Raster previews only (xs, bN) — never downgrade the current one.
      if (variant != 'xs' && !variant.startsWith('b')) return;
      if (_variantRank(variant) <= _variantRank(_previewVariant)) return;
      setState(() {
        _preview = e.$2;
        _previewVariant = variant;
      });
    });
    final forId = id;
    final known = widget.url.isNotEmpty ? widget.url : _resolvedUrl;
    if (known != null && known.isNotEmpty) {
      _issueRequest(hub, known, tier, screenPx, original);
    } else if (widget.urlResolver != null) {
      // Lazy: the resolver only runs on a cache miss.
      if (_resolving == null) {
        late Future<String?> fut;
        // Future.sync (not .value): a synchronously-throwing resolver must
        // surface through onError -> errorBuilder, not crash the build.
        fut = _resolving = Future<String?>.sync(() => widget.urlResolver!())
            .then((u) {
              // Ignore a resolution that finished after the url/source moved on.
              if (identical(_resolving, fut)) _resolvedUrl = u;
              return u;
            });
      }
      _resolving!.then(
        (u) {
          if (!mounted || _loadedFor != forId) return;
          if (u == null || u.isEmpty) {
            setState(
              () => _error = StateError('urlResolver produced no usable url'),
            );
            return;
          }
          _issueRequest(hub, u, tier, screenPx, original);
        },
        onError: (Object e) {
          if (mounted && _loadedFor == forId) setState(() => _error = e);
        },
      );
    } else {
      // Same behavior as before: an empty url is reported by the downloader.
      _issueRequest(hub, widget.url, tier, screenPx, original);
    }
  }

  /// Issues a hub request for [url] and wires its completion into state.
  void _issueRequest(
    ImageHub hub,
    String url,
    int tier,
    Size screenPx,
    bool original,
  ) {
    final resolver = widget.urlResolver;
    final req = _request = hub.request(
      url,
      tier,
      screenPx,
      cacheKey: widget.cacheKey,
      // The resolver doubles as the refresher: re-invoking it is exactly
      // "give me a fresh url for this identity".
      refresher:
          widget.urlRefresher ??
          (resolver == null ? null : (_) => Future<String?>.value(resolver())),
      original: original,
    );
    req.future.then(
      (r) {
        if (mounted && _request == req) {
          setState(() {
            _file = r.file;
            _svg = r.svg;
          });
        }
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
    final hub = ImageHub.instance;
    final url = widget.url, cacheKey = widget.cacheKey, svg = _svg;
    if (svg) {
      await hub.invalidateSvg(url, cacheKey: cacheKey);
    } else if (widget.showOriginalImage) {
      await hub.invalidateOrg(url, cacheKey: cacheKey);
    } else {
      await hub.invalidate(url, tier, cacheKey: cacheKey);
    }
    if (!mounted) return;
    setState(() {
      _file = null;
      _svg = false;
      _svgLoader = null;
      _error = null;
      _retriedFor = null;
      _loadedFor = null;
      // A retry should re-resolve rather than reuse a possibly stale url.
      _resolvedUrl = null;
      _resolving = null;
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
    // Capture the file's identity now — by the time the post-frame callback
    // runs, widget.url/_svg may already describe a different image.
    final forId = _loadedFor;
    final tier = _tier!;
    final url = widget.url, cacheKey = widget.cacheKey, svg = _svg;
    final original = widget.showOriginalImage;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _loadedFor != forId) return;
      final hub = ImageHub.instance;
      if (svg) {
        await hub.invalidateSvg(url, cacheKey: cacheKey);
      } else if (original) {
        await hub.invalidateOrg(url, cacheKey: cacheKey);
      } else {
        await hub.invalidate(url, tier, cacheKey: cacheKey);
      }
      if (!mounted || _loadedFor != forId) return;
      setState(() {
        _file = null;
        _svg = false;
        _svgLoader = null;
        _loadedFor = null;
      });
    });
  }

  /// Keeps finite values >= 0 and +infinity (expand-to-fill); drops NaN,
  /// -infinity and negatives which would crash SizedBox.
  static double? _layoutDim(double? v) => v == null || (v.isFinite && v >= 0)
      ? v
      : (v == double.infinity ? v : null);

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final w = _layoutDim(widget.width), h = _layoutDim(widget.height);
    // Only finite dimensions count as known for tier resolution:
    // double.infinity ("fill parent") is measured after layout instead of
    // being resolved as an infinitely large image.
    final mw = w != null && w.isFinite ? w : null;
    final mh = h != null && h.isFinite ? h : null;
    final screenPx = screen * dpr;
    // Known size: resolve right here in build (no extra frame, and a cached
    // image shows immediately). Unknown size: measure after layout.
    if (mw != null && mh != null) {
      _ensureLoaded(
        ImageHub.instance.scheme.resolve(Size(mw, mh), screen),
        screenPx,
      );
    } else {
      // Rebuilds can resolve immediately: the previous frame's render
      // object still carries its constraints. First mounts have no render
      // object yet and must wait for the post-frame measure.
      final box = context.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        final size = box.size;
        final biggest = box.constraints.biggest;
        double pick(double? known, double painted, double cap, double full) =>
            known ?? (painted > 0 ? painted : (cap.isFinite ? cap : full));
        final realW = pick(mw, size.width, biggest.width, screen.width);
        final realH = pick(mh, size.height, biggest.height, screen.height);
        _measuredSize = Size(realW, realH);
        _ensureLoaded(
          ImageHub.instance.scheme.resolve(_measuredSize!, screen),
          screenPx,
        );
      }
      // Best-effort preview on the first frame, before measurement lands:
      // show the largest cached variant instead of a bare skeleton.
      if (_preview == null) {
        final pv = ImageHub.instance.peekBestPreview(
          widget.url,
          cacheKey: widget.cacheKey,
        );
        _preview = pv?.file;
        _previewVariant = pv?.variant;
      }
    }
    return _MeasuredSize(
      enabled: mw == null || mh == null,
      onSize: (size, biggest) {
        if (!mounted) return;
        // Painted size is authoritative when non-zero; under loose
        // constraints the skeleton paints at 0x0, so fall back to the
        // offered constraint space, then to the full screen.
        double pick(double? known, double painted, double cap, double full) =>
            known ?? (painted > 0 ? painted : (cap.isFinite ? cap : full));
        final realW = pick(mw, size.width, biggest.width, screen.width);
        final realH = pick(mh, size.height, biggest.height, screen.height);
        _measuredSize = Size(realW, realH);
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
          if (_file != null && _svg) {
            final file = _file!;
            // Resolve the theme in build (dependOn* is illegal async) and
            // bake it into the loader, so our pre-load and SvgPicture's own
            // loadBytes share one SvgCacheKey.
            final theme = DefaultSvgTheme.of(context)?.theme;
            var loader = _svgLoader;
            if (loader == null || loader.theme != theme) {
              loader = _svgLoader = _SvgLoader(file, theme: theme);
            }
            // loadBytes compiles the SVG and is memoized in svg.cache by
            // loader key, so SvgPicture's own load hits the same entry:
            // this only pre-fires the completion signal for onLoaded.
            // Future() guards against loadBytes throwing synchronously
            // (Cache.putIfAbsent invokes the loader inline).
            unawaited(
              Future(() => loader!.loadBytes(null))
                  .then((_) {
                    if (mounted && _file == file && _svg) _notifyLoaded();
                  })
                  .catchError((_) {}),
            );
            return SvgPicture(
              loader,
              width: w,
              height: h,
              fit: widget.fit ?? BoxFit.contain,
              alignment: widget.alignment,
              placeholderBuilder: (ctx) =>
                  widget.placeholder?.call(ctx) ??
                  ResponsiveImageSkeleton(
                    baseColor: ImageHub.instance.skeletonBaseColor,
                    highlightColor: ImageHub.instance.skeletonHighlightColor,
                  ),
              errorBuilder: (ctx, e, st) {
                _onFileError();
                return widget.errorBuilder?.call(ctx, e, _retry) ??
                    const SizedBox.shrink();
              },
            );
          }
          if (_file != null) {
            return Image.file(
              _file!,
              width: w,
              height: h,
              fit: widget.fit,
              alignment: widget.alignment,
              // Original mode decodes at native resolution (zoom viewers);
              // bucketed images are still capped at display size for memory.
              cacheWidth: widget.showOriginalImage
                  ? null
                  : (mw ?? _measuredSize?.width ?? screen.width) * dpr > 0
                  ? ((mw ?? _measuredSize?.width ?? screen.width) * dpr).round()
                  : null,
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
              cacheWidth: (mw ?? _measuredSize?.width ?? screen.width) * dpr > 0
                  ? ((mw ?? _measuredSize?.width ?? screen.width) * dpr).round()
                  : null,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) {
                // Broken/deleted preview: drop the file it came from and
                // fall back to skeleton — post-frame, since errorBuilder
                // runs inside build.
                final pv = _previewVariant;
                final url = widget.url, cacheKey = widget.cacheKey;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  if (pv != null) {
                    unawaited(
                      ImageHub.instance.invalidateVariant(
                        url,
                        pv,
                        cacheKey: cacheKey,
                      ),
                    );
                  }
                  setState(() {
                    _preview = null;
                    _previewVariant = null;
                  });
                });
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

/// A [SvgFileLoader] whose cache identity also covers the file's content
/// (size + mtime): a re-downloaded or replaced file under the same path
/// compiles fresh instead of reusing a stale entry — flutter_svg's [Cache]
/// keeps a failed load in its pending map forever.
class _SvgLoader extends SvgFileLoader {
  _SvgLoader(super.file, {super.theme}) : _stamp = _stampOf(file);

  final int _stamp;

  static int _stampOf(File f) {
    try {
      final s = f.statSync();
      return Object.hash(s.size, s.modified.microsecondsSinceEpoch);
    } catch (_) {
      return 0;
    }
  }

  @override
  int get hashCode => Object.hash(file, theme, colorMapper, _stamp);

  @override
  bool operator ==(Object other) =>
      other is _SvgLoader &&
      other.file == file &&
      other.theme == theme &&
      other.colorMapper == colorMapper &&
      other._stamp == _stamp;
}

class _MeasuredSize extends StatefulWidget {
  const _MeasuredSize({
    required this.enabled,
    required this.onSize,
    required this.child,
  });
  final bool enabled;
  final void Function(Size painted, Size biggest) onSize;
  final Widget child;

  @override
  State<_MeasuredSize> createState() => _MeasuredSizeState();
}

class _MeasuredSizeState extends State<_MeasuredSize> {
  Size? _last;
  Size? _lastBiggest;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final size = box.size;
      final biggest = box.constraints.biggest;
      if (size != _last || biggest != _lastBiggest) {
        _last = size;
        _lastBiggest = biggest;
        widget.onSize(size, biggest);
      }
    });
    return widget.child;
  }
}
