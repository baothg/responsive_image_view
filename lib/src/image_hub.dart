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
  final Future<File> future;
  final void Function() _cancel;
  void cancel() => _cancel();
}

class _Job {
  _Job(this.key, this.url, this.bucket, this.screenPx, this.refresher);
  final String key;
  final String url;
  final SizeBucket bucket;
  final Size screenPx;
  final UrlRefresher? refresher;
  final completer = Completer<File>()..future.ignore();
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
  }) : cache = cache ?? DiskCache(),
       _downloader = downloader ?? Downloader(),
       _resizer = resizer ?? const Resizer(),
       _cpu = _Gate(maxProcessing) {
    unawaited(_warmUp());
  }

  static final ImageHub instance = ImageHub();

  static const _knownCapacity = 2000;

  final DiskCache cache;
  final Downloader _downloader;
  final Resizer _resizer;
  final int maxDownloads;
  final _Gate _cpu;

  final _jobs = <String, _Job>{};
  final _queue = <_Job>[];
  final _runningKeys = <String>{};
  int _running = 0;
  final _known = <String, File>{};

  /// Cleans the disk cache and indexes surviving files so [peek] works from
  /// the first frame of a new session.
  Future<void> _warmUp() async {
    try {
      for (final f in await cache.cleanup()) {
        final name = f.uri.pathSegments.last;
        if (name.endsWith('.img')) {
          _remember(name.substring(0, name.length - 4), f);
        }
      }
    } catch (_) {}
  }

  void _remember(String id, File f) {
    _known.remove(id);
    _known[id] = f;
    if (_known.length > _knownCapacity) _known.remove(_known.keys.first);
  }

  String _id(String key, SizeBucket b) => '${key}_${b.name}';

  static String _keyOf(String url, String? cacheKey) =>
      cacheKey == null ? DiskCache.keyFor(url) : DiskCache.hash(cacheKey);

  /// Synchronous lookup of an already produced file (avoids a placeholder
  /// flash when a list item is rebuilt).
  File? peek(String url, SizeBucket bucket, {String? cacheKey}) {
    final id = _id(_keyOf(url, cacheKey), bucket);
    final f = _known[id];
    if (f == null) return null;
    if (!f.existsSync()) {
      _known.remove(id);
      return null;
    }
    return f;
  }

  /// Drops a (possibly corrupt) cached file so the next request rebuilds it.
  Future<void> invalidate(
    String url,
    SizeBucket bucket, {
    String? cacheKey,
  }) async {
    await _invalidateKey(_keyOf(url, cacheKey), bucket);
  }

  Future<void> _invalidateKey(String key, SizeBucket bucket) async {
    _known.remove(_id(key, bucket));
    await (await cache.fileFor(
      key,
      bucket,
    )).delete().catchError((_) => File(''));
  }

  ImageRequest request(
    String url,
    SizeBucket bucket,
    Size screenPx, {
    String? cacheKey,
    UrlRefresher? refresher,
  }) {
    final key = _keyOf(url, cacheKey);
    final id = _id(key, bucket);
    final job = _jobs.putIfAbsent(id, () {
      final j = _Job(key, url, bucket, screenPx, refresher);
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
          .then(job.completer.complete, onError: job.completer.completeError)
          .whenComplete(() {
            _jobs.remove(_id(job.key, job.bucket));
            _running--;
            _runningKeys.remove(job.key);
            _pump();
          });
    }
  }

  Future<File> _run(_Job job) async {
    final hit = await cache.get(job.key, job.bucket);
    if (hit != null) {
      _remember(_id(job.key, job.bucket), hit);
      return hit;
    }

    // Lazy: reuse the nearest larger cached bucket as source, else download.
    for (final b in job.bucket.sameOrLarger.skip(1)) {
      final f = await cache.get(job.key, b);
      if (f == null) continue;
      try {
        return await _process(job, f, [
          for (final x in SizeBucket.values.reversed)
            if (x.index >= job.bucket.index && x.index < b.index) x,
        ]);
      } catch (_) {
        await invalidate(
          job.url,
          b,
          cacheKey: job.key,
        ); // corrupt source: fall back to a fresh download
      }
      break;
    }

    final temp = await cache.tempFile(
      '${job.key}_${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await _downloader.download(job.url, temp, refresher: job.refresher);
      return await _process(job, temp, [
        for (final x in SizeBucket.values.reversed)
          if (x.index >= job.bucket.index) x,
      ]);
    } finally {
      await temp.delete().catchError((_) => temp);
    }
  }

  /// Produces every bucket in [steps] (largest first) directly from [source],
  /// so quality never degrades through repeated lossy re-encoding.
  Future<File> _process(_Job job, File source, List<SizeBucket> steps) async {
    final srcSize = await _resizer.dimensions(source);
    File? result;
    Size? lastTarget;
    List<int>? lastBytes;
    for (final b in steps) {
      final target = b.targetSize(srcSize, job.screenPx);
      if (target != lastTarget) {
        lastBytes = await _cpu.run(
          () => _resizer.resize(source, srcSize, target),
        );
        lastTarget = target;
      }
      result = await cache.put(job.key, b, lastBytes!);
      _remember(_id(job.key, b), result);
    }
    return result!;
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

bool isCancelled(Object e) => e is _Cancelled;
