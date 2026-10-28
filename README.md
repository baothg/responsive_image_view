# responsive_image_view

A single widget, `ResponsiveImageView`, that loads a network image at a size suited to its on-screen area.

```dart
ResponsiveImageView(
  'https://example.com/photo.jpg',
  width: 100,
  height: 100,
  fit: BoxFit.cover,
  urlRefresher: (expired) async => await api.refreshUrl(expired), // optional
);
```

## How it works
- Buckets by widget area / screen area: S < 20%, M < 60%, L >= 60%. Target pixels are 20% / 60% / 100% of physical screen pixels; images are never upscaled.
- Download once (retry with backoff; `urlRefresher` called on 401/403/404/410). Each needed bucket (L, M, S, down to the requested one) is encoded directly from the original download, so there is no generational quality loss (native WebP, pure Dart fallback). If only a larger bucket is cached, it is used as the source instead of downloading again.
- Disk cache per image and bucket; entries expire after 30 days from creation, oldest are evicted above 300MB. Signing query params (`X-Amz-*`, `Expires`, `Signature`, ...) are ignored in the cache key; override with `cacheKey`. A corrupt cached file is deleted and rebuilt automatically.
- A hub admits up to 6 images at a time (newest request first, identical requests deduplicated, queued ones dropped when widgets are disposed) but runs at most 2 resize/encode steps concurrently. Files already on disk are indexed at startup so rebuilt list items show instantly without a placeholder flash.

Only static raster images are supported. Animated images (GIF, animated WebP) are reduced to their first frame; SVG is not supported and reports an error.

Platforms: Android, iOS.

## Install (git)
```yaml
dependencies:
  responsive_image_view:
    git: https://github.com/baothg/responsive_image.git
```
