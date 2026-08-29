#!/usr/bin/env python3
"""Generate the Bondy load-regulation / rate-limiting diagrams.

Emits two focused SVGs rather than one dense map:

  1. <out>/load_regulation_ingress.svg  — per-transport ingress and admission
  2. <out>/load_regulation_pools.svg    — pools, worker queues and overflow

(The former third diagram, "regulators and signals", was replaced by markdown
tables in the guides — its at-a-glance content reads better as tables.)

Every fact encoded here was verified against the tree at HEAD: schema/bondy.schema,
schema/bondy_bridge_relay.schema, and the modules named in each box.

Usage:  gen_load_regulation_diagram.py <output-dir> [<output-dir> ...]
"""
import html
import os
import sys

C = {
    "bg": "#ffffff", "ink": "#132030", "muted": "#5d6d80", "faint": "#8a97a6",
    "panel": "#fbfcfd", "panelEdge": "#dfe5ec", "laneBg": "#f7f9fb", "laneEdge": "#e3e9f0",
}
KIND = {
    "external":  ("#f1f4f8", "#94a3b3", "#33414f"),
    "transport": ("#e6f0fa", "#2f6fb5", "#1b4a7d"),
    "pool":      ("#efeafa", "#6b4fbb", "#4a3487"),
    "regulator": ("#fff4e3", "#c8801f", "#8a5410"),
    "limiter":   ("#fdeced", "#c0392b", "#8e2620"),
    "core":      ("#e9f5ed", "#2e7d4f", "#1d5334"),
    "gap":       ("#f6f7f8", "#9aa3ad", "#5d6d80"),
}
FS = "Inter, 'Helvetica Neue', Helvetica, Arial, sans-serif"
FM = "'SF Mono', 'JetBrains Mono', Menlo, Consolas, monospace"

TITLE_FS, BODY_FS, KEY_FS = 14.5, 12.5, 11.5
PAD_T, TITLE_GAP, BODY_STEP, KEY_GAP, KEY_STEP, PAD_B = 25, 22, 17.5, 6, 15.5, 16


def esc(s):
    return html.escape(s, quote=True)


def measure(lines, keys):
    h = PAD_T + TITLE_GAP
    if lines:
        h += len(lines) * BODY_STEP
    if keys:
        h += KEY_GAP + len(keys) * KEY_STEP
    return h + PAD_B


