# Cube

Production-grade adaptive image optimization pipeline for Odin Hoster.

Transparently intercepts image requests, resizes, re-encodes, caches, and serves optimized variants — no application changes required.

## Architecture

```
Client
   │
   ▼
Odin Hoster (Cube)
   │
   ├── Image Detection (?w= / ?h= query params)
   ├── Cache Lookup (memory + disk)
   ├── Transform Pipeline (decode → resize → encode)
   ├── Background Job Queue (pre-generate common sizes)
   ├── Telemetry
   └── Cache Store
   │
   ▼
Caddy / Filesystem
```

## Features

### Image Pipeline
- Detects image paths with `?w=` or `?h=` query parameters
- Decodes images via stb_image (JPEG, PNG, WebP, AVIF, GIF first frame)
- Resizes to requested dimensions while maintaining aspect ratio
- Re-encodes as JPEG or PNG
- Skips optimization if output would be larger than input
- Skips resize if requested size exceeds original dimensions (no upscale by default)
- Safe fallback to original image on any failure

### Caching
- Two-tier cache: bounded memory LRU + persistent disk cache
- Cache key includes original path, file version (mtime + size), width, height, format, and quality
- Original file changes automatically invalidate all derived variants
- Disk cache survives restarts

### Background Generation
- After serving a request, queues background jobs for other common sizes
- Pre-generates 400, 800, 1200, 1600 widths in JPEG and PNG
- Subsequent requests for these sizes hit cache immediately

### Browser Format Negotiation
- Respects `Accept` header for preferred format
- Decision order: AVIF → WebP → JPEG → PNG
- Falls back gracefully when encoders are unavailable

### Telemetry & Dashboard
- Tracks request metrics, cache hit/miss, compression ratios
- Aggregate dashboard at `/telemetry` with:
  - Total images served
  - Bandwidth saved
  - Cache hit rate
  - Recent requests with format/size breakdown

### Configuration
- Hot-reloadable via inotify or SIGHUP
- Stored in `cube.toml`

## Installation

```bash
git clone https://github.com/Wadim-cloud/cube.git
cd cube
odin build ./cmd/cube/
```

## Configuration

Edit `cube.toml`:

```toml
# Root directory for served files
root = "/home/ds/dev/microfolio-odin/dist"

# Server settings
max_connections = 1024
cache_enabled = true
cache_max_mb = 32
cache_max_file_kb = 256
log_level = 1

# Image pipeline
img_enabled = true
img_cache_dir = "/home/ds/dev/cube/cache/images"
img_max_mem_mb = 128
img_quality = 85
img_max_width = 3840
img_max_height = 2160
img_max_input = 10485760  # 10MB
```

### Config Options

| Option | Description | Default |
|--------|-------------|---------|
| `root` | Root directory for static files | required |
| `max_connections` | Max concurrent connections | 1024 |
| `cache_enabled` | Enable HTTP cache | true |
| `cache_max_mb` | HTTP cache size in MB | 32 |
| `cache_max_file_kb` | Max file size for HTTP cache (KB) | 256 |
| `log_level` | 0=error, 1=info, 2=debug, 3=trace | 1 |
| `img_enabled` | Enable image optimization pipeline | false |
| `img_cache_dir` | Disk cache directory for optimized images | `./cache/images` |
| `img_max_mem_mb` | Memory cache budget for image cache | 128 |
| `img_quality` | JPEG/WebP quality (1-100) | 85 |
| `img_max_width` | Maximum resize width | 3840 |
| `img_max_height` | Maximum resize height | 2160 |
| `img_max_input` | Maximum input file size (bytes) | 10485760 |

## Usage

### Image Resize Requests

Request a resized version by adding query parameters:

```
GET /path/to/image.jpg?w=400
GET /path/to/image.jpg?h=300
GET /path/to/image.jpg?w=400&h=300
GET /path/to/image.jpg?w=400&format=webp
GET /path/to/image.jpg?w=400&quality=90
```

On first request, Cube decodes, resizes, encodes, and caches the result. Subsequent requests for the same variant are served from cache.

### Responsive Images (srcset)

