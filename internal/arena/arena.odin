// Arena allocator for per-request memory isolation
package arena

import "core:mem"
import "core:runtime"

Arena :: struct {
    buf:    []u8,
    offset: int,
    allocator: mem.Allocator,
}

arena_init :: proc(a: ^Arena, size: int, allocator := runtime.default_allocator) {
    a.buf = make([]u8, size)
    a.offset = 0
    a.allocator = allocator
}

arena_alloc :: proc(a: ^Arena, size: int) -> rawptr {
    if a.offset + size > len(a.buf) {
        return nil
    }
    ptr := &a.buf[a.offset]
    a.offset += size
    return ptr
}

arena_reset :: proc(a: ^Arena) {
    a.offset = 0
}

arena_destroy :: proc(a: ^Arena) {
    delete(a.buf)
    a.offset = 0
}

arena_bytes_used :: proc(a: ^Arena) -> int {
    return a.offset
}
