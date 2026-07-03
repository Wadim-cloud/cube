package main

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "core:sync"
import "../../core/image_jobs"
import "../../core/storage"

import "../../core/cube_image"
import "../../core/image_cache"
import "../../core/pipeline"
import "core:sys/posix"
import "core:sys/linux"

import "../../internal/eventbus"
import "core:thread"

// ============================================================
// TYPES — HTTP
// ============================================================

Request :: struct {
    method:       []byte,
    path:         []byte,
    headers:      [32]Header,
    header_count: int,
    buf:          []byte,
    body_start:   int, // offset into buf where body begins
    body_len:     int,
}

Header :: struct {
    key:     [64]byte,
    key_len: int,
    val:     [256]byte,
    val_len: int,
}

Response :: struct {
    sock: net.TCP_Socket,
    sent: bool,
}

RequestContext :: struct {
    req:       Request,
    resp:      Response,
    trace_idx: int, // index into trace ring for this request
}

// ============================================================
// TYPES — TELEMETRY (Layer ①)
// ============================================================

Telemetry_Path_Counter :: struct {
    path:  [128]byte,
    len:   int,
    count: int,
}

Visitor_Entry :: struct {
    path:     [128]byte,
    path_len: int,
    ip:       [64]byte,
    ip_len:   int,
    referrer: [256]byte,
    ref_len:  int,
    ua:       [128]byte,
    ua_len:   int,
    ts:       time.Time,
}

Telemetry :: struct {
    total_requests:   u64,
    total_bytes_sent: u64,
    total_404s:       u64,
    total_500s:       u64,
    total_304s:       u64,
    total_206s:       u64,
    start_time:       time.Time,

    mutex:       sync.Mutex,
    path_visits: [256]Telemetry_Path_Counter,
    path_count:  int,

    week_start:     time.Time,
    week_hits:      u64,
    week_paths:     [128][128]byte,
    week_path_lens: [128]int,
    week_path_count: int,

    visitors:       [256]Visitor_Entry,
    visitor_head:   u64,
}

global_telemetry: Telemetry

// ============================================================
// TYPES — TRACING (Layer ②)
// ============================================================

Trace_Entry :: struct {
    trace_id:   u64,
    worker_id:  int,
    path:       [128]byte,
    path_len:   int,
    method:     [8]byte,
    method_len: int,
    status:     u16,
    t_accept:   time.Time,
    t_parsed:   time.Time,
    t_routed:   time.Time,
    t_done:     time.Time,
    bytes_sent: int,
    cached:     bool,
}

TRACE_RING_SIZE :: 1024

Trace_Ring :: struct {
    entries: [TRACE_RING_SIZE]Trace_Entry,
    head:    u64, // atomic write cursor (monotonic)
}

global_traces:        Trace_Ring
global_trace_counter: u64

Image_Metric :: struct {
    path:     [128]byte,
    path_len: int,
    orig_bytes: int,
    out_bytes:  int,
    fmt:       [8]byte,
    fmt_len:   int,
    w:         int,
    h:         int,
    cached:    bool,
    ts:        time.Time,
}

// ============================================================
// TYPES — BACKPRESSURE (Layer ③)
// ============================================================

Backpressure :: struct {
    active_connections: i64,
    max_connections:    i64,
    total_rejected:     u64,
}

global_backpressure: Backpressure

// ============================================================
// TYPES — CACHE (Layer ④)
// ============================================================

CACHE_MAX_ENTRIES :: 128
CACHE_POOL_SIZE   :: 32 * 1024 * 1024 // 32MB

Cache_Entry :: struct {
    path:      [256]byte,
    path_len:  int,
    data_off:  int,       // offset into pool
    data_len:  int,
    mime:      [64]byte,
    mime_len:  int,
    mtime:     i64,
    last_used: time.Time,
    hits:      u64,
    valid:     bool,
}

Cache :: struct {
    entries:    [CACHE_MAX_ENTRIES]Cache_Entry,
    count:      int,
    pool:       []byte,
    pool_used:  int,
    mutex:      sync.Mutex,
    enabled:    bool,
    max_file:   int,  // max cacheable file size (bytes)
    total_hits: u64,
    total_miss: u64,
}

global_cache: Cache
global_image_cache: image_cache.Image_Cache
global_image_metrics: [256]Image_Metric
global_image_metric_head: u64

// ============================================================
// TYPES — CONFIG (Layer ⑥)
// ============================================================

Config :: struct {
    root_dir:        [256]byte,
    root_dir_len:    int,
    max_connections: i64,
    cache_enabled:   bool,
    cache_max_mb:    int,
    cache_max_file:  int, // bytes
    log_level:       int, // 0=error, 1=info, 2=debug, 3=trace

    img_enabled:     bool,
    img_cache_dir:   [256]byte,
    img_cache_dir_len: int,
    img_max_mem_mb:  int,
    img_quality:     int,
    img_max_width:   int,
    img_max_height:  int,
    img_max_input:   int, // bytes
}

global_config:         Config
config_mutex:          sync.RW_Mutex
config_version:        u64
config_path:           [256]byte
config_path_len:       int

// ============================================================
// TYPES — WORKER STATS (Layer ⑦)
// ============================================================

Worker_Stats :: struct {
    requests_handled: u64,
    bytes_sent:       u64,
    arena_peak:       int,
    last_request:     time.Time,
}

MAX_WORKERS :: 64
global_worker_stats: [MAX_WORKERS]Worker_Stats

// ============================================================
// TYPES — ADAPTIVE (Layer ⑧)
// ============================================================

Adjustment_Log :: struct {
    timestamp:  time.Time,
    field:      [32]byte,
    field_len:  int,
    old_value:  i64,
    new_value:  i64,
    reason:     [64]byte,
    reason_len: int,
}

Adaptive :: struct {
    enabled:        bool,
    check_interval: time.Duration,
    last_check:     time.Time,

    prev_requests:  u64,
    prev_cache_hits: u64,
    prev_cache_miss: u64,
    prev_404s:      u64,

    rps:            f64,
    cache_hit_rate: f64,
    error_rate:     f64,
    p99_latency_us: f64,

    adjustments:    [64]Adjustment_Log,
    adj_count:      int,
    adj_mutex:      sync.Mutex,
}

global_adaptive: Adaptive

// ============================================================
// EXECUTION GRAPH
// ============================================================

HttpHandler :: proc(ctx: ^RequestContext, g: ^Graph)

Graph_Node :: struct {
    prefix:  string,
    handler: HttpHandler,
}

Graph :: struct {
    nodes: [32]Graph_Node,
    count: int,
}

graph_init :: proc(g: ^Graph) {
    g.count = 0
}

graph_add :: proc(g: ^Graph, prefix: string, handler: HttpHandler) {
    if g.count >= len(g.nodes) {
        return
    }
    g.nodes[g.count] = Graph_Node{prefix = prefix, handler = handler}
    g.count += 1
}

graph_resolve :: proc(g: ^Graph, path: string) -> (HttpHandler, bool) {
    best_len := 0
    best_handler: HttpHandler = nil
    found := false
    for i := 0; i < g.count; i += 1 {
        n := &g.nodes[i]
        if strings.has_prefix(path, n.prefix) {
            plen := len(n.prefix)
            if plen >= best_len {
                best_len = plen
                best_handler = n.handler
                found = true
            }
        }
    }
    return best_handler, found
}

// ============================================================
// PARSER
// ============================================================

parse_request :: proc(data: []byte) -> (req: Request, ok: bool) {
    ok = true
    req.buf = slice.clone(data)
    if req.buf == nil {
        return req, false
    }
    header_end := -1
    for i := 0; i < len(req.buf) - 3; i += 1 {
        if req.buf[i] == '\r' && req.buf[i+1] == '\n' && req.buf[i+2] == '\r' && req.buf[i+3] == '\n' {
            header_end = i
            break
        }
    }
    if header_end == -1 {
        return req, false
    }

    // Body starts after \r\n\r\n
    req.body_start = header_end + 4
    req.body_len = len(req.buf) - req.body_start
    if req.body_len < 0 { req.body_len = 0 }

    header_block := req.buf[:header_end]
    line_end := -1
    for i := 0; i < len(header_block); i += 1 {
        if header_block[i] == '\r' {
            line_end = i
            break
        }
    }
    if line_end == -1 {
        return req, false
    }
    request_line := header_block[:line_end]
    parts := strings.fields(string(request_line))
    if len(parts) < 2 {
        return req, false
    }
    req.method = str_to_bytes(parts[0])
    req.path = str_to_bytes(parts[1])
    header_lines := header_block[line_end+2:]
    req.header_count = 0
    for req.header_count < len(req.headers) {
        nl := -1
        for i := 0; i < len(header_lines); i += 1 {
            if header_lines[i] == '\r' {
                nl = i
                break
            }
        }
        if nl == -1 {
            break
        }
        line := header_lines[:nl]
        colon := -1
        for i := 0; i < len(line); i += 1 {
            if line[i] == ':' {
                colon = i
                break
            }
        }
        if colon != -1 && req.header_count < len(req.headers) {
            h := &req.headers[req.header_count]
            klen := min(colon, int(size_of(h.key)) - 1)
            // Skip leading space in value
            val_start := colon + 1
            if val_start < len(line) && line[val_start] == ' ' {
                val_start += 1
            }
            vlen := min(len(line) - val_start, int(size_of(h.val)) - 1)
            for i := 0; i < klen; i += 1 { h.key[i] = line[i] }
            h.key_len = klen
            for i := 0; i < vlen; i += 1 { h.val[i] = line[val_start + i] }
            h.val_len = vlen
            req.header_count += 1
        }
        if len(header_lines) > nl + 2 {
            header_lines = header_lines[nl+2:]
        } else {
            break
        }
    }
    return req, true
}

// Find a header value by key (case-insensitive)
find_header :: proc(req: ^Request, name: string) -> (string, bool) {
    for i := 0; i < req.header_count; i += 1 {
        h := &req.headers[i]
        k := string(h.key[:h.key_len])
        if strings.equal_fold(k, name) {
            return string(h.val[:h.val_len]), true
        }
    }
    return "", false
}

// ============================================================
// HANDLERS — STATIC FILES
// ============================================================

root_dir: string = "/home/ds/Documents/Dev/dist"

