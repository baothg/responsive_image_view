import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'disk_cache.dart';
import 'downloader.dart';
import 'resizer.dart';
import 'size_bucket.dart';

/// Handle returned to a widget; call [cancel] on dispose.
class ImageRequest {
  ImageRequest._(this.future, this._cancel);
  final Future<({File file, bool svg})> future;
  final void Function() _cancel;
  void cancel() => _cancel();
}

class _Job {
  _Job(
    this.key,
    this.url,
    this.tier,
    this.screenPx,
    this.refresher,
    this.original,
  ) : variant = original ? 'org' : 'b$tier';
  final String key;
  final String url;
  final int tier;
  final Size screenPx;
  final UrlRefresher? refresher;

  /// Fetches the untouched original file instead of a resized bucket.
  final bool original;

  /// Cache variant this job produces ('org' or `bN`).
  final String variant;
  final completer = Completer<({File file, bool svg})>()..future.ignore();
  int listeners = 0;
  bool started = false;
}

/// Limits concurrent async work; waiters are served newest first.
class _Gate {
  _Gate(this.limit);
  final int limit;
  int _active = 0;
  final _waiters = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() fn) async {
    if (_active >= limit) {
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    } else {
      _active++;
    }
    try {
      return await fn();
    } finally {
      if (_waiters.isNotEmpty) {
        _waiters.removeLast().complete();
      } else {
        _active--;
      }
    }
  }
}

/// Coordinates all image work: dedupes identical requests, admits at most
/// [maxDownloads] jobs at once (newest first, so images currently on screen
/// win over ones scrolled past) and runs at most [maxProcessing] CPU-heavy
/// resize/encode steps at a time.
class ImageHub {
  ImageHub({
    DiskCache? cache,
    Downloader? downloader,
    Resizer? resizer,
    this.maxDownloads = 6,
    int maxProcessing = 2,
    this.maxPixels = 100 * 1000 * 1000,
    this.skeletonBaseColor = const Color(0xFFBDBDBD),
    this.skeletonHighlightColor = const Color(0xFFFAFAFA),
    BucketScheme? scheme,
  }) : cache = cache ?? DiskCache(),
       _downloader = downloader ?? Downloader(),
       _resizer = resizer ?? const Resizer(),
       _cpu = _Gate(maxProcessing),
       scheme = scheme ?? BucketScheme() {
    unawaited(_warmUp());
  }

  /// The shared hub used by [ResponsiveImageView]. Defaults to sensible
  /// limits; replace via [configure] *before the first image request*.
  static ImageHub instance = ImageHub();

