# responsive_image_view

A single widget, `ResponsiveImageView`, that loads a network image at a size suited to its on-screen area.

```dart
ResponsiveImageView(
  'https://example.com/photo.jpg',
  width: 100,
  height: 100,
  fit: BoxFit.cover,
  // Shows a shimmer skeleton while loading; override with `placeholder`.
  errorBuilder: (context, error, retry) => IconButton(icon: Icon(Icons.refresh), onPressed: retry),
  urlRefresher: (expired) async => await api.refreshUrl(expired), // optional
);
```

## How it works
- Buckets by widget area / screen area (default S < 20%, M < 60%, L >= 60%; configurable via `bucketThresholds`, 2-4 ascending ratios). Target pixels are a share of physical screen pixels; images are never upscaled.
- Download once (retry with backoff; `urlRefresher` called on 401/403; 404/410 fail fast as `ImageNotFoundException`). Each needed bucket (L, M, S, down to the requested one) is encoded directly from the original download, so there is no generational quality loss (native WebP, pure Dart fallback). If only a larger bucket is cached, it is used as the source instead of downloading again.
- `ResponsiveImageView.lazy(cacheKey:..., urlResolver:...)` resolves the signed url only on a cache miss — cached content shows without ever calling the resolver (ideal for object-key workflows). The resolver doubles as the 401/403 refresher fallback.
- `showOriginalImage: true` fetches the untouched original (still behind skeleton and the best cached preview) instead of a bucket. It is stored as a single file — no variants produced — and later doubles as the highest-fidelity resize source for bucket requests.
- Disk cache per image and bucket; entries expire after 30 days from creation, oldest are evicted above 300MB. Signing query params (`X-Amz-*`, `Expires`, `Signature`, ...) are ignored in the cache key; override with `cacheKey`. A corrupt cached file is deleted and rebuilt automatically.
- A hub admits up to 6 images at a time (newest request first, identical requests deduplicated, queued ones dropped when widgets are disposed) but runs at most 2 resize/encode steps concurrently. Files already on disk are indexed at startup so rebuilt list items show instantly without a placeholder flash.

Limits: downloads over 30MB and images over 100 megapixels are rejected (`ImageTooLargeException`, never retried) before any heavy work. A failed image is not re-downloaded automatically for 60s; the `retry` callback in `errorBuilder` forces a reload.

```dart
// Optional, call once before the first image (e.g. in main()):
ResponsiveImageView.configure(
  maxDownloads: 6,        // concurrent download+process jobs
  maxProcessing: 2,       // concurrent resize/encode steps
  maxDownloadBytes: 30 * 1024 * 1024,
  maxAttempts: 3,           // tries per download; urlRefresher runs at most once each
  maxPixels: 100 * 1000 * 1000,
  quality: 80,            // WebP quality
  cacheMaxAge: Duration(days: 30),
  cacheMaxBytes: 300 * 1024 * 1024,
  bucketThresholds: [0.2, 0.6, 1.0], // 2-4 ascending ratios; XS preview fixed at 5%
);
```

Only static raster images plus SVG are supported. Raster images go through the bucket/resize pipeline; SVG is detected by content, cached as a single original file (no resize variants; it scales losslessly) and rendered with flutter_svg. Animated images (GIF, animated WebP) are reduced to their first frame.

Platforms: Android, iOS.

## Install (git)
```yaml
dependencies:
  responsive_image_view:
    git: https://github.com/baothg/responsive_image_view.git
```
