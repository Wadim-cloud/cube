package codecs

import "core:mem"
import "core:strings"
import "core:c"

foreign import cube_image "../core/cube_image/stb_image_wrapper.a"
@(default_calling_convention="c")
foreign cube_image {
    cube_image_load_from_memory :: proc(bytes: rawptr, len: c.int, out_w: ^c.int, out_h: ^c.int, out_channels: ^c.int) -> rawptr ---
    cube_image_free :: proc(img: rawptr) ---
    cube_image_get_data :: proc(img: rawptr) -> rawptr ---
    cube_image_encode_jpeg :: proc(data: rawptr, w: c.int, h: c.int, channels: c.int, quality: c.int, out_len: ^c.int) -> rawptr ---
    cube_image_encode_png :: proc(data: rawptr, w: c.int, h: c.int, channels: c.int, stride: c.int, out_len: ^c.int) -> rawptr ---
    cube_image_free_buffer :: proc(buf: rawptr) ---
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

Decoder :: struct {
    Name:      string,
    CanDecode: proc(ext: string, data: []u8) -> bool,
    Decode:    proc(data: []u8, file: string) -> Image,
}

Encoder :: struct {
    Name:          string,
    SupportsAlpha: bool,
    Encode:        proc(img: Image, quality: int) -> []u8,
}

Decoder_Registry :: struct {
    decoders: []Decoder,
}

Encoder_Registry :: struct {
    encoders: map[string]Encoder,
}

jpeg_can_decode :: proc(ext: string, data: []u8) -> bool {
    if ext == "jpg" || ext == "jpeg" {
        return true
    }
    if len(data) >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF {
        return true
    }
    return false
}

jpeg_decode :: proc(data: []u8, file: string) -> Image {
    out_w: c.int; out_h: c.int; out_channels: c.int
    ptr := cube_image_load_from_memory(rawptr(&data[0]), c.int(len(data)), &out_w, &out_h, &out_channels)
    if ptr == nil {
        return Image{}
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
    return Image{u32(w), u32(h), buf, cs, am, Orientation.TopLeft}
}

jpeg_encode :: proc(img: Image, quality: int) -> []u8 {
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

png_can_decode :: proc(ext: string, data: []u8) -> bool {
    if ext == "png" {
        return true
    }
    if len(data) >= 4 && data[0] == 0x89 && data[1] == 'P' && data[2] == 'N' && data[3] == 'G' {
        return true
    }
    return false
}

png_decode :: proc(data: []u8, file: string) -> Image {
    return jpeg_decode(data, file)
}

png_encode :: proc(img: Image, quality: int) -> []u8 {
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

webp_can_decode :: proc(ext: string, data: []u8) -> bool {
    if ext == "webp" {
        return true
    }
    if len(data) >= 4 && data[0] == 'R' && data[1] == 'I' && data[2] == 'F' && data[3] == 'F' {
        return true
    }
    return false
}

webp_decode :: proc(data: []u8, file: string) -> Image {
    return Image{}
}

webp_encode :: proc(img: Image, quality: int) -> []u8 {
    return nil
}

decoder_registry_init :: proc() -> Decoder_Registry {
    reg := Decoder_Registry{decoders = make([]Decoder, 3)}
    reg.decoders[0] = Decoder{
        Name = "jpeg",
        CanDecode = jpeg_can_decode,
        Decode = jpeg_decode,
    }
    reg.decoders[1] = Decoder{
        Name = "png",
        CanDecode = png_can_decode,
        Decode = png_decode,
    }
    reg.decoders[2] = Decoder{
        Name = "webp",
        CanDecode = webp_can_decode,
        Decode = webp_decode,
    }
    return reg
}

encoder_registry_init :: proc() -> Encoder_Registry {
    reg := Encoder_Registry{encoders = make(map[string]Encoder)}
    reg.encoders["jpeg"] = Encoder{Name = "jpeg", SupportsAlpha = false, Encode = jpeg_encode}
    reg.encoders["jpg"] = Encoder{Name = "jpg", SupportsAlpha = false, Encode = jpeg_encode}
    reg.encoders["png"] = Encoder{Name = "png", SupportsAlpha = true, Encode = png_encode}
    return reg
}
