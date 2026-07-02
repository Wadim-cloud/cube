// Per-core worker with isolated event loop and arena
package runtime

import "core:fmt"
import "core:nbio"
import "core:net"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"

import "cube/internal/arena"
import "cube/core/graph"
import "cube/internal/arena"

// Forward declarations
Request :: struct  // defined in http package
str_to_bytes :: proc(s: string) -> []byte
parse_request :: proc(data: []byte) -> (req: Request, ok: bool)
write_response_simple :: proc(sock: net.TCP_Socket, buf: ^[65536]byte, off: ^int, status: u16, mime: string, body: []byte)
graph_resolve :: proc(g: ^graph.Graph, path: string) -> (graph.Handler, bool)

Worker :: struct {
    id:        int,
    loop:      ^nbio.Event_Loop,
    listener:  net.TCP_Socket,
    arena:     arena.Arena,
    graph:     graph.Graph,
    running:   bool,
}

// Start a worker on its own thread with its own acceptor
worker_start :: proc(w: ^Worker) {
    w.running = true

    // Acquire event loop for this thread
    err := nbio.acquire_thread_event_loop()
    if err != nil {
        fmt.println(fmt.tprintf("cube: worker %d event loop init failed", w.id))
        return
    }
    defer nbio.release_thread_event_loop()
    w.loop = nbio.event_loop()

    fmt.printf("cube: worker %d started\n", w.id)

    // Accept loop for this worker
    for {
        if !w.running {
            break
        }

        client, _, err := net.accept_tcp(w.listener)
        if err != .None {
            continue
        }

        // Handle request inline (on this worker's thread)
        w.handle_request(client)
    }

    fmt.printf("cube: worker %d stopped\n", w.id)
}

handle_request :: proc(w: ^Worker, sock: net.TCP_Socket) {
    defer net.close(sock)

    recv_buf := make([]byte, 65536)
    send_buf: [65536]byte
    send_off := 0

    for {
        n, err := net.recv_tcp(sock, recv_buf)
        if err != .None || n == 0 {
            return
        }

        req, ok := parse_request(recv_buf[:n])
        if !ok {
            write_response_simple(sock, &send_buf, &send_off, 400, "text/plain", str_to_bytes("Bad Request"))
            return
        }

        // Execute compiled execution graph (zero runtime string lookup)
        handler, found := graph_resolve(&w.graph, string(req.path))
        if !found {
            write_response_simple(sock, &send_buf, &send_off, 404, "text/html", str_to_bytes("<html><body><h1>404 Not Found</h1></body></html>"))
            delete(req.buf)
            continue
        }

        // Execute handler with isolated arena
        arena.arena_reset(&w.arena)
        handler(&req)
        delete(req.buf)

        // Reset arena after request
        arena.arena_reset(&w.arena)
    }
}
