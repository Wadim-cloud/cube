package pipeline

import "core:mem"
import "core:strings"
import "core:os"
import "core:time"
import "core:fmt"
import "core:hash"
import "core:c"
import "../../core/image_cache"
import "../../codecs"

foreign import cube_image "../cube_image/stb_image_wrapper.a"
@(default_calling_convention="c")
foreign cube_image {
    cube_image_resize :: proc(pixels: rawptr, src_w: c.int, src_h: c.int, new_w: c.int, new_h: c.int, channels: c.int) -> rawptr ---
    cube_image_get_data :: proc(img: rawptr) -> rawptr ---
    cube_image_free :: proc(img: rawptr) ---
}

Pipeline_Error :: struct {
    Stage:   string,
    Codec:   string,
    File:    string,
    Message: string,
}

Validation_Error :: struct {
    Stage:   string,
    Codec:   string,
    File:    string,
    Message: string,
}

pipeline_validate :: proc(file: string, data: []u8, img: codecs.Image, max_bytes: i64) -> Validation_Error {
    if img.Width == 0 || img.Height == 0 {
        return Validation_Error{Stage="validate", Codec="", File=file, Message="invalid dimensions"}
    }
    if img.Width > 0x8000 || img.Height > 0x8000 {
        return Validation_Error{Stage="validate", Codec="", File=file, Message="dimensions exceed maximum"}
    }
    expected := u64(img.Width) * u64(img.Height) * u64(4)
    if expected > 0xFFFFFFFF {
        return Validation_Error{Stage="validate", Codec="", File=file, Message="integer overflow in pixel buffer"}
    }
    if len(img.Pixels) > 0 && u64(len(img.Pixels)) != u64(img.Width) * u64(img.Height) * u64(4) {
        if len(img.Pixels) != int(u64(img.Width) * u64(img.Height) * u64(3)) {
            return Validation_Error{Stage="validate", Codec="", File=file, Message="pixel buffer size mismatch"}
        }
    }
    if len(data) == 0 {
        return Validation_Error{Stage="validate", Codec="", File=file, Message="empty input data"}
    }
    if i64(len(data)) > max_bytes {
        return Validation_Error{Stage="validate", Codec="", File=file, Message="file exceeds maximum size"}
    }
    return Validation_Error{}
}

pipeline_decode :: proc(r: ^codecs.Decoder_Registry, data: []u8, file: string) -> (codecs.Image, Pipeline_Error) {
    ext := ""
    if idx := strings.index(file, "."); idx != -1 {
        ext = strings.to_lower(file[idx+1:])
    }
    for dec in r.decoders {
        if dec.CanDecode(ext, data) {
            img := dec.Decode(data, file)
            if img.Width == 0 && img.Height == 0 {
                return codecs.Image{}, Pipeline_Error{Stage="decode", Codec=dec.Name, File=file, Message="decode failed"}
            }
            return img, Pipeline_Error{}
        }
    }
    return codecs.Image{}, Pipeline_Error{Stage="decode", Codec="unknown", File=file, Message="no decoder found"}
}

pipeline_normalize :: proc(img: ^codecs.Image) {
    pipeline_normalize_orientation(img)
    pipeline_normalize_alpha(img)
    pipeline_normalize_colorspace(img)
}

pipeline_normalize_orientation :: proc(img: ^codecs.Image) {
    img.Orientation = codecs.Orientation.TopLeft
}

pipeline_normalize_colorspace :: proc(img: ^codecs.Image) {
    if img.ColorSpace == codecs.ColorSpace.GRAYA || img.ColorSpace == codecs.ColorSpace.YCbCr || img.ColorSpace == codecs.ColorSpace.RGBA {
        if img.AlphaMode == codecs.AlphaMode.Opaque {
            if len(img.Pixels) < int(img.Width * img.Height * 3) { return }
            out := make([]u8, int(img.Width * img.Height * 3))
            cnt := int(img.Width * img.Height)
            for i := 0; i < cnt; i += 1 {
                out[i*3+0] = img.Pixels[i*4+0]
                out[i*3+1] = img.Pixels[i*4+1]
                out[i*3+2] = img.Pixels[i*4+2]
            }
            delete(img.Pixels); img.Pixels = out
            img.ColorSpace = codecs.ColorSpace.RGB; img.AlphaMode = codecs.AlphaMode.Opaque
        }
    }
}

pipeline_normalize_alpha :: proc(img: ^codecs.Image) {
    if img.AlphaMode == codecs.AlphaMode.Premultiplied {
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
        img.AlphaMode = codecs.AlphaMode.Straight
    }
}

pipeline_resize :: proc(img: codecs.Image, nw: int, nh: int) -> codecs.Image {
    if nw <= 0 || nh <= 0 { return img }
    channels := 4
    if img.ColorSpace == codecs.ColorSpace.RGB || img.ColorSpace == codecs.ColorSpace.GRAY { channels = 3 }
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
    return codecs.Image{u32(nw), u32(nh), out, codecs.ColorSpace.RGB, codecs.AlphaMode.Opaque, codecs.Orientation.TopLeft}
}

pipeline_encode :: proc(r: ^codecs.Encoder_Registry, img: codecs.Image, format_req: string, quality: int) -> []u8 {
    fmt := format_req
    if fmt == "" {
        if img.AlphaMode != codecs.AlphaMode.Opaque { fmt = "png" } else { fmt = "jpeg" }
    }
    fmt = strings.to_lower(fmt)
    if fmt == "jpg" { fmt = "jpeg" }
    enc, ok := r.encoders[fmt]
    if !ok {
        if img.AlphaMode != codecs.AlphaMode.Opaque { enc = r.encoders["png"] } else { enc = r.encoders["jpeg"] }
    }
    return enc.Encode(img, quality)
}

pipeline_choose_mime :: proc(fmt: string) -> string {
    if fmt == "png" { return "image/png" }
    return "image/jpeg"
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
    format_req:  string,
    quality:     int,
    root_dir:    string,
    cache_dir:   string,
    max_bytes:   int,
    max_width:   int,
    max_height:  int,
    img_cfg:     ^image_cache.Image_Cache,
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
    dec_reg := codecs.decoder_registry_init()
    dec_img, dec_err := pipeline_decode(&dec_reg, orig_file, phys_path)
    delete(orig_file)
    if dec_err.Message != "" { return nil, "", false }
    v_err := pipeline_validate(phys_path, orig_file, dec_img, i64(max_bytes))
    if v_err.Message != "" { return nil, "", false }
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
    enc_reg := codecs.encoder_registry_init()
    out := pipeline_encode(&enc_reg, dec_img, ff, quality)
    if out == nil || len(out) == 0 { return nil, "", false }
    if len(out) >= int(fi.size) { return nil, "", false }
    image_cache.image_cache_put(img_cfg, key, out, fmime, int(dec_img.Width), int(dec_img.Height))
    pipeline_cache_disk_put(cache_dir, key, out)
    return out, fmime, false
}
