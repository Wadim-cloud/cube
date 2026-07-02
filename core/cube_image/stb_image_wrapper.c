#define STB_IMAGE_IMPLEMENTATION
#include "/home/ds/.local/odin/vendor/stb/src/stb_image.h"

#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "/home/ds/.local/odin/vendor/stb/src/stb_image_resize.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "/home/ds/.local/odin/vendor/stb/src/stb_image_write.h"

#define _GNU_SOURCE
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>

typedef struct {
    int w, h, channels;
    unsigned char *data;
} CImage;

CImage* cube_image_load(const char *path, int *out_w, int *out_h, int *out_channels) {
    CImage *img = (CImage*)malloc(sizeof(CImage));
    if (!img) return NULL;
    img->data = stbi_load(path, out_w, out_h, out_channels, 0);
    if (!img->data) { free(img); return NULL; }
    img->w = *out_w;
    img->h = *out_h;
    img->channels = *out_channels;
    return img;
}

CImage* cube_image_load_from_memory(const unsigned char *bytes, int len, int *out_w, int *out_h, int *out_channels) {
    CImage *img = (CImage*)malloc(sizeof(CImage));
    if (!img) return NULL;
    img->data = stbi_load_from_memory(bytes, len, out_w, out_h, out_channels, 0);
    if (!img->data) { free(img); return NULL; }
    img->w = *out_w;
    img->h = *out_h;
    img->channels = *out_channels;
    return img;
}

void cube_image_free(CImage *img) {
    if (img) {
        if (img->data) stbi_image_free(img->data);
        free(img);
    }
}

void cube_image_free_buffer(unsigned char *buf) {
    if (buf) free(buf);
}

const unsigned char* cube_image_get_data(const CImage *img) {
    return img ? img->data : NULL;
}

unsigned char* cube_image_encode_webp(const unsigned char *pixels, int w, int h, int channels, int quality, int *out_len) {
#ifdef HAVE_WEBP
    uint8_t *out = NULL;
    int stride = w * channels;
    int ok = WebPEncodeRGB(pixels, w, h, stride, (float)quality, &out);
    if (!ok || !out) return NULL;
    // WebP library does not expose output size directly via this API,
    // so we write to a file.
    // For now, return NULL until a proper memory-based path is added.
#else
    (void)pixels; (void)w; (void)h; (void)channels; (void)quality; (void)out_len;
#endif
    return NULL;
}

CImage* cube_image_resize(const unsigned char *pixels, int src_w, int src_h, int new_w, int new_h, int channels) {
    if (!pixels || new_w <= 0 || new_h <= 0 || channels <= 0) return NULL;
    CImage *dst = (CImage*)malloc(sizeof(CImage));
    if (!dst) return NULL;
    dst->data = (unsigned char*)malloc(new_w * new_h * channels);
    if (!dst->data) { free(dst); return NULL; }
    int ok = stbir_resize_uint8(pixels, src_w, src_h, 0,
                                dst->data, new_w, new_h, 0, channels);
    if (!ok) {
        free(dst->data);
        free(dst);
        return NULL;
    }
    dst->w = new_w;
    dst->h = new_h;
    dst->channels = channels;
    return dst;
}

unsigned char* cube_image_encode_jpeg(const unsigned char *pixels, int w, int h, int channels, int quality, int *out_len) {
    char tmpl[] = "/tmp/cube_jpeg_XXXXXX.jpg";
    int fd = mkstemps(tmpl, 4);
    if (fd < 0) {
        fd = mkstemp(tmpl);
        if (fd < 0) return NULL;
        if (strlen(tmpl) + 4 < sizeof(tmpl)) {
            strcat(tmpl, ".jpg");
        }
    }
    close(fd);
    stbi_write_jpg(tmpl, w, h, channels, pixels, quality);
    FILE *f = fopen(tmpl, "rb");
    if (!f) { unlink(tmpl); return NULL; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *buf = (unsigned char*)malloc(sz);
    if (buf) fread(buf, 1, sz, f);
    fclose(f);
    unlink(tmpl);
    if (out_len && buf) *out_len = (int)sz;
    return buf;
}

unsigned char* cube_image_encode_png(const unsigned char *pixels, int w, int h, int channels, int stride, int *out_len) {
    return stbi_write_png_to_mem(pixels, stride, w, h, channels, out_len);
}
