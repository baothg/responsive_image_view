import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:responsive_image_view/responsive_image_view.dart';
import 'package:responsive_image_view/src/disk_cache.dart';
import 'package:responsive_image_view/src/downloader.dart';
import 'package:responsive_image_view/src/image_hub.dart';
import 'package:image/image.dart' as img;
import 'package:responsive_image_view/src/resizer.dart';
import 'package:responsive_image_view/src/size_bucket.dart'
    show BucketScheme, SizeTier;

class _FakeDownloader extends Downloader {
  int calls = 0, active = 0, maxActive = 0;
  @override
  Future<void> download(
    String url,
    File target, {
    UrlRefresher? refresher,
  }) async {
    calls++;
    maxActive = active + 1 > maxActive ? active + 1 : maxActive;
    active++;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await target.writeAsBytes([1, 2, 3]);
    active--;
  }
}

/// Writes a valid but 1-pixel image, like a truncated JPEG would decode.
/// Claims 4000x3000 from the header while the file decodes to something
/// tiny — what a truncated JPEG looks like on a real device.
class _BigHeaderResizer extends Resizer {
  @override
  Future<Size> dimensions(File f) async => const Size(4000, 3000);
}

class _TinyDownloader extends Downloader {
  int calls = 0;
  @override
  Future<void> download(
    String url,
    File target, {
    UrlRefresher? refresher,
  }) async {
    calls++;
    await target.writeAsBytes(img.encodePng(img.Image(width: 1, height: 1)));
  }
}

const _svgBody =
    '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">'
    '<rect width="10" height="10" fill="#f00"/></svg>';

/// Writes raw bytes (e.g. SVG markup) as the download result.
class _RawDownloader extends Downloader {
  _RawDownloader(this.body);
  final List<int> body;
  int calls = 0;
  @override
  Future<void> download(
    String url,
    File target, {
    UrlRefresher? refresher,
  }) async {
    calls++;
    await target.writeAsBytes(body);
  }
}

class _FailingDownloader extends Downloader {
  static int calls = 0;
  @override
  Future<void> download(
    String url,
    File target, {
    UrlRefresher? refresher,
  }) async {
    calls++;
    throw DownloadException('boom', 500);
  }
}

class _FakeResizer extends Resizer {
  final sizes = <Size>[];
  final sources = <String>[];
  int active = 0, maxActive = 0;
  @override
  Future<Size> dimensions(File f) async {
    if (f.readAsBytesSync().first == 0) throw UnsupportedImageException('bad');
    return const Size(4000, 3000);
  }

  @override
  Future<Uint8List> resize(File src, Size source, Size target) async {
    sizes.add(target);
    sources.add(src.path);
    maxActive = ++active > maxActive ? active : maxActive;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    active--;
    return Uint8List.fromList([9, 9]);
  }
}

Future<HttpServer> _serve(void Function(HttpResponse r) handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => handler(req.response));
  return server;
}

/// Like [_serve] but the handler also sees the request (path-aware).
Future<HttpServer> _serveReq(
  void Function(HttpRequest req, HttpResponse r) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => handler(req, req.response));
  return server;
}

