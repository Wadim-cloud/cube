package image_jobs

import "core:time"
import "core:fmt"
import "core:os"
import "core:strings"
import "../cube_image"
import "../image_cache"
import "core:sync"

// Background job: generate variants of an image
Image_Job :: struct {
    path:       string,
    width:      int,
    height:     int,
    format:     string,
    quality:    int,
    root_dir:   string,
    cache_dir:  string,
    max_mem_mb: int,
}

Max_Image_Jobs :: 4096

image_job_queue: [Max_Image_Jobs]Image_Job
image_job_head: u64
image_job_tail: u64
image_job_mutex: sync.Mutex

image_job_has_work: bool

image_jobs_init :: proc() {
    image_job_has_work = false
}

image_job_submit :: proc(job: Image_Job) -> bool {
    sync.mutex_lock(&image_job_mutex)
    head := sync.atomic_load(&image_job_head)
    tail := sync.atomic_load(&image_job_tail)
    if (tail + 1) % u64(Max_Image_Jobs) == head {
        sync.mutex_unlock(&image_job_mutex)
        return false
    }
    image_job_queue[tail % u64(Max_Image_Jobs)] = job
    sync.atomic_add(&image_job_tail, 1)
    image_job_has_work = true
    sync.mutex_unlock(&image_job_mutex)
    return true
}

image_job_worker :: proc() {
    for {
        sync.mutex_lock(&image_job_mutex)
        head := sync.atomic_load(&image_job_head)
        tail := sync.atomic_load(&image_job_tail)
        for head == tail {
            image_job_has_work = false
            sync.mutex_unlock(&image_job_mutex)
            time.sleep(time.Millisecond * 100)
            sync.mutex_lock(&image_job_mutex)
            head = sync.atomic_load(&image_job_head)
            tail = sync.atomic_load(&image_job_tail)
            if image_job_has_work { break }
        }
        job := image_job_queue[head % u64(Max_Image_Jobs)]
        sync.atomic_add(&image_job_head, 1)
        sync.mutex_unlock(&image_job_mutex)

        _ = process_image_job(job)
    }
}

process_image_job :: proc(job: Image_Job) -> bool {
    phys := strings.join({job.root_dir, job.path}, "")
    if !os.exists(phys) { return false }

    fi, err := os.stat(phys, context.temp_allocator)
    if err != nil || fi.size > 10 * 1024 * 1024 { return false }

    version := fmt.aprintf("%d_%d", time.time_to_unix(fi.modification_time), int(fi.size))
    key := image_cache.image_cache_key(job.path, version, job.width, job.height, job.format, job.quality)

    cache := image_cache.image_cache_init(job.cache_dir, job.max_mem_mb)
    _, _, hit := image_cache.image_cache_get(&cache, key, "")
    if hit { return true }

    file, rerr := os.read_entire_file_from_path(phys, context.allocator)
    if rerr != nil { return false }
    dec_img: cube_image.Image
    dec_ok: bool
    cube_image.load_from_memory(file, &dec_img, &dec_ok)
    delete(file)
    if !dec_ok { return false }
    defer cube_image.image_free(dec_img)

    tw, th := job.width, job.height
    if tw == 0 && th > 0 {
        tw = int(f64(dec_img.w) * f64(th) / f64(dec_img.h))
    }
    if th == 0 && tw > 0 {
        th = int(f64(dec_img.h) * f64(tw) / f64(dec_img.w))
    }
    if tw > dec_img.w || th > dec_img.h {
        return false
    }

    if tw > 0 || th > 0 {
        resized := cube_image.resize(dec_img, tw, th, dec_img.channels)
        if !resized.ok { return false }
        defer cube_image.image_free(resized.img)
        dec_img = resized.img
    }

    out: []byte
    if job.format == "jpeg" {
        out = cube_image.encode_jpeg(dec_img, job.quality)
    } else if job.format == "png" {
        out = cube_image.encode_png(dec_img)
    }
    if out == nil { return false }

    mime := image_cache.guess_mime(strings.concatenate([]string{"x.", job.format}))
    image_cache.image_cache_put(&cache, key, out, mime, dec_img.w, dec_img.h)
    return true
}

image_job_queue_background :: proc(_: int) {
    for {
        image_job_worker()
    }
}

image_job_queue_async :: proc(path: string, w: int, h: int, root_dir: string, cache_dir: string, max_mem_mb: int) {
    formats := []string{"jpeg", "png"}
    sizes := []int{400, 800, 1200, 1600}
    quality := 85

    for fmt in formats {
        for sz in sizes {
            if sz == w { continue }
            job := Image_Job{
                path = path,
                width = sz,
                height = 0,
                format = fmt,
                quality = quality,
                root_dir = root_dir,
                cache_dir = cache_dir,
                max_mem_mb = max_mem_mb,
            }
            image_job_submit(job)
        }
    }
}
