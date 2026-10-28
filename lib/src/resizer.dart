import 'dart:io';
import 'dart:math' as math;
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;

/// Thrown when the downloaded data is not a supported static raster image
/// (e.g. SVG or corrupt data). Animated images are reduced to their first frame.
class UnsupportedImageException implements Exception {
  UnsupportedImageException(this.message);
  final String message;
  @override
  String toString() => 'UnsupportedImageException: $message';
}

/// The encoded output's dimensions do not match what was requested — almost
/// always a truncated download that decoded as a partial/tiny bitmap.
class CorruptImageException implements Exception {
  CorruptImageException(this.message);
  final String message;
  @override
  String toString() => 'CorruptImageException: $message';
}

/// Downscales (never upscales) and recompresses images.
/// Native encoder (WebP) first, pure Dart (`image`) fallback.
class Resizer {
  const Resizer({this.quality = 80});
  final int quality;

  /// Reads width/height from the header only (no full decode). The engine
  /// already applies EXIF orientation, matching what the native encoder uses.
  Future<ui.Size> dimensions(File f) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(f.path);
    try {
      final ui.ImageDescriptor d;
      try {
        d = await ui.ImageDescriptor.encoded(buffer);
      } catch (e) {
        throw UnsupportedImageException('$e');
      }
      final s = ui.Size(d.width.toDouble(), d.height.toDouble());
      d.dispose();
      return s;
    } finally {
      buffer.dispose();
    }
  }

  /// Produces bytes of [src] scaled to [target] (equal to source size = no
  /// resize, only recompress). Returned bytes may be the original if smaller.
  Future<Uint8List> resize(File src, ui.Size source, ui.Size target) async {
    final w = target.width.round(), h = target.height.round();
    Uint8List? bytes;
    try {
      bytes = await FlutterImageCompress.compressWithFile(
        src.path,
        minWidth: w,
        minHeight: h,
        quality: quality,
        format: CompressFormat.webp,
        keepExif: false,
        inSampleSize: _sampleSize(source, target),
      );
    } catch (e) {
      debugPrint(
        'ResponsiveImageView: native compress failed ($e), falling back to Dart',
      );
    }
    final Uint8List out =
        bytes ??
        await Isolate.run<Uint8List>(
          () => _dartResize(
            src.path,
            w,
            h,
            quality,
            source.width.round(),
            source.height.round(),
          ),
        );
    final noResize = target == source;
    if (noResize && out.length >= await src.length()) return src.readAsBytes();
    if (!noResize) await _expectSize(out, target);
    return out;
  }

  Future<void> _expectSize(Uint8List out, ui.Size target) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(out);
    ui.Size got;
    try {
      final d = await ui.ImageDescriptor.encoded(buffer);
      got = ui.Size(d.width.toDouble(), d.height.toDouble());
      d.dispose();
    } catch (e) {
      throw CorruptImageException('undecodable output: $e');
    } finally {
      buffer.dispose();
    }
    if (got.width * got.height < target.width * target.height * 0.5) {
      throw CorruptImageException(
        'decoded ${got.width.round()}x${got.height.round()}, expected ${target.width.round()}x${target.height.round()}',
      );
    }
  }
}

int _sampleSize(ui.Size source, ui.Size target) {
  var ratio = math.min(
    source.width / target.width,
    source.height / target.height,
  );
  var n = 1;
  while (ratio >= 2) {
    n *= 2;
    ratio /= 2;
  }
  return n;
}

Uint8List _dartResize(String path, int w, int h, int quality, int sw, int sh) {
  var image = img.decodeImage(File(path).readAsBytesSync());
  if (image == null) throw const FormatException('Unsupported image');
  image = img.bakeOrientation(image);
  // Compare against the *decoded* size, not the header: a truncated source
  // decodes smaller than declared and must not be upscaled to mask it.
  if (w < image.width || h < image.height) {
    image = img.copyResize(
      image,
      width: w,
      height: h,
      interpolation: img.Interpolation.average,
    );
  }
  return image.hasAlpha
      ? img.encodePng(image, level: 6)
      : img.encodeJpg(image, quality: quality);
}
