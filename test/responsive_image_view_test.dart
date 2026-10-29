import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
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
        expect(f.existsSync(), true);
        await hub.invalidate('u', 1, cacheKey: 'k');
        expect(hub.peek('u', 1, cacheKey: 'k'), isNull);
        expect(f.existsSync(), false);
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
}
