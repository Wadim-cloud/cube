package image_cache

import "core:os"
import "core:strings"
import "core:mem"
import "core:fmt"
import "core:time"
import "core:hash"

Cache_Entry :: struct {
    key:        string,
    data:       []byte,
    mime:       string,
    w:          int,
    h:          int,
    ts:         i64,
}

Image_Cache :: struct {
    mem:         map[string]Cache_Entry,
    dir:         string,
    max_mem:     int,
    used_mem:    int,
    hits:        u64,
    misses:      u64,
}

image_cache_init :: proc(dir: string, max_mem_mb: int) -> Image_Cache {
    os.make_directory_all(dir)
    return {
        mem = make(map[string]Cache_Entry),
        dir = dir,
        max_mem = max_mem_mb * 1024 * 1024,
        used_mem = 0,
    }
}

image_cache_key :: proc(orig_path: string, version: string, w: int, h: int, format_str: string, quality: int) -> string {
    raw := strings.concatenate([]string{orig_path, "_", version, "_", fmt.tprintf("%d_%d_", w, h), format_str, "_", fmt.tprintf("%d", quality)})
    h := hash.fnv32a(transmute([]byte)raw)
    return fmt.tprintf("%08x.bin", h)
}

now_ts :: proc() -> i64 {
    return time.time_to_unix(time.now())
}

image_cache_get :: proc(cache: ^Image_Cache, key: string, fallback_mime: string) -> ([]byte, string, bool) {
    entry, ok := cache.mem[key]
    if ok {
        entry.ts = now_ts()
        cache.mem[key] = entry
        cache.hits += 1
        return entry.data, entry.mime, true
    }
    disk_path := strings.join({cache.dir, key}, "/")
    if os.exists(disk_path) {
        data, rerr := os.read_entire_file_from_path(disk_path, context.allocator)
        if rerr == nil {
            cache.mem[key] = {key = key, data = data, mime = fallback_mime, ts = now_ts()}
            cache.used_mem += len(data)
            cache.hits += 1
            return data, fallback_mime, true
        }
    }
    cache.misses += 1
    return nil, "", false
}

image_cache_put :: proc(cache: ^Image_Cache, key: string, data: []byte, mime: string, w: int, h: int) {
    cache.mem[key] = Cache_Entry{key = key, data = data, mime = mime, w = w, h = h, ts = now_ts()}
    cache.used_mem += len(data)
    if cache.used_mem > cache.max_mem {
        lru_key := ""
        lru_ts: i64 = -1
        for k, v in cache.mem {
            if lru_ts < 0 || v.ts < lru_ts {
                lru_ts = v.ts
                lru_key = k
            }
        }
        if lru_key != "" {
            old := cache.mem[lru_key]
            cache.used_mem -= len(old.data)
            delete_key(&cache.mem, lru_key)
        }
    }
    disk_path := strings.join({cache.dir, key}, "/")
    os.make_directory_all(cache.dir)
    _ = os.write_entire_file(disk_path, data)
}

guess_mime :: proc(key: string) -> string {
    if strings.has_suffix(key, ".avif") { return "image/avif" }
    if strings.has_suffix(key, ".webp") { return "image/webp" }
    if strings.has_suffix(key, ".png")  { return "image/png" }
    if strings.has_suffix(key, ".jpg") || strings.has_suffix(key, ".jpeg") { return "image/jpeg" }
    return "application/octet-stream"
}