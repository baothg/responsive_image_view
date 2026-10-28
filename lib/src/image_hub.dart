import 'dart:async';
import 'dart:collection';
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
  final completer = Completer<File>();
  int listeners = 0;
  bool started = false;
}

/// Coordinates all image work: dedupes identical requests, runs at most
/// [maxConcurrent] pipelines at once, newest request first (LIFO, so images
/// currently on screen win over ones scrolled past).
class ImageHub {
  ImageHub({
    DiskCache? cache,
    Downloader? downloader,
    Resizer? resizer,
    this.maxConcurrent = 3,
  })  : cache = cache ?? DiskCache(),
        _downloader = downloader ?? Downloader(),
        _resizer = resizer ?? const Resizer() {
    unawaited(this.cache.cleanup().catchError((_) {}));
  }

  static final ImageHub instance = ImageHub();

  final DiskCache cache;
  final Downloader _downloader;
  final Resizer _resizer;
  final int maxConcurrent;

  final _jobs = <String, _Job>{};
  final _queue = ListQueue<_Job>();
  int _running = 0;

  ImageRequest request(String url, SizeBucket bucket, Size screenPx, {String? cacheKey, UrlRefresher? refresher}) {
    final key = cacheKey ?? DiskCache.keyFor(url);
    final id = '${key}_${bucket.name}';
    final job = _jobs.putIfAbsent(id, () {
      final j = _Job(key, url, bucket, screenPx, refresher);
      _queue.addLast(j);
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
        job.completer.future.ignore();
        job.completer.completeError(const _Cancelled());
      }
    });
  }

  void _pump() {
    while (_running < maxConcurrent && _queue.isNotEmpty) {
      final job = _queue.removeLast();
      job.started = true;
      _running++;
      _run(job).then(job.completer.complete, onError: job.completer.completeError).whenComplete(() {
        _jobs.remove('${job.key}_${job.bucket.name}');
        _running--;
        _pump();
      });
    }
  }

  Future<File> _run(_Job job) async {
    final hit = await cache.get(job.key, job.bucket);
    if (hit != null) return hit;

    // Lazy: reuse the nearest larger cached bucket as source, else download.
    File? source;
    var from = SizeBucket.l;
    for (final b in job.bucket.sameOrLarger.skip(1)) {
      final f = await cache.get(job.key, b);
      if (f != null) {
        source = f;
        from = b;
        break;
      }
    }
    File? temp;
    if (source == null) {
      temp = await cache.tempFile('${job.key}_${DateTime.now().microsecondsSinceEpoch}');
      await _downloader.download(job.url, temp, refresher: job.refresher);
      source = temp;
    }
    try {
      // Chain L -> M -> S, each step from the previous output.
      final steps = <SizeBucket>[
        for (final b in SizeBucket.values.reversed)
          if (b.index >= job.bucket.index && (temp != null || b.index < from.index)) b
      ];
      var srcSize = await _resizer.dimensions(source);
      File? result;
      for (final b in steps) {
        final target = b.targetSize(srcSize, job.screenPx);
        final bytes = result != null && target == srcSize
            ? await source!.readAsBytes()
            : await _resizer.resize(source!, srcSize, target);
        result = await cache.put(job.key, b, bytes);
        source = result;
        srcSize = target;
      }
      return result!;
    } finally {
      if (temp != null) await temp.delete().catchError((_) => temp!);
    }
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

bool isCancelled(Object e) => e is _Cancelled;