serve_static_handler :: proc(ctx: ^RequestContext, g: ^Graph) {
    _ = g
    req_path := string(ctx.req.path)
    if qs := strings.index(req_path, "?"); qs != -1 {
        req_path = req_path[:qs]
    }
    if !strings.has_prefix(req_path, "/") {
        write_response(&ctx.resp, 400, "text/plain", str_to_bytes("Bad Request"))
        return
    }
    rel := req_path
    if rel == "/" {
        rel = "/index.html"
    }

    // Read root_dir from config with read lock
    rd := get_root_dir()
    abs := fmt.tprintf("%s%s", rd, rel)
    if !strings.has_prefix(abs, rd) {
        write_response(&ctx.resp, 403, "text/plain", str_to_bytes("Forbidden"))
        return
    }
    if os.is_file(abs) {
        send_file_with_cache(&ctx.req, &ctx.resp, abs)
        return
    }
    if os.is_directory(abs) {
        idx := abs
        if strings.has_suffix(abs, "/") {
            idx = fmt.tprintf("%sindex.html", abs)
        } else {
            idx = fmt.tprintf("%s/index.html", abs)
        }
        if os.is_file(idx) {
            send_file_with_cache(&ctx.req, &ctx.resp, idx)
            return
        }
    }
    write_response(&ctx.resp, 404, "text/html", str_to_bytes("<html><body><h1>404 Not Found</h1></body></html>"))
}

// ============================================================
// HANDLERS — PROXY
// ============================================================

serve_proxy_handler :: proc(ctx: ^RequestContext, g: ^Graph) {
    _ = g
    req_path := string(ctx.req.path)
    backend_path := req_path
    if strings.has_prefix(backend_path, "/zerophone/") {
        backend_path = backend_path[len("/zerophone/"):]
        if backend_path == "" {
            backend_path = "/"
        }
    }
    ep, ok := net.parse_endpoint("127.0.0.1:9443")
    if !ok {
        write_response(&ctx.resp, 502, "text/html", str_to_bytes("<html><body><h1>502 Bad Gateway</h1></body></html>"))
        return
    }
    backend, berr := net.dial_tcp_from_endpoint(ep)
    if berr != nil {
        write_response(&ctx.resp, 502, "text/html", str_to_bytes("<html><body><h1>502 Bad Gateway</h1></body></html>"))
        return
    }

    b: strings.Builder
    strings.builder_init(&b)
    fmt.sbprintf(&b, "%s %s HTTP/1.1\r\n", string(ctx.req.method), backend_path)
    for i := 0; i < ctx.req.header_count; i += 1 {
        h := &ctx.req.headers[i]
        k := string(h.key[:h.key_len])
        if strings.equal_fold(k, "host") {
            continue
        }
        fmt.sbprintf(&b, "%s: %s\r\n", k, string(h.val[:h.val_len]))
    }
    strings.write_string(&b, "Connection: close\r\n\r\n")

    _, send_err := net.send_tcp(backend, transmute([]byte)strings.to_string(b))
    if send_err != nil {
        write_response(&ctx.resp, 502, "text/html", str_to_bytes("<html><body><h1>502 Bad Gateway</h1></body></html>"))
        net.close(backend)
        return
    }

    resp_buf: [65536]byte
    for {
        n, rerr := net.recv_tcp(backend, resp_buf[:])
        if rerr != nil || n == 0 {
            break
        }
        _, serr := net.send_tcp(ctx.resp.sock, resp_buf[:n])
        if serr != nil {
            break
        }
    }
    ctx.resp.sent = true
    net.close(backend)
}

// ============================================================
// TELEMETRY — RECORDING (Layer ①)
// ============================================================

record_visit :: proc(path: string, ip: string, referrer: string, ua: string) {
    if len(path) == 0 || len(path) >= 128 {
        return
    }
    if strings.has_prefix(path, "/_cube/") {
        return
    }
    if strings.contains(path, ".") {
        if !strings.has_suffix(path, ".html") {
            return
        }
    }
    sync.mutex_lock(&global_telemetry.mutex)
    defer sync.mutex_unlock(&global_telemetry.mutex)

    // --- path counter (all-time) ---
    found := false
    for i := 0; i < global_telemetry.path_count; i += 1 {
        item := &global_telemetry.path_visits[i]
        item_str := string(item.path[:item.len])
        if item_str == path {
            item.count += 1
            found = true
            break
        }
    }
    if !found && global_telemetry.path_count < len(global_telemetry.path_visits) {
        item := &global_telemetry.path_visits[global_telemetry.path_count]
        copy(item.path[:], transmute([]byte)path)
        item.len = len(path)
        item.count = 1
        global_telemetry.path_count += 1
    }

    // --- week counter ---
    now := time.now()
    if time.diff(global_telemetry.week_start, now) > 7 * 24 * time.Hour {
        global_telemetry.week_start = now
        global_telemetry.week_hits = 0
        global_telemetry.week_path_count = 0
        for i := 0; i < len(global_telemetry.week_paths); i += 1 {
            global_telemetry.week_paths[i] = [128]byte{}
        }
    }
    global_telemetry.week_hits += 1
    found = false
    for i := 0; i < global_telemetry.week_path_count; i += 1 {
        if string(global_telemetry.week_paths[i][:global_telemetry.week_path_lens[i]]) == path {
            found = true
            break
        }
    }
    if !found && global_telemetry.week_path_count < len(global_telemetry.week_paths) {
        copy(global_telemetry.week_paths[global_telemetry.week_path_count][:], transmute([]byte)path)
        global_telemetry.week_path_lens[global_telemetry.week_path_count] = len(path)
        global_telemetry.week_path_count += 1
    }

    // --- visitor ring ---
    head := sync.atomic_add(&global_telemetry.visitor_head, 1)
    slot := int(head % u64(len(global_telemetry.visitors)))
    v := &global_telemetry.visitors[slot]
    copy(v.path[:], transmute([]byte)path)
    v.path_len = len(path)
    iplen := min(len(ip), 63)
    copy(v.ip[:iplen], transmute([]byte)ip[:iplen])
    v.ip_len = iplen
    reflen := min(len(referrer), 255)
    copy(v.referrer[:reflen], transmute([]byte)referrer[:reflen])
    v.ref_len = reflen
    ualen := min(len(ua), 127)
    copy(v.ua[:ualen], transmute([]byte)ua[:ualen])
    v.ua_len = ualen
    v.ts = now
}

// ============================================================
// TRACING — RECORDING (Layer ②)
// ============================================================

trace_begin :: proc(worker_id: int) -> int {
    id := sync.atomic_add(&global_trace_counter, 1)
    idx := int(id % TRACE_RING_SIZE)
    e := &global_traces.entries[idx]
    e.trace_id = id
    e.worker_id = worker_id
    e.t_accept = time.now()
    e.status = 0
    e.bytes_sent = 0
    e.cached = false
    e.path_len = 0
    e.method_len = 0
    return idx
}

trace_set_request :: proc(idx: int, req: ^Request) {
    e := &global_traces.entries[idx]
    plen := min(len(req.path), 128)
    for i := 0; i < plen; i += 1 { e.path[i] = req.path[i] }
    e.path_len = plen
    mlen := min(len(req.method), 8)
    for i := 0; i < mlen; i += 1 { e.method[i] = req.method[i] }
    e.method_len = mlen
    e.t_parsed = time.now()
}

trace_set_routed :: proc(idx: int) {
    global_traces.entries[idx].t_routed = time.now()
}

trace_finish :: proc(idx: int, status: u16, bytes_sent: int, cached: bool) {
    e := &global_traces.entries[idx]
    e.status = status
    e.bytes_sent = bytes_sent
    e.cached = cached
    e.t_done = time.now()
    sync.atomic_store(&global_traces.head, e.trace_id)
}

// ============================================================
// CACHE (Layer ④)
// ============================================================

cache_init :: proc() {
    if !global_cache.enabled { return }
    cache_mb := 32
    sync.shared_lock(&config_mutex)
    cache_mb = global_config.cache_max_mb
    sync.shared_unlock(&config_mutex)
    if cache_mb <= 0 { cache_mb = 32 }
    global_cache.pool = make([]byte, cache_mb * 1024 * 1024)
    global_cache.pool_used = 0
    global_cache.count = 0
}

cache_lookup :: proc(path: string) -> (data: []byte, mime: string, found: bool) {
    if !global_cache.enabled { return nil, "", false }
    sync.mutex_lock(&global_cache.mutex)
    defer sync.mutex_unlock(&global_cache.mutex)

    for i := 0; i < global_cache.count; i += 1 {
        e := &global_cache.entries[i]
        if !e.valid { continue }
        if e.path_len == len(path) && string(e.path[:e.path_len]) == path {
            // Check mtime for invalidation
            fi, ferr := os.stat(path, context.temp_allocator)
            if ferr == nil {
                file_mtime := time.time_to_unix(fi.modification_time)
                if file_mtime != e.mtime {
                    e.valid = false
                    return nil, "", false
                }
            }
            e.last_used = time.now()
            e.hits += 1
            sync.atomic_add(&global_cache.total_hits, 1)
            return global_cache.pool[e.data_off:e.data_off + e.data_len], string(e.mime[:e.mime_len]), true
        }
    }
    sync.atomic_add(&global_cache.total_miss, 1)
    return nil, "", false
}

cache_insert :: proc(path: string, data: []byte, mime: string, mtime: i64) {
    if !global_cache.enabled { return }
    if len(data) > global_cache.max_file { return }

    sync.mutex_lock(&global_cache.mutex)
    defer sync.mutex_unlock(&global_cache.mutex)

    // Check if there's room in the pool
    if global_cache.pool_used + len(data) > len(global_cache.pool) {
        // Try to evict LRU entries to make space
        for global_cache.pool_used + len(data) > len(global_cache.pool) {
            if !cache_evict_lru_locked() {
                return // can't free enough space
            }
        }
    }

    // Find a free slot
    slot := -1
    if global_cache.count < CACHE_MAX_ENTRIES {
        slot = global_cache.count
        global_cache.count += 1
    } else {
        // Find an invalid slot
        for i := 0; i < CACHE_MAX_ENTRIES; i += 1 {
            if !global_cache.entries[i].valid {
                slot = i
                break
            }
        }
        if slot == -1 {
            // Evict LRU
            if !cache_evict_lru_locked() { return }
            for i := 0; i < CACHE_MAX_ENTRIES; i += 1 {
                if !global_cache.entries[i].valid {
                    slot = i
                    break
                }
            }
            if slot == -1 { return }
        }
    }

    e := &global_cache.entries[slot]
    plen := min(len(path), 256)
    copy(e.path[:], transmute([]byte)path[:plen])
    e.path_len = plen
    e.data_off = global_cache.pool_used
    e.data_len = len(data)
    copy(global_cache.pool[global_cache.pool_used:], data)
    global_cache.pool_used += len(data)
    mlen := min(len(mime), 64)
    copy(e.mime[:], transmute([]byte)mime[:mlen])
    e.mime_len = mlen
    e.mtime = mtime
    e.last_used = time.now()
    e.hits = 0
    e.valid = true
}

