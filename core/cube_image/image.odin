package cube_image

import "core:mem"
import "core:c"
import "core:strings"

foreign import cube_image "stb_image_wrapper.a"

@(default_calling_convention="c")
foreign cube_image {
	cube_image_load           :: proc(path: cstring, out_w: ^c.int, out_h: ^c.int, out_channels: ^c.int) -> rawptr ---
	cube_image_load_from_memory :: proc(bytes: rawptr, len: c.int, out_w: ^c.int, out_h: ^c.int, out_channels: ^c.int) -> rawptr ---
	cube_image_free           :: proc(img: rawptr) ---
	cube_image_resize         :: proc(pixels: rawptr, src_w: c.int, src_h: c.int, new_w: c.int, new_h: c.int, channels: c.int) -> rawptr ---
	cube_image_encode_png     :: proc(data: rawptr, w: c.int, h: c.int, channels: c.int, stride: c.int, out_len: ^c.int) -> rawptr ---
	cube_image_encode_jpeg    :: proc(data: rawptr, w: c.int, h: c.int, channels: c.int, quality: c.int, out_len: ^c.int) -> rawptr ---
	cube_image_encode_webp    :: proc(data: rawptr, w: c.int, h: c.int, channels: c.int, quality: c.int, out_len: ^c.int) -> rawptr ---
	cube_image_free_buffer    :: proc(buf: rawptr) ---
	cube_image_get_data       :: proc(img: rawptr) -> rawptr ---
}

Image :: struct {
    w:        int,
    h:        int,
    channels: int,
    data:     []byte,
    data_len: int,
}

Image_Result :: struct {
    img: Image,
    ok:  bool,
    err: string,
}

load_from_file :: proc(path: string) -> Image_Result {
    out_w, out_h, out_channels: c.int
    cpath := strings.clone_to_cstring(path)
    data := cube_image_load(cpath, &out_w, &out_h, &out_channels)
    delete(cpath)
    if data == nil {
        return {ok = false, err = "decode failed"}
    }
    w, h, ch := int(out_w), int(out_h), int(out_channels)
    sz := w * h * ch
    buf := make([]byte, sz)
    mem.copy(rawptr(&buf[0]), data, sz)
    cube_image_free(data)
    return {img = {w = w, h = h, channels = ch, data = buf}, ok = true}
}

load_from_memory :: proc(bytes: []byte, result: ^Image, ok: ^bool) {
    if len(bytes) == 0 {
        if ok != nil { ok^ = false }
        return
    }
    out_w, out_h, out_channels: c.int
    img_ptr := cube_image_load_from_memory(rawptr(&bytes[0]), c.int(len(bytes)), &out_w, &out_h, &out_channels)
    if img_ptr == nil || result == nil {
        if ok != nil { ok^ = false }
        return
    }
    w, h, ch := int(out_w), int(out_h), int(out_channels)
    sz := w * h * ch
    pixel_ptr := cube_image_get_data(img_ptr)
    buf := make([]byte, sz)
    mem.copy(rawptr(&buf[0]), pixel_ptr, sz)
    cube_image_free(img_ptr)
    result^ = {w = w, h = h, channels = ch, data = buf, data_len = sz}
    if ok != nil { ok^ = true }
}

resize :: proc(src: Image, new_w: int, new_h: int, channels: int) -> Image_Result {
    if new_w <= 0 || new_h <= 0 || channels <= 0 {
        return {ok = false, err = "invalid resize"}
    }
    img_ptr := cube_image_resize(rawptr(&src.data[0]), c.int(src.w), c.int(src.h), c.int(new_w), c.int(new_h), c.int(channels))
    if img_ptr == nil {
        return {ok = false, err = "resize failed"}
    }
    pixel_ptr := cube_image_get_data(img_ptr)
    out := make([]byte, new_w * new_h * channels)
    mem.copy(rawptr(&out[0]), pixel_ptr, new_w * new_h * channels)
    cube_image_free(img_ptr)
    return {img = {w = new_w, h = new_h, channels = channels, data = out}, ok = true}
}

copy_to_channels :: proc(src: Image, dst_channels: int) -> Image_Result {
    if src.channels == dst_channels {
        return {img = src, ok = true}
    }
    if dst_channels < src.channels {
        return {img = {w = src.w, h = src.h, channels = dst_channels, data = src.data[:src.w * src.h * dst_channels]}, ok = true}
    }
    return {ok = false, err = "channel expansion not supported"}
}

encode_png :: proc(img: Image) -> []byte {
    if len(img.data) == 0 { return nil }
    out_len: c.int
    ptr := cube_image_encode_png(rawptr(&img.data[0]), c.int(img.w), c.int(img.h), c.int(img.channels), c.int(img.w * img.channels), &out_len)
    if ptr == nil || out_len == 0 { return nil }
    out := make([]byte, int(out_len))
    mem.copy(rawptr(&out[0]), ptr, int(out_len))
    cube_image_free_buffer(ptr)
    return out
}

encode_jpeg :: proc(img: Image, quality: int) -> []byte {
    if len(img.data) == 0 { return nil }
    src := img
    if img.channels == 4 {
        conv := copy_to_channels(img, 3)
        if !conv.ok { return nil }
        src = conv.img
    }
    out_len: c.int
    ptr := cube_image_encode_jpeg(rawptr(&src.data[0]), c.int(src.w), c.int(src.h), c.int(src.channels), c.int(quality), &out_len)
    if ptr == nil || out_len == 0 { return nil }
    out := make([]byte, int(out_len))
    mem.copy(rawptr(&out[0]), ptr, int(out_len))
    cube_image_free_buffer(ptr)
    return out
}

encode_webp :: proc(img: Image, quality: int) -> []byte {
    if len(img.data) == 0 { return nil }
    out_len: c.int
    ptr := cube_image_encode_webp(rawptr(&img.data[0]), c.int(img.w), c.int(img.h), c.int(img.channels), c.int(quality), &out_len)
    if ptr == nil || out_len == 0 { return nil }
    out := make([]byte, int(out_len))
    mem.copy(rawptr(&out[0]), ptr, int(out_len))
    cube_image_free_buffer(ptr)
    return out
}

image_free :: proc(img: Image) {
    if img.data != nil {
        delete(img.data)
    }
}