class Svg:
    def __init__(self, w, h):
        self.w, self.h, self.o = w, h, []

    def add(self, s):
        self.o.append(s)

    def box(self, x, y, w, kind, title, lines=None, keys=None, dashed=False, h=None):
        lines, keys = lines or [], keys or []
        h = h or measure(lines, keys)
        fill, stroke, tcol = KIND[kind]
        dash = ' stroke-dasharray="7 4"' if dashed else ""
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{fill}" '
                 f'stroke="{stroke}" stroke-width="1.7"{dash}/>')
        self.add(f'<rect x="{x}" y="{y}" width="5" height="{h}" rx="2.5" fill="{stroke}"/>')
        ty = y + PAD_T
        self.add(f'<text x="{x+17}" y="{ty}" font-family="{FS}" font-size="{TITLE_FS}" '
                 f'font-weight="600" fill="{tcol}">{esc(title)}</text>')
        ty += TITLE_GAP
        for ln in lines:
            self.add(f'<text x="{x+17}" y="{ty}" font-family="{FS}" font-size="{BODY_FS}" '
                     f'fill="{C["ink"]}">{esc(ln)}</text>')
            ty += BODY_STEP
        if keys:
            ty += KEY_GAP
            for k in keys:
                self.add(f'<text x="{x+17}" y="{ty}" font-family="{FM}" font-size="{KEY_FS}" '
                         f'fill="{C["muted"]}">{esc(k)}</text>')
                ty += KEY_STEP
        return h

    def text(self, x, y, s, size=12.5, col=None, weight="400", anchor="start",
             font=None, italic=False):
        st = ' font-style="italic"' if italic else ""
        self.add(f'<text x="{x}" y="{y}" font-family="{font or FS}" font-size="{size}" '
                 f'font-weight="{weight}" fill="{col or C["ink"]}" '
                 f'text-anchor="{anchor}"{st}>{esc(s)}</text>')

    def arrow(self, x, y1, y2, col="#7d8b9a", dashed=False):
        dash = ' stroke-dasharray="5 4"' if dashed else ""
        self.add(f'<line x1="{x}" y1="{y1}" x2="{x}" y2="{y2}" stroke="{col}" '
                 f'stroke-width="1.8"{dash} marker-end="url(#arw)"/>')

    def panel(self, x, y, w, h, title, sub=None):
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="11" fill="{C["panel"]}" '
                 f'stroke="{C["panelEdge"]}" stroke-width="1.5"/>')
        self.text(x + 18, y - 11, title, size=13, col=C["muted"], weight="700")
        if sub:
            self.text(x + 18 + len(title) * 7.9 + 16, y - 11, sub, size=12,
                      col=C["faint"], italic=True)

    def header(self, title, sub, legend):
        self.text(44, 44, title, size=22, weight="700")
        self.text(44, 69, sub, size=13, col=C["muted"])
        lx = 44
        for kind, name in legend:
            fill, stroke, _ = KIND[kind]
            self.add(f'<rect x="{lx}" y="87" width="16" height="14" rx="3.5" fill="{fill}" '
                     f'stroke="{stroke}" stroke-width="1.6"/>')
            self.text(lx + 23, 99, name, size=12, col=C["muted"])
            lx += 28 + len(name) * 6.7 + 24

    def footer(self, s):
        self.text(44, self.h - 24, s, size=12, col=C["faint"])

    def render(self):
        head = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" '
                f'viewBox="0 0 {self.w} {self.h}" font-family="{FS}">'
                '<defs><marker id="arw" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
                'markerHeight="7" orient="auto-start-reverse">'
                '<path d="M 0 0 L 10 5 L 0 10 z" fill="#7d8b9a"/></marker></defs>'
                f'<rect width="{self.w}" height="{self.h}" fill="{C["bg"]}"/>')
        return head + "".join(self.o) + "</svg>"