// Must be called with cache mutex held
cache_evict_lru_locked :: proc() -> bool {
    oldest_idx := -1
    oldest_time := time.Time{}
    for i := 0; i < global_cache.count; i += 1 {
        e := &global_cache.entries[i]
        if !e.valid { continue }
        if oldest_idx == -1 || time.diff(e.last_used, oldest_time) > 0 {
            oldest_idx = i
            oldest_time = e.last_used
        }
    }
    if oldest_idx == -1 { return false }
    global_cache.entries[oldest_idx].valid = false
    // Note: pool space is not reclaimed (simple slab). Full compaction happens on flush.
    return true
}

cache_flush :: proc() {
    sync.mutex_lock(&global_cache.mutex)
    defer sync.mutex_unlock(&global_cache.mutex)
    for i := 0; i < global_cache.count; i += 1 {
        global_cache.entries[i].valid = false
    }
    global_cache.pool_used = 0
    global_cache.count = 0
}

// ============================================================
// STREAMING — Range & ETag (Layer ⑤)
// ============================================================

generate_etag :: proc(mtime: i64, size: i64) -> string {
    return fmt.tprintf("\"%d-%d\"", mtime, size)
}

parse_range_header :: proc(range_val: string, file_size: i64) -> (start: i64, end: i64, ok: bool) {
    // Format: bytes=START-END or bytes=START- or bytes=-SUFFIX
    if !strings.has_prefix(range_val, "bytes=") {
        return 0, 0, false
    }
    spec := range_val[6:]
    dash := strings.index(spec, "-")
    if dash == -1 {
        return 0, 0, false
    }

    start_str := spec[:dash]
    end_str := spec[dash+1:]

    if len(start_str) == 0 {
        // Suffix range: -500 means last 500 bytes
        suffix := parse_int(end_str)
        if suffix <= 0 { return 0, 0, false }
        start = file_size - suffix
        if start < 0 { start = 0 }
        end = file_size - 1
        return start, end, true
    }

    start = parse_int(start_str)
    if len(end_str) == 0 {
        end = file_size - 1
    } else {
        end = parse_int(end_str)
    }

    if start < 0 || start >= file_size || end < start || end >= file_size {
        return 0, 0, false
    }
    return start, end, true
}

// ============================================================
// FILE SERVING WITH CACHE + STREAMING (Layers ④ + ⑤)
// ============================================================

send_file_with_cache :: proc(req: ^Request, resp: ^Response, path: string) {
    // Try cache first
    cached_data, cached_mime, cache_hit := cache_lookup(path)
    if cache_hit {
        // Stat the file for ETag generation
        fi, ferr := os.stat(path, context.temp_allocator)
        if ferr == nil {
            mtime := time.time_to_unix(fi.modification_time)
            etag := generate_etag(mtime, fi.size)

            // Check ETag conditional
            inm_val, has_inm := find_header(req, "If-None-Match")
            if has_inm && strings.trim_space(inm_val) == etag {
                write_response_status(resp, 304, "text/plain", nil)
                return
            }

            // Check Range on cached data
            range_val, has_range := find_header(req, "Range")
            if has_range {
                range_start, range_end, range_ok := parse_range_header(range_val, i64(len(cached_data)))
                if range_ok {
                    content_len := range_end - range_start + 1
                    hdr := fmt.tprintf(
                        "HTTP/1.1 206 Partial Content\r\nContent-Type: %s\r\nContent-Range: bytes %d-%d/%d\r\nContent-Length: %d\r\nAccept-Ranges: bytes\r\nETag: %s\r\nConnection: close\r\n\r\n",
                        cached_mime, range_start, range_end, len(cached_data), content_len, etag,
                    )
                    net.send_tcp(resp.sock, str_to_bytes(hdr))
                    net.send_tcp(resp.sock, cached_data[range_start:range_end+1])
                    resp.sent = true
                    sync.atomic_add(&global_telemetry.total_206s, 1)
                    return
                }
            }

            // Full response with ETag headers
            hdr := fmt.tprintf(
                "HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccept-Ranges: bytes\r\nETag: %s\r\nConnection: close\r\n\r\n",
                cached_mime, len(cached_data), etag,
            )
            n1, _ := net.send_tcp(resp.sock, str_to_bytes(hdr))
            n2, _ := net.send_tcp(resp.sock, cached_data)
            resp.sent = true
            sync.atomic_add(&global_telemetry.total_bytes_sent, u64(max(n1, 0) + max(n2, 0)))
            return
        }
        // Fallback: serve from cache without ETag
        write_response(resp, 200, cached_mime, cached_data)
        return
    }

    // Cache miss — serve from disk
    send_file(req, resp, path)
}

send_file :: proc(req: ^Request, resp: ^Response, path: string) {
    f, err := os.open(path)
    if err != nil {
        write_response(resp, 404, "text/html", str_to_bytes("<html><body><h1>404 Not Found</h1></body></html>"))
        return
    }
    defer os.close(f)

    fi, ferr := os.stat(path, context.allocator)
    if ferr != nil {
        write_response(resp, 404, "text/html", str_to_bytes("<html><body><h1>404 Not Found</h1></body></html>"))
        return
    }

    ext := os.ext(path)
    mime := lookup_mime(ext)
    mtime := time.time_to_unix(fi.modification_time)
    etag := generate_etag(mtime, fi.size)

    // Check If-None-Match (ETag conditional)
    inm_val, has_inm := find_header(req, "If-None-Match")
    if has_inm && strings.trim_space(inm_val) == etag {
        write_response_status(resp, 304, "text/plain", nil)
        sync.atomic_add(&global_telemetry.total_304s, 1)
        return
    }

    // Check Range header
    range_val, has_range := find_header(req, "Range")
    if has_range {
        range_start, range_end, range_ok := parse_range_header(range_val, fi.size)
        if !range_ok {
            // 416 Range Not Satisfiable
            hdr := fmt.tprintf(
                "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */%d\r\nConnection: close\r\n\r\n",
                fi.size,
            )
            net.send_tcp(resp.sock, str_to_bytes(hdr))
            resp.sent = true
            return
        }

        content_len := range_end - range_start + 1
        hdr := fmt.tprintf(
            "HTTP/1.1 206 Partial Content\r\nContent-Type: %s\r\nContent-Range: bytes %d-%d/%d\r\nContent-Length: %d\r\nAccept-Ranges: bytes\r\nETag: %s\r\nConnection: close\r\n\r\n",
            mime, range_start, range_end, fi.size, content_len, etag,
        )
        net.send_tcp(resp.sock, str_to_bytes(hdr))
        resp.sent = true

        // Seek to start
        os.seek(f, range_start, .Start)
        remaining := content_len
        buf: [32768]byte
        total_bytes := 0
        for remaining > 0 {
            to_read := min(int(remaining), len(buf))
            n, rerr := os.read(f, buf[:to_read])
            if rerr != nil || n <= 0 { break }
            n_sent, send_err := net.send_tcp(resp.sock, buf[:n])
            if send_err != nil { break }
            total_bytes += max(n_sent, 0)
            remaining -= i64(n)
        }
        sync.atomic_add(&global_telemetry.total_bytes_sent, u64(total_bytes))
        sync.atomic_add(&global_telemetry.total_206s, 1)
        return
    }

    // Full file response
    if resp.sent { return }
    resp.sent = true

    hdr := fmt.tprintf(
        "HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccept-Ranges: bytes\r\nETag: %s\r\nConnection: close\r\n\r\n",
        mime, fi.size, etag,
    )
    hdr_bytes := str_to_bytes(hdr)
    n_hdr, _ := net.send_tcp(resp.sock, hdr_bytes)
    total_bytes := max(n_hdr, 0)

    // Stream body in chunks — also collect for cache if small enough
    cache_eligible := global_cache.enabled && fi.size <= i64(global_cache.max_file) && fi.size > 0
    cache_buf: []byte = nil
    cache_off := 0
    if cache_eligible {
        cache_buf = make([]byte, int(fi.size))
    }

    buf: [32768]byte
    for {
        n, rerr := os.read(f, buf[:])
        if rerr != nil || n <= 0 { break }
        n_sent, send_err := net.send_tcp(resp.sock, buf[:n])
        if send_err != nil { break }
        total_bytes += max(n_sent, 0)
        // Accumulate for cache
        if cache_buf != nil && cache_off + n <= len(cache_buf) {
            copy(cache_buf[cache_off:], buf[:n])
            cache_off += n
        }
    }
    sync.atomic_add(&global_telemetry.total_bytes_sent, u64(total_bytes))

    // Insert into cache
    if cache_buf != nil && cache_off == int(fi.size) {
        cache_insert(path, cache_buf[:cache_off], mime, mtime)
    }
    if cache_buf != nil {
        delete(cache_buf)
    }
}

// ============================================================
// CONFIG FILE PARSER (Layer ⑥)
// ============================================================

parse_config_file :: proc(path: string) -> (cfg: Config, ok: bool) {
    data, read_err := os.read_entire_file(path, context.allocator)
    if read_err != nil { return cfg, false }
    defer delete(data)

    // Defaults
    cfg.max_connections = 1024
    cfg.cache_enabled = true
    cfg.cache_max_mb = 32
    cfg.cache_max_file = 256 * 1024
    cfg.log_level = 1

    content := string(data)
    for line in strings.split_lines(content) {
        trimmed := strings.trim_space(line)
        if len(trimmed) == 0 || trimmed[0] == '#' { continue }

        eq := strings.index(trimmed, "=")
        if eq == -1 { continue }

        key := strings.trim_space(trimmed[:eq])
        val := strings.trim_space(trimmed[eq+1:])
        // Strip quotes from string values
        if len(val) >= 2 && val[0] == '"' && val[len(val)-1] == '"' {
            val = val[1:len(val)-1]
        }

        switch key {
        case "root":
            rlen := min(len(val), 256)
            copy(cfg.root_dir[:], transmute([]byte)val[:rlen])
            cfg.root_dir_len = rlen
        case "max_connections":
            cfg.max_connections = parse_int(val)
        case "cache_enabled":
            cfg.cache_enabled = (val == "true" || val == "1")
        case "cache_max_mb":
            cfg.cache_max_mb = int(parse_int(val))
        case "cache_max_file_kb":
            cfg.cache_max_file = int(parse_int(val)) * 1024
        case "log_level":
            cfg.log_level = int(parse_int(val))
        case "img_enabled":
            cfg.img_enabled = (val == "true" || val == "1")
        case "img_cache_dir":
            clen := min(len(val), 256)
            copy(cfg.img_cache_dir[:], transmute([]byte)val[:clen])
            cfg.img_cache_dir_len = clen
        case "img_max_mem_mb":
            cfg.img_max_mem_mb = int(parse_int(val))
        case "img_quality":
            cfg.img_quality = int(parse_int(val))
        case "img_max_width":
            cfg.img_max_width = int(parse_int(val))
        case "img_max_height":
            cfg.img_max_height = int(parse_int(val))
        case "img_max_input":
            cfg.img_max_input = int(parse_int(val))
        }
    }
    return cfg, true
}

