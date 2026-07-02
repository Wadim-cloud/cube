package cube

import "core:fmt"
import "core:net"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

// Config holds server configuration
Config :: struct {
    addr:       string,
    root:       string,
    timeout:    time.Duration,
    keepalive:  time.Duration,
    workers:    int,
}

// Server holds runtime state
Server :: struct {
    config:   Config,
    listener: net.TCP_Socket,
    running:  bool,
}

// Atomic running flag for signal-safe shutdown
server_running: i32 = 1

default_config :: proc() -> Config {
    return Config{
        addr      = ":8080",
        root      = "./dist",
        timeout   = time.Second * 30,
        keepalive = time.Second * 75,
        workers   = 4,
    }
}

// start begins accepting connections. Blocks until stop() is called.
start :: proc(s: ^Server) {
    sync.atomic_store(&server_running, 1, .Release)
    setup_signals()

    endpoint, ok := net.parse_endpoint(s.config.addr)
    if !ok {
        fmt.eprintf("cube: bad address %s\n", s.config.addr)
        os.exit(1)
    }

    listener, err := net.listen_tcp(endpoint, 4096)
    if err != nil {
        fmt.eprintf("cube: listen failed on %s: %v\n", s.config.addr, err)
        os.exit(1)
    }
    s.listener = listener
    defer net.close(listener)

    fmt.printf("cube: listening on %s (root=%s)\n", s.config.addr, s.config.root)

    for {
        running := sync.atomic_load(&server_running, .Acquire)
        if running == 0 {
            break
        }

        client, _, err := net.accept_tcp(listener)
        if err != nil {
            if running != 0 {
                fmt.eprintf("cube: accept: %v\n", err)
            }
            continue
        }

        thread.create_and_start_with_poly_data(client, proc(sock: net.TCP_Socket) {
            handle_connection(sock, s.config)
            net.close(sock)
        })
    }

    fmt.println("cube: stopped")
}

// stop requests shutdown.
stop :: proc(s: ^Server) {
    sync.atomic_store(&server_running, 0, .Release)
    net.close(s.listener)
}

// handle_connection reads from the socket until close.
// Phase 1: simple read loop. Will become HTTP parser in Phase 2.
handle_connection :: proc(sock: net.TCP_Socket, cfg: Config) {
    buf := make([]byte, 8192)

    for {
        n, err := net.recv_tcp(sock, buf)
        if err != nil || n == 0 {
            return
        }

        // Phase 1: echo back for now
        send_buf := slice.clone(buf[:n])
        _, send_err := net.send_tcp(sock, send_buf)
        delete(send_buf)
        if send_err != nil {
            return
        }
    }
}

// setup_signals registers SIGTERM and SIGINT for graceful shutdown.
setup_signals :: proc() {
    act: posix.sigaction_t
    act.sa_handler = cast(posix.sa_handler) on_signal
    posix.sigemptyset(&act.sa_mask)
    act.sa_flags = 0

    posix.sigaction(posix.SIGTERM, &act, nil)
    posix.sigaction(posix.SIGINT, &act, nil)
}

// on_signal is the POSIX signal handler (C calling convention).
on_signal :: proc "c" (sig: posix.Signal) {
    _ = sig
    sync.atomic_store(&server_running, 0, .Release)
}
