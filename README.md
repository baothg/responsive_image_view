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
- Download once (retry with backoff; `urlRefresher` called on 401/403/404/410), then resize L -> M -> S lazily down to the needed bucket (native WebP, pure Dart fallback).
- Disk cache per image and bucket; entries expire after 30 days from creation, oldest are evicted above 300MB. Signing query params (`X-Amz-*`, `Expires`, `Signature`, ...) are ignored in the cache key; override with `cacheKey`.
- A hub runs at most 3 images at a time, newest request first, deduplicating identical requests and dropping queued ones when widgets are disposed.

Platforms: Android, iOS.

## Install (git)
```yaml
dependencies:
  responsive_image_view:
    git: https://github.com/baothg/responsive_image.git
```
