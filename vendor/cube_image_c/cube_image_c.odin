package cube_image_c

import "core:c"

foreign import cube_image "system:stb_wrapper"

@(default_calling_convention="c")
foreign cube_image {
    load_from_file :: proc(path: cstring, out_w: ^c.int, out_h: ^c.int, out_channels: ^c.int) -> rawptr ---
    load_from_memory :: proc(bytes: rawptr, len: c.int, out_w: ^c.int, out_h: ^c.int, out_channels: ^c.int) -> rawptr ---
    free :: proc(ptr: rawptr) ---
    resize :: proc(src: rawptr, src_w: c.int, src_h: c.int, new_w: c.int, new_h: c.int, channels: c.int) -> rawptr ---
    encode_png_to_mem :: proc(data: rawptr, w: c.int, h: c.int, channels: c.int, stride: c.int, out_len: ^c.int) -> rawptr ---
}
