import 'dart:io';

import 'package:crypto/crypto.dart';

import 'dart:convert';

import 'package:path_provider/path_provider.dart';

/// File based cache: one file per (image, bucket). Entry age = file mtime
/// (creation time, never touched on read).
class DiskCache {
  DiskCache({
    this.maxAge = const Duration(days: 30),
    this.maxBytes = 300 * 1024 * 1024,
    Directory? directory,
  }) : _dir = directory;

  final Duration maxAge;
  final int maxBytes;
  Directory? _dir;
  Future<Directory>? _init;

  static const _signingParams = {
    'expires',
    'signature',
    'sig',
    'token',
    'se',
    'sv',
    'sp',
    'sr',
    'st',
    'googleaccessid',
    'policy',
    'key-pair-id',
    'e',
  };

  static String hash(String s) => sha1.convert(utf8.encode(s)).toString();

  static String keyFor(String url) {
    final uri = Uri.tryParse(url);
    var normalized = url;
    if (uri != null && uri.hasQuery) {
      final kept = Map.of(uri.queryParametersAll)
        ..removeWhere((k, _) {
          final l = k.toLowerCase();
          return _signingParams.contains(l) ||
              l.startsWith('x-amz-') ||
              l.startsWith('x-goog-');
        });
      normalized = uri.replace(queryParameters: kept).toString();
    }
    return hash(normalized);
  }

  Future<Directory> get directory => _init ??= () async {
    final d =
        _dir ??
        Directory(
          '${(await getTemporaryDirectory()).path}/responsive_image_view',
        );
    await d.create(recursive: true);
    return _dir = d;
  }();

  Future<File> fileFor(String key, String variant) async =>
      File('${(await directory).path}/${key}_$variant.img');

  /// Returns the cached file if present and not expired.
  Future<File?> get(String key, String variant) async {
    final f = await fileFor(key, variant);
    try {
      final stat = await f.stat();
      if (stat.type != FileSystemEntityType.file) return null;
      if (DateTime.now().difference(stat.modified) > maxAge) {
        await f.delete();
        return null;
      }
      return f;
    } catch (_) {
      return null;
    }
  }

  /// Atomically stores [bytes].
  Future<File> put(String key, String variant, List<int> bytes) async {
    final f = await fileFor(key, variant);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    return tmp.rename(f.path);
  }

  Future<File> tempFile(String name) async =>
      File('${(await directory).path}/$name.tmp');

  /// Removes expired entries, then oldest entries until under [maxBytes].
  /// Returns the surviving cache files, oldest first.
  Future<List<File>> cleanup() async {
    final entries = <(File, FileStat)>[];
    var total = 0;
    final now = DateTime.now();
    await for (final e in (await directory).list()) {
      if (e is! File) continue;
      final s = await e.stat();
      if (e.path.endsWith('.tmp')
          ? now.difference(s.modified) > const Duration(hours: 1)
          : now.difference(s.modified) > maxAge) {
        await e.delete().catchError((_) => e);
        continue;
      }
      if (!e.path.endsWith('.tmp')) entries.add((e, s));
      total += s.size;
    }
    entries.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    var i = 0;
    for (; i < entries.length && total > maxBytes; i++) {
      await entries[i].$1.delete().catchError((_) => entries[i].$1);
      total -= entries[i].$2.size;
    }
    return [for (final (f, _) in entries.skip(i)) f];
  }
}
