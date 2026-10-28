import 'dart:io';

import 'package:flutter/widgets.dart';

import 'image_hub.dart';
import 'size_bucket.dart';

/// Network image that is downloaded once, downscaled to a size bucket
/// (S/M/L, by screen area share) and cached on disk.
class ResponsiveImageView extends StatefulWidget {
  const ResponsiveImageView(
    this.url, {
    super.key,
    this.width,
    this.height,
    this.fit,
    this.alignment = Alignment.center,
    this.placeholder,
    this.errorBuilder,
    this.urlRefresher,
    this.cacheKey,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final WidgetBuilder? placeholder;
  final Widget Function(BuildContext context, Object error)? errorBuilder;

  /// Called when the url looks expired (401/403/404/410) to obtain a fresh one.
  final Future<String?> Function(String expiredUrl)? urlRefresher;

  /// Overrides the default cache identity (url without signing query params).
  final String? cacheKey;

  @override
  State<ResponsiveImageView> createState() => _ResponsiveImageViewState();
}

class _ResponsiveImageViewState extends State<ResponsiveImageView> {
  ImageRequest? _request;
  String? _sourceId;
  String? _loadedFor;
  File? _file;
  Object? _error;

  @override
  void dispose() {
    _request?.cancel();
    super.dispose();
  }

  void _ensureLoaded(SizeBucket bucket, Size screenPx) {
    final source = widget.cacheKey ?? widget.url;
    final id = '$source|${bucket.name}';
    if (_loadedFor == id) return;
    _loadedFor = id;
    _request?.cancel();
    _request = null;
    if (_sourceId != source) _file = null;
    _sourceId = source;
    _error = null;
    final cached = ImageHub.instance.peek(widget.url, bucket, cacheKey: widget.cacheKey);
    if (cached != null) {
      _file = cached;
      return;
    }
    final req = _request = ImageHub.instance.request(widget.url, bucket, screenPx,
        cacheKey: widget.cacheKey, refresher: widget.urlRefresher);
    req.future.then((f) {
      if (mounted && _request == req) setState(() => _file = f);
    }, onError: (Object e) {
      if (mounted && _request == req && !isCancelled(e)) setState(() => _error = e);
    });
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(builder: (context, c) {
      final w = widget.width ?? (c.hasBoundedWidth ? c.maxWidth : screen.width);
      final h = widget.height ?? (c.hasBoundedHeight ? c.maxHeight : screen.height);
      final bucket = SizeBucket.resolve(Size(w, h), screen);
      _ensureLoaded(bucket, screen * dpr);
      Widget child;
      if (_file != null) {
        child = Image.file(_file!,
            key: ValueKey(_file!.path),
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            alignment: widget.alignment,
            cacheWidth: (w * dpr).round(),
            gaplessPlayback: true,
            errorBuilder: widget.errorBuilder == null ? null : (ctx, e, _) => widget.errorBuilder!(ctx, e));
      } else if (_error != null && widget.errorBuilder != null) {
        child = widget.errorBuilder!(context, _error!);
      } else {
        child = widget.placeholder?.call(context) ?? const SizedBox.shrink();
      }
      return SizedBox(width: widget.width, height: widget.height, child: child);
    });
  }
}
