package main

import "core:os"
import "core:fmt"
import "core:image"

main :: proc() {
    data, err := os.read_entire_file("/home/ds/dev/microfolio-odin/dist/projects/03-Sign/images/03-sign-1.png", context.allocator)
    if err != nil {
        fmt.println("read failed:", err)
        return
    }
    defer delete(data)
    fmt.println("read ok, bytes=", len(data))
    dec := image.load_from_memory(data)
    if !dec.ok {
        fmt.println("decode failed")
        return
    }
    fmt.println("decode ok, w=", dec.img.w, " h=", dec.img.h, " ch=", dec.img.channels)
}
