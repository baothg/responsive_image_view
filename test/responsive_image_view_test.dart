import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:responsive_image_view/src/disk_cache.dart';
import 'package:responsive_image_view/src/downloader.dart';
import 'package:responsive_image_view/src/image_hub.dart';
import 'package:image/image.dart' as img;
import 'package:responsive_image_view/src/resizer.dart';
import 'package:responsive_image_view/src/size_bucket.dart';

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
    expect(SizeBucket.resolve(const Size(100, 100), screen), SizeBucket.s);
    expect(SizeBucket.resolve(const Size(300, 400), screen), SizeBucket.m);
    expect(SizeBucket.resolve(const Size(400, 600), screen), SizeBucket.l);
  });

  test('targetSize never upscales and keeps aspect', () {
    const px = Size(1200, 2400);
    expect(
      SizeBucket.l.targetSize(const Size(100, 100), px),
      const Size(100, 100),
    );
    final t = SizeBucket.s.targetSize(const Size(4000, 2000), px);
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
        Downloader(maxBytes: 1000)
            .download('http://127.0.0.1:${server.port}/a', target),
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
        Downloader(maxBytes: 1000)
            .download('http://127.0.0.1:${server.port}/a', target),
        throwsA(isA<ImageTooLargeException>()),
      );
      expect(target.existsSync(), false);
      await server.close(force: true);
    });

    test('accepts file under the limit', () async {
      final server = await _serve((r) {
        r.add(List.filled(500, 1));
        r.close();
      });
      final target = File('${dir.path}/t');
      await Downloader(maxBytes: 1000)
          .download('http://127.0.0.1:${server.port}/a', target);
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
      final old = await cache.put('a', SizeBucket.s, List.filled(8, 0));
      old.setLastModifiedSync(
        DateTime.now().subtract(const Duration(days: 31)),
      );
      final mid = await cache.put('b', SizeBucket.s, List.filled(8, 0));
      mid.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 2)));
      final fresh = await cache.put('c', SizeBucket.s, List.filled(8, 0));
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

        final a = hub.request('u1', SizeBucket.s, px, cacheKey: 'k1');
        final a2 = hub.request('u1', SizeBucket.s, px, cacheKey: 'k1');
        await Future.wait([a.future, a2.future]);
        expect(dl.calls, 1);
        expect(rs.sizes.length, 3); // L, M, S
        expect(rs.sources.toSet().length, 1); // all derived from the original

        rs.sizes.clear();
        await hub
            .request('u1', SizeBucket.m, px, cacheKey: 'k1')
            .future; // cached
        expect(dl.calls, 1);
        expect(rs.sizes, isEmpty);

        expect(hub.peek('u1', SizeBucket.s, cacheKey: 'k1'), isNotNull);
        expect(hub.peek('u1', SizeBucket.s, cacheKey: 'nope'), isNull);

        await Future.wait([
          for (var i = 0; i < 6; i++)
            hub.request('x$i', SizeBucket.l, px, cacheKey: 'x$i').future,
        ]);
        expect(dl.maxActive, lessThanOrEqualTo(2));
        expect(rs.maxActive, lessThanOrEqualTo(2));
      },
    );

    test(
      'corrupt cached source falls back to download; peek is warmed from disk',
      () async {
        final cache = DiskCache(directory: dir);
        await cache.put(DiskCache.hash('k'), SizeBucket.l, [0]); // corrupt L
        final dl = _FakeDownloader();
        final hub = ImageHub(
          cache: cache,
          downloader: dl,
          resizer: _FakeResizer(),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(hub.peek('u', SizeBucket.l, cacheKey: 'k'), isNotNull);
        final f = await hub
            .request('u', SizeBucket.m, const Size(1200, 2400), cacheKey: 'k')
            .future;
        expect(dl.calls, 1);
        expect(f.existsSync(), true);
        await hub.invalidate('u', SizeBucket.m, cacheKey: 'k');
        expect(hub.peek('u', SizeBucket.m, cacheKey: 'k'), isNull);
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
        hub.request('u', SizeBucket.l, px, cacheKey: 'z').future,
        hub.request('u', SizeBucket.s, px, cacheKey: 'z').future,
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
        hub
            .request('u', SizeBucket.s, const Size(1200, 2400), cacheKey: 'big')
            .future,
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
          .request('u', SizeBucket.s, px, cacheKey: 'f')
          .future
          .then((_) {}, onError: (_) {});
      await attempt();
      await attempt();
      expect(_FailingDownloader.calls, 1);
      await hub.invalidate('u', SizeBucket.s, cacheKey: 'f');
      await attempt();
      expect(_FailingDownloader.calls, 2);
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
      final r1 = hub.request('a', SizeBucket.l, px, cacheKey: 'a');
      final r2 = hub.request('b', SizeBucket.l, px, cacheKey: 'b');
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
}
