package pipeline

import "core:mem"
import "core:strings"
import "core:os"
import "core:time"
import "core:fmt"
import "core:hash"
import "core:c"
import "../../core/image_cache"

foreign import cube_image "../cube_image/stb_image_wrapper.a"
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

Pipeline_Error :: struct {
    Stage:   string,
    Codec:   string,
    File:    string,
    Message: string,
}

ColorSpace :: enum { RGB, RGBA, GRAY, GRAYA, YCbCr }
AlphaMode :: enum { Opaque, Premultiplied, Straight }
Orientation :: enum { TopLeft, TopRight, BottomRight, BottomLeft }

Image :: struct {
    Width:       u32,
    Height:      u32,
    Pixels:      []u8,
    ColorSpace:  ColorSpace,
    AlphaMode:   AlphaMode,
    Orientation: Orientation,
}

image_free :: proc(img: Image) {
    if img.Pixels != nil {
        delete(img.Pixels)
    }
}

copy_to_channels_direct :: proc(src: []u8, w, h, s_ch, d_ch: int) -> []u8 {
    if s_ch == d_ch { return src }
    if d_ch < s_ch {
        out := make([]u8, w * h * d_ch)
        cnt := w * h
        for i := 0; i < cnt; i += 1 {
            for c := 0; c < d_ch; c += 1 {
                out[i * d_ch + c] = src[i * s_ch + c]
            }
        }
        return out
    }
    return nil
}

pipeline_decode :: proc(data: []u8, file: string) -> (Image, Pipeline_Error) {
    out_w: c.int; out_h: c.int; out_channels: c.int
    ptr := cube_image_load_from_memory(rawptr(&data[0]), c.int(len(data)), &out_w, &out_h, &out_channels)
    if ptr == nil {
        err := Pipeline_Error{Stage="decode", Codec="", File=file, Message="stbi_load_from_memory failed"}
        return Image{}, err
    }
    w, h, ch := int(out_w), int(out_h), int(out_channels)
    px := cube_image_get_data(ptr)
    sz := w * h * ch
    buf := make([]u8, sz)
    mem.copy(rawptr(&buf[0]), px, sz)
    cube_image_free(ptr)
    cs := ColorSpace.RGB
    am := AlphaMode.Opaque
    if ch == 4 { cs = ColorSpace.RGBA; am = AlphaMode.Straight }
    else if ch == 1 { cs = ColorSpace.GRAY }
    else if ch == 2 { cs = ColorSpace.GRAYA; am = AlphaMode.Straight }
    return Image{u32(w), u32(h), buf, cs, am, Orientation.TopLeft}, Pipeline_Error{}
}

pipeline_normalize :: proc(img: ^Image) {
    pipeline_normalize_orientation(img)
    pipeline_normalize_alpha(img)
    pipeline_normalize_colorspace(img)
}

pipeline_normalize_orientation :: proc(img: ^Image) {
    img.Orientation = Orientation.TopLeft
}

pipeline_normalize_colorspace :: proc(img: ^Image) {
    if img.ColorSpace == ColorSpace.GRAYA || img.ColorSpace == ColorSpace.YCbCr || img.ColorSpace == ColorSpace.RGBA {
        if img.AlphaMode == AlphaMode.Opaque {
            if len(img.Pixels) < int(img.Width * img.Height * 3) { return }
            out := make([]u8, int(img.Width * img.Height * 3))
            cnt := int(img.Width * img.Height)
            for i := 0; i < cnt; i += 1 {
                out[i*3+0] = img.Pixels[i*4+0]
                out[i*3+1] = img.Pixels[i*4+1]
                out[i*3+2] = img.Pixels[i*4+2]
            }
            delete(img.Pixels); img.Pixels = out
            img.ColorSpace = ColorSpace.RGB; img.AlphaMode = AlphaMode.Opaque
        }
    }
}

pipeline_normalize_alpha :: proc(img: ^Image) {
    if img.AlphaMode == AlphaMode.Premultiplied {
        cnt := int(img.Width * img.Height)
        ch := 4
        for i := 0; i < cnt; i += 1 {
            a := f32(img.Pixels[i*ch+3]) / 255.0
            if a > 0 {
                img.Pixels[i*ch+0] = u8(f32(img.Pixels[i*ch+0]) * a)
                img.Pixels[i*ch+1] = u8(f32(img.Pixels[i*ch+1]) * a)
                img.Pixels[i*ch+2] = u8(f32(img.Pixels[i*ch+2]) * a)
            }
        }
        img.AlphaMode = AlphaMode.Straight
    }
}

pipeline_resize :: proc(img: Image, nw: int, nh: int) -> Image {
    if nw <= 0 || nh <= 0 { return img }
    channels := 4
    if img.ColorSpace == ColorSpace.RGB || img.ColorSpace == ColorSpace.GRAY { channels = 3 }
    ptr := cube_image_resize(
        rawptr(&img.Pixels[0]),
        c.int(img.Width), c.int(img.Height),
        c.int(nw), c.int(nh), c.int(channels),
    )
    if ptr == nil { return img }
    px := cube_image_get_data(ptr)
    out_sz := nw * nh * channels
    out := make([]u8, out_sz)
    mem.copy(rawptr(&out[0]), px, out_sz)
    cube_image_free(ptr)
    return Image{u32(nw), u32(nh), out, ColorSpace.RGB, AlphaMode.Opaque, Orientation.TopLeft}
}

