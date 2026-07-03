package internal

import "core:sync"
import "core:atomic"

RwLock :: struct {
    mutex: sync.RW_Mutex,
}

rwlock_init :: proc() -> RwLock {
    return RwLock{mutex: sync.rwmutex_create()}
}

rwlock_read :: proc(l: ^RwLock) {
    sync.rwmutex_read_lock(&l.mutex)
}

rwlock_read_unlock :: proc(l: ^RwLock) {
    sync.rwmutex_read_unlock(&l.mutex)
}

rwlock_write :: proc(l: ^RwLock) {
    sync.rwmutex_write_lock(&l.mutex)
}

rwlock_write_unlock :: proc(l: ^RwLock) {
    sync.rwmutex_write_unlock(&l.mutex)
}