get_root_dir :: proc() -> string {
    sync.shared_lock(&config_mutex)
    rd := string(global_config.root_dir[:global_config.root_dir_len])
    sync.shared_unlock(&config_mutex)
    if len(rd) == 0 { return root_dir }
    return rd
}

reload_config :: proc() {
    if config_path_len == 0 { return }
    path := string(config_path[:config_path_len])
    cfg, ok := parse_config_file(path)
    if !ok {
        fmt.println("cube: config reload failed — file unreadable")
        return
    }

    sync.lock(&config_mutex)
    old_root := string(global_config.root_dir[:global_config.root_dir_len])
    global_config = cfg
    sync.atomic_add(&config_version, 1)
    sync.unlock(&config_mutex)

    // Update runtime values
    sync.atomic_store(&global_backpressure.max_connections, cfg.max_connections)
    global_cache.enabled = cfg.cache_enabled
    global_cache.max_file = cfg.cache_max_file

    // Update root_dir global
    if cfg.root_dir_len > 0 {
        root_dir = string(cfg.root_dir[:cfg.root_dir_len])
    }

    // If root changed, flush cache
    new_root := string(cfg.root_dir[:cfg.root_dir_len])
    if new_root != old_root && len(new_root) > 0 {
        cache_flush()
        fmt.printf("cube: root changed to %s, cache flushed\n", new_root)
    }

    ver := sync.atomic_load(&config_version)
    fmt.printf("cube: config reloaded (version %d)\n", ver)
}

// inotify watcher thread
config_watch_thread :: proc(dummy: int) {
    _ = dummy
    if config_path_len == 0 { return }

    ifd, ierr := linux.inotify_init()
    if ierr != .NONE {
        fmt.println("cube: inotify_init failed, config watching disabled")
        return
    }

    path_cstr := strings.clone_to_cstring(string(config_path[:config_path_len]))
    _, werr := linux.inotify_add_watch(ifd, path_cstr, {.MODIFY, .CLOSE_WRITE})
    if werr != .NONE {
        fmt.println("cube: inotify_add_watch failed")
        return
    }

    fmt.println("cube: config watcher started")
    event_buf: [4096]byte
    for {
        running := sync.atomic_load(&server_running)
        if running == 0 { break }
        n, rerr := linux.read(ifd, event_buf[:])
        if rerr != .NONE || n <= 0 {
            time.sleep(time.Second)
            continue
        }
        // Debounce: wait a bit for file to be fully written
        time.sleep(100 * time.Millisecond)
        reload_config()
    }
}

// ============================================================
// SIGNAL HANDLING
// ============================================================

server_running: i32 = 1

setup_signals :: proc() {
    act: posix.sigaction_t
    act.sa_handler = cast(proc "c" (posix.Signal)) on_signal
    posix.sigemptyset(&act.sa_mask)
    act.sa_flags = {}
    dummy: posix.sigaction_t
    posix.sigaction(cast(posix.Signal)(15), &act, &dummy) // SIGTERM
    posix.sigaction(cast(posix.Signal)(2), &act, &dummy)  // SIGINT

    // SIGHUP for config reload
    hup_act: posix.sigaction_t
    hup_act.sa_handler = cast(proc "c" (posix.Signal)) on_sighup
    posix.sigemptyset(&hup_act.sa_mask)
    hup_act.sa_flags = {}
    posix.sigaction(cast(posix.Signal)(1), &hup_act, &dummy) // SIGHUP
}

on_signal :: proc "c" (sig: posix.Signal) {
    _ = sig
    sync.atomic_store(&server_running, 0)
}

sighup_pending: i32 = 0

on_sighup :: proc "c" (sig: posix.Signal) {
    _ = sig
    sync.atomic_store(&sighup_pending, 1)
}

// ============================================================
// RESPONSE WRITER
// ============================================================

write_response :: proc(resp: ^Response, status: u16, mime: string, body: []byte) {
    if resp.sent { return }
    resp.sent = true
    status_text := status_to_text(status)
    hdr := fmt.tprintf(
        "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n",
        status, status_text, mime, len(body),
    )
    hdr_bytes := str_to_bytes(hdr)
    n1, _ := net.send_tcp(resp.sock, hdr_bytes)
    n2 := 0
    if len(body) > 0 {
        n2, _ = net.send_tcp(resp.sock, body)
    }
    sync.atomic_add(&global_telemetry.total_bytes_sent, u64(max(n1, 0) + max(n2, 0)))
    if status == 404 {
        sync.atomic_add(&global_telemetry.total_404s, 1)
    } else if status == 500 || status == 502 {
        sync.atomic_add(&global_telemetry.total_500s, 1)
    }
}

write_response_status :: proc(resp: ^Response, status: u16, mime: string, body: []byte) {
    if resp.sent { return }
    resp.sent = true
    status_text := status_to_text(status)
    body_len := 0
    if body != nil { body_len = len(body) }
    hdr := fmt.tprintf(
        "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n",
        status, status_text, mime, body_len,
    )
    net.send_tcp(resp.sock, str_to_bytes(hdr))
    if body != nil && len(body) > 0 {
        net.send_tcp(resp.sock, body)
    }
    if status == 304 {
        sync.atomic_add(&global_telemetry.total_304s, 1)
    }
}

status_to_text :: proc(status: u16) -> string {
    switch status {
    case 200: return "OK"
    case 206: return "Partial Content"
    case 304: return "Not Modified"
    case 400: return "Bad Request"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 416: return "Range Not Satisfiable"
    case 500: return "Internal Server Error"
    case 502: return "Bad Gateway"
    case 503: return "Service Unavailable"
    case:     return "OK"
    }
}

// ============================================================
// CONTROL PLANE (Layer ⑦)
// ============================================================

control_plane_key: string = ""

serve_control_plane_handler :: proc(ctx: ^RequestContext, g: ^Graph) {
    _ = g
    sub_path := string(ctx.req.path)
    if !strings.has_prefix(sub_path, "/_cube/") {
        write_response(&ctx.resp, 404, "text/plain", str_to_bytes("Not Found"))
        return
    }
    sub := sub_path[len("/_cube/"):]
    method := string(ctx.req.method)

    // Auth check for POST endpoints
    is_post := (method == "POST")
    if is_post && len(control_plane_key) > 0 {
        key_val, has_key := find_header(&ctx.req, "X-Cube-Key")
        if !has_key || key_val != control_plane_key {
            write_response(&ctx.resp, 403, "text/plain", str_to_bytes("Forbidden: invalid key"))
            return
        }
    }

    switch {
    case sub == "health":
        write_response(&ctx.resp, 200, "application/json", str_to_bytes("{\"status\":\"ok\"}"))

    case sub == "status":
        serve_status_json(ctx)

    case sub == "traces":
        serve_traces_json(ctx)

    case sub == "config" && !is_post:
        serve_config_json(ctx)

    case sub == "config" && is_post:
        reload_config()
        write_response(&ctx.resp, 200, "application/json", str_to_bytes("{\"reloaded\":true}"))

    case sub == "cache/flush" && is_post:
        cache_flush()
        write_response(&ctx.resp, 200, "application/json", str_to_bytes("{\"flushed\":true}"))

    case sub == "cache/stats":
        serve_cache_stats_json(ctx)

    case sub == "workers":
        serve_workers_json(ctx)

    case sub == "adaptive":
        serve_adaptive_json(ctx)

    case sub == "visits":
        serve_visits_json(ctx)

    case sub == "images":
        serve_images_json(ctx)

    case strings.has_prefix(sub, "events"):
        serve_sse_handler(ctx)

    case:
        write_response(&ctx.resp, 404, "text/plain", str_to_bytes("Unknown control plane endpoint"))
    }
}

serve_status_json :: proc(ctx: ^RequestContext) {
    uptime := time.duration_seconds(time.since(global_telemetry.start_time))
    b: strings.Builder
    strings.builder_init(&b)
    fmt.sbprintf(&b, "{{\n")
    fmt.sbprintf(&b, "  \"uptime_seconds\": %.2f,\n", uptime)
    fmt.sbprintf(&b, "  \"total_requests\": %d,\n", sync.atomic_load(&global_telemetry.total_requests))
    fmt.sbprintf(&b, "  \"total_bytes_sent\": %d,\n", sync.atomic_load(&global_telemetry.total_bytes_sent))
    fmt.sbprintf(&b, "  \"errors_404\": %d,\n", sync.atomic_load(&global_telemetry.total_404s))
    fmt.sbprintf(&b, "  \"errors_500\": %d,\n", sync.atomic_load(&global_telemetry.total_500s))
    fmt.sbprintf(&b, "  \"total_304s\": %d,\n", sync.atomic_load(&global_telemetry.total_304s))
    fmt.sbprintf(&b, "  \"total_206s\": %d,\n", sync.atomic_load(&global_telemetry.total_206s))
    fmt.sbprintf(&b, "  \"active_connections\": %d,\n", sync.atomic_load(&global_backpressure.active_connections))
    fmt.sbprintf(&b, "  \"max_connections\": %d,\n", sync.atomic_load(&global_backpressure.max_connections))
    fmt.sbprintf(&b, "  \"total_rejected\": %d,\n", sync.atomic_load(&global_backpressure.total_rejected))
    fmt.sbprintf(&b, "  \"cache_hits\": %d,\n", sync.atomic_load(&global_cache.total_hits))
    fmt.sbprintf(&b, "  \"cache_misses\": %d,\n", sync.atomic_load(&global_cache.total_miss))
    fmt.sbprintf(&b, "  \"cache_entries\": %d,\n", global_cache.count)
    fmt.sbprintf(&b, "  \"cache_pool_used\": %d,\n", global_cache.pool_used)
    fmt.sbprintf(&b, "  \"config_version\": %d,\n", sync.atomic_load(&config_version))

    // Page visits
    fmt.sbprintf(&b, "  \"page_visits\": [\n")
    sync.mutex_lock(&global_telemetry.mutex)
    for i := 0; i < global_telemetry.path_count; i += 1 {
        item := &global_telemetry.path_visits[i]
        path_str := string(item.path[:item.len])
        comma := (i + 1 < global_telemetry.path_count) ? "," : ""
        fmt.sbprintf(&b, "    {{\"path\": \"%s\", \"visits\": %d}}%s\n", path_str, item.count, comma)
    }
    sync.mutex_unlock(&global_telemetry.mutex)
    fmt.sbprintf(&b, "  ]\n")
    fmt.sbprintf(&b, "}}\n")
    write_response(&ctx.resp, 200, "application/json", transmute([]byte)strings.to_string(b))
}

