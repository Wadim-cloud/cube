# Cube

Production-grade adaptive image optimization pipeline.

Cube is a standalone HTTP server written in Odin that sits in front of Caddy (or any reverse proxy) and transparently optimizes images on-the-fly. It is designed to be used as part of **Odin Hoster**, a larger self-hosted platform, but works independently for any static site.

## What is Odin Hoster?

**Odin Hoster** is the broader hosting platform that Cube is built for. It is a self-contained, high-performance static site hosting stack written in Odin, which includes:

- **Cube** — the image optimization layer (this repository)
- **Caddy** — reverse proxy / TLS termination
- **microfolio-odin** — the portfolio site generator that produces the HTML/CSS/JS served through the stack

Odin Hoster’s design goal is to give you a fully self-hosted, zero-config, high-performance personal site / portfolio platform. Cube is the image optimization module within that stack.

## How Cube Fits Into Odin Hoster

```
┌─────────────┐
│   Browser   │
└──────┬──────┘
       │
       ▼
┌─────────────────────────────────────────┐
│             Caddy (TLS)                 │
└──────┬──────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────┐
│              Cube                       │
│  ┌─────────────────────────────────┐   │
│  │  Image Detection (?w= / ?h=)   │   │
│  ├─────────────────────────────────┤   │
│  │  Cache Lookup (memory + disk)   │   │
│  ├─────────────────────────────────┤   │
│  │  Transform Pipeline             │   │
│  │  decode → resize → encode       │   │
│  ├─────────────────────────────────┤   │
│  │  Background Job Queue           │   │
│  │  (pre-generate common sizes)    │   │
│  ├─────────────────────────────────┤   │
│  │  Telemetry                      │   │
│  └─────────────────────────────────┘   │
└──────┬──────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────┐
│  microfolio-odin static files (dist/)   │
└─────────────────────────────────────────┘
```

When a browser requests `/projects/foo/images/bar.jpg?w=400`:

1. Caddy forwards the request to Cube
2. Cube detects the `?w=400` query parameter
3. Cube checks its cache (memory first, then disk)
4. On cache miss: Cube decodes the original image from disk, resizes it, encodes it as JPEG/PNG, and stores the result
5. Cube returns the optimized image to Caddy, which forwards it to the browser
6. In the background, Cube queues jobs to pre-generate other common sizes (800, 1200, 1600) so future requests are instant

## Architecture

```
Client
   │
   ▼
Odin Hoster
   │
   ├── Caddy (reverse proxy / TLS)
   │
   ▼
Cube (this repository)
   │
   ├── Image Detection (?w= / ?h= query params)
   ├── Cache Lookup (memory + disk)
   ├── Transform Pipeline (decode → resize → encode)
   ├── Background Job Queue (pre-generate common sizes)
   ├── Telemetry
   └── Cache Store
   │
   ▼
Static File Root (microfolio-odin dist/)
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

## Internals

### Workers

Cube uses a multi-threaded worker pool. On startup, the main thread spawns N worker threads (default: 4, max: 64). Each worker runs an independent event loop:

1. `net.accept_tcp` — accept a connection
2. Check backpressure limits
3. Read request buffer (64KB per worker)
4. Parse HTTP request
5. If the path is an image with `?w=` / `?h=` params, route to `serve_image`
6. Otherwise, resolve via the routing graph and invoke the handler
7. Track per-worker stats (requests handled, bytes sent, arena peak)
8. Close connection and loop

Arena allocation: each worker owns a 10MB arena that is reset after every request, giving cache-friendly sequential allocation without per-request malloc overhead.

### Backpressure

Active connections are counted atomically. If active connections exceed `max_connections`, new connections are immediately rejected with `503 Service Unavailable` instead of queued. This keeps latency bounded under load and prevents memory exhaustion.

The configured `max_connections` can also be adjusted by the adaptive runtime.

### Adaptive Runtime

A dedicated background thread runs every `check_interval` (default: 1s). It samples telemetry counters and applies self-tuning rules:

- **High cache miss rate (>80%)**: raises `cache_max_file` up to 2MB to cache larger files.
- **P99 latency spike (>100ms)**: reduces `max_connections` by 25% to shed load.
- **Sustained high load (connection utilization >90%)**: raises `cache_max_file` up to 4MB to improve hit rate.

Adjustments are logged to an `Adjustment_Log` ring buffer and published via the internal event bus for the dashboard.

### Background Image Jobs

On every cache miss, after serving the requested variant, Cube enqueues background jobs for the same image at other common sizes (400, 800, 1200, 1600) in JPEG and PNG. A dedicated background worker thread pulls from a 4096-slot MPSC queue and pre-generates those variants. When a browser later requests one of those sizes, it is already in the disk/memory cache.

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

## Experimental Runtime

`core/runtime/worker.odin` contains an experimental per-core worker runtime built on Odin's `core:nbio` event loop. It is **not currently used** by the main server path.

The experimental design goals were:
- One event loop per worker thread via `nbio.acquire_thread_event_loop`
- Isolated arena per worker, reset after each request
- Zero runtime string lookup via the compiled execution graph
- Inline request handling on the worker's own thread

The current production server uses a simpler acceptor-per-worker thread model in `cmd/cube/main.odin` (`worker_run`), which proved more reliable and easier to reason about. The experimental runtime is preserved for future migration once nbio matures.

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