# =============================================================================
# 1 — INGRESS
# =============================================================================
def diagram_ingress():
    W, LANE_W, GAP, X0 = 1900, 348, 20, 36
    lanes = [X0 + i * (LANE_W + GAP) for i in range(5)]
    bx = [x + 12 for x in lanes]
    bw = LANE_W - 24
    cen = [x + LANE_W / 2 for x in lanes]

    titles = [
        ("HTTP / HTTPS", "API Gateway · Admin API · MCP · SSE · long-poll"),
        ("WAMP WebSocket", "upgrade on any listener declaring wamp_ws"),
        ("WAMP TCP / TLS", "raw socket"),
        ("Partisan", "cluster peer plane"),
        ("Bondy Bridge Relay", "edge / bridge peers"),
    ]

    hello = (["Busy node → immediate retryable ABORT",
              "with wamp.error.unavailable. Established",
              "sessions and post-HELLO handshakes are",
              "unaffected."],
             ["load_regulation.hello.enabled  on",
              "busy signal <- node load monitor",
              "-> bondy_wamp_dropped_total{admission}"])
    limits = (["handshake 10/s·50 — on HELLO, after the gate",
               "auth 5/s·20 — on AUTHENTICATE, BEFORE any",
               "   credential verification",
               "message 1000/s·2000 — per session, opt-in",
               "Each class also budgets at listener and",
               "realm scope; the realm adds a shared",
               "total — a per-node tenant quota."],
              ["-> bondy_rate_limited_total{class, scope}"])

    bands = [
        [("external", "REST · MCP · long-poll · SSE · /metrics", [], [], False),
         ("external", "WAMP WS / WSS clients", [], [], False),
         ("external", "WAMP raw-socket clients", [], [], False),
         ("external", "Other Bondy nodes", [], [], False),
         ("external", "Edge routers / bridge peers", [], [], False)],

        [("transport", "Cowboy on Ranch — operator inventory",
          ["Any listener declaring HTTP services.",
           "Defaults: admin :18081 (early phase),",
           "api_gateway_http :18080."],
          ["listeners.$name.services = api_gateway, ...",
           "listeners.$name.acceptors_pool_size 10",
           "listeners.$name.max_connections infinity"], False),
         ("transport", "Shares its listener's socket",
          ["/ws mounts on every listener declaring",
           "wamp_ws — the acceptor pool and",
           "max_connections are that listener's."],
          ["listeners.$name.websocket.* — ping, idle,",
           "  compression"], False),
         ("transport", "Ranch — protocol wamp_rawsocket",
          ["Default: wamp_tcp :18082. TLS is the",
           "same protocol over transport = tls."],
          ["listeners.$name.acceptors_pool_size 10",
           "listeners.$name.max_connections infinity"], False),
         ("transport", "Partisan peer listener :18086",
          ["N connections per peer per channel:",
           "data · rpc · membership · wamp_relay"],
          ["cluster.channels.$c.parallelism",
           "cluster.max_message_size 64MB cap"], False),
         ("transport", "Ranch — protocol bridge_relay",
          ["inbound bondy_bridge_relay_server;",
           "outbound bondy_bridge_relay_client.",
           "None in the default inventory."],
          ["listeners.$name.auth_timeout 5s",
           "listeners.$name.max_connections infinity"], False)],

        [("gap", "No connection-class limit",
          ["Nothing gates the TCP connection itself;",
           "admission is per REQUEST — the http",
           "class, two boxes down."], [], True),
         ("limiter", "connection — per source IP",
          ["over limit → HTTP 429, upgrade refused"],
          ["node 20/s·100 · + listener scope",
           "-> bondy_rate_limited_total{class, scope}"], False),
         ("limiter", "connection — per source IP",
          ["over limit → socket closed immediately"],
          ["node 20/s·100 · + listener scope",
           "-> bondy_rate_limited_total{class, scope}"], False),
         ("gap", "No admission gate, no rate limit",
          ["Peer plane is trusted; back-pressure",
           "happens at the flow pool instead."], [], True),
         ("gap", "No admission gate, no rate limit",
          ["Back-pressure happens at the flow",
           "pool instead."], [], True)],

        [("transport", "bondy_http_gateway_rest_handler",
          ["also bondy_mcp_http_handler and the",
           "SSE / long-poll transport handlers"], [], False),
         ("transport", "bondy_wamp_ws_connection_handler",
          ["one process per connection"], [], False),
         ("transport", "bondy_wamp_tcp_connection_handler",
          ["one process per connection"], [], False),
         ("transport", "Partisan connection process",
          ["no relay process on ingress"], [], False),
         ("transport", "bondy_bridge_relay_server / _client",
          ["one gen_statem per connection"], [], False)],

        [("limiter", "http — per source IP, per request",
          ["Every API Gateway, Admin API and MCP",
           "request consumes the node, listener and",
           "realm budgets in that order — the first",
           "refusal answers 429 with retry-after."],
          ["node 100/s·500 (higher than connection)",
           "listeners.$name.rate_limit.http.*",
           "realm rate_limit property (+ total quota)",
           "-> bondy_rate_limited_total{class, scope}"], False),
         ("regulator", "HELLO admission gate", hello[0], hello[1], False),
         ("regulator", "HELLO admission gate", hello[0], hello[1], False),
         ("core", "Direct-to-worker ingress",
          ["The sender pins each flow to one",
           "wamp_relay connection; this node resolves",
           "the same key and delivers straight into",
           "the owning flow-pool worker."],
          ["{via, bondy_router_worker, FlowKey}"], False),
         ("core", "Forwarded onto the flow pool",
          ["Keyed by the bridged session ref / flow",
           "pair, so each flow stays in arrival order."],
          ["bondy_router_worker:cast/3"], False)],

        [("core", "WAMP over SSE / long-poll",
          ["An open creates a WAMP session on this",
           "listener: the HELLO admission gate and",
           "the handshake, auth and message limits",
           "apply exactly as in the WebSocket lane."], [], False),
         ("limiter", "Per-source-IP and per-session limits", limits[0], limits[1], False),
         ("limiter", "Per-source-IP and per-session limits", limits[0], limits[1], False),
         None, None],
    ]

    BAND_GAP, LANE_TOP = 26, 166
    heights, ys, y = [], [], LANE_TOP + 58
    for band in bands:
        hh = max(measure(b[2], b[3]) for b in band if b)
        ys.append(y)
        heights.append(hh)
        y += hh + BAND_GAP
    lane_bottom = y - BAND_GAP + 18
    H = lane_bottom + 74

    s = Svg(W, H)
    s.header("Bondy — ingress and admission, per transport",
             "Where a connection or a session can be refused, and what the client sees. "
             "One lane per transport, because the gates genuinely differ per lane.",
             [("external", "Client / peer"), ("transport", "Connection & acceptors"),
              ("regulator", "Load regulator"), ("limiter", "Rate limiter"),
              ("core", "Core subsystem"), ("gap", "No regulation here")])
    s.panel(36, 146, W - 72, lane_bottom - 146 + 14, "INGRESS")

    for i, x in enumerate(lanes):
        s.add(f'<rect x="{x}" y="{LANE_TOP}" width="{LANE_W}" height="{lane_bottom-LANE_TOP}" '
              f'rx="9" fill="{C["laneBg"]}" stroke="{C["laneEdge"]}" stroke-width="1.4"/>')
        s.text(x + 14, LANE_TOP + 24, titles[i][0], size=14.5, weight="700")
        s.text(x + 14, LANE_TOP + 42, titles[i][1], size=11.5, col=C["faint"], italic=True)

    for bi, band in enumerate(bands):
        for i, b in enumerate(band):
            if not b:
                continue
            s.box(bx[i], ys[bi], bw, b[0], b[1], b[2], b[3], dashed=b[4], h=heights[bi])
            if bi > 0 and bands[bi - 1][i]:
                s.arrow(cen[i], ys[bi - 1] + heights[bi - 1], ys[bi] - 4)

    s.footer("Verified against schema/bondy.schema, bondy_rate_limit and the modules named above. "
             "Dashed boxes mark where no regulator exists today.   "
             "Continues in: Pools & worker queues.")
    return "load_regulation_ingress.svg", s.render()