serve_visits_json :: proc(ctx: ^RequestContext) {
    sync.mutex_lock(&global_telemetry.mutex)
    defer sync.mutex_unlock(&global_telemetry.mutex)

    b: strings.Builder
    strings.builder_init(&b)
    fmt.sbprintf(&b, "{{\n")
    fmt.sbprintf(&b, "  \"week_hits\": %d,\n", global_telemetry.week_hits)
    fmt.sbprintf(&b, "  \"week_unique_paths\": %d,\n", global_telemetry.week_path_count)
    week_start_str, _ := time.time_to_rfc3339(global_telemetry.week_start)
    fmt.sbprintf(&b, "  \"week_start\": \"%s\",\n", week_start_str)

    fmt.sbprintf(&b, "  \"week_paths\": [\n")
    for i := 0; i < global_telemetry.week_path_count; i += 1 {
        plen := global_telemetry.week_path_lens[i]
        if plen > 128 { plen = 128 }
        p := string(global_telemetry.week_paths[i][:plen])
        comma := (i + 1 < global_telemetry.week_path_count) ? "," : ""
        fmt.sbprintf(&b, "    \"%s\"%s\n", p, comma)
    }
    fmt.sbprintf(&b, "  ],\n")

    fmt.sbprintf(&b, "  \"all_time_paths\": [\n")
    for i := 0; i < global_telemetry.path_count; i += 1 {
        item := &global_telemetry.path_visits[i]
        path_str := string(item.path[:item.len])
        comma := (i + 1 < global_telemetry.path_count) ? "," : ""
        fmt.sbprintf(&b, "    {{\"path\": \"%s\", \"visits\": %d}}%s\n", path_str, item.count, comma)
    }
    fmt.sbprintf(&b, "  ],\n")

    // Recent visitors ring (last 20 entries from visitor_head)
    fmt.sbprintf(&b, "  \"recent_visitors\": [\n")
    count := 0
    first := true
    vhead := sync.atomic_load(&global_telemetry.visitor_head)
    if vhead > 0 {
        for i := int(vhead) - 1; i >= 0 && count < 20; i -= 1 {
            idx := i % len(global_telemetry.visitors)
            v := &global_telemetry.visitors[idx]
            if v.path_len == 0 { continue }
            path_str := string(v.path[:v.path_len])
            ip_str := string(v.ip[:v.ip_len])
            ref_str := string(v.referrer[:v.ref_len])
            ua_str := string(v.ua[:v.ua_len])
            ts_iso, _ := time.time_to_rfc3339(v.ts)
            valid := true
            for ch in ip_str { if ch < 32 || ch >= 127 { valid = false; break } }
            for ch in ua_str { if ch < 32 || ch >= 127 { valid = false; break } }
            if !valid { continue }
            if !first { fmt.sbprintf(&b, ",\n") }
            first = false
            fmt.sbprintf(&b, "    {{\"path\":\"%s\",\"ip\":\"%s\",\"referrer\":\"%s\",\"ua\":\"%s\",\"ts\":\"%s\"}}",
                path_str, ip_str, ref_str, ua_str, ts_iso)
            count += 1
        }
    }
    fmt.sbprintf(&b, "\n  ]\n")
    fmt.sbprintf(&b, "}}\n")
    write_response(&ctx.resp, 200, "application/json", transmute([]byte)strings.to_string(b))
}

serve_images_json :: proc(ctx: ^RequestContext) {
    b: strings.Builder
    strings.builder_init(&b)
    fmt.sbprintf(&b, "{{\n")

    total_served := sync.atomic_load(&global_image_metric_head)
    total_orig := 0
    total_out := 0
    total_cached := 0
    n := min(int(total_served), len(global_image_metrics))
    for i := 0; i < n; i += 1 {
        m := &global_image_metrics[i]
        total_orig += m.orig_bytes
        total_out += m.out_bytes
        if m.cached { total_cached += 1 }
    }
    savings := 0.0
    if total_orig > 0 {
        savings = f64(total_orig - total_out) / f64(total_orig) * 100.0
    }
    cache_hit_rate := 0.0
    if total_served > 0 {
        cache_hit_rate = f64(total_cached) / f64(total_served) * 100.0
    }
    fmt.sbprintf(&b, "  \"total_served\": %d,\n", total_served)
    fmt.sbprintf(&b, "  \"total_original_bytes\": %d,\n", total_orig)
    fmt.sbprintf(&b, "  \"total_optimized_bytes\": %d,\n", total_out)
    fmt.sbprintf(&b, "  \"bandwidth_saved_bytes\": %d,\n", total_orig - total_out)
    fmt.sbprintf(&b, "  \"savings_pct\": %.1f,\n", savings)
    fmt.sbprintf(&b, "  \"cache_hit_rate_pct\": %.1f,\n", cache_hit_rate)
    fmt.sbprintf(&b, "  \"cache_hits\": %d,\n", total_cached)

    fmt.sbprintf(&b, "  \"recent\": [\n")
    first := true
    for i := int(total_served) - 1; i >= 0 && (int(total_served) - i) < 20; i -= 1 {
        idx := i % len(global_image_metrics)
        m := &global_image_metrics[idx]
        if m.path_len == 0 { continue }
        path_str := string(m.path[:m.path_len])
        fmt_str := string(m.fmt[:m.fmt_len])
        if !first { fmt.sbprintf(&b, ",\n") }
        first = false
        fmt.sbprintf(&b, "    {{\"path\":\"%s\",\"orig_bytes\":%d,\"out_bytes\":%d,\"fmt\":\"%s\",\"w\":%d,\"h\":%d,\"cached\":%v}}",
            path_str, m.orig_bytes, m.out_bytes, fmt_str, m.w, m.h, m.cached)
    }
    fmt.sbprintf(&b, "\n  ]\n")
    fmt.sbprintf(&b, "}}\n")
    write_response(&ctx.resp, 200, "application/json", transmute([]byte)strings.to_string(b))
}

// ============================================================
serve_telemetry_handler :: proc(ctx: ^RequestContext, g: ^Graph) {
    _ = g
    serve_status_json(ctx)
}

serve_traces_json :: proc(ctx: ^RequestContext) {
    b: strings.Builder
    strings.builder_init(&b)
    fmt.sbprintf(&b, "{{\"traces\":[\n")

    head := sync.atomic_load(&global_traces.head)
    count := min(int(head), TRACE_RING_SIZE)
    first := true
    // Walk backwards from head for most recent
    for i := 0; i < count; i += 1 {
        idx := int((head - u64(i)) % TRACE_RING_SIZE)
        e := &global_traces.entries[idx]
        if e.trace_id == 0 { continue }

        path_str := string(e.path[:e.path_len])
        if strings.has_prefix(path_str, "/_cube/") { continue }

        if !first { fmt.sbprintf(&b, ",\n") }
        first = false

        accept_to_parse := i64(time.duration_microseconds(time.diff(e.t_accept, e.t_parsed)))
        parse_to_route := i64(time.duration_microseconds(time.diff(e.t_parsed, e.t_routed)))
        route_to_done := i64(time.duration_microseconds(time.diff(e.t_routed, e.t_done)))
        total := i64(time.duration_microseconds(time.diff(e.t_accept, e.t_done)))

        fmt.sbprintf(&b,
            "  {{\"id\":%d,\"worker\":%d,\"method\":\"%s\",\"path\":\"%s\",\"status\":%d,\"bytes_sent\":%d,\"cached\":%v,\"parse_us\":%d,\"route_us\":%d,\"handle_us\":%d,\"total_us\":%d}}",
            e.trace_id, e.worker_id,
            string(e.method[:e.method_len]),
            string(e.path[:e.path_len]),
            e.status, e.bytes_sent, e.cached,
            accept_to_parse, parse_to_route, route_to_done, total,
        )
    }
    fmt.sbprintf(&b, "\n]}}\n")
    write_response(&ctx.resp, 200, "application/json", transmute([]byte)strings.to_string(b))
}

serve_config_json :: proc(ctx: ^RequestContext) {
    sync.shared_lock(&config_mutex)
    cfg := global_config
    sync.shared_unlock(&config_mutex)

    b: strings.Builder
    strings.builder_init(&b)
    fmt.sbprintf(&b, "{{\n")
    fmt.sbprintf(&b, "  \"root\": \"%s\",\n", string(cfg.root_dir[:cfg.root_dir_len]))
    fmt.sbprintf(&b, "  \"max_connections\": %d,\n", cfg.max_connections)
    fmt.sbprintf(&b, "  \"cache_enabled\": %v,\n", cfg.cache_enabled)
    fmt.sbprintf(&b, "  \"cache_max_mb\": %d,\n", cfg.cache_max_mb)
    fmt.sbprintf(&b, "  \"cache_max_file_kb\": %d,\n", cfg.cache_max_file / 1024)
    fmt.sbprintf(&b, "  \"log_level\": %d,\n", cfg.log_level)
    fmt.sbprintf(&b, "  \"config_version\": %d\n", sync.atomic_load(&config_version))
    fmt.sbprintf(&b, "}}\n")
    write_response(&ctx.resp, 200, "application/json", transmute([]byte)strings.to_string(b))
}

serve_cache_stats_json :: proc(ctx: ^RequestContext) {
    b: strings.Builder
    strings.builder_init(&b)
    fmt.sbprintf(&b, "{{\n")
    fmt.sbprintf(&b, "  \"enabled\": %v,\n", global_cache.enabled)
    fmt.sbprintf(&b, "  \"total_hits\": %d,\n", sync.atomic_load(&global_cache.total_hits))
    fmt.sbprintf(&b, "  \"total_misses\": %d,\n", sync.atomic_load(&global_cache.total_miss))
    fmt.sbprintf(&b, "  \"entries_count\": %d,\n", global_cache.count)
    fmt.sbprintf(&b, "  \"pool_used_bytes\": %d,\n", global_cache.pool_used)
    fmt.sbprintf(&b, "  \"pool_total_bytes\": %d,\n", len(global_cache.pool))
    fmt.sbprintf(&b, "  \"max_file_bytes\": %d,\n", global_cache.max_file)

    hit_rate := f64(0.0)
    total := sync.atomic_load(&global_cache.total_hits) + sync.atomic_load(&global_cache.total_miss)
    if total > 0 {
        hit_rate = f64(sync.atomic_load(&global_cache.total_hits)) / f64(total)
    }
    fmt.sbprintf(&b, "  \"hit_rate\": %.4f,\n", hit_rate)

    fmt.sbprintf(&b, "  \"entries\": [\n")
    sync.mutex_lock(&global_cache.mutex)
    first := true
    for i := 0; i < global_cache.count; i += 1 {
        e := &global_cache.entries[i]
        if !e.valid { continue }
        if !first { fmt.sbprintf(&b, ",\n") }
        first = false
        fmt.sbprintf(&b, "    {{\"path\":\"%s\",\"size\":%d,\"hits\":%d}}",
            string(e.path[:e.path_len]), e.data_len, e.hits,
        )
    }
    sync.mutex_unlock(&global_cache.mutex)
    fmt.sbprintf(&b, "\n  ]\n")
    fmt.sbprintf(&b, "}}\n")
    write_response(&ctx.resp, 200, "application/json", transmute([]byte)strings.to_string(b))
}

