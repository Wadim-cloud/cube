package eventbus

import "core:fmt"
import "core:net"
import "core:sync"
import "core:time"

EVENT_BUS_CAPACITY :: 256
EVENT_ENTRY_SIZE   :: 256
MAX_SSE_CLIENTS    :: 16

Event_Type :: enum {
    METRICS,
    ADJUSTMENT,
    STATUS,
    VISITOR,
}

Visitor_Event :: struct {
    path:     [128]byte,
    path_len: int,
    ip:       [64]byte,
    ip_len:   int,
    ts:       i64,
}

Event_Entry :: struct {
    event_type: Event_Type,
    data:       [EVENT_ENTRY_SIZE]byte,
    data_len:   int,
}

Event_bus:        [EVENT_BUS_CAPACITY]Event_Entry
Event_bus_write:  u64
Event_bus_mutex:  sync.Mutex
Sse_clients:      [MAX_SSE_CLIENTS]net.TCP_Socket
Sse_client_count: int

Event_bus_publish :: proc(et: Event_Type, data: string) {
    if len(data) > EVENT_ENTRY_SIZE {
        return
    }
    slot := int(sync.atomic_load(&Event_bus_write) % u64(EVENT_BUS_CAPACITY))
    e := &Event_bus[slot]
    e.event_type = et
    e.data_len = len(data)
    if len(data) > 0 {
        copy(e.data[:], transmute([]byte)data)
    }
    sync.atomic_add(&Event_bus_write, 1)
}

Event_bus_publish_visitor :: proc(v: ^Visitor_Event) {
    path_str := string(v.path[:v.path_len])
    ip_str := string(v.ip[:v.ip_len])
    data := fmt.tprintf("{\"path\":\"%s\",\"ip\":\"%s\",\"ts\":%d}", path_str, ip_str, v.ts)
    Event_bus_publish(.VISITOR, data)
}

Event_bus_register :: proc(sock: net.TCP_Socket) -> bool {
    sync.mutex_lock(&Event_bus_mutex)
    defer sync.mutex_unlock(&Event_bus_mutex)

    idx := -1
    for i := 0; i < MAX_SSE_CLIENTS; i += 1 {
        if Sse_clients[i] == (net.TCP_Socket{}) {
            idx = i
            break
        }
    }
    if idx == -1 {
        idx = 0
    }
    Sse_clients[idx] = sock
    if idx >= Sse_client_count {
        Sse_client_count = idx + 1
    }
    return true
}

Event_bus_unregister :: proc(sock: net.TCP_Socket) {
    sync.mutex_lock(&Event_bus_mutex)
    defer sync.mutex_unlock(&Event_bus_mutex)

    for i := 0; i < Sse_client_count; i += 1 {
        if Sse_clients[i] == sock {
            Sse_clients[i] = net.TCP_Socket{}
            for j := i; j < Sse_client_count - 1; j += 1 {
                Sse_clients[j] = Sse_clients[j + 1]
            }
            Sse_client_count -= 1
            break
        }
    }
}

Event_bus_drain :: proc(sock: net.TCP_Socket, last_seen: ^u64) {
    head := sync.atomic_load(&Event_bus_write)
    if head <= last_seen^ + 1 {
        return
    }

    total := int(head - last_seen^ - 1)
    if total > EVENT_BUS_CAPACITY {
        total = EVENT_BUS_CAPACITY
    }

    start_slot := int((last_seen^ + 1) % u64(EVENT_BUS_CAPACITY))

    for i := 0; i < total; i += 1 {
        idx := (start_slot + i) % EVENT_BUS_CAPACITY
        e := &Event_bus[idx]
        frame := fmt.tprintf("event: %s\ndata: %s\n\n",
            event_type_to_string(e.event_type),
            string(e.data[:e.data_len]),
        )
        _, serr := net.send_tcp(sock, transmute([]byte)frame)
        if serr != nil {
            return
        }
        last_seen^ += 1
    }
}

event_type_to_string :: proc(et: Event_Type) -> string {
    switch et {
    case .METRICS:    return "metric"
    case .ADJUSTMENT: return "adjustment"
    case .STATUS:     return "status"
    case .VISITOR:    return "visitor"
    case:             return "unknown"
    }
}
