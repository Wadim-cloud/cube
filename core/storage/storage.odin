package storage

import "core:os"
import "core:strings"
import "core:mem"
import "core:fmt"
import "core:time"

// Storage backend abstraction for image cache
// Currently uses local filesystem, designed for future S3/GCS/Azure backends

Storage_Backend :: struct {
    backend_type: string,
    base_path:    string,
}

storage_init :: proc(dir: string) -> Storage_Backend {
    os.make_directory_all(dir)
    return {
        backend_type = "local",
        base_path = dir,
    }
}

storage_get :: proc(backend: ^Storage_Backend, key: string) -> ([]byte, bool) {
    if backend.backend_type == "local" {
        path := strings.join({backend.base_path, key}, "/")
        if os.exists(path) {
            data, err := os.read_entire_file_from_path(path, context.allocator)
            if err == nil {
                return data, true
            }
        }
    }
    return nil, false
}

storage_put :: proc(backend: ^Storage_Backend, key: string, data: []byte) -> bool {
    if backend.backend_type == "local" {
        os.make_directory_all(backend.base_path)
        path := strings.join({backend.base_path, key}, "/")
        err := os.write_entire_file(path, data)
        return err == nil
    }
    return false
}

storage_delete :: proc(backend: ^Storage_Backend, key: string) -> bool {
    if backend.backend_type == "local" {
        path := strings.join({backend.base_path, key}, "/")
        return os.remove(path) == nil
    }
    return false
}

storage_exists :: proc(backend: ^Storage_Backend, key: string) -> bool {
    if backend.backend_type == "local" {
        path := strings.join({backend.base_path, key}, "/")
        return os.exists(path)
    }
    return false
}
