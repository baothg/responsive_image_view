import 'dart:io';

import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';

import 'size_bucket.dart';

/// File based cache: one file per (image, bucket). Entry age = file mtime
/// (creation time, never touched on read).
class DiskCache {
  DiskCache({this.maxAge = const Duration(days: 30), this.maxBytes = 300 * 1024 * 1024, Directory? directory})
      : _dir = directory;

  final Duration maxAge;
  final int maxBytes;
  Directory? _dir;
  Future<Directory>? _init;

  static const _signingParams = {
    'expires', 'signature', 'sig', 'token', 'se', 'sv', 'sp', 'sr', 'st', 'googleaccessid', 'policy', 'key-pair-id', 'e',
  };

  static String keyFor(String url) {
    final uri = Uri.tryParse(url);
    var normalized = url;
    if (uri != null && uri.hasQuery) {
      final kept = Map.of(uri.queryParametersAll)
        ..removeWhere((k, _) {
          final l = k.toLowerCase();
          return _signingParams.contains(l) || l.startsWith('x-amz-') || l.startsWith('x-goog-');
        });
      normalized = uri.replace(queryParameters: kept).toString();
    }
    return sha1.convert(utf8.encode(normalized)).toString();
  }

  Future<Directory> get directory => _init ??= () async {
        final d = _dir ?? Directory('${(await getTemporaryDirectory()).path}/responsive_image_view');
        await d.create(recursive: true);
        return _dir = d;
      }();

  Future<File> fileFor(String key, SizeBucket b) async => File('${(await directory).path}/${key}_${b.name}.img');

  /// Returns the cached file if present and not expired.
  Future<File?> get(String key, SizeBucket b) async {
    final f = await fileFor(key, b);
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
  Future<File> put(String key, SizeBucket b, List<int> bytes) async {
    final f = await fileFor(key, b);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    return tmp.rename(f.path);
  }

  Future<File> tempFile(String name) async => File('${(await directory).path}/$name.tmp');

  /// Removes expired entries, then oldest entries until under [maxBytes].
  Future<void> cleanup() async {
    final entries = <(File, FileStat)>[];
    var total = 0;
    final now = DateTime.now();
    await for (final e in (await directory).list()) {
      if (e is! File) continue;
      final s = await e.stat();
      if (e.path.endsWith('.tmp') ? now.difference(s.modified) > const Duration(hours: 1) : now.difference(s.modified) > maxAge) {
        await e.delete().catchError((_) => e);
        continue;
      }
      entries.add((e, s));
      total += s.size;
    }
    if (total <= maxBytes) return;
    entries.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (final (f, s) in entries) {
      if (total <= maxBytes) break;
      await f.delete().catchError((_) => f);
      total -= s.size;
    }
  }
}