serve_workers_json :: proc(ctx: ^RequestContext) {
    b: strings.Builder
    strings.builder_init(&b)
    fmt.sbprintf(&b, "{{\"workers\":[\n")
    wc := cfg_workers_global
    for i := 0; i < wc; i += 1 {
        ws := &global_worker_stats[i]
        comma := (i + 1 < wc) ? "," : ""
        last_req_ago := time.duration_seconds(time.since(ws.last_request))
        fmt.sbprintf(&b, "  {{\"id\":%d,\"requests\":%d,\"bytes_sent\":%d,\"arena_peak\":%d,\"idle_seconds\":%.1f}}%s\n",
            i, sync.atomic_load(&ws.requests_handled), sync.atomic_load(&ws.bytes_sent),
            ws.arena_peak, last_req_ago, comma,
        )
    }
    fmt.sbprintf(&b, "]}}\n")
    write_response(&ctx.resp, 200, "application/json", transmute([]byte)strings.to_string(b))
}

serve_adaptive_json :: proc(ctx: ^RequestContext) {
    b: strings.Builder
    strings.builder_init(&b)
    fmt.sbprintf(&b, "{{\n")
    fmt.sbprintf(&b, "  \"enabled\": %v,\n", global_adaptive.enabled)
    fmt.sbprintf(&b, "  \"rps\": %.2f,\n", global_adaptive.rps)
    fmt.sbprintf(&b, "  \"cache_hit_rate\": %.4f,\n", global_adaptive.cache_hit_rate)
    fmt.sbprintf(&b, "  \"error_rate\": %.4f,\n", global_adaptive.error_rate)
    fmt.sbprintf(&b, "  \"p99_latency_us\": %.1f,\n", global_adaptive.p99_latency_us)

    fmt.sbprintf(&b, "  \"adjustments\": [\n")
    sync.mutex_lock(&global_adaptive.adj_mutex)
    for i := 0; i < global_adaptive.adj_count; i += 1 {
        a := &global_adaptive.adjustments[i]
        comma := (i + 1 < global_adaptive.adj_count) ? "," : ""
        ago := time.duration_seconds(time.since(a.timestamp))
        fmt.sbprintf(&b, "    {{\"field\":\"%s\",\"old\":%d,\"new\":%d,\"reason\":\"%s\",\"ago_seconds\":%.1f}}%s\n",
            string(a.field[:a.field_len]),
            a.old_value, a.new_value,
            string(a.reason[:a.reason_len]),
            ago, comma,
        )
    }
    sync.mutex_unlock(&global_adaptive.adj_mutex)
    fmt.sbprintf(&b, "  ]\n")
    fmt.sbprintf(&b, "}}\n")
    write_response(&ctx.resp, 200, "application/json", transmute([]byte)strings.to_string(b))
}

serve_sse_handler :: proc(ctx: ^RequestContext) {
    sock := ctx.resp.sock
    if !eventbus.Event_bus_register(sock) {
        write_response(&ctx.resp, 503, "text/plain", str_to_bytes("Too many dashboard clients"))
        return
    }
    defer eventbus.Event_bus_unregister(sock)

    header := "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
    _, _ = net.send_tcp(sock, str_to_bytes(header))

    last_seen := sync.atomic_load(&eventbus.Event_bus_write)
    if last_seen > 0 {
        last_seen -= 1
    }
    eventbus.Event_bus_drain(sock, &last_seen)

    keepalive_buf := str_to_bytes(":\r\n\r\n")
    keepalive_counter := 0

    for {
        running := sync.atomic_load(&server_running)
        if running == 0 { break }

        time.sleep(1 * time.Second)
        eventbus.Event_bus_drain(sock, &last_seen)

        keepalive_counter += 1
        if keepalive_counter >= 15 {
            keepalive_counter = 0
            _, serr := net.send_tcp(sock, keepalive_buf)
            if serr != nil { break }
        }
    }
}

// ============================================================
// ADAPTIVE RUNTIME (Layer ⑧)
// ============================================================

adaptive_log_adjustment :: proc(field: string, old_val: i64, new_val: i64, reason: string) {
    sync.mutex_lock(&global_adaptive.adj_mutex)
    defer sync.mutex_unlock(&global_adaptive.adj_mutex)

    idx := global_adaptive.adj_count
    if idx >= len(global_adaptive.adjustments) {
        // Shift left to make room
        for i := 0; i < len(global_adaptive.adjustments) - 1; i += 1 {
            global_adaptive.adjustments[i] = global_adaptive.adjustments[i+1]
        }
        idx = len(global_adaptive.adjustments) - 1
    } else {
        global_adaptive.adj_count += 1
    }

    a := &global_adaptive.adjustments[idx]
    a.timestamp = time.now()
    flen := min(len(field), 32)
    copy(a.field[:], transmute([]byte)field[:flen])
    a.field_len = flen
    a.old_value = old_val
    a.new_value = new_val
    rlen := min(len(reason), 64)
    copy(a.reason[:], transmute([]byte)reason[:rlen])
    a.reason_len = rlen

    fmt.printf("cube: adaptive: %s %d -> %d (%s)\n", field, old_val, new_val, reason)

    {
        b: strings.Builder
        strings.builder_init(&b)
        strings.write_string(&b, "{\"field\":\"")
        strings.write_string(&b, field)
        strings.write_string(&b, "\",\"old\":")
        strings.write_string(&b, fmt.aprintf("%d", old_val))
        strings.write_string(&b, ",\"new\":")
        strings.write_string(&b, fmt.aprintf("%d", new_val))
        strings.write_string(&b, ",\"reason\":\"")
        strings.write_string(&b, reason)
        strings.write_string(&b, "\"}")
        eventbus.Event_bus_publish(.ADJUSTMENT, strings.to_string(b))
    }
}

compute_p99_latency :: proc() -> f64 {
    head := sync.atomic_load(&global_traces.head)
    count := min(int(head), TRACE_RING_SIZE)
    if count == 0 { return 0.0 }

    latencies: [TRACE_RING_SIZE]i64
    n := 0
    MAX_US :: 30_000_000 // 30 s cap
    for i := 0; i < count; i += 1 {
        idx := int((head - u64(i)) % TRACE_RING_SIZE)
        e := &global_traces.entries[idx]
        if e.trace_id == 0 { continue }
        total := i64(time.duration_microseconds(time.diff(e.t_accept, e.t_done)))
        if total > 0 && total < MAX_US {
            latencies[n] = total
            n += 1
        }
    }
    if n == 0 { return 0.0 }

    for i := 0; i < n - 1; i += 1 {
        for j := i + 1; j < n; j += 1 {
            if latencies[j] < latencies[i] {
                latencies[i], latencies[j] = latencies[j], latencies[i]
            }
        }
    }

    p99_idx := int(f64(n) * 0.99)
    if p99_idx >= n { p99_idx = n - 1 }
    return f64(latencies[p99_idx])
}

adaptive_loop :: proc(dummy: int) {
    _ = dummy
    if !global_adaptive.enabled { return }
    fmt.println("cube: adaptive runtime started")
    global_adaptive.last_check = time.now()

    for {
        running := sync.atomic_load(&server_running)
        if running == 0 { break }
        time.sleep(global_adaptive.check_interval)

        now := time.now()
        elapsed := time.duration_seconds(time.diff(global_adaptive.last_check, now))
        if elapsed <= 0 { continue }
        global_adaptive.last_check = now

        // Snapshot current counters
        cur_requests := sync.atomic_load(&global_telemetry.total_requests)
        cur_cache_hits := sync.atomic_load(&global_cache.total_hits)
        cur_cache_miss := sync.atomic_load(&global_cache.total_miss)
        cur_404s := sync.atomic_load(&global_telemetry.total_404s)

        // Compute rates
        req_delta := cur_requests - global_adaptive.prev_requests
        global_adaptive.rps = f64(req_delta) / elapsed

        hit_delta := cur_cache_hits - global_adaptive.prev_cache_hits
        miss_delta := cur_cache_miss - global_adaptive.prev_cache_miss
        total_cache := hit_delta + miss_delta
        if total_cache > 0 {
            global_adaptive.cache_hit_rate = f64(hit_delta) / f64(total_cache)
        }

        err_delta := cur_404s - global_adaptive.prev_404s
        if req_delta > 0 {
            global_adaptive.error_rate = f64(err_delta) / f64(req_delta)
        }

        global_adaptive.p99_latency_us = compute_p99_latency()

        // Store snapshots for next cycle
        global_adaptive.prev_requests = cur_requests
        global_adaptive.prev_cache_hits = cur_cache_hits
        global_adaptive.prev_cache_miss = cur_cache_miss
        global_adaptive.prev_404s = cur_404s

        // Publish metrics snapshot for SSE dashboard
        {
            b: strings.Builder
            strings.builder_init(&b)
            strings.write_string(&b, "{\"rps\":")
            strings.write_string(&b, fmt.aprintf("%.1f", global_adaptive.rps))
            strings.write_string(&b, ",\"cache_hit_rate\":")
            strings.write_string(&b, fmt.aprintf("%.4f", global_adaptive.cache_hit_rate))
            strings.write_string(&b, ",\"err_rate\":")
            strings.write_string(&b, fmt.aprintf("%.4f", global_adaptive.error_rate))
            strings.write_string(&b, ",\"p99_us\":")
            strings.write_string(&b, fmt.aprintf("%.0f", global_adaptive.p99_latency_us))
            strings.write_string(&b, "}")
            eventbus.Event_bus_publish(.METRICS, strings.to_string(b))
        }

        // Publish status snapshot for SSE dashboard
        {
            b: strings.Builder
            strings.builder_init(&b)
            strings.write_string(&b, "{\"uptime\":")
            strings.write_string(&b, fmt.aprintf("%.1f", time.duration_seconds(time.since(global_telemetry.start_time))))
            strings.write_string(&b, ",\"total_requests\":")
            strings.write_string(&b, fmt.aprintf("%d", sync.atomic_load(&global_telemetry.total_requests)))
            strings.write_string(&b, ",\"total_bytes_sent\":")
            strings.write_string(&b, fmt.aprintf("%d", sync.atomic_load(&global_telemetry.total_bytes_sent)))
            strings.write_string(&b, ",\"active_conn\":")
            strings.write_string(&b, fmt.aprintf("%d", sync.atomic_load(&global_backpressure.active_connections)))
            strings.write_string(&b, ",\"max_conn\":")
            strings.write_string(&b, fmt.aprintf("%d", sync.atomic_load(&global_backpressure.max_connections)))
            strings.write_string(&b, "}")
            eventbus.Event_bus_publish(.STATUS, strings.to_string(b))
        }

        // === Adaptive Rules ===

        // Rule 1: High cache miss rate — increase max cacheable file size
        if total_cache > 10 && global_adaptive.cache_hit_rate < 0.20 && global_cache.enabled {
            old := global_cache.max_file
            new_val := int(f64(old) * 1.5)
            max_limit := 2 * 1024 * 1024 // 2MB cap
            if new_val > max_limit { new_val = max_limit }
            if new_val != old {
                global_cache.max_file = new_val
                adaptive_log_adjustment("cache_max_file", i64(old), i64(new_val), "cache miss rate > 80%")
            }
        }

        // Rule 2: P99 latency spike — log warning
        if global_adaptive.p99_latency_us > 100000 { // > 100ms
            max_c := sync.atomic_load(&global_backpressure.max_connections)
            new_max := max_c * 3 / 4 // reduce by 25%
            min_conns := i64(64)
            if new_max < min_conns { new_max = min_conns }
            if new_max != max_c {
                sync.atomic_store(&global_backpressure.max_connections, new_max)
                adaptive_log_adjustment("max_connections", max_c, new_max, "p99 > 100ms")
            }
        }

        // Rule 3: Sustained high load — enable aggressive caching
        active := sync.atomic_load(&global_backpressure.active_connections)
        max_c := sync.atomic_load(&global_backpressure.max_connections)
        if max_c > 0 && f64(active) / f64(max_c) > 0.9 {
            old := global_cache.max_file
            new_val := old * 2
            max_limit := 4 * 1024 * 1024
            if new_val > max_limit { new_val = max_limit }
            if new_val != old {
                global_cache.max_file = new_val
                adaptive_log_adjustment("cache_max_file", i64(old), i64(new_val), "conn utilization > 90%")
            }
        }

        // Rule 4: Idle period — compact cache
        if req_delta == 0 && global_cache.count > 0 {
            // Count valid entries
            valid := 0
            sync.mutex_lock(&global_cache.mutex)
            for i := 0; i < global_cache.count; i += 1 {
                if global_cache.entries[i].valid { valid += 1 }
            }
            sync.mutex_unlock(&global_cache.mutex)
            if valid == 0 && global_cache.pool_used > 0 {
                cache_flush()
                adaptive_log_adjustment("cache", i64(global_cache.pool_used), 0, "idle compaction")
            }
        }
    }
    fmt.println("cube: adaptive runtime stopped")
}