  /// Replaces [instance] with custom limits. Throws if images were already
  /// requested, since tuning mid-flight would split state between hubs.
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
  }) {
    if (instance._used) {
      throw StateError(
        'ImageHub.configure() must run before any ResponsiveImageView is built',
      );
    }
    instance = ImageHub(
      cache: DiskCache(maxAge: cacheMaxAge, maxBytes: cacheMaxBytes),
      downloader: Downloader(
        maxBytes: maxDownloadBytes,
        maxAttempts: maxAttempts,
      ),
      resizer: Resizer(quality: quality),
      maxDownloads: maxDownloads,
      maxProcessing: maxProcessing,
      maxPixels: maxPixels,
      scheme: BucketScheme(bucketThresholds),
      skeletonBaseColor: skeletonBaseColor,
      skeletonHighlightColor: skeletonHighlightColor,
    );
  }

  static const _knownCapacity = 2000;

  /// A failed image is not retried automatically for this long (scrolling
  /// back to it would otherwise re-download and fail again). `invalidate`
  /// (used by the widget's retry) clears it.
  static const failureTtl = Duration(seconds: 60);

  final DiskCache cache;
  final Downloader _downloader;
  final Resizer _resizer;
  final int maxDownloads;
  final int maxPixels;
  final BucketScheme scheme;
  final Color skeletonBaseColor;
  final Color skeletonHighlightColor;
  final _Gate _cpu;

  final _jobs = <String, _Job>{};
  final _queue = <_Job>[];
  final _runningKeys = <String>{};
  int _running = 0;
  bool _used = false;
  final _known = <String, (File, bool)>{};
  final _failures = <String, (DateTime, Object)>{};
  final _events = StreamController<(String, File)>.broadcast();

  /// Emits (cache id, file) for every bucket produced, smallest first, so
  /// widgets can show previews while the target bucket is still processing.
  Stream<(String, File)> get events => _events.stream;

  /// Cleans the disk cache and indexes surviving files so [peek] works from
  /// the first frame of a new session.
  Future<void> _warmUp() async {
    try {
      for (final f in await cache.cleanup()) {
        final name = f.uri.pathSegments.last;
        if (name.endsWith('.img')) {
          final id = name.substring(0, name.length - 4);
          _remember(id, f, svg: id.endsWith('_svg'));
        }
      }
    } catch (_) {}
  }

  void _remember(String id, File f, {bool svg = false}) {
    _known.remove(id);
    _known[id] = (f, svg);
    if (_known.length > _knownCapacity) _known.remove(_known.keys.first);
    _events.add((id, f));
  }

  static String keyOf(String url, String? cacheKey) =>
      cacheKey == null ? DiskCache.keyFor(url) : DiskCache.hash(cacheKey);

  static String _id(String key, String variant) => '${key}_$variant';

  /// Synchronous lookup of an already produced file (avoids a placeholder
  /// flash when a list item is rebuilt). The index is authoritative: the hub
  /// owns every write/delete, and decode errors self-heal via the widget.
  ({File file, bool svg})? peek(String url, int tier, {String? cacheKey}) {
    final key = keyOf(url, cacheKey);
    final hit = _known[_id(key, 'svg')] ?? _known[_id(key, 'b$tier')];
    return hit == null ? null : (file: hit.$1, svg: hit.$2);
  }

  /// The cached XS preview file, if any.
  File? peekXs(String url, {String? cacheKey}) =>
      _known[_id(keyOf(url, cacheKey), 'xs')]?.$1;

  /// The best already-cached preview for progressive display: the largest
  /// available bucket variant, else the XS preview.
  ({File file, String variant})? peekBestPreview(
    String url, {
    String? cacheKey,
  }) {
    final key = keyOf(url, cacheKey);
    for (var i = scheme.count - 1; i >= 0; i--) {
      final f = _known[_id(key, 'b$i')];
      if (f != null) return (file: f.$1, variant: 'b$i');
    }
    final xs = _known[_id(key, 'xs')];
    return xs == null ? null : (file: xs.$1, variant: 'xs');
  }

  /// The cached untouched original (or SVG, which is inherently original).
  ({File file, bool svg})? peekOriginal(String url, {String? cacheKey}) {
    final key = keyOf(url, cacheKey);
    final hit = _known[_id(key, 'svg')] ?? _known[_id(key, 'org')];
    return hit == null ? null : (file: hit.$1, svg: hit.$2);
  }

  /// Drops a (possibly corrupt) cached file so the next request rebuilds it.
  Future<void> invalidate(String url, int tier, {String? cacheKey}) async {
    await _invalidateVariant(keyOf(url, cacheKey), 'b$tier');
  }

  /// Drops the cached XS preview file.
  Future<void> invalidateXs(String url, {String? cacheKey}) =>
      invalidateVariant(url, 'xs', cacheKey: cacheKey);

  /// Drops the cached SVG file.
  Future<void> invalidateSvg(String url, {String? cacheKey}) =>
      invalidateVariant(url, 'svg', cacheKey: cacheKey);

  /// Drops the cached original file.
  Future<void> invalidateOrg(String url, {String? cacheKey}) =>
      invalidateVariant(url, 'org', cacheKey: cacheKey);

  /// Drops the cached file for an arbitrary [variant]
  /// ('xs', 'svg', 'org', 'b0'...).
  Future<void> invalidateVariant(
    String url,
    String variant, {
    String? cacheKey,
  }) async {
    await _invalidateVariant(keyOf(url, cacheKey), variant);
  }

  Future<void> _invalidateVariant(String key, String variant) async {
    final id = _id(key, variant);
    _known.remove(id);
    _failures.remove(id);
    await (await cache.fileFor(
      key,
      variant,
    )).delete().catchError((_) => File(''));
  }

  ImageRequest request(
    String url,
    int tier,
    Size screenPx, {
    String? cacheKey,
    UrlRefresher? refresher,
    bool original = false,
  }) {
    final key = keyOf(url, cacheKey);
    final id = _id(key, original ? 'org' : 'b$tier');
    final failed = _failures[id];
    if (failed != null) {
      if (DateTime.now().difference(failed.$1) < failureTtl) {
        return ImageRequest._(
          Future<({File file, bool svg})>.error(failed.$2)..ignore(),
          () {},
        );
      }
      _failures.remove(id);
    }
    _used = true;
    final job = _jobs.putIfAbsent(id, () {
      final j = _Job(key, url, tier, screenPx, refresher, original);
      _queue.add(j);
      scheduleMicrotask(_pump);
      return j;
    });
    job.listeners++;
    var cancelled = false;
    return ImageRequest._(job.completer.future, () {
      if (cancelled) return;
      cancelled = true;
      if (--job.listeners == 0 && !job.started) {
        _queue.remove(job);
        _jobs.remove(id);
        job.completer.completeError(const _Cancelled());
      }
    });
  }

  void _pump() {
    while (_running < maxDownloads) {
      // Newest first, but never run two jobs for the same image at once: the
      // later one reuses the files the first one writes instead of downloading again.
      final i = _queue.lastIndexWhere((j) => !_runningKeys.contains(j.key));
      if (i < 0) return;
      final job = _queue.removeAt(i);
      job.started = true;
      _running++;
      _runningKeys.add(job.key);
      _run(job)
          .then(
            job.completer.complete,
            onError: (Object e, StackTrace st) {
              if (_failures.length > 200) {
                _failures.remove(_failures.keys.first);
              }
              _failures[_id(job.key, job.variant)] = (DateTime.now(), e);
              job.completer.completeError(e, st);
            },
          )
          .whenComplete(() {
            _jobs.remove(_id(job.key, job.variant));
            _running--;
            _runningKeys.remove(job.key);
            _pump();
          });
    }
  }

  Future<({File file, bool svg})> _run(_Job job) async {
    final svgHit = await cache.get(job.key, 'svg');
    if (svgHit != null) {
      _remember(_id(job.key, 'svg'), svgHit, svg: true);
      return (file: svgHit, svg: true);
    }
    if (job.original) {
      final orgHit = await cache.get(job.key, 'org');
      if (orgHit != null) {
        _remember(_id(job.key, 'org'), orgHit);
        return (file: orgHit, svg: false);
      }
    } else {
      final hit = await cache.get(job.key, job.variant);
      if (hit != null) {
        _remember(_id(job.key, job.variant), hit);
        return (file: hit, svg: false);
      }

      // The cached original is the highest-fidelity resize source.
      final org = await cache.get(job.key, 'org');
      if (org != null) {
        try {
          return (
            file: await _process(job, org, [
              for (var x = scheme.count - 1; x >= job.tier; x--) 'b$x',
            ]),
            svg: false,
          );
        } catch (_) {
          await _invalidateVariant(job.key, 'org');
        }
      }

      // Lazy: reuse the *nearest* larger cached tier as source, else download.
      for (var i = job.tier + 1; i < scheme.count; i++) {
        final v = 'b$i';
        final f = await cache.get(job.key, v);
        if (f == null) continue;
        try {
          return (
            file: await _process(job, f, [
              for (var x = i - 1; x >= job.tier; x--) 'b$x',
            ]),
            svg: false,
          );
        } catch (_) {
          await _invalidateVariant(
            job.key,
            v,
          ); // corrupt source: fall back to a fresh download
        }
        break;
      }
    }

    // Retry once when the download decoded as corrupt (e.g. a truncated
    // transfer that closed cleanly).
    for (var attempt = 0; attempt < 2; attempt++) {
      final temp = await cache.tempFile(
        '${job.key}_${DateTime.now().microsecondsSinceEpoch}',
      );
      try {
        await _downloader.download(job.url, temp, refresher: job.refresher);
        if (await _looksSvg(temp)) {
          final f = await cache.adopt(job.key, 'svg', temp);
          _remember(_id(job.key, 'svg'), f, svg: true);
          return (file: f, svg: true);
        }
        if (job.original) {
          return (file: await _adoptOriginal(job, temp), svg: false);
        }
        return (
          file: await _process(job, temp, [
            for (var x = scheme.count - 1; x >= job.tier; x--) 'b$x',
          ]),
          svg: false,
        );
      } on CorruptImageException {
        if (attempt == 1) rethrow;
      } finally {
        await temp.delete().catchError((_) => temp);
      }
    }
    throw StateError('unreachable');
  }

  /// Validates [temp] as a displayable raster source, stores it as the
  /// cached untouched original and produces the XS preview for progressive
  /// display. No bucket variants are produced on this path.
  Future<File> _adoptOriginal(_Job job, File temp) async {
    final srcSize = await _resizer.dimensions(temp);
    if (srcSize.width < 4 || srcSize.height < 4) {
      throw CorruptImageException(
        'implausibly small source ${srcSize.width.round()}x${srcSize.height.round()}',
      );
    }
    if (srcSize.width * srcSize.height > maxPixels) {
      throw ImageTooLargeException(
        '${srcSize.width.round()}x${srcSize.height.round()} exceeds $maxPixels pixels',
      );
    }
    final f = await cache.adopt(job.key, 'org', temp);
    _remember(_id(job.key, 'org'), f);
    // The preview is progressive-only: it must never sink the original.
    try {
      await _ensureXs(job, f, srcSize);
    } catch (_) {}
    return f;
  }

  /// Produces the XS preview variant if it does not exist yet and emits it
  /// to listeners. Shared by the bucket pipeline and the original path.
  Future<void> _ensureXs(_Job job, File source, Size srcSize) async {
    if (await cache.get(job.key, 'xs') != null) return;
    final f = await cache.put(
      job.key,
      'xs',
      await _cpu.run(
        () => _resizer.resize(
          source,
          srcSize,
          xsTier.targetSize(srcSize, job.screenPx),
        ),
      ),
    );
    _remember(_id(job.key, 'xs'), f);
  }

  /// Produces every variant in [steps] (largest first) directly from [source],
  /// so quality never degrades through repeated lossy re-encoding. The XS
  /// preview is encoded first so it reaches listeners as early as possible.
  Future<File> _process(_Job job, File source, List<String> steps) async {
    final srcSize = await _resizer.dimensions(source);
    if (srcSize.width < 4 || srcSize.height < 4) {
      // A download that decodes to a handful of pixels (truncated transfer or
      // a CDN mitigation pixel) is corrupt for our purposes — retry/fail
      // rather than caching a stretched flat color for a month.
      throw CorruptImageException(
        'implausibly small source ${srcSize.width.round()}x${srcSize.height.round()}',
      );
    }
    if (srcSize.width * srcSize.height > maxPixels) {
      throw ImageTooLargeException(
        '${srcSize.width.round()}x${srcSize.height.round()} exceeds $maxPixels pixels',
      );
    }
    await _ensureXs(job, source, srcSize);
    File? result;
    Size? lastTarget;
    List<int>? lastBytes;
    for (final v in steps) {
      final tier = int.parse(v.substring(1));
      final target = scheme[tier].targetSize(srcSize, job.screenPx);
      if (target != lastTarget) {
        lastBytes = await _cpu.run(
          () => _resizer.resize(source, srcSize, target),
        );
        lastTarget = target;
      }
      result = await cache.put(job.key, v, lastBytes!);
      _remember(_id(job.key, v), result);
    }
    return result!;
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

bool isCancelled(Object e) => e is _Cancelled;

/// Sniffs the first 512 bytes of [f]: content containing an `<svg>` tag —
/// after rejecting known raster magic bytes — bypasses the raster pipeline
/// and is cached/rendered as a vector instead.
Future<bool> _looksSvg(File f) async {
  try {
    final raf = await f.open();
    try {
      final head = await raf.read(512);
      if (head.length < 4) return false;
      // Reject known raster magics first.
      const magics = [
        [0xFF, 0xD8], // jpeg
        [0x89, 0x50], // png
        [0x47, 0x49], // gif
        [0x52, 0x49], // riff/webp
        [0x42, 0x4D], // bmp
      ];
      for (final m in magics) {
        if (head[0] == m[0] && head[1] == m[1]) return false;
      }
      final text = String.fromCharCodes(head);
      return RegExp(r'<svg[\s/>]').hasMatch(text);
    } finally {
      await raf.close();
    }
  } catch (_) {
    return false;
  }
}
