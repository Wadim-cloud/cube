# Building a Self-Hosted Image Optimization Pipeline in Odin

## The Problem

I run a portfolio site with a lot of large images. A single page load would pull down 6MB+ of raw JPEGs from drone photography and 3D renders. There was no resizing, no format negotiation, no caching — just raw files served through Caddy. Page load times were brutal, especially on mobile.

I wanted transparent, zero-config image optimization that sits in front of Caddy and requires zero changes to the application. No Ruby modules, no nginx config hacks, no external CDN. Just a self-contained binary that intercepts image requests and does the right thing.

So I built **Cube**.

## What Cube Does

Cube is a standalone HTTP server written in [Odin](https://odin-lang.org/) that sits between Caddy and your static files. When a browser requests:

```
GET /projects/foo/images/bar.jpg?w=400
```

Cube detects the `?w=400` query parameter, checks its cache (memory first, then disk), and on a cache miss:

1. Reads the original file from disk
2. Decodes it with `stb_image`
3. Resizes it maintaining aspect ratio
4. Re-encodes as JPEG or PNG
5. Stores the result in both memory and disk cache
6. Returns the optimized image

The original file path stays the same. The application doesn't need to change anything. The first request pays the transformation cost; all subsequent requests are served from cache.

## Architecture

```
Browser
   │
   ▼
Caddy (TLS / reverse proxy)
   │
   ▼
Cube (port 3050)
   │
   ├── Image Detection (?w= / ?h=)
   ├── Cache Lookup (memory LRU + disk)
   ├── Transform Pipeline (decode → resize → encode)
   ├── Background Job Queue (pre-generate common sizes)
   └── Telemetry Dashboard
   │
   ▼
Static file root (microfolio-odin dist/)
```

Cube has a compiled routing graph — on startup, routes are resolved to a prefix tree, so every request is a zero-allocation prefix check followed by a direct function call. No runtime string parsing of the route table.

## Worker Model

Cube spawns N worker threads (default 4, max 64). Each worker owns:

- A 10MB arena allocator, reset after every request — no malloc per request
- A 64KB receive buffer
- An independent accept loop

Active connections are counted atomically. If a worker sees `active > max_connections`, it immediately returns `503 Service Unavailable`. This is the entire backpressure mechanism — no queuing, no latency spikes. The server sheds load cleanly when saturated.

## The Adaptive Runtime

A dedicated background thread runs every second and samples telemetry counters:

- **High cache miss rate (>80%)** → raises `cache_max_file` up to 2MB so larger files get cached
- **P99 latency spike (>100ms)** → reduces `max_connections` by 25% to shed load
- **Connection utilization >90%** → raises `cache_max_file` up to 4MB for sustained high-load scenarios

Every adjustment is timestamped and reason-logged to a ring buffer. The internal event bus publishes metrics snapshots for the dashboard.

## Background Pre-Generation

On every cache miss, after serving the requested variant, Cube enqueues background jobs for the same image at other common widths — 400, 800, 1200, 1600 — in both JPEG and PNG. A dedicated worker thread pulls from a 4096-slot MPSC queue and pre-generates those variants. When a browser later requests one of those sizes, it's already cached.

This matters for responsive images. The portfolio site emits a `srcset` attribute:

```html
<img
  src="/projects/foo/images/bar.jpg?w=400"
  srcset="/projects/foo/images/bar.jpg?w=400 400w,
          /projects/foo/images/bar.jpg?w=800 800w,
          /projects/foo/images/bar.jpg?w=1200 1200w,
          /projects/foo/images/bar.jpg?w=1600 1600w"
  sizes="(max-width: 768px) 400px, (max-width: 1200px) 800px, 1200px"
>
```

The browser picks the optimal size for the viewport. The first visitor to each size pays the transformation cost; everyone else gets a cache hit.

## Cache Design

The cache key is an FNV-32a hash of:

```
original_path + "_" + mtime + "_" + size + "_" + width + "_" + height + "_" + format + "_" + quality
```

This means any change to the original file (mtime or size change) automatically invalidates all derived variants. The next request for `?w=400` will miss cache, re-transform the new original, and store a fresh variant.

The memory cache is bounded — when it exceeds `img_max_mem_mb`, the least-recently-used entry is evicted. Every store also writes to disk, so optimized variants survive restarts.

## Telemetry Dashboard

Every image optimization is recorded into a 256-slot ring buffer with:

- Original path, original bytes, output bytes
- Output format and dimensions
- Cache hit/miss flag
- Timestamp

The dashboard at `/_cube/images` returns JSON with:

- Total images served
- Bandwidth saved and compression percentage
- Cache hit rate
- Last 20 requests with per-entry formatting

Visitor tracking records page views into a separate ring with IP, referrer, user agent, and timestamp. The endpoint `/_cube/visits` returns weekly and all-time path statistics plus recent visitor entries.

## Safety Rules

Cube is designed to never fail a request because optimization failed:

- If decode fails → serve original
- If resize fails → serve original
- If encode fails → serve original
- If output is larger than input → serve original
- If requested size exceeds original dimensions → serve original (no upscale)
- If file exceeds `img_max_input` → serve original

In all these cases, the original file is served as-is through the normal static file handler.

## Performance

On the live portfolio site, the first request for a 64KB PNG thumbnail at 400px wide:

- Decode: stb_image reads the 64KB PNG in ~2ms
- Resize: stb_image_resize scales 1100×471 → 400×171 in ~1ms
- Encode: stb_image_write outputs JPEG at quality 85 in ~1ms
- Total transform: ~4ms

Result: 14,387 bytes (77.7% reduction). The second request for the same size hits memory cache and returns in under 1ms.

The DJI aerial photographs are larger — a 6.7MB JPG at `?w=1200` takes ~250ms on cold miss. The background job queue pre-generates 800/1600 variants immediately after, so subsequent requests for those sizes are instant.

## What's Built vs. Spec

| Feature | Status |
|---------|--------|
| Transparent `?w=`/`?h=` interception | ✅ |
| JPEG/PNG encode | ✅ |
| Memory + disk cache | ✅ |
| Cache invalidation on original change | ✅ |
| Skip if output > input | ✅ |
| No upscale by default | ✅ |
| Background pre-generation | ✅ |
| Dashboard telemetry | ✅ |
| Storage abstraction (local now, S3 later) | ✅ |
| Browser Accept negotiation (AVIF→WebP→JPEG) | ⚠️ Falls back to JPEG; WebP/AVIF blocked by missing system libs |
| Responsive srcset generation | ✅ Done in the portfolio site generator |

## What's Next

The codebase is structured for incremental improvement:

- **WebP support**: `libwebp-devel` needs to be installed on the build machine and the C wrapper extended
- **AVIF support**: Requires `libavif` — the decision tree is already in place, just needs an encoder
- **Animated formats**: GIF/WebP/AVIF animation would need a frame-decoding pipeline
- **Object storage**: The `core/storage` package has an interface; S3/GCS backends are a few function implementations away

The repo is at [github.com/Wadim-cloud/cube](https://github.com/Wadim-cloud/cube).

## Why Odin?

Odin's C interoperability made this straightforward. The entire image pipeline is a thin Odin wrapper around `stb_image`, `stb_image_resize`, and `stb_image_write` — three single-header C libraries. The worker pool, arena allocator, and routing graph are pure Odin. The result is a single static binary with zero runtime dependencies.

For a personal Infrastructure project, that's the right tradeoff. No Go toolchain, no Python virtualenv, no Node modules. Just `odin build ./cmd/cube/` and a 800KB binary.

---

*Cube is part of a broader self-hosted Odin Hoster stack that includes Caddy for TLS and microfolio-odin for site generation. The pipeline is live at [dev.wadiem.cloudns.be](https://dev.wadiem.cloudns.be).*