pipeline_encode_jpeg :: proc(img: Image, quality: int) -> []u8 {
    if len(img.Pixels) == 0 { return nil }
    sp := img.Pixels; sch := 3
    if img.ColorSpace == ColorSpace.RGBA {
        sp = copy_to_channels_direct(img.Pixels, int(img.Width), int(img.Height), 4, 3)
        if sp != nil { sch = 3 } else { sp = img.Pixels; sch = 4 }
    } else if img.ColorSpace == ColorSpace.RGB { sch = 3 }
    out_len: c.int
    ptr := cube_image_encode_jpeg(rawptr(&sp[0]), c.int(img.Width), c.int(img.Height), c.int(sch), c.int(quality), &out_len)
    if ptr == nil || out_len == 0 { return nil }
    out := make([]u8, int(out_len))
    mem.copy(rawptr(&out[0]), ptr, int(out_len))
    cube_image_free_buffer(ptr)
    return out
}

pipeline_encode_png :: proc(img: Image, quality: int) -> []u8 {
    if len(img.Pixels) == 0 { return nil }
    sch := 3
    if img.ColorSpace == ColorSpace.RGBA || img.ColorSpace == ColorSpace.GRAYA { sch = 4 }
    else if img.ColorSpace == ColorSpace.GRAY { sch = 1 }
    out_len: c.int
    ptr := cube_image_encode_png(rawptr(&img.Pixels[0]), c.int(img.Width), c.int(img.Height), c.int(sch), c.int(int(img.Width)*sch), &out_len)
    if ptr == nil || out_len == 0 { return nil }
    out := make([]u8, int(out_len))
    mem.copy(rawptr(&out[0]), ptr, int(out_len))
    cube_image_free_buffer(ptr)
    return out
}

pipeline_choose_mime :: proc(fmt: string) -> string {
    if fmt == "png" { return "image/png" }
    return "image/jpeg"
}

pipeline_parse_format :: proc(accept: string, requested: string) -> string {
    if requested != "" { return strings.to_lower(requested) }
    al := strings.to_lower(accept)
    if strings.contains(al, "image/png") { return "png" }
    return "jpeg"
}

pipeline_key :: proc(file: string, version: string, w: int, h: int, f: string, quality: int) -> string {
    raw := strings.concatenate([]string{file, version, fmt.tprintf("x%d", h), fmt.tprintf("q%d", quality)})
    h := hash.fnv32a(transmute([]byte)raw)
    return fmt.tprintf("%08x.bin", h)
}

pipeline_cache_disk_put :: proc(dir: string, key: string, data: []u8) {
    os.make_directory_all(dir)
    _ = os.write_entire_file(strings.join({dir, key}, "/"), data)
}

pipeline_process :: proc(
    path:        string,
    phys_path:   string,
    w:           int,
    h:           int,
    format_req:   string,
    quality:      int,
    root_dir:     string,
    cache_dir:    string,
    max_bytes:    int,
    max_width:    int,
    max_height:   int,
    img_cfg:      ^image_cache.Image_Cache,
) -> ([]u8, string, bool) {
    if !os.exists(phys_path) { return nil, "", false }
    fi, err := os.stat(phys_path, context.temp_allocator)
    if err != nil || fi.size > i64(max_bytes) { return nil, "", false }
    version := fmt.tprintf("%d_%d", time.time_to_unix(fi.modification_time), int(fi.size))
    ff := strings.to_lower(strings.trim_space(format_req))
    if ff == "avif" || ff == "webp" { ff = "jpeg" }
    key := pipeline_key(phys_path, version, w, h, ff, quality)
    fmime := pipeline_choose_mime(ff)
    cached, cmime, did_hit := image_cache.image_cache_get(img_cfg, key, fmime)
    if did_hit { return cached, fmime, true }
    orig_file, rerr := os.read_entire_file_from_path(phys_path, context.allocator)
    if rerr != nil { return nil, "", false }
    t0 := time.now()
    dec_img, dec_err := pipeline_decode(orig_file, phys_path)
    delete(orig_file)
    if dec_err.Message != "" { return nil, "", false }
    pipeline_normalize(&dec_img)
    tw, th := w, h
    if tw == 0 && th > 0 {
        tw = int(f64(dec_img.Width) * f64(th) / f64(dec_img.Height))
    }
    if th == 0 && tw > 0 {
        th = int(f64(dec_img.Height) * f64(tw) / f64(dec_img.Width))
    }
    if tw > 0 && th > 0 && (tw > int(dec_img.Width) || th > int(dec_img.Height)) {
        tw, th = 0, 0
    }
    if tw > 0 && th > 0 && (tw > max_width || th > max_height) {
        return nil, "", false
    }
    if tw > 0 || th > 0 {
        dec_img = pipeline_resize(dec_img, tw, th)
        if dec_img.Width == 0 || dec_img.Height == 0 { return nil, "", false }
    }
    out := pipeline_encode_jpeg(dec_img, quality)
    if out == nil || len(out) == 0 { return nil, "", false }
    _ = t0
    if len(out) >= int(fi.size) { return nil, "", false }
    image_cache.image_cache_put(img_cfg, key, out, fmime, int(dec_img.Width), int(dec_img.Height))
    pipeline_cache_disk_put(cache_dir, key, out)
    return out, fmime, true
}
