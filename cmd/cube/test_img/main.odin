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

    dec_img: image.Image
    dec_ok: bool
    image.load_from_memory(data, &dec_img, &dec_ok)
    if !dec_ok {
        fmt.println("decode failed")
        return
    }
    fmt.println("decode ok, w=", dec_img.w, " h=", dec_img.h, " ch=", dec_img.channels)

    new_h := int(f64(dec_img.h)*400.0/f64(dec_img.w))
    resized := image.resize(dec_img, 400, new_h, 3)
    if !resized.ok {
        fmt.println("resize failed")
        return
    }
    fmt.println("resize ok, w=", resized.img.w, " h=", resized.img.h)

    out := image.encode_jpeg(resized.img, 85)
    if out == nil {
        fmt.println("jpeg encode failed")
        return
    }
    defer delete(out)
    fmt.println("jpeg ok, bytes=", len(out))

    os.write_entire_file("/tmp/test-output.jpg", out)
    fmt.println("wrote /tmp/test-output.jpg")
    image_free(resized.img)
}