// ============================================================
// MIME TYPES
// ============================================================

mime_types := []struct {
    ext:  string,
    mime: string,
}{
    {".html", "text/html"},
    {".css", "text/css"},
    {".js", "application/javascript"},
    {".json", "application/json"},
    {".png", "image/png"},
    {".jpg", "image/jpeg"},
    {".jpeg", "image/jpeg"},
    {".gif", "image/gif"},
    {".svg", "image/svg+xml"},
    {".ico", "image/x-icon"},
    {".xml", "application/rss+xml"},
    {".txt", "text/plain"},
    {".pdf", "application/pdf"},
    {".mp4", "video/mp4"},
    {".webm", "video/webm"},
    {".webp", "image/webp"},
    {".woff", "font/woff"},
    {".woff2", "font/woff2"},
    {".ttf", "font/ttf"},
    {".toml", "text/plain"},
}

lookup_mime :: proc(ext: string) -> string {
    lower := strings.to_lower(ext)
    for mt in mime_types {
        if lower == mt.ext {
            return mt.mime
        }
    }
    return "application/octet-stream"
}

// ============================================================
// HELPERS
// ============================================================

str_to_bytes :: proc(s: string) -> []byte {
    return transmute([]byte)s
}

get_header :: proc(req: Request, key: string) -> string {
    lower_key := strings.to_lower(key)
    for i := 0; i < req.header_count; i += 1 {
        h := req.headers[i]
        hkey := string(h.key[:h.key_len])
        if strings.to_lower(hkey) == lower_key {
            return string(h.val[:h.val_len])
        }
    }
    return ""
}

get_client_ip :: proc(client: net.TCP_Socket) -> string {
    ep, perr := net.peer_endpoint(client)
    if perr != nil {
        return "unknown"
    }
    return net.address_to_string(ep.address)
}

// ============================================================
// IMAGE PIPELINE (Layer ③½)
// ============================================================

is_image_path :: proc(path: string) -> bool {
    p := path
    if qs := strings.index(p, "?"); qs != -1 {
        p = p[:qs]
    }
    lower := strings.to_lower(p)
    return strings.has_suffix(lower, ".jpg") || strings.has_suffix(lower, ".jpeg") ||
           strings.has_suffix(lower, ".png") || strings.has_suffix(lower, ".webp") ||
           strings.has_suffix(lower, ".gif") || strings.has_suffix(lower, ".bmp")
}

choose_format :: proc(accept_header: string) -> string {
    lower := strings.to_lower(accept_header)
    if strings.contains(lower, "image/avif") { return "avif" }
    if strings.contains(lower, "image/webp") { return "webp" }
    return "jpeg"
}

parse_image_params :: proc(req: Request) -> (int, int, int, string, bool) {
    w, h, q := 0, 0, 0
    fmt_str, ok := "", false
    path := string(req.path)
    qpos := strings.index(path, "?")
    if qpos == -1 { return 0, 0, 0, "", false }
    query := path[qpos+1:]
    param_pairs := strings.split(query, "&")
    for pair in param_pairs {
        eq := strings.index(pair, "=")
        if eq == -1 { continue }
        k := strings.trim_space(pair[:eq])
        v := strings.trim_space(pair[eq+1:])
        switch k {
    case "w", "width":  w = int(parse_int(v))
    case "h", "height": h = int(parse_int(v))
    case "q", "quality": q = int(parse_int(v))
        case "fmt", "format": fmt_str = v
        }
    }
    if w > 0 || h > 0 { ok = true }
    return w, h, q, fmt_str, ok
}

serve_image :: proc(ctx: ^RequestContext, g: ^Graph, orig_path: string, w: int, h: int) {
    cfg := global_config
    img_cfg := global_image_cache
    if !cfg.img_enabled {
        serve_static_file(ctx, g, orig_path)
        return
    }

    phys_path := orig_path
    if qs := strings.index(phys_path, "?"); qs != -1 {
        phys_path = phys_path[:qs]
    }
    if !strings.has_prefix(phys_path, "/") { phys_path = strings.concatenate([]string{"/", phys_path}) }

    root := string(cfg.root_dir[:cfg.root_dir_len])
    phys := strings.join({root, phys_path}, "")
    if !os.exists(phys) {
        serve_static_file(ctx, g, phys_path)
        return
    }

    fi, ferr := os.stat(phys, context.temp_allocator)
    if ferr != nil || fi.size > i64(cfg.img_max_input) {
        serve_static_file(ctx, g, phys_path)
        return
    }

    version := fmt.aprintf("%d_%d", time.time_to_unix(fi.modification_time), int(fi.size))
    _, _, _, fmt_override, _ := parse_image_params(ctx.req)
    if fmt_override == "" {
        fmt_override = choose_format(get_header(ctx.req, "Accept"))
    }

    quality := cfg.img_quality
    if quality <= 0 { quality = 85 }

    fmt_override = strings.to_lower(strings.trim_space(fmt_override))
    switch fmt_override {
    case "avif", "webp":
        fmt_override = "jpeg"
    case "png", "jpeg", "jpg":
    case:
        fmt_override = "jpeg"
    }

    key := image_cache.image_cache_key(phys_path, version, w, h, fmt_override, quality)
    fallback_mime := image_cache.guess_mime(strings.concatenate([]string{"x.", fmt_override}))

    cached_data, cached_mime, hit := image_cache.image_cache_get(&img_cfg, key, fallback_mime)
    if hit {
        write_response(&ctx.resp, 200, cached_mime, cached_data)
        return
    }

    t0 := time.now()

    root_dir_str := string(cfg.root_dir[:cfg.root_dir_len])
    cache_dir_str := string(cfg.img_cache_dir[:cfg.img_cache_dir_len])
    if cache_dir_str == "" { cache_dir_str = "./cache/images" }

    out, mime, cached := pipeline.pipeline_process(
        orig_path,
        phys_path,
        w, h,
        fmt_override,
        quality,
        root_dir_str,
        cache_dir_str,
        cfg.img_max_input,
        cfg.img_max_width,
        cfg.img_max_height,
        &img_cfg,
    )

    _ = t0
    if !cached && out != nil && len(out) > 0 {
        write_response(&ctx.resp, 200, mime, out)

        root_dir := string(cfg.root_dir[:cfg.root_dir_len])
        img_cache_dir := string(cfg.img_cache_dir[:cfg.img_cache_dir_len])
        if img_cache_dir == "" { img_cache_dir = "./cache/images" }
        image_jobs.image_job_queue_async(phys_path, w, h, root_dir, img_cache_dir, cfg.img_max_mem_mb)
        record_image_metric(phys_path, 0, len(out), fmt_override, w, h, false)
        return
    }

    if cached {
        record_image_metric(phys_path, 0, 0, fmt_override, w, h, true)
        return
    }

    serve_static_file(ctx, g, phys_path)
    record_image_metric(phys_path, 0, 0, fmt_override, w, h, false)
}

serve_static_file :: proc(ctx: ^RequestContext, g: ^Graph, path: string) {
    handler, found := graph_resolve(g, path)
    if found {
        handler(ctx, g)
    } else {
        write_response(&ctx.resp, 404, "text/html", str_to_bytes("<html><body><h1>404 Not Found</h1></body></html>"))
    }
}

record_image_metric :: proc(path: string, orig_bytes: int, out_bytes: int, fmt: string, w: int, h: int, cached: bool) {
    head := sync.atomic_add(&global_image_metric_head, 1)
    slot := int(head % u64(len(global_image_metrics)))
    m := &global_image_metrics[slot]
    copy(m.path[:], transmute([]byte)path)
    m.path_len = len(path)
    m.orig_bytes = orig_bytes
    m.out_bytes = out_bytes
    copy(m.fmt[:], transmute([]byte)fmt)
    m.fmt_len = len(fmt)
    m.w = w
    m.h = h
    m.cached = cached
    m.ts = time.now()
}

image_free :: proc(img: cube_image.Image) {
    if img.data != nil {
        delete(img.data)
    }
}

// ============================================================

cfg_workers_global: int = 4