void main() {
  const screen = Size(400, 800);

  test('bucket by area ratio', () {
    expect(BucketScheme().resolve(const Size(100, 100), screen), 0);
    expect(BucketScheme().resolve(const Size(300, 400), screen), 1);
    expect(BucketScheme().resolve(const Size(400, 600), screen), 2);
  });

  test('dynamic schemes: 2-tier and 4-tier resolve', () {
    expect(BucketScheme([0.5, 1.0]).resolve(const Size(100, 400), screen), 0);
    expect(BucketScheme([0.5, 1.0]).resolve(const Size(400, 800), screen), 1);
    expect(
      BucketScheme([
        0.1,
        0.33,
        0.66,
        1.0,
      ]).resolve(const Size(100, 100), screen),
      0,
    );
    expect(
      BucketScheme([
        0.1,
        0.33,
        0.66,
        1.0,
      ]).resolve(const Size(500, 400), screen),
      2,
    );
    expect(() => BucketScheme([0.5]), throwsArgumentError);
    expect(() => BucketScheme([0.6, 0.2]), throwsArgumentError);
  });

  test('targetSize never upscales and keeps aspect', () {
    const px = Size(1200, 2400);
    expect(
      SizeTier(1.0).targetSize(const Size(100, 100), px),
      const Size(100, 100),
    );
    final t = SizeTier(0.2).targetSize(const Size(4000, 2000), px);
    expect(t.width / t.height, closeTo(2, 0.01));
    expect(t.width * t.height, lessThanOrEqualTo(0.2 * 1200 * 2400 * 1.01));
  });

  test('cache key ignores signing params', () {
    expect(
      DiskCache.keyFor('https://a.com/x.jpg?X-Amz-Signature=1&Expires=2'),
      DiskCache.keyFor('https://a.com/x.jpg?X-Amz-Signature=9&Expires=8'),
    );
    expect(
      DiskCache.keyFor('https://a.com/x.jpg?id=1'),
      isNot(DiskCache.keyFor('https://a.com/x.jpg?id=2')),
    );
  });

  group('downloader limits', () {
    late Directory dir;
    setUp(() {
      HttpOverrides.global = null;
      dir = Directory.systemTemp.createTempSync('ri');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('rejects by Content-Length without retry', () async {
      var hits = 0;
      final server = await _serve((r) {
        hits++;
        r.contentLength = 5000;
        r.add(List.filled(5000, 1));
        r.close();
      });
      final target = File('${dir.path}/t');
      await expectLater(
        Downloader(
          maxBytes: 1000,
        ).download('http://127.0.0.1:${server.port}/a', target),
        throwsA(isA<ImageTooLargeException>()),
      );
      expect(hits, 1);
      expect(target.existsSync(), false);
      await server.close(force: true);
    });

    test('rejects chunked stream that grows past the limit', () async {
      final server = await _serve((r) {
        r.headers.chunkedTransferEncoding = true;
        for (var i = 0; i < 10; i++) {
          r.add(List.filled(500, 1));
        }
        r.close();
      });
      final target = File('${dir.path}/t');
      await expectLater(
        Downloader(
          maxBytes: 1000,
        ).download('http://127.0.0.1:${server.port}/a', target),
        throwsA(isA<ImageTooLargeException>()),
      );
      expect(target.existsSync(), false);
      await server.close(force: true);
    });

    test('rejects truncated responses and retries', () async {
      var hits = 0;
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(
        server.forEach((socket) async {
          hits++;
          socket.write('HTTP/1.1 200 OK\r\ncontent-length: 5000\r\n\r\n');
          socket.add(List.filled(500, 1));
          await socket.flush();
          await socket.close();
        }),
      );
      final target = File('${dir.path}/t');
      await expectLater(
        Downloader(
          maxAttempts: 2,
          retryDelay: Duration.zero,
        ).download('http://127.0.0.1:${server.port}/a', target),
        throwsA(isA<IOException>()),
      );
      expect(hits, 2);
      expect(target.existsSync(), false);
      await server.close();
    });

    for (final code in [404, 410]) {
      test('HTTP $code fails fast as ImageNotFoundException', () async {
        var hits = 0;
        var refresherCalls = 0;
        final server = await _serve((r) {
          hits++;
          r.statusCode = code;
          r.close();
        });
        final url = 'http://127.0.0.1:${server.port}/missing';
        final target = File('${dir.path}/t$code');
        await expectLater(
          Downloader(retryDelay: Duration.zero).download(
            url,
            target,
            refresher: (_) async {
              refresherCalls++;
              return url;
            },
          ),
          throwsA(
            isA<ImageNotFoundException>()
                .having((e) => e.statusCode, 'statusCode', code)
                .having((e) => e.url, 'url', url),
          ),
        );
        expect(hits, 1); // no retry, definitive status
        expect(refresherCalls, 0); // refresher is for auth expiry only
        await server.close(force: true);
      });
    }

    test('401/403 ask the refresher and retry with the new url', () async {
      var hits = 0;
      var refresherCalls = 0;
      final png = img.encodePng(img.Image(width: 2, height: 2));
      late HttpServer server;
      server = await _serveReq((req, r) {
        hits++;
        if (req.uri.path == '/fresh') {
          r.add(png);
        } else {
          r.statusCode = 401;
        }
        r.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      final target = File('${dir.path}/auth');
      await Downloader(retryDelay: Duration.zero).download(
        '$base/expired',
        target,
        refresher: (expired) async {
          refresherCalls++;
          expect(expired, '$base/expired');
          return '$base/fresh';
        },
      );
      expect(hits, 2);
      expect(refresherCalls, 1);
      expect(target.readAsBytesSync(), png);
      await server.close(force: true);
    });

    test('401 without a refresher rethrows the original error', () async {
      final server = await _serve((r) {
        r.statusCode = 403;
        r.close();
      });
      await expectLater(
        Downloader(
          retryDelay: Duration.zero,
        ).download('http://127.0.0.1:${server.port}/x', File('${dir.path}/nf')),
        throwsA(
          isA<DownloadException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e is ImageNotFoundException, 'notFound', isFalse),
        ),
      );
      await server.close(force: true);
    });

    test('a refreshed url that is itself missing fails as not-found', () async {
      var hits = 0;
      final server = await _serveReq((req, r) {
        hits++;
        r.statusCode = req.uri.path == '/a' ? 403 : 404;
        r.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      await expectLater(
        Downloader(retryDelay: Duration.zero).download(
          '$base/a',
          File('${dir.path}/m'),
          refresher: (_) async => '$base/b',
        ),
        throwsA(isA<ImageNotFoundException>()),
      );
      expect(hits, 2);
      await server.close(force: true);
    });

    test('auth-expired status calls the refresher at most once', () async {
      var hits = 0;
      var refresherCalls = 0;
      // e.g. S3 answering 403 for a missing object: refreshing can never
      // help, so it must not be invoked once per retry.
      final server = await _serveReq((req, r) {
        hits++;
        r.statusCode = 403;
        r.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      await expectLater(
        Downloader(retryDelay: Duration.zero, maxAttempts: 3).download(
          '$base/gone',
          File('${dir.path}/gone'),
          refresher: (_) async {
            refresherCalls++;
            return '$base/gone2';
          },
        ),
        throwsA(isA<DownloadException>()),
      );
      expect(hits, 2); // original + one refreshed attempt, then fail fast
      expect(refresherCalls, 1);
      await server.close(force: true);
    });

    test('maxAttempts bounds the total number of tries', () async {
      var hits = 0;
      final server = await _serve((r) {
        hits++;
        r.statusCode = 500;
        r.close();
      });
      await expectLater(
        Downloader(
          maxAttempts: 1,
          retryDelay: Duration.zero,
        ).download('http://127.0.0.1:${server.port}/x', File('${dir.path}/ma')),
        throwsA(isA<DownloadException>()),
      );
      expect(hits, 1);
      await server.close(force: true);
    });

    test('a slow-drip stream hits the overall download deadline', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var running = true;
      unawaited(
        server
            .forEach((socket) async {
              socket.write('HTTP/1.1 200 OK\r\ncontent-length: 999999\r\n\r\n');
              await socket.flush();
              while (running) {
                socket.add([1]);
                await socket.flush();
                await Future<void>.delayed(const Duration(milliseconds: 200));
              }
              await socket.close();
            })
            .catchError((_) {}),
      );
      final target = File('${dir.path}/t');
      final sw = Stopwatch()..start();
      await expectLater(
        Downloader(
          maxAttempts: 1,
          perDownloadTimeout: const Duration(milliseconds: 500),
        ).download('http://127.0.0.1:${server.port}/a', target),
        throwsA(isA<TimeoutException>()),
      );
      expect(sw.elapsed.inSeconds, lessThan(10));
      running = false;
      await server.close();
    });

    test('accepts file under the limit', () async {
      final server = await _serve((r) {
        r.add(List.filled(500, 1));
        r.close();
      });
      final target = File('${dir.path}/t');
      await Downloader(
        maxBytes: 1000,
      ).download('http://127.0.0.1:${server.port}/a', target);
      expect(target.lengthSync(), 500);
      await server.close(force: true);
    });
  });

  group('with temp dir', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ri'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('cleanup removes expired then oldest over quota', () async {
      final cache = DiskCache(directory: dir, maxBytes: 10);
      final old = await cache.put('a', 'b0', List.filled(8, 0));
      old.setLastModifiedSync(
        DateTime.now().subtract(const Duration(days: 31)),
      );
      final mid = await cache.put('b', 'b0', List.filled(8, 0));
      mid.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 2)));
      final fresh = await cache.put('c', 'b0', List.filled(8, 0));
      await cache.cleanup();
      expect(old.existsSync(), false);
      expect(mid.existsSync(), false);
      expect(fresh.existsSync(), true);
    });

    test(
      'hub: lazy chain, dedupe, reuse larger bucket, concurrency cap',
      () async {
        final dl = _FakeDownloader();
        final rs = _FakeResizer();
        final hub = ImageHub(
          cache: DiskCache(directory: dir),
          downloader: dl,
          resizer: rs,
          maxDownloads: 2,
        );
        const px = Size(1200, 2400);

        final a = hub.request('u1', 0, px, cacheKey: 'k1');
        final a2 = hub.request('u1', 0, px, cacheKey: 'k1');
        await Future.wait([a.future, a2.future]);
        expect(dl.calls, 1);
        expect(rs.sizes.length, 4); // XS, L, M, S
        expect(rs.sources.toSet().length, 1); // all derived from the original

        rs.sizes.clear();
        await hub.request('u1', 1, px, cacheKey: 'k1').future; // cached
        expect(dl.calls, 1);
        expect(rs.sizes, isEmpty);

        expect(hub.peek('u1', 0, cacheKey: 'k1'), isNotNull);
        expect(hub.peekXs('u1', cacheKey: 'k1'), isNotNull);
        expect(hub.peek('u1', 0, cacheKey: 'nope'), isNull);

        await Future.wait([
          for (var i = 0; i < 6; i++)
            hub.request('x$i', 2, px, cacheKey: 'x$i').future,
        ]);
        expect(dl.maxActive, lessThanOrEqualTo(2));
        expect(rs.maxActive, lessThanOrEqualTo(2));
      },
    );

    test(
      'corrupt cached source falls back to download; peek is warmed from disk',
      () async {
        final cache = DiskCache(directory: dir);
        await cache.put(DiskCache.hash('k'), 'b2', [0]); // corrupt L
        final dl = _FakeDownloader();
        final hub = ImageHub(
          cache: cache,
          downloader: dl,
          resizer: _FakeResizer(),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(hub.peek('u', 2, cacheKey: 'k'), isNotNull);
        final f = await hub
            .request('u', 1, const Size(1200, 2400), cacheKey: 'k')
            .future;
        expect(dl.calls, 1);
        expect(f.file.existsSync(), true);
        await hub.invalidate('u', 1, cacheKey: 'k');
        expect(hub.peek('u', 1, cacheKey: 'k'), isNull);
        expect(f.file.existsSync(), false);
      },
    );

    test('same image requested in two buckets downloads once', () async {
      final dl = _FakeDownloader();
      final hub = ImageHub(
        cache: DiskCache(directory: dir),
        downloader: dl,
        resizer: _FakeResizer(),
      );
      const px = Size(1200, 2400);
      await Future.wait([
        hub.request('u', 2, px, cacheKey: 'z').future,
        hub.request('u', 0, px, cacheKey: 'z').future,
      ]);
      expect(dl.calls, 1);
    });

    test('rejects images over the pixel limit', () async {
      final hub = ImageHub(
        cache: DiskCache(directory: dir),
        downloader: _FakeDownloader(),
        resizer: _FakeResizer(),
        maxPixels: 1000,
      );
      await expectLater(
        hub.request('u', 0, const Size(1200, 2400), cacheKey: 'big').future,
        throwsA(isA<ImageTooLargeException>()),
      );
    });

    test('failed image is not re-downloaded until invalidated', () async {
      final hub = ImageHub(
        cache: DiskCache(directory: dir),
        downloader: _FailingDownloader(),
        resizer: _FakeResizer(),
      );
      const px = Size(1200, 2400);
      Future<void> attempt() => hub
          .request('u', 0, px, cacheKey: 'f')
          .future
          .then((_) {}, onError: (_) {});
      await attempt();
      await attempt();
      expect(_FailingDownloader.calls, 1);
      await hub.invalidate('u', 0, cacheKey: 'f');
      await attempt();
      expect(_FailingDownloader.calls, 2);
    });

    test('configure replaces the singleton and rejects late calls', () async {
      ImageHub.configure(maxDownloads: 4);
      expect(ImageHub.instance.maxDownloads, 4);
      await expectLater(
        ImageHub.instance
            .request('u', 0, const Size(1200, 2400), cacheKey: 'cfg')
            .future,
        completes,
      ).catchError((_) {}); // download will fail offline; only _used matters
      expect(() => ImageHub.configure(), throwsStateError);
      ImageHub.instance = ImageHub(cache: DiskCache(directory: dir));
    });

    test(
      'truncated download producing tiny output is retried then errors',
      () async {
        final dl = _TinyDownloader();
        final hub = ImageHub(
          cache: DiskCache(directory: dir),
          downloader: dl,
          resizer: _BigHeaderResizer(),
          maxPixels: 1000 * 1000 * 1000,
        );
        await expectLater(
          hub.request('u', 2, const Size(1200, 2400), cacheKey: 'tiny').future,
          throwsA(isA<CorruptImageException>()),
        );
        expect(dl.calls, 2);
      },
    );

    test('request S prefers nearest larger cached tier (M over L)', () async {
      final dl = _FakeDownloader();
      final rs = _FakeResizer();
      final hub = ImageHub(
        cache: DiskCache(directory: dir),
        downloader: dl,
        resizer: rs,
      );
      const px = Size(1200, 2400);
      await hub
          .request('u', 2, px, cacheKey: 'n')
          .future; // L (+ M? no: L only)
      rs.sources.clear();
      await hub.request('u', 0, px, cacheKey: 'n').future; // S
      // S must derive M then S: 2 resize calls, all from the same source
      expect(rs.sources.length, 2);
      await hub.request('u', 1, px, cacheKey: 'n').future; // M already cached
      // now request another image with only L cached -> S reuses L
    });

    test(
      'svg bypasses raster pipeline: one cached file, no variants',
      () async {
        final cache = DiskCache(directory: dir);
        final dl = _RawDownloader(utf8.encode(_svgBody));
        final rs = _FakeResizer();
        final hub = ImageHub(cache: cache, downloader: dl, resizer: rs);
        const px = Size(1200, 2400);
        final r = await hub.request('u', 0, px, cacheKey: 's').future;
        expect(r.svg, isTrue);
        expect(r.file.existsSync(), isTrue);
        expect(r.file.path, endsWith('_svg.img'));
        expect(rs.sizes, isEmpty); // never enters the raster resizer
        final key = DiskCache.hash('s');
        expect(await cache.get(key, 'xs'), isNull);
        expect(await cache.get(key, 'b0'), isNull);
        // peek sees the svg file for any tier.
        final hit = hub.peek('u', 2, cacheKey: 's');
        expect(hit!.svg, isTrue);
        expect(hit.file.path, r.file.path);
        // Another tier reuses the svg file — no second download.
        final r2 = await hub.request('u', 2, px, cacheKey: 's').future;
        expect(r2.svg, isTrue);
        expect(r2.file.path, r.file.path);
        expect(dl.calls, 1);
        // Dropping it makes the next request download again.
        await hub.invalidateSvg('u', cacheKey: 's');
        expect(hub.peek('u', 0, cacheKey: 's'), isNull);
        await hub.request('u', 0, px, cacheKey: 's').future;
        expect(dl.calls, 2);
      },
    );

    test('xml with an <svg> root (after <?xml>) is detected', () async {
      final dl = _RawDownloader(
        utf8.encode('<?xml version="1.0"?>\n$_svgBody'),
      );
      final hub = ImageHub(
        cache: DiskCache(directory: dir),
        downloader: dl,
        resizer: _FakeResizer(),
      );
      final r = await hub
          .request('u', 0, const Size(1200, 2400), cacheKey: 'x')
          .future;
      expect(r.svg, isTrue);
    });

    test('non-svg xml/text is not misdetected', () async {
      for (final body in [
        '<?xml version="1.0"?><feed title="svg-icon"/>',
        '<rss version="2.0"></rss>',
        'plain text with svg word inside',
      ]) {
        final hub = ImageHub(
          cache: DiskCache(directory: dir),
          downloader: _RawDownloader(utf8.encode(body)),
          resizer: _FakeResizer(),
        );
        final r = await hub
            .request('u', 0, const Size(1200, 2400), cacheKey: body)
            .future;
        expect(r.svg, isFalse, reason: body);
      }
    });

    test(
      'original request stores one org file + xs, no bucket variants',
      () async {
        final cache = DiskCache(directory: dir);
        final dl = _RawDownloader(utf8.encode('raster-ish-bytes'));
        final rs = _FakeResizer();
        final hub = ImageHub(cache: cache, downloader: dl, resizer: rs);
        const px = Size(1200, 2400);
        final r = await hub
            .request('u', 0, px, cacheKey: 'o', original: true)
            .future;
        expect(r.svg, isFalse);
        expect(r.file.path, endsWith('_org.img'));
        expect(r.file.existsSync(), isTrue);
        final key = DiskCache.hash('o');
        expect(await cache.get(key, 'b0'), isNull);
        expect(await cache.get(key, 'b2'), isNull);
        expect(await cache.get(key, 'xs'), isNotNull); // preview produced
        // Only the XS resize ran — the original itself is stored as-is.
        expect(rs.sizes.length, 1);
        // peekOriginal sees it; plain peek does not mistake it for a bucket.
        expect(hub.peekOriginal('u', cacheKey: 'o')!.file.path, r.file.path);
        expect(hub.peek('u', 0, cacheKey: 'o'), isNull);
        // A second original request at another tier dedupes — no re-download.
        await hub.request('u', 2, px, cacheKey: 'o', original: true).future;
        expect(dl.calls, 1);
        // And a bucket request now derives from the cached original.
        rs.sources.clear();
        await hub.request('u', 0, px, cacheKey: 'o').future;
        expect(rs.sources, isNotEmpty);
        expect(rs.sources.first, r.file.path); // resized FROM the original
        expect(dl.calls, 1);
        // Invalidating drops the original.
        await hub.invalidateOrg('u', cacheKey: 'o');
        expect(hub.peekOriginal('u', cacheKey: 'o'), isNull);
      },
    );

    test('svg url serves an original request from the svg variant', () async {
      final cache = DiskCache(directory: dir);
      await cache.put(DiskCache.hash('os'), 'svg', utf8.encode(_svgBody));
      final dl = _RawDownloader(utf8.encode('unused'));
      final hub = ImageHub(
        cache: cache,
        downloader: dl,
        resizer: _FakeResizer(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final r = await hub
          .request(
            'u',
            0,
            const Size(1200, 2400),
            cacheKey: 'os',
            original: true,
          )
          .future;
      expect(r.svg, isTrue);
      expect(dl.calls, 0); // served from cache, nothing downloaded
    });

    test('best preview prefers the largest cached variant over xs', () async {
      final cache = DiskCache(directory: dir);
      final key = DiskCache.hash('bp');
      await cache.put(key, 'xs', [1]);
      await cache.put(key, 'b0', [3]);
      await cache.put(key, 'b1', [2]);
      final hub = ImageHub(
        cache: cache,
        downloader: _RawDownloader(utf8.encode('x')),
        resizer: _FakeResizer(),
      );
      // _warmUp indexes existing files.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // b1 outranks both b0 and xs.
      expect(
        hub.peekBestPreview('u', cacheKey: 'bp')!.file.path,
        endsWith('_b1.img'),
      );
    });

    test('cancelled queued job is dropped', () async {
      final dl = _FakeDownloader();
      final hub = ImageHub(
        cache: DiskCache(directory: dir),
        downloader: dl,
        resizer: _FakeResizer(),
        maxDownloads: 1,
      );
      const px = Size(1200, 2400);
      final r1 = hub.request('a', 2, px, cacheKey: 'a');
      final r2 = hub.request('b', 2, px, cacheKey: 'b');
      r1.future.ignore();
      r1.cancel();
      r2.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(dl.calls, lessThanOrEqualTo(1));
    });
  });

  test('dimensions are EXIF-oriented', () async {
    final dir = Directory.systemTemp.createTempSync('ri');
    addTearDown(() => dir.deleteSync(recursive: true));
    final image = img.Image(width: 40, height: 20)
      ..exif.imageIfd.orientation = 6;
    final f = File('${dir.path}/a.jpg')..writeAsBytesSync(img.encodeJpg(image));
    final plain = File('${dir.path}/b.jpg')
      ..writeAsBytesSync(img.encodeJpg(img.Image(width: 40, height: 20)));
    expect(await const Resizer().dimensions(f), const Size(20, 40));
    expect(await const Resizer().dimensions(plain), const Size(40, 20));
  });

  testWidgets('builds under IntrinsicHeight and shows skeleton', (t) async {
    await t.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: IntrinsicHeight(
          child: Row(
            children: [ResponsiveImageView('http://x/a.jpg', height: 80)],
          ),
        ),
      ),
    );
    await t.pump();
    expect(find.byType(ResponsiveImageSkeleton), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  for (final fixedSize in [true, false]) {
    testWidgets(
      'already-cached image replaces skeleton (${fixedSize ? 'fixed' : 'measured'} size)',
      (t) async {
        final dir = Directory.systemTemp.createTempSync('ri_w');
        addTearDown(() => dir.deleteSync(recursive: true));
        final cache = DiskCache(directory: dir);
        final key = DiskCache.hash('cached-key');
        final png = img.encodePng(img.Image(width: 8, height: 8));
        await t.runAsync(() async {
          await cache.put(key, 'b0', png);
          await cache.put(key, 'xs', png);
        });
        late ImageHub hub;
        await t.runAsync(() async {
          hub = ImageHub(cache: cache, downloader: _FailingDownloader());
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        ImageHub.instance = hub;
        await t.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 72,
                height: 72,
                child: ResponsiveImageView(
                  'http://x/a.jpg',
                  cacheKey: 'cached-key',
                  width: fixedSize ? 72 : null,
                  height: fixedSize ? 72 : null,
                ),
              ),
            ),
          ),
        );
        await t.pump();
        await t.pump();
        expect(find.byType(ResponsiveImageSkeleton), findsNothing);
        expect(find.byType(Image), findsOneWidget);
      },
    );
  }

  testWidgets('onLoaded fires once after decode, incl. cache hit', (t) async {
    final dir = Directory.systemTemp.createTempSync('ri_l');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache = DiskCache(directory: dir);
    final key = DiskCache.hash('load-key');
    final png = img.encodePng(img.Image(width: 8, height: 8));
    await t.runAsync(() async {
      await cache.put(key, 'b0', png);
      await cache.put(key, 'xs', png);
    });
    late ImageHub hub;
    await t.runAsync(() async {
      hub = ImageHub(cache: cache, downloader: _FailingDownloader());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    ImageHub.instance = hub;
    var calls = 0;
    File? got;
    await t.runAsync(() async {
      await t.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 72,
            height: 72,
            child: ResponsiveImageView(
              'http://x/a.jpg',
              cacheKey: 'load-key',
              width: 72,
              height: 72,
              onLoaded: (f) {
                calls++;
                got = f;
              },
            ),
          ),
        ),
      );
      await t.pump();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await t.pump();
    });
    await t.pump();
    expect(calls, 1);
    expect(got!.path, contains('_b0'));
  });

  testWidgets('onLoaded is not fired for the XS preview', (t) async {
    final dir = Directory.systemTemp.createTempSync('ri_l2');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache = DiskCache(directory: dir);
    final key = DiskCache.hash('xs-key');
    await t.runAsync(
      () => cache.put(key, 'xs', img.encodePng(img.Image(width: 8, height: 8))),
    );
    late ImageHub hub;
    await t.runAsync(() async {
      hub = ImageHub(cache: cache, downloader: _FailingDownloader());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    ImageHub.instance = hub;
    var calls = 0;
    await t.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 72,
          height: 72,
          child: ResponsiveImageView(
            'http://x/b.jpg',
            cacheKey: 'xs-key',
            width: 72,
            height: 72,
            onLoaded: (_) => calls++,
          ),
        ),
      ),
    );
    await t.pump();
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await t.pump();
    expect(find.byType(ResponsiveImageSkeleton), findsNothing);
    expect(calls, 0);
  });

  testWidgets('svg renders via SvgPicture and fires onLoaded', (t) async {
    final dir = Directory.systemTemp.createTempSync('ri_svg');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache = DiskCache(directory: dir);
    final key = DiskCache.hash('svg-key');
    await t.runAsync(() => cache.put(key, 'svg', utf8.encode(_svgBody)));
    late ImageHub hub;
    await t.runAsync(() async {
      hub = ImageHub(cache: cache, downloader: _FailingDownloader());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    ImageHub.instance = hub;
    var calls = 0;
    File? got;
    await t.runAsync(() async {
      await t.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 72,
            height: 72,
            child: ResponsiveImageView(
              'http://x/s.svg',
              cacheKey: 'svg-key',
              width: 72,
              height: 72,
              onLoaded: (f) {
                calls++;
                got = f;
              },
            ),
          ),
        ),
      );
      await t.pump();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await t.pump();
    });
    await t.pump();
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.byType(ResponsiveImageSkeleton), findsNothing);
    expect(calls, 1);
    expect(got!.path, contains('_svg'));
  });

  testWidgets('malformed svg surfaces through errorBuilder', (t) async {
    final dir = Directory.systemTemp.createTempSync('ri_svgbad');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache = DiskCache(directory: dir);
    final key = DiskCache.hash('bad-svg');
    await t.runAsync(
      () => cache.put(
        key,
        'svg',
        utf8.encode('<svg xmlns="http://www.w3.org/2000/svg"><rect'),
      ),
    );
    late ImageHub hub;
    await t.runAsync(() async {
      hub = ImageHub(cache: cache, downloader: _FailingDownloader());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    ImageHub.instance = hub;
    await t.runAsync(() async {
      await t.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 72,
            height: 72,
            child: ResponsiveImageView(
              'http://x/b.svg',
              cacheKey: 'bad-svg',
              width: 72,
              height: 72,
              errorBuilder: (ctx, e, retry) => const Text('err'),
            ),
          ),
        ),
      );
      await t.pump();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await t.pump();
      // The file error invalidates + re-downloads; the request then fails
      // (downloader always throws) and the final error lands in errorBuilder.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await t.pump();
    });
    await t.pump();
    expect(find.text('err'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('non-finite width/height do not crash the build', (t) async {
    ImageHub.instance = ImageHub(
      cache: DiskCache(
        directory: Directory.systemTemp.createTempSync('ri_inf')
          ..deleteSync(recursive: true),
      ),
      downloader: _FailingDownloader(),
    );
    for (final dims in [
      (double.infinity, 100.0),
      (100.0, double.infinity),
      (double.nan, double.nan),
      (double.negativeInfinity, 50.0),
      (-10.0, -10.0),
    ]) {
      await t.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 200,
            child: ResponsiveImageView(
              'http://x/i.jpg',
              width: dims.$1,
              height: dims.$2,
            ),
          ),
        ),
      );
      await t.pump();
    }
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'loose constraints use offered space, not screen, for tier pick',
    (t) async {
      final dir = Directory.systemTemp.createTempSync('ri_loose');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cache = DiskCache(directory: dir);
      final key = DiskCache.hash('loose-key');
      final png = img.encodePng(img.Image(width: 8, height: 8));
      // Only the smallest tier is cached: if the widget resolved the screen
      // size (tier 2) it would miss cache and error instead of showing it.
      await t.runAsync(() => cache.put(key, 'b0', png));
      late ImageHub hub;
      await t.runAsync(() async {
        hub = ImageHub(cache: cache, downloader: _FailingDownloader());
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      ImageHub.instance = hub;
      await t.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 800,
              height: 600,
              child: Center(child: SizedBox.shrink()),
            ),
          ),
        ),
      );
      // Rebuild with the actual widget under loose (0..100) constraints.
      await t.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 100, maxHeight: 100),
              child: const ResponsiveImageView(
                'http://x/l.jpg',
                cacheKey: 'loose-key',
              ),
            ),
          ),
        ),
      );
      await t.pump();
      await t.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('showOriginalImage renders cached org and fires onLoaded', (
    t,
  ) async {
    final dir = Directory.systemTemp.createTempSync('ri_org');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache = DiskCache(directory: dir);
    final key = DiskCache.hash('org-key');
    final png = img.encodePng(img.Image(width: 8, height: 8));
    await t.runAsync(() async {
      await cache.put(key, 'org', png);
      await cache.put(key, 'b0', png); // best preview while org is unknown
    });
    late ImageHub hub;
    await t.runAsync(() async {
      hub = ImageHub(cache: cache, downloader: _FailingDownloader());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    ImageHub.instance = hub;
    var calls = 0;
    File? got;
    await t.runAsync(() async {
      await t.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 72,
            height: 72,
            child: ResponsiveImageView(
              'http://x/o.jpg',
              cacheKey: 'org-key',
              width: 72,
              height: 72,
              showOriginalImage: true,
              onLoaded: (f) {
                calls++;
                got = f;
              },
            ),
          ),
        ),
      );
      await t.pump();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await t.pump();
    });
    await t.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(calls, 1);
    expect(got!.path, contains('_org'));
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'preview falls back to the largest cached variant in bucket mode too',
    (t) async {
      final dir = Directory.systemTemp.createTempSync('ri_pv');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cache = DiskCache(directory: dir);
      final key = DiskCache.hash('pv-key');
      final png = img.encodePng(img.Image(width: 8, height: 8));
      // Only b2 cached; the b0 the widget needs will fail to download, so
      // the preview must stay on the largest available file.
      await t.runAsync(() => cache.put(key, 'b2', png));
      late ImageHub hub;
      await t.runAsync(() async {
        hub = ImageHub(cache: cache, downloader: _FailingDownloader());
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      ImageHub.instance = hub;
      await t.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 72,
            height: 72,
            child: ResponsiveImageView(
              'http://x/p.jpg',
              cacheKey: 'pv-key',
              width: 72,
              height: 72,
            ),
          ),
        ),
      );
      await t.pump();
      final image = t.widget<Image>(find.byType(Image));
      final provider = image.image;
      final file =
          (provider is ResizeImage ? provider.imageProvider : provider)
              as FileImage;
      expect(file.file.path, endsWith('_b2.img'));
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('lazy ctor never calls urlResolver on a cache hit', (t) async {
    final dir = Directory.systemTemp.createTempSync('ri_lz');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache = DiskCache(directory: dir);
    final key = DiskCache.hash('lazy-key');
    final png = img.encodePng(img.Image(width: 8, height: 8));
    await t.runAsync(() => cache.put(key, 'b0', png));
    late ImageHub hub;
    await t.runAsync(() async {
      hub = ImageHub(cache: cache, downloader: _FailingDownloader());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    ImageHub.instance = hub;
    var resolves = 0;
    await t.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 72,
          height: 72,
          child: ResponsiveImageView.lazy(
            cacheKey: 'lazy-key',
            urlResolver: () async {
              resolves++;
              return 'http://x/late.jpg';
            },
            width: 72,
            height: 72,
          ),
        ),
      ),
    );
    await t.pump();
    await t.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(resolves, 0); // cache hit: resolver never ran
    expect(t.takeException(), isNull);
  });

  testWidgets('lazy ctor resolves the url only on a cache miss', (t) async {
    final dir = Directory.systemTemp.createTempSync('ri_lz2');
    addTearDown(() => dir.deleteSync(recursive: true));
    final dl = _RawDownloader(img.encodePng(img.Image(width: 8, height: 8)));
    late ImageHub hub;
    await t.runAsync(() async {
      hub = ImageHub(
        cache: DiskCache(directory: dir),
        downloader: dl,
        resizer: _FakeResizer(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    ImageHub.instance = hub;
    var resolves = 0;
    await t.runAsync(() async {
      await t.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 72,
            height: 72,
            child: ResponsiveImageView.lazy(
              cacheKey: 'lazy-miss',
              urlResolver: () async {
                resolves++;
                return 'http://x/late.jpg';
              },
              width: 72,
              height: 72,
            ),
          ),
        ),
      );
      await t.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await t.pump();
    });
    await t.pump();
    expect(resolves, 1); // resolved exactly once, after the miss
    expect(dl.calls, 1); // and the resolved url was downloaded once
    expect(t.takeException(), isNull);
  });

  testWidgets('lazy ctor surfaces a null resolution as an error', (t) async {
    ImageHub.instance = ImageHub(
      cache: DiskCache(
        directory: Directory.systemTemp.createTempSync('ri_lz3')
          ..deleteSync(recursive: true),
      ),
      downloader: _FailingDownloader(),
    );
    var errors = 0;
    await t.runAsync(() async {
      await t.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 72,
            height: 72,
            child: ResponsiveImageView.lazy(
              cacheKey: 'lazy-null',
              urlResolver: () async => null,
              width: 72,
              height: 72,
              errorBuilder: (_, e, retry) {
                errors++;
                return const Text('err', textDirection: TextDirection.ltr);
              },
            ),
          ),
        ),
      );
      await t.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await t.pump();
    });
    expect(errors, greaterThan(0));
    expect(t.takeException(), isNull);
  });

  testWidgets('lazy ctor: synchronously-throwing resolver -> errorBuilder', (
    t,
  ) async {
    ImageHub.instance = ImageHub(
      cache: DiskCache(
        directory: Directory.systemTemp.createTempSync('ri_lz4')
          ..deleteSync(recursive: true),
      ),
      downloader: _FailingDownloader(),
    );
    var errors = 0;
    await t.runAsync(() async {
      await t.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 72,
            height: 72,
            child: ResponsiveImageView.lazy(
              cacheKey: 'lazy-throw',
              urlResolver: () =>
                  throw const FormatException('Unexpected character'),
              width: 72,
              height: 72,
              errorBuilder: (_, e, retry) {
                errors++;
                return const Text('err', textDirection: TextDirection.ltr);
              },
            ),
          ),
        ),
      );
      await t.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await t.pump();
    });
    expect(errors, greaterThan(0));
    expect(t.takeException(), isNull);
  });
}
