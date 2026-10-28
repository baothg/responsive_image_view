import 'dart:async';
import 'dart:io';

typedef UrlRefresher = Future<String?> Function(String expiredUrl);

class DownloadException implements Exception {
  DownloadException(this.message, [this.statusCode]);
  final String message;
  final int? statusCode;
  @override
  String toString() => 'DownloadException($statusCode): $message';
}

/// The image exceeds the configured byte or pixel limit. Never retried.
class ImageTooLargeException implements Exception {
  ImageTooLargeException(this.message);
  final String message;
  @override
  String toString() => 'ImageTooLargeException: $message';
}

/// Streams a url to [target]. Retries network/5xx errors with backoff; for
/// expired-link statuses (401/403/404/410) asks [refresher] for a fresh url.
class Downloader {
  Downloader({
    HttpClient? client,
    this.maxAttempts = 3,
    this.maxBytes = 30 * 1024 * 1024,
    this.perDownloadTimeout = const Duration(seconds: 60),
    this.retryDelay = const Duration(milliseconds: 500),
  }) : _client = (client ?? HttpClient())
         ..connectionTimeout = const Duration(seconds: 15);

  final HttpClient _client;
  final int maxAttempts;
  final int maxBytes;

  /// Hard deadline per download attempt — a stalled/slow-drip connection can
  /// otherwise hold a hub slot forever and starve every queued image.
  final Duration perDownloadTimeout;
  final Duration retryDelay;

  static bool _expired(int s) => s == 401 || s == 403 || s == 404 || s == 410;

  Future<void> download(
    String url,
    File target, {
    UrlRefresher? refresher,
  }) async {
    Object? last;
    var current = url;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        await _fetch(current, target).timeout(perDownloadTimeout);
        return;
      } on DownloadException catch (e) {
        last = e;
        final code = e.statusCode;
        if (code != null && _expired(code)) {
          final fresh = refresher == null ? null : await refresher(url);
          if (fresh == null) rethrow;
          current = fresh;
          continue;
        }
        if (code != null && code < 500) rethrow;
      } on IOException catch (e) {
        last = e;
      } on TimeoutException catch (e) {
        last = e;
      }
      await Future<void>.delayed(retryDelay * (1 << attempt));
    }
    throw last!;
  }

  Future<void> _fetch(String url, File target) async {
    final req = await _client
        .getUrl(Uri.parse(url))
        .timeout(const Duration(seconds: 15));
    final res = await req.close().timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw DownloadException('HTTP ${res.statusCode}', res.statusCode);
    }
    if (res.contentLength > maxBytes) {
      await res.drain<void>().catchError((_) {});
      throw ImageTooLargeException(
        'Content-Length ${res.contentLength} > $maxBytes bytes',
      );
    }
    final sink = target.openWrite();
    var received = 0;
    try {
      await sink.addStream(
        res.timeout(const Duration(seconds: 30)).map((chunk) {
          received += chunk.length;
          if (received > maxBytes) {
            throw ImageTooLargeException('Download exceeded $maxBytes bytes');
          }
          return chunk;
        }),
      );
      await sink.close();
      if (res.contentLength >= 0 && received != res.contentLength) {
        throw const FileSystemException('Truncated download');
      }
    } catch (_) {
      await sink.close().catchError((_) {});
      await target.delete().catchError((_) => target);
      rethrow;
    }
  }
}