The microfolio-odin site generator emits `srcset` attributes for listing thumbnails:

```html
<img 
  src="/projects/foo/images/bar.jpg?w=400"
  srcset="/projects/foo/images/bar.jpg?w=400 400w,
          /projects/foo/images/bar.jpg?w=800 800w,
          /projects/foo/images/bar.jpg?w=1200 1200w,
          /projects/foo/images/bar.jpg?w=1600 1600w"
  sizes="(max-width: 768px) 400px, (max-width: 1200px) 800px, 1200px"
  alt="Project title"
>
```

### Dashboard

Access telemetry at:

```
GET /telemetry
```

Returns JSON with:
- `total_served`: number of optimized images served
- `total_original_bytes`: sum of original file sizes
- `total_optimized_bytes`: sum of delivered file sizes
- `bandwidth_saved_bytes`: bytes saved via optimization
- `savings_pct`: percentage of bandwidth saved
- `cache_hit_rate_pct`: percentage of requests served from cache
- `cache_hits`: number of cache hits
- `recent`: last 20 image requests with details

### Control Plane

Cube includes a control plane for remote management:

```
POST /_cube/config
GET /_cube/status
```

## Pipeline Behavior

### Skip Rules
- If encoded output is larger than original input → serves original
- If requested size exceeds original dimensions → serves original (no upscale)
- If requested size exceeds configured max width/height → serves original
- If input file exceeds `img_max_input` → serves original
- If decode or encode fails → serves original

### Cache Invalidation
Any change to the original file (mtime or size) produces a new version identifier, automatically invalidating all previously cached variants.

### Supported Input Formats
- JPEG
- PNG
- WebP
- AVIF
- GIF (first frame only)

### Supported Output Formats
- JPEG (default when browser accepts any image)
- PNG (fallback when JPEG not suitable)
- WebP (planned, requires libwebp)
- AVIF (planned, requires libavif)

## Storage Backend

The `storage` package (`core/storage/storage.odin`) provides an abstraction layer for cache storage:

```odin
import "../storage"

backend := storage.storage_init("/home/ds/dev/cube/cache/images")

// Store
ok := storage.storage_put(&backend, key, data)

// Retrieve
data, found := storage.storage_get(&backend, key)

// Check existence
exists := storage.storage_exists(&backend, key)

// Delete
deleted := storage.storage_delete(&backend, key)
```

Currently implements local filesystem backend. Designed for future S3/GCS/Azure backends.

## API

### Image Cache API

```odin
import "../image_cache"

// Initialize cache
cache := image_cache.image_cache_init(dir, max_mem_mb)

// Lookup
data, mime, hit := image_cache.image_cache_get(&cache, key, fallback_mime)

// Store
image_cache.image_cache_put(&cache, key, data, mime, width, height)

// Generate cache key
key := image_cache.image_cache_key(orig_path, version, w, h, format, quality)
```

### Image Pipeline API

```odin
import "../cube_image"

// Load image
img, ok := cube_image.load_from_file("path/to/image.jpg")

// Resize
resized := cube_image.resize(img, new_width, new_height, channels)

// Encode
jpeg_data := cube_image.encode_jpeg(img, quality)
png_data := cube_image.encode_png(img)

// Free
cube_image.image_free(img)
```

### Telemetry API

```odin
record_image_metric(path, orig_bytes, out_bytes, format, width, height, cached)
```

Records per-request image metrics into the global telemetry ring buffer.

## Success Criteria

| Criterion | Status |
|-----------|--------|
| Transparent optimization without app changes | ✅ |
| Resize on demand (`?w=`/`?h=`) | ✅ |
| Memory + disk cache | ✅ |
| Cache invalidation on original change | ✅ |
| Skip if output > input | ✅ |
| No upscale by default | ✅ |
| Safe fallback to original | ✅ |
| Config parsing for `[images]` | ✅ |
| Dashboard with aggregate metrics | ✅ |
| Background pre-generation | ✅ |
| Storage abstraction | ✅ |
| AVIF/WebP output | ❌ Requires libwebp/libavif |
| Browser Accept negotiation | ⚠️ Falls back to JPEG |

## License

MIT