worker_run :: proc(id: int, listener: net.TCP_Socket, g: ^Graph) {
    fmt.printf("cube: worker %d started\n", id)

    arena_buf := make([]byte, 10 * 1024 * 1024)
    defer delete(arena_buf)

    arena: mem.Arena
    mem.arena_init(&arena, arena_buf)

    recv_buf := make([]byte, 65536)
    defer delete(recv_buf)

    for {
        running := sync.atomic_load(&server_running)
        if running == 0 { break }

        // Check for pending SIGHUP
        if sync.atomic_load(&sighup_pending) == 1 {
            sync.atomic_store(&sighup_pending, 0)
            reload_config()
        }

        client, _, aerr := net.accept_tcp(listener)
        if aerr != nil { continue }

        // Telemetry: count request
        sync.atomic_add(&global_telemetry.total_requests, 1)

        // Backpressure: check active connections
        active := sync.atomic_add(&global_backpressure.active_connections, 1)
        max_conns := sync.atomic_load(&global_backpressure.max_connections)
        if max_conns > 0 && active > max_conns {
            sync.atomic_add(&global_backpressure.total_rejected, 1)
            sync.atomic_add(&global_backpressure.active_connections, -1)
            resp := Response{sock = client, sent = false}
            write_response(&resp, 503, "text/html", str_to_bytes("<html><body><h1>503 Service Unavailable</h1></body></html>"))
            net.close(client)
            continue
        }

        // Tracing: begin trace
        trace_idx := trace_begin(id)

        // Reset request arena
        mem.arena_free_all(&arena)
        context.allocator = mem.arena_allocator(&arena)

        n, nerr := net.recv_tcp(client, recv_buf)
        if nerr != nil || n == 0 {
            sync.atomic_add(&global_backpressure.active_connections, -1)
            trace_finish(trace_idx, 0, 0, false)
            net.close(client)
            continue
        }

        req, ok := parse_request(recv_buf[:n])
        if !ok {
            resp := Response{sock = client, sent = false}
            write_response(&resp, 400, "text/plain", str_to_bytes("Bad Request"))
            sync.atomic_add(&global_backpressure.active_connections, -1)
            trace_finish(trace_idx, 400, 0, false)
            net.close(client)
            continue
        }

        trace_set_request(trace_idx, &req)

        // Image pipeline: intercept ?w=/ ?width= on image paths
        if is_image_path(string(req.path)) {
            img_w, img_h, _, _, img_ok := parse_image_params(req)
            if img_ok {
                ctx := RequestContext{
                    req = req,
                    resp = Response{sock = client, sent = false},
                    trace_idx = trace_idx,
                }
                trace_set_routed(trace_idx)
                ip_raw := get_header(req, "X-Forwarded-For")
                if len(ip_raw) == 0 {
                    ip_raw = get_client_ip(client)
                }
                comma := strings.index(ip_raw, ",")
                if comma >= 0 {
                    ip_raw = ip_raw[:comma]
                }
                ip_raw = strings.trim_space(ip_raw)
                if len(ip_raw) == 0 {
                    ip_raw = "unknown"
                }
                record_visit(
                    string(req.path),
                    ip_raw,
                    get_header(req, "Referer"),
                    get_header(req, "User-Agent"),
                )
                serve_image(&ctx, g, string(req.path), img_w, img_h)
                sync.atomic_add(&global_worker_stats[id].requests_handled, 1)
                global_worker_stats[id].last_request = time.now()
                trace_finish(trace_idx, 200, 0, false)
                sync.atomic_add(&global_backpressure.active_connections, -1)
                net.close(client)
                continue
            }
        }

        handler, found := graph_resolve(g, string(req.path))
        trace_set_routed(trace_idx)

        if found {
            ip_raw := get_header(req, "X-Forwarded-For")
            if len(ip_raw) == 0 {
                ip_raw = get_client_ip(client)
            }
            comma := strings.index(ip_raw, ",")
            if comma >= 0 {
                ip_raw = ip_raw[:comma]
            }
            ip_raw = strings.trim_space(ip_raw)
            if len(ip_raw) == 0 {
                ip_raw = "unknown"
            }

            record_visit(
                string(req.path),
                ip_raw,
                get_header(req, "Referer"),
                get_header(req, "User-Agent"),
            )
        }
        if !found {
            resp := Response{sock = client, sent = false}
            write_response(&resp, 404, "text/html", str_to_bytes("<html><body><h1>404 Not Found</h1></body></html>"))
            sync.atomic_add(&global_backpressure.active_connections, -1)
            trace_finish(trace_idx, 404, 0, false)
            net.close(client)
            continue
        }

        ctx := RequestContext{
            req = req,
            resp = Response{sock = client, sent = false},
            trace_idx = trace_idx,
        }
        handler(&ctx, g)

        // Worker stats
        sync.atomic_add(&global_worker_stats[id].requests_handled, 1)
        global_worker_stats[id].last_request = time.now()
        arena_used := arena.peak_used
        if arena_used > global_worker_stats[id].arena_peak {
            global_worker_stats[id].arena_peak = arena_used
        }

        // Finish trace
        trace_finish(trace_idx, 200, 0, false)

        sync.atomic_add(&global_backpressure.active_connections, -1)
        net.close(client)
    }
    fmt.printf("cube: worker %d stopped\n", id)
}

// ============================================================
// MAIN
// ============================================================

main :: proc() {
    cfg_addr := "0.0.0.0:8080"
    cfg_root := "/home/ds/Documents/Dev/dist"
    cfg_workers := 4
    cfg_max_conns := i64(1024)
    cfg_cache_enabled := true
    cfg_cache_mb := 32
    cfg_cache_max_file := 256 * 1024
    cfg_config_path := ""
    cfg_cp_key := ""
    cfg_adaptive := false

    args := os.args
    for i := 1; i < len(args); i += 1 {
        switch args[i] {
        case "--addr":
            if i+1 < len(args) { cfg_addr = args[i+1]; i += 1 }
        case "--root":
            if i+1 < len(args) { cfg_root = args[i+1]; i += 1 }
        case "--workers":
            if i+1 < len(args) { cfg_workers = int(parse_int(args[i+1])); i += 1 }
        case "--max-conns":
            if i+1 < len(args) { cfg_max_conns = parse_int(args[i+1]); i += 1 }
        case "--cache-size":
            if i+1 < len(args) { cfg_cache_mb = int(parse_int(args[i+1])); i += 1 }
        case "--max-cache-file":
            if i+1 < len(args) { cfg_cache_max_file = int(parse_int(args[i+1])) * 1024; i += 1 }
        case "--no-cache":
            cfg_cache_enabled = false
        case "--config":
            if i+1 < len(args) { cfg_config_path = args[i+1]; i += 1 }
        case "--control-plane-key":
            if i+1 < len(args) { cfg_cp_key = args[i+1]; i += 1 }
        case "--adaptive":
            cfg_adaptive = true
        }
    }

    root_dir = cfg_root
    cfg_workers_global = cfg_workers
    control_plane_key = cfg_cp_key

    // Initialize config
    rlen := min(len(cfg_root), 256)
    copy(global_config.root_dir[:], transmute([]byte)cfg_root[:rlen])
    global_config.root_dir_len = rlen
    global_config.max_connections = cfg_max_conns
    global_config.cache_enabled = cfg_cache_enabled
    global_config.cache_max_mb = cfg_cache_mb
    global_config.cache_max_file = cfg_cache_max_file
    global_config.log_level = 1

    // Load config file if specified
    if len(cfg_config_path) > 0 {
        plen := min(len(cfg_config_path), 256)
        copy(config_path[:], transmute([]byte)cfg_config_path[:plen])
        config_path_len = plen

        cfg, ok := parse_config_file(cfg_config_path)
        if ok {
            global_config = cfg
            if cfg.root_dir_len > 0 {
                root_dir = string(cfg.root_dir[:cfg.root_dir_len])
            }
            cfg_max_conns = cfg.max_connections
            cfg_cache_enabled = cfg.cache_enabled
            cfg_cache_mb = cfg.cache_max_mb
            cfg_cache_max_file = cfg.cache_max_file
            fmt.printf("cube: loaded config from %s\n", cfg_config_path)
        } else {
            fmt.printf("cube: warning: could not load config from %s, using defaults\n", cfg_config_path)
        }
    }

    // Initialize backpressure
    global_backpressure.max_connections = cfg_max_conns

    // Initialize cache
    global_cache.enabled = cfg_cache_enabled
    global_cache.max_file = cfg_cache_max_file
    cache_init()

    // Initialize image cache
    img_cache_dir := string(global_config.img_cache_dir[:global_config.img_cache_dir_len])
    if len(img_cache_dir) == 0 { img_cache_dir = "./cache/images" }
    global_image_cache = image_cache.image_cache_init(img_cache_dir, global_config.img_max_mem_mb)

    // Initialize adaptive
    global_adaptive.enabled = cfg_adaptive
    global_adaptive.check_interval = 1 * time.Second

    sync.atomic_store(&server_running, 1)
    setup_signals()

    endpoint, ok := net.parse_endpoint(cfg_addr)
    if !ok {
        fmt.println(fmt.tprintf("cube: bad address %s", cfg_addr))
        os.exit(1)
    }

    listener, lerr := net.listen_tcp(endpoint, 4096)
    if lerr != nil {
        fmt.println(fmt.tprintf("cube: listen failed on %s: %v", cfg_addr, lerr))
        os.exit(1)
    }

    global_telemetry.start_time = time.now()
    global_telemetry.week_start = time.now()

    g := Graph{}
    graph_init(&g)
    graph_add(&g, "/", serve_static_handler)
    graph_add(&g, "/zerophone/", serve_proxy_handler)
    graph_add(&g, "/telemetry", serve_telemetry_handler)
    graph_add(&g, "/_cube/", serve_control_plane_handler)

    fmt.printf("cube: %d workers on %s (root=%s)\n", cfg_workers, cfg_addr, root_dir)
    fmt.printf("cube: backpressure max_conns=%d cache=%v cache_mb=%d adaptive=%v\n",
        cfg_max_conns, cfg_cache_enabled, cfg_cache_mb, cfg_adaptive)

    global_graph := &g

    // Start worker threads
    for i := 0; i < cfg_workers; i += 1 {
        thread.create_and_start_with_poly_data3(i, listener, global_graph, worker_run)
    }

    // Start config watcher thread (if config file specified)
    if config_path_len > 0 {
        thread.create_and_start_with_poly_data(0, config_watch_thread)
    }

    // Start adaptive runtime thread
    if cfg_adaptive {
        thread.create_and_start_with_poly_data(0, adaptive_loop)
    }

    // Start background image generation thread
    image_jobs.image_jobs_init()
    thread.create_and_start_with_poly_data(0, image_jobs.image_job_queue_background)

    for {
        running := sync.atomic_load(&server_running)
        if running == 0 { break }
        time.sleep(time.Second)
    }

    net.close(listener)
    fmt.println("cube: all workers stopped")
}

parse_int :: proc(s: string) -> i64 {
    val := i64(0)
    neg := false
    for i := 0; i < len(s); i += 1 {
        c := s[i]
        if i == 0 && c == '-' {
            neg = true
            continue
        }
        if c >= '0' && c <= '9' {
            val = val * 10 + i64(c - '0')
        }
    }
    if neg { return -val }
    return val
}