# =============================================================================
# 2 — POOLS
# =============================================================================
def diagram_pools():
    W, COLS, CW, GAP, X0 = 1900, 4, 436, 24, 42
    xs = [X0 + i * (CW + GAP) for i in range(COLS)]

    items = [
        ("pool", "Router pool  (sidejob)",
         ["Fed by: locally-originated WAMP routing.",
          "Unordered — any worker may take any job.",
          "",
          "On overload the publish path logs and routes",
          "SYNCHRONOUSLY, blocking the caller. It does",
          "not drop the message."],
         ["router.pool.size      16",
          "router.pool.capacity  2,000,000",
          "router.pool.type      transient"]),
        ("pool", "Flow pool  (bondy_router_worker)",
         ["Fed by: Partisan relay and bridge-relay",
          "INGRESS ONLY — never local routing.",
          "",
          "Per-flow FIFO: one worker per flow key. Over",
          "its share the message is SHED. It cannot spill",
          "to another worker or run inline — either would",
          "overtake the flow's queued messages."],
         ["flow_pool.capacity 100,000 / router.pool.size",
          "-> bondy_wamp_dropped_total{shed, family}"]),
        ("pool", "Session manager pool",
         ["Fed by: session open and close.",
          "",
          "Hashed gen_server pool owning session",
          "lifecycle: store the session, monitor its",
          "connection process, register per-session",
          "procedures, close individually or in bulk."],
         ["session_manager.pool.size  32"]),
        ("pool", "Job manager pool + FIFO queues",
         ["Fed by: meta events and WAMP event",
          "publication.",
          "",
          "One bounded passive FIFO per worker. Past",
          "the size bound the OLDEST entry is evicted;",
          "entries also expire on TTL."],
         ["job_manager.pool.size   16",
          "job_manager.queue.size  160,000 (all queues)",
          "job_manager.queue.ttl   1m"]),
        ("pool", "Registry partitions",
         ["Fed by: SUBSCRIBE / REGISTER and removals.",
          "",
          "Writes run in the CALLER's process — no",
          "serialisation point: exact indices via",
          "concurrent ETS, prefix/wildcard via the",
          "persistent ptrie's path-copy + root CAS,",
          "retrying on CAS loss. The partition process",
          "owns the tables and the reclamation janitors.",
          "Entries hash by realm URI to a partition."],
         ["registry.partitions       32",
          "-> bondy_registry_ptrie_cas_retries_total",
          "db.registry.shard_count   (storage, separate)"]),
        ("pool", "Transport queue",
         ["Fed by: HTTP long-poll and SSE transports,",
          "which are not continuously connected.",
          "",
          "Bounded sharded ETS queue with three",
          "independent bounds: message count, total",
          "byte size, and a background TTL sweep."],
         ["http_transport.queue.max_messages / .max_bytes",
          "  .message_ttl · .partitions · .eviction_interval",
          "http_transport.idle_timeout (the session's)"]),
        ("pool", "Anti-entropy reactor pool",
         ["Fed by: anti-entropy syncs landing.",
          "",
          "Applies remote-merge reactions — session",
          "close, RBAC cache invalidation, routing",
          "summary updates. Sharded by cell key, so one",
          "cell's changes stay ordered on one worker."],
         ["aae_reactor.pool.size  16"]),
        ("core", "What happens when each one fills",
         ["Only the flow pool loses messages outright:"],
         ["router pool      routes synchronously",
          "flow pool        drops (shed), counted",
          "job queue        evicts oldest, then TTL",
          "transport queue  per overflow_strategy",
          "registry parts   no queue; writers CAS-retry",
          "session manager  no bound; work queues",
          "aae reactor      no bound; work queues"]),
    ]

    rows = [items[:4], items[4:]]
    row_h = [max(measure(i[2], i[3]) for i in r) for r in rows]
    y0 = 168
    H = y0 + row_h[0] + 34 + row_h[1] + 76

    s = Svg(W, H)
    s.header("Bondy — pools, worker queues and what happens when they fill",
             "Every bounded pool and queue on the request path: what feeds it, what bounds it, "
             "and whether overflow blocks, evicts or drops.",
             [("pool", "Pool / worker queue"), ("core", "Summary")])
    s.panel(36, 146, W - 72, H - 146 - 56, "POOLS & WORKER QUEUES")

    y = y0
    for ri, row in enumerate(rows):
        for ci, it in enumerate(row):
            s.box(xs[ci], y, CW, it[0], it[1], it[2], it[3], h=row_h[ri])
        y += row_h[ri] + 34

    s.footer("Verified against schema/bondy.schema and the modules named above.   "
             "Continues in: Ingress and admission.")
    return "load_regulation_pools.svg", s.render()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for out_dir in sys.argv[1:]:
        for fn in (diagram_ingress, diagram_pools):
            name, body = fn()
            p = os.path.join(out_dir, name)
            open(p, "w", encoding="utf-8").write(body)
            print("wrote", p)
