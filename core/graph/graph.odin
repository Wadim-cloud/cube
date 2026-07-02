// Execution graph router - compiled at startup, zero runtime string logic
package graph

import "core:strings"

Handler :: proc "c" ()

RouteNode :: struct {
    path_prefix: string,
    prefix_len: int,
    handler: Handler,
}

Graph :: struct {
    routes: [32]RouteNode,
    count: int,
}

graph_init :: proc(g: ^Graph) {
    g.count = 0
}

graph_add_route :: proc(g: ^Graph, prefix: string, handler: Handler) {
    if g.count >= len(g.routes) {
        return
    }
    g.routes[g.count] = RouteNode{
        path_prefix = prefix,
        prefix_len = len(prefix),
        handler = handler,
    }
    g.count += 1
}

// Compiled lookup - no string allocations, just prefix comparison
graph_resolve :: proc(g: ^Graph, path: string) -> (Handler, bool) {
    best_len := 0
    best_handler: Handler = nil
    found := false

    for i := 0; i < g.count; i += 1 {
        rt := &g.routes[i]
        if strings.has_prefix(path, rt.path_prefix[:rt.prefix_len]) {
            if rt.prefix_len >= best_len {
                best_len = rt.prefix_len
                best_handler = rt.handler
                found = true
            }
        }
    }

    return best_handler, found
}
