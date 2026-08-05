# TODO

Working list for the registry/oplog workstream. Update in place as items
land: move finished items to the Done section with the date rather than
deleting them, so the list doubles as a change journal.

Status legend: `[ ]` open · `[~]` in progress · `[x]` done.

## Performance

- [x] 2026-08-04 — **Subscribe-burst quadratic FIXED & FLY-VALIDATED
  (s20, s18 params/baseline): subscribe med 1.57s→103ms (15x), 1000-sub
  burst med 5.06s→214ms (24x) p95 15.62s→561ms, delivery med 6ms /
  p95 50ms (sub-50ms p95 ACHIEVED) / p99 136ms (was 1.65s), welcome
  med ~400ms→11ms, +20% offered load (9.45k pub/s); AE perfect (full
  drain ~5min, identical frontiers, 0 gap verdicts/rebootstraps/
  rebuilds, 11 doored on one node = live door working).** s21 TRUE
  50k-VU ceiling probe (8 pub LGs × 6,250, under the ~8k/IP edge cap
  that invalidated s6's single-LG "50k"): 8.04M publishes @ SUSTAINED
  28.7k pub/s — workstream record; ~29k concurrently-served publishers
  (s17: 20.8k admitted of 28k) — the session-establishment ceiling
  itself moved up. Delivery med 27ms / p95 1.96s at ~6x-over-ceiling
  offered load; subscribe burst med 382ms at full saturation; ~140k
  cheap admission refusals; AE perfect under the biggest close-storm
  yet (897k peak backlog → 0 in <40s, identical frontiers). s6
  comparison caveated: its numbers were harness artifacts.
  Root cause of the burst cost (s18 residual p99 ~1.7s during the
  subscribe ramp): the idempotent-SUBSCRIBE duplicate check in
  `bondy_registry:maybe_add/6` folded over ALL of the session's
  entries — and `find_pairs` is eager, materialising every `#entry{}`
  out of ETS before the fold's early-exit could run — so the k-th
  SUBSCRIBE copied k−1 full entries in the conn process (~500k copies
  per 1000-sub session). The session index was also a `bag` keyed
  `{Type, Realm, SessionId}`, so inserts dup-checked the per-key chain
  (O(k) in C per subscribe) and `delete_object` scanned it again per
  entry at session close. Fix: `local_session_idx_tab` → `ordered_set`
  keyed `{Type, Realm, SessionId, Uri, Policy, EntryId}`; dup check =
  `bondy_registry_store:find_session_entry/6` bounded prefix select
  (O(log n), independent of the session's entry count); session-close
  enumeration = prefix select; index delete = exact-key delete. Also
  corrected the latent session-less semantics: same-ref re-subscribe
  stays idempotent, but a DIFFERENT internal process now gets its own
  entry (previously it silently got the other process's entry — or a
  case_clause crash with 2+ matches). New CT cases
  `sub_same_uri_multiple_policies` + `sub_sessionless_refs`. Gates:
  registry CT 23/23, registry_entry+meta 11/11, meta_events+retained+
  wamp_protocol 20/20, connect pubsub 7/7, rib eunit 5/5. Secondary
  (not fixed, evidence-gated): `sub_local_exact_idx_tab` is a bag
  keyed {Realm, Uri} — per-topic chains make inserts O(subscribers on
  that topic) in C; converting touches the publish-side match path.
  Detail in memory topic subscribe-burst-quadratic.

- [ ] **Delivery-tail (p95) — remaining items after the 2026-08-04
  per-event CPU batch (items 1–5+8 of the audit are DONE, see Done).**
  (6) gproc_pool pick → persistent_term cache: tried and REVERTED
  2026-08-04. Fly s23+s23b showed it NEUTRAL at the 50k saturation
  noise floor (s21 28.7k / s23 26.7k / s23b 27.6k pub/s, ±3.5%; tails
  swing 7x between identical-build runs — sub-µs on a ~50-90µs
  publish), and the decisive counter-argument (user): a partition
  crash-restart mutates the single persistent_term key, which forces
  a GLOBAL all-process heap scan (~30k conn processes) exactly when
  the node is already unhealthy. Per-pid NEW-key puts (what store/1
  does) are the GC-safe persistent_term idiom; single-key RMW on the
  hot path is not. Behavior pin kept: CT case
  partition_pick_recovers_after_crash (green against the plain gproc
  pick). Item CLOSED — do not revisit without a multi-core (16x+)
  profile showing gproc-table contention.
  (7) VM-args arc REFUTED 2026-08-04: `+stbt db` silently cannot bind
  on Fly microVMs (topology visible, sched_setaffinity restricted) and
  `+zdbbl` is IRRELEVANT — all inter-node traffic rides Partisan's own
  TCP connections, not disterl (user correction; the dev/bridge
  profiles' +zdbbl is pre-Partisan cargo). s22 was additionally
  INVALID: the vm-args entrypoint override clobbered setup.sh
  (nodename/mesh + nofile + setpriv), producing 3 isolated fd-starved
  nodes — machine-level entrypoint overrides on the fleet MUST chain
  `source /bondy/setup.sh`. NIF audit: leveled's lz4 + ezstd
  NIFs (OpenRiak forks) run WITHOUT dirty-scheduler flags (crc32cer
  has them) — durable-path block compression can block normal
  schedulers; fix is dirty flags upstream, NOT +A. WS hard-codes
  active_n=1 over config (deliberate per in-code comment — revisit
  with a bondy_regulator-driven strategy). CLOSED 2026-08-04 (residue
  batch): epoch_tab decentralized_counters (the ONLY real ETS gap —
  ordered_set tables get the flag by default, so retire_tab/rib_stubs
  were never gapped, correcting the audit); dead `[Ref, socket_opts]`
  reads removed from the TCP handler + bridge_relay_server (listener
  opts are inherited from the listen socket); stale wildcard
  serialised-through-gen_server docs in bondy_registry_store and the
  router_pool max(size, schedulers) schema doc corrected. s17 (s16-params Fly rerun) DONE
  2026-08-04: delivery med 27→18 ms, welcome p95 8.49→5.58 s, AE
  perfect (full drain to 0 on all nodes, identical frontiers, P1
  tripwire clean, 0 mst_rebuilds; 16 gap verdicts / 6 re-bootstraps
  all healed); delivery tail NOT judgeable at saturation (runq peaks
  377–516 on 8 vCPU; the 6 mid-load catalogue re-bootstraps are
  themselves CPU bursts). s18/s19 moderate-load A/B DONE: off_heap
  wins every delivery stat (med 13 vs 16 ms, p95 106 vs 148 ms, +7%
  events) — off_heap stays the default, A/B settled. Sub-50 ms p95
  ACHIEVED at moderate load (s18 p95 106 ms is close; med 13 ms);
  the residual p99 ~1.7 s = subscribe-burst/admission phase spikes,
  so the next tail levers are the subscribe burst (RIB write storm)
  and the vm.extra.args experiments (+zdbbl, +sbt on dedicated CPU).
  Detail in memory topic p95-latency-audit.

- [ ] **Raise the session-establishment CEILING (admission control now
  protects quality, not capacity).** With the HELLO gate live (s14),
  admitted sessions are served well (welcome med ~500ms, p95 14.5s)
  but the node's sustainable open rate under data-plane load still
  caps concurrent publishers at ~21k of the 28k target — the gate
  converts the excess into cheap retryable refusals rather than
  timeouts, which is correct, but the ceiling itself is CPU. Levers:
  the leveled_bookie session-churn writes (see the RIB batch item
  below), cheaper open/teardown (session-manager cleanup cost), more
  vCPU, or accepting the ceiling and scaling nodes. Also consider
  tuning watermarks (current defaults high 8x / low 4x schedulers)
  once more deployments exercise them.

- [ ] **Session-open (WELCOME) under load — honest numbers, next
  lever is data-plane CPU or admission control.** Storm-free +
  fence-fixed s10 (29k sessions admitted, 19.7k pub/s): welcome med
  ~7s, p95 ~27s under full saturation; session-manager pool remains
  exonerated (open queue p50 0.6ms, service p99 16ms in s9
  histograms). Levers: data-plane CPU (see delivery backlog above),
  early admission control (bondy_regulator busy-ABORT on HELLO).
  Watchlist: `gproc:reg_other` on open is a call into the single
  node-wide gproc server (invisible at this load).

- [ ] **Fly edge caps ~8k concurrent connections per source IP —
  permanent harness constraint.** Discovered 2026-08-02: publisher
  sessions plateaued at exactly 8192/8098/8191 in three runs; excess
  connects get raw TCP EOF (no HTTP status) and at breach the edge
  axed all established connections. This silently bounded EVERY
  historic fleet run (the old "9k ceiling" = 8k pub-LG cap + 1k sub
  LG). Rules: keep each LG's VUs (incl. retries) under ~7k via
  `fly.dev`, scale publisher LG count instead; or bypass the edge with
  6PN-direct (requires `api_gateway.http.ip_version = 6` — the
  listener currently binds IPv4-only `0.0.0.0:18080`; verify
  fly-proxy/health still work before switching).

- [ ] **Coalesce session-close RIB operations into one bondy_db batch
  (OPTIONAL throughput optimization — the durable-write justification
  is REFUTED, see the 2026-08-03 diagnosis in Done).** Measured: a
  session's churn writes are exactly 1 ephemeral `apply_async`
  (memory topology) per SUBSCRIBE and 1 per entry at close, ~0 at
  open, and ZERO leveled/durable writes anywhere — so batching cannot
  reduce durable IO. What it would reduce: per-op dispatch overhead
  during a close storm (bench scale: 29k sessions x 1000 subs = 29M
  apply_asyncs collapsing to 29k batches). Still a significant
  `bondy_registry` intervention; only worth it if close-storm dispatch
  shows up in a future profile. Token/ticket creation writes remain a
  durable contributor for credential-minting auth methods (not
  exercised by the anonymous bench).

- [ ] **Attribute the s13 `leveled_bookie` mailbox backlogs (10–21k).**
  NOT session churn (diagnosis above: zero leveled writes from
  open/subscribe/close). Remaining suspects, both read-side load on
  the bookie gen_servers under CPU starvation: AAE sync rounds folding
  the durable security namespaces (continuous, fence-backing), and
  `bondy_prometheus_db` stats collection calling into bookies. Needs a
  Fly sampler capturing one flooded bookie's mailbox sample + which
  namespace its shard belongs to.

## Correctness / reclamation residue

- [ ] **P1 (root cause) — own-root MST pages lost on an ephemeral ETS
  store (found live on Fly s16; recovery machinery now DONE — see Done
  below).** One node's `registry/4` lost 2 pages of its own current
  root mid-run. The recovery deadlock it caused is closed (peer-side
  `root_unservable_behind` escalation + broken-side domination-gated
  MST rebuild), but WHY the pages vanished is unexplained. Suspects:
  `bondy_mst:gc` mark/sweep edge against the current root (the mark
  walk tolerates missing pages — a transiently-missing parent could
  orphan a live subtree), fused-drain page-write/root-publish
  ordering, door-hold/pin interactions. A TRIPWIRE is armed: the
  sustained cluster case asserts every node's every instance root is
  servable at end of run (`do_unservable_roots/0`, with diagnose_root
  evidence on trip), and any production occurrence now shows as
  `bondy_oplog_mst_rebuilt_total` on the sync dashboard. Next step if
  it trips or recurs: capture the absent page ids vs gc telemetry and
  bisect the truncate/gc call sites.

- [ ] **Vector-stability certification (unlocks aw_map/aw_set nested-key
  folding).** R2 folding ships struct-only because the HLC frontier only
  licenses folding dot-stores that are never partially dropped by an
  observed context — an `{rmv, K}` minted pre-certification can carry an
  HLC above the frontier while observing only a prefix of a stable run
  (counterexample documented in `bondy_oplog_crdt_nested_core`'s
  moduledoc). Folding the collection types needs a certified lower bound
  on every future op's *context* (a confirmed cluster-min VV), which the
  substrate does not track. Only matters if a workload accumulates
  nested sub-ops under aw_map/aw_set keys — none does today.

- [ ] **Durable pack-store reclamation.** Same never-called-GC class as
  the fixed ETS page leak, but disk: `bondy_oplog` never invokes
  `bondy_mst_pack_store`'s list-mode GC (a sealed-pack rewrite with its
  own lifecycle — respect `seal_in_flight`), and epoch-mode GC is a
  documented no-op there. Every durable truncation leaves its dropped
  prefix in sealed packs. Slow-burning (`main/*` write volume is low)
  but unbounded. Needs a small design pass: trigger cadence, in-flight
  seal interaction, KeepRoots choice.

- [ ] **Stale-peer rejoin audit (durable path).** A peer silent past
  `peer_timeout_ms` (30s) stops pinning the stability frontier; durable
  truncation proceeds without its confirmation. On live rejoin it takes
  catalogue install + rederive — believed complete (its unique ops are
  in its own MST) but never explicitly tested. One CT case settles it.

- [ ] **VV-bounded retention truncation (only if `mst_retention` is
  ever enabled in anger).** The opt-in backstop's documented trade:
  ops clobbered outside the retained window cannot be restored by
  rederive. Hardening = bound retention truncation by the cluster-min
  applied-frontier VV so no live peer's applied-but-unretained ops are
  ever discarded. Not needed while the defaults stay off; needed before
  recommending the backstop to an overloaded deployment.

## Registry bugs (found by the compaction diagnostic suite)

(Both fixed 2026-08-03 — see Done.)

## Older pending

- [ ] **`callees/2` cluster introspection under write-only RIB** —
  flagged open when the registry mode ladder was removed.

## Harness / tooling

- [ ] **Fleet bench HTML report.** `run-fleet-lg.sh` should finish by
  generating a single self-contained, shareable HTML report (charts
  inline, no external assets) covering:
  - **Test parameters**: node count + machine size, publisher/subscriber
    VU totals, subscriptions per user, group size, vehicle pool,
    publish interval, ramp/hold/session durations, git ref of the
    deployed build.
  - **k6 metrics with charts**: welcome / subscribe / delivery latency
    (avg, med, p95, p99, max), publishes sent + rate, session and
    subscribe success counts, error counts — parsed from the per-LG
    `out/*.txt` summaries.
  - **Cluster resource series with charts**: per-node RSS and ETS over
    time through load + settle (the `ab_mem_sample.sh`-style sampling
    should become part of the run, not a separate script), ideally plus
    registry event counts to show compaction keeping up.
  - Output to `harness/fleet-scale/out/report-<timestamp>.html`.

## Test infra / hygiene

- [ ] **`bondy_oplog_proper_test` fixture fragility** — properties run
  without the eunit app-start fixture under standalone `-p` invocation
  (always-red by construction), and module sweeps can race app startup.
  Add a `?SETUP` wrapper per property.

- [ ] **`bondy_alarm_handler` does not dedupe repeat `set_alarm` by
  id** (found during the http_connector observability work).

## Done

- [x] 2026-08-05 — **`ZoomSvg` shipped and the load-regulation
  diagrams now zoom in place.** Template tagged v0.1.1 by AR;
  `bondy_docs` bumped off `#v0.1.0`, `yarn.lock` updated, the three
  `<figure class="diagram">` blocks replaced with `<ZoomSvg …/>`, and the
  now-dead `.diagram` rules dropped from `brand.css` (the medium-zoom
  z-index fix stays — it still matters for every other `<ZoomImg>` on
  the site).
  Component lives at `theme/src/components/ZoomSvg.vue` in
  `@leapsight/vitepress-template`. It inlines the fetched .svg as DOM and
  zooms by rewriting the `<svg>`'s own `viewBox`, so rasterisation
  happens AFTER the transform — sharp at any zoom by construction, not
  by browser luck. `<img>` renders server-side and pre-hydration and is
  swapped on mount, so a failed fetch just leaves the image.
  Verified against the real tag, not a staged copy: all three figures
  hydrate to inline `<svg>` with a viewBox, controls and zoom readout
  present, fallback replaced, and zero `<script>`/`on*` attributes
  survive inlining (the component strips them). Page screenshot confirms
  the diagram sits inside the prose column with no TOC overlap.
  Two of my own defects fixed on the way: the `.diagram` rule I had
  added widened the figure 224px into the outline gutter — which is
  where the TOC lives — and the earlier single combined diagram was
  unreadable. Both were visible in screenshots I had already taken and
  misread.

- [x] 2026-08-05 — **Load regulation diagrams: three SVGs, embedded in
  both doc surfaces.** Generated by
  `scripts/gen_load_regulation_diagram.py <out-dir> [<out-dir> ...]`
  (auto-sizing boxes, so text can never clip) into `doc/assets/` and
  `bondy_docs/docs/assets/`:
  `load_regulation_ingress.svg` (five transport lanes: client →
  listener/acceptors → connection admission → connection process →
  session admission → per-session limits),
  `load_regulation_pools.svg` (all seven pools/queues: what feeds each,
  what bounds it, what it does when it fills), and
  `load_regulation_signals.svg` (node load monitor, the two INDEPENDENT
  run-queue signals, fail-open, the four anti-entropy regulators,
  callee-side admission, metrics).
  Replaces a single combined diagram that was correct but unreadable —
  user feedback, and right. Each is embedded at the point in both guides
  where it earns its keep, not stacked at the top. Rendered to PNG and
  eyeballed at three zoom levels each; three layout defects caught that
  way (caption/bus collisions, two boxes overflowing the canvas, key
  lines overrunning their box).
  Plumbing fixed along the way:
  (a) `bondy_docs` **ZoomImg zoom was broken** — the shared template
  gives medium-zoom overlay `z-index: 20` / image `21`, but VitePress's
  sidebar is `--vp-z-index-sidebar: 60`, so any zoomed image on a page
  with a sidebar rendered BEHIND the left-hand nav. Overridden to
  100/101 in `docs/.vitepress/theme/brand.css` (site layer — never edit
  the template in node_modules). Affects every `<ZoomImg>` on the site,
  not just these.
  (a2) **ZoomImg also rendered the SVGs blurry, so these diagrams no
  longer use it.** medium-zoom zooms with `transform: scale()` plus
  `will-change: transform`, which pins the `<img>` to a compositor layer
  rasterised ONCE at its ~688px in-page size and then GPU-upscales that
  raster — vector detail is gone before the zoom happens. Tried to
  verify a `will-change: auto` override in headless Chrome and could
  not: headless re-rasterises in every case (the with/without renders
  are byte-identical), so it reproduces neither the bug nor a fix. Took
  the deterministic route instead — a `<figure class="diagram">` whose
  image is wrapped in `<a href="/assets/x.svg" target="_blank">`, so a
  click opens the real vector and the browser renders it natively at any
  zoom. Confirmed crisp by screenshotting the served .svg in Chrome and
  magnifying past its natural size. `.diagram` in brand.css also lets
  the in-page render reclaim the outline gutter above 1280px, verified
  by screenshotting the built page. ex_doc equivalent:
  `[![alt](assets/x.svg)](assets/x.svg)`.
  (b) ex_doc needs `{assets, #{"doc/assets" => "assets"}}` in
  `rebar.config` or images referenced from extras are simply not copied.
  Added. Note `docs/assets/` — NOT `docs/images/` — is the live dir in
  bondy_docs; `/images/` is referenced by nothing.
  (c) `migrating_from_1.0.0-rc.65.md` and `progressive_calls.md` were
  linked from published extras but were not themselves in `{extras}`,
  so ex_doc emitted four broken-link warnings. Both added; ex_doc now
  builds warning-free.
  Found-not-fixed: **`groups_for_extras` never takes effect.**
  rebar3_ex_doc matches it with `when is_list(Groups)`, `rebar.config`
  gives it as a map, so the whole option is dropped with an "unknown
  ex_doc option" line and every extra lands ungrouped. `{name, "Bondy"}`
  and `{extra_section, "Pages"}` are dropped the same way. Converting
  `groups_for_extras` to a list of `{Name, [Path]}` tuples would fix the
  grouping.

- [x] 2026-08-04 — **Load regulation + rate limiting documented as a
  guide, in the repo and in `bondy_docs`.** Scope established by diffing
  cuttlefish keys at tag `1.0.0-rc.65` against HEAD rather than from
  memory: 16 new keys (`load_regulation.hello.enabled`,
  `load_regulation.load_monitor.*`, `load_regulation.router.flow_pool.
  capacity`, `load_regulation.aae_reactor.pool.size`, all ten
  `security.rate_limit.*`), plus the whole `db.aae.*` family (rc.65 had
  the plum_db-era `aae.*` hashtree keys, so `db.aae.load_adaptive` /
  `live_sync` / `max_concurrency` / `max_pages_in_flight` are new, not
  renames), plus two new modules (`bondy_regulator_load`,
  `bondy_rate_limiter`) and `bondy_connect_load`.
  Delivered: `doc/guides/configuration/load_regulation_and_rate_limiting.md`
  (registered in both `{extras}` and `groups_for_extras`);
  `bondy_docs` `docs/guides/administration/load_regulation_and_rate_limiting.md`
  + sidebar entry; `docs/reference/configuration/overload_protection.md`
  extended with the load-monitor and session-admission sections.
  `yarn docs:build` green and every anchor in the new pages verified
  against the generated ids.
  Two corrections made while writing, both verified in source: the flow
  pool is **ingress-only** (relay + bridge-relay; `cast/3` has no other
  callers) and its overload outcome is a **shed**, not an error to the
  client — `overload_protection.md` claimed both wrongly. Also fixed
  stale defaults there (`router.pool.size` 8→16 and the false "max of
  configured value and schedulers" claim — the schema says verbatim;
  `router.pool.capacity` 100000→2000000).
  Found-not-fixed, all needing a decision:
  (a) `doc/guides/configuration/migrating_from_1.0.0-rc.65.md` step 4 and
  its Result section claim an unrecognised key **fails boot** and names
  the offender. It does not: rebar3_scuttler's generated hook runs
  cuttlefish with `--allow_extra --silent`. Booted a container with
  `this.key.does.not.exist = 42` — node started listeners, no complaint.
  (b) Same guide's step 2 lists `oplog.aae.*` as the "Old key (≤ 1.0.0-rc.65)";
  rc.65 actually had `aae.{enabled,exchange_timer,hashtree_timer,
  hashtree_ttl,data_exchange_timeout}` and `startup.wait_for_store_*`.
  `oplog.aae.*` was an intermediate name that never shipped in rc.65.
  (c) `bondy_docs` `data_storage.md` documents `db.aae.fence.max_lag`
  default as `1s`; schema says `60s` (also referenced as 1s in the
  `db.pack_auto_seal_bytes` prose).
  (d) The schema comment on `load_regulation.router.pool.capacity` says
  Bondy "will respond with an overload error", but `bondy_router:forward/3`
  logs and routes **synchronously** on `{error, overload}`. Left the doc
  wording alone rather than guess which is authoritative.
  (e) `load_regulation.job_manager.{pool.size,queue.size,queue.ttl}`
  (pre-existing, not new) are documented nowhere.

- [x] 2026-08-04 — **`deployment/` Dockerfiles brought up to date with
  the current tree — both images build AND boot clean (verified, not
  assumed).** Debian and Alpine images each built for linux/arm64 and
  run to `/ping` + `/ready` = 204 with zero `level=error`/CRASH lines,
  and `bondy_db` writes its real on-disk tree (`data/bondy_db/{main,
  mst,wal}`).
  (1) **Boot-blocker fixed**: the images declared `VOLUME` for
  `/bondy/data`, `/bondy/log` and `/bondy/tmp` without creating them,
  so Docker made each mountpoint `root:root` at container-create time
  while the container runs as the unprivileged `bondy` user. Every
  `docker run` died in `bondy_namespace_catalog:do_open_main/1` with
  `{badmatch,{error,enoent}}` — `filelib:ensure_path/1` reporting the
  real EACCES on `/bondy/data/bondy_db/main` as `enoent`. Both
  Dockerfiles now `mkdir` + `chown bondy:bondy` all four VOLUME paths
  before `USER`, so Docker seeds the anonymous volume from a
  correctly-owned mountpoint. This was latent, not new: only
  `/bondy/etc` was ever created, and `make docker-run-prod` masked it
  by running `-u 0:1000`.
  (2) **`deployment/fly/config/bondy.conf.template` migrated off the
  plum_db-era vocabulary**: 14 keys resolved against NO schema —
  `aae.{data_exchange_timeout,enabled,exchange_timer,hashtree_timer,
  hashtree_ttl}` (hashtree/exchange model replaced by the bondy_db sync
  scheduler → `db.aae` + `db.aae.interval`), `startup.wait_for_store_*`
  (3, no counterpart, dropped), and six `vm.*` renames
  (`vm.{port,process}_limit` → `vm.{port,process}.limit`,
  `vm.cpu.dirty_schedulers.*` → `vm.cpu.dirty_scheduler.*`,
  `vm.cpu.schedulers.*` → `vm.cpu.scheduler.*`, `vm.io.dirty_schedulers`
  → `vm.io.dirty_scheduler.number`). NOT fatal — rebar3_scuttler's
  generated hook runs cuttlefish with `--allow_extra`, so a dead key is
  silently dropped, which is exactly why these rotted unnoticed: the
  VM limits and dirty-IO scheduler count were simply never applied.
  Verified with the release's own `bin/cuttlefish` across BOTH schema
  dirs (`releases/<vsn>` for vm_args, `releases/<vsn>/schema/` for the
  app schemas): 14 dead keys before, 0 after.
  (3) **Second fly boot-blocker fixed**: that config sets
  `cluster.peer_discovery.enabled = on` with no cluster TLS, and
  `bondy_app:guard_peer_plane/0` now refuses to start in exactly that
  shape. Reproduced both verdicts in-container (`refuse` →
  `error({insecure_cluster_peer_plane, tls_disabled})`, exit 1; `allow`
  → boots), and added the required `cluster.tls.allow_insecure = on`
  acknowledgement for Fly's private 6PN peer plane.
  Found-not-fixed (out of scope, all non-fatal thanks to
  `--allow_extra`): stale keys in `config/dev/bondy.conf.template` (18),
  `config/bridge/bondy.conf.template` (13), and the `config/test/*`
  node templates (3–6 each) — mostly the retired `erlang.*` family from
  the disabled `schema/erlang_vm.schema_bak`, plus
  `admin_api.http.dynamic_buffer.{min,max}`. Also
  `.github/workflows/docker-debian.yaml` is still named "Bondy Debian
  OTP 27" while the images build on OTP 28.

- [x] 2026-08-04 — **Per-event CPU batch (p95 audit items 1–5+8) —
  IMPLEMENTED, all gates green, Fly validation pending.**
  (1) `erts_debug:flat_size/1` removed from the per-message telemetry:
  `bondy_telemetry:wamp_message/3` now carries the WIRE size from the
  encode/decode sites (outbound clauses reordered to encode-then-notify;
  inbound notified ONCE at the `handle_inbound` decode point with the
  frame's byte_size — which also fixes a pre-existing gap where
  established-path inbound messages were never counted at all); the
  bytes histogram only observes when a wire size was measured.
  (2) WS hibernate idle-gated: `wamp.websocket.hibernate =
  never|idle|always` (default idle) — the data path no longer pays a
  full-sweep GC per delivered EVENT; control events still shrink quiet
  connections. (3) `bondy:do_send/3`: single pid conversion
  (`Pid =:= self()` instead of `bondy_ref:is_self/1`) and
  `bondy_session:transport_id/1` by id (ets:lookup_element) instead of
  copying the whole `#session{}` per delivery. (4) iodata end-to-end:
  json/cbor `encode_with_tail` return iodata (the per-subscriber
  payload flatten is gone); TCP frames with `iolist_size` and sends a
  reply LIST as ONE writev (`send_messages/2`); WS passes a single
  message as `[{Type, Bin}]`. Contract hardened: protocol replies are
  now ALWAYS proper lists — `open_session`/challenge leaked single
  binaries before (`{reply, Bin}` → `{reply, [Bin]}`; the http
  transport session's defensive re-wrap clause removed). SSE and the
  bondy_connect client flatten at their own boundary. (5) conn-handler
  mailboxes off_heap via hidden `wamp.connection.message_queue_data`
  (default off_heap) — MUST A/B on Fly (off-heap costs more CPU per
  send). NIF audit: leveled's `lz4`/`ezstd` NIFs are NOT dirty-flagged
  (crc32cer is) — durable-path compression can block normal
  schedulers; `+A` cannot help NIFs (async pool serves legacy port
  drivers only), so the lever is dirty flags upstream / `+SDio`.
  Gates: eunit 2698/0; proper 69/69; CT wamp json 15 / cbor 14 /
  encoding 183 / partial 22, connect codec 18 / pubsub 7 / call 6 /
  auth 4, longpoll 10, SSE 9. Test fallout was flat-binary assertions
  on partial paths → flattened at assignment sites in the four wamp
  suites.

- [x] 2026-08-04 — **P1 recovery: the dangling-own-root deadlock is
  CLOSED (both halves built, eunit-locked; page-loss root cause stays
  open above with a tripwire armed).** Peer side: a session whose
  round dies on `root_unservable` now enriches the error to
  `root_unservable_behind` when the peer's pre-round applied frontier
  is strictly ahead after the local settle; the scheduler debounces
  THREE consecutive strikes into the catalogue re-bootstrap (the
  peer's snapshot producer reads its PROJECTION — servable even when
  its MST is not), with the ahead-gate as loop protection after the
  heal. Broken-node side: `maybe_self_heal_unservable/2` on the
  compaction tick rebuilds a persistently-unservable fused MST (drop
  tree, advance watermark, keep projection + applied frontier) gated
  on EVERY recency-live peer's recorded frontier dominating ours —
  peer frontiers are now captured into `bondy_oplog_peer_state` (new
  `frontier` field) by each completed round; unknown blocks the heal.
  The halves sequence: escalated bootstraps drain the broken node's
  surplus → the domination gate opens → rebuild → plain AE resumes.
  `finish_bootstrap` tolerates a trailing unservable AE round (the
  install already supplied data + frontier; the live-rederive still
  runs). Observability: `[bondy_oplog, instance, mst_rebuilt]` →
  `bondy_oplog_mst_rebuilt_total` + a series on the Cluster Sync
  trend panel. Locks: 2 scheduler eunit (3-strike escalation;
  no-deficit never escalates) + 2 fused eunit (self-heal with
  dominating peer incl. shard-alive-after; hold-until-domination)
  built on a real fault primitive (`drop_root_referenced_page/1` —
  public MST page tab). Found-and-fixed en route: my compaction-hook
  edit shadowed a bound `State1` → badmatch on every compaction —
  caught immediately by the existing fused suite.

- [x] 2026-08-04 — **Fly bench s16 + report regeneration.** Rerun of
  the s14/s15 profile on the final tree (incl. AE-health prometheus
  export + ptrie CAS telemetry). k6: delivery med 27ms / p95 1.64s,
  welcome med 589ms, 3.64M publishes at 13k/s — s15 class, normal
  variance. Report regenerated with s16 + per-run charts (generator
  now discovers `s<N>_mem*/s<N>_ae*` sampler files generically), same
  artifact URL. THE REAL VALUE: s16 SURFACED the dangling-own-root
  recovery deadlock (P1 open item above) — caught precisely because
  the drain sampler watched oplog events per node and one shard never
  drained. Sampler gotcha: the Fly image has no curl/wget — in-VM
  /metrics scraping needs an erlang httpc eval instead.

- [x] 2026-08-04 — **Fleet bench HTML report (#73).** New
  `harness/fleet-scale/report.py`: parses the artifacts a run leaves
  behind (k6 LG summaries `run_s<N>.log`/`s<N>_lg.log`, mem/ETS sampler
  CSVs, AE-health sampler logs) and emits ONE self-contained HTML
  (inline CSS + inline SVG charts, no external assets — safe to mail or
  archive). Content: KPI strip for the latest run, run-comparison table
  across the whole s-series (best delivery-median highlighted; aborts
  column caveated — from s14 on it is dominated by admission-control
  refusals), per-node resource charts, per-run detail sections with
  params + milestone annotations (maintained in the script's NOTES
  map). Generated the s1–s15 report from the session archives: numbers
  spot-checked against the recorded results (s10 3m13s → s15 19ms
  delivery med). Published for viewing at
  https://claude.ai/code/artifact/05c1628a-50c4-486d-892a-64cc3261b130.

- [x] 2026-08-04 — **Registry partition-grain design pass — realm grain
  KEPT; Fix A / task #23 ("widen pick/1's hash key") CLOSED as refuted
  (user-ratified 2026-08-04).** Decision record:
  `_design/REGISTRY_PARTITION_GRAIN.md`. Code-verified findings that
  changed the answer: the store's hot path is caller-process lock-free
  END TO END regardless of partition (exact = concurrent ETS;
  prefix/wildcard = persistent-ART path-copy + root CAS with retries —
  the 2026-04-22 rewrite; the partition gen_server's execute API has
  ZERO production callers), so realm-collapse costs nothing measurable
  for exact-dominant workloads, while any plain key widening would
  force per-message scatter reads across all partitions (patterns can
  live anywhere). The bondy_db `registry/*` replication layer already
  spreads a single realm (entity strategy hashes the full RIB cell
  key). Genuine residual: ptrie root-CAS contention under sustained
  single-realm PATTERN churn — remedy if ever observed is
  pattern-broadcast sharding (specified, NOT built). Built now: the
  evidence hook — `[bondy, registry, ptrie, cas_retry|cas_exhausted]`
  telemetry (emitted only on lost rounds; zero cost uncontended) →
  `bondy_registry_ptrie_cas_{retries,exhausted}_total` in
  bondy_prometheus (+ eunit `bondy_prometheus_ptrie_cas_test`) + a
  Router/WAMP dashboard panel; stale "serialized through a
  gen_server/trie server" docs corrected in bondy_registry_partition
  and the `registry.partitions` schema entry.

- [x] 2026-08-04 — **Churn-safe fused live re-bootstrap — the
  standing-gap WARNING carve-out RETIRED; the frontier-gap remedy now
  applies uniformly** (applier-backed durable, retention-fused, and
  fused-at-defaults). The carve-out guarded a corruption class that
  predated the watermark door; post-triad the soundness argument
  closed: (a) the fused install runs IN the instance gen_server —
  atomic w.r.t. the fused drain; (b) every op a replace-install can
  clobber is either peer-confirmed (fused peers fold at integrate
  before their root is confirmable ⇒ in the snapshot) or retained in
  the local MST ⇒ restored by the post-bootstrap rederive; (c)
  `finalize_catalogue_bootstrap` never truncates the MST, so unshared
  local ops survive for peers to pull. Locks:
  `gap_two_strikes_rebootstraps_fused` (scheduler eunit, RED-verified
  against the carve-out — two-strike gap on a fused-no-retention
  instance now schedules the catalogue re-bootstrap and consumes the
  flag as a bootstrap dispatch) and
  `live_bootstrap_with_churn_between_batches_converges` (fused eunit:
  mid-install churn; instructive find — a churn op can make the local
  cell NEWER so skip-if-older leaves it missing the peer's
  contribution, the mirror image of the clobber; the production
  sequence install → finalize → AE round → rederive converges both
  ways). Cluster-level coverage rests on composition: the stale-rejoin
  CT case proves the scheduler-driven chain end-to-end on real nodes,
  and the sustained case's no-unhealed-gaps assertion now exercises
  the un-scoped remedy for any fused standing gap it ever meets.

- [x] 2026-08-04 — **AE-health observability + Cluster·Sync dashboard
  (topsight drill-down).** (1) Prometheus export of the AE-health
  signals that s15 had to sample by hand over SSH:
  `bondy_oplog_frontier_gap_verdicts_total{instance_id,peer}`,
  `bondy_oplog_rebootstraps_scheduled_total{instance_id,peer}`,
  `bondy_oplog_doored_events_total{instance_id,action}` in
  `bondy_prometheus_db` (+ `ae_health_events_are_counted` eunit).
  (2) New L1c dashboard `bondy-cluster-sync` completing the July
  hierarchy: whole-cluster sync state in ONE view — an N×N node × peer
  matrix (last-sync age; red row = node can't pull, red column = peer
  unservable) + a gap-verdict matrix (1 = benign door-fold transient,
  2+ = rebootstrap threshold), AE-health stat row with
  threshold-colored semantics explained in panel descriptions, trend
  panels, plus the six cluster-level sections moved out of the storage
  detail dashboard (now per-node only, 97→52 panels). (3) L0 overview
  gained an "AE / sync health" row whose stats data-link into the sync
  dashboard — topsight flow: overview stat goes amber → matrix names
  the pair → pair inspector → node detail. Nav mesh wired across all 7
  dashboards; provisioning validated in live Grafana 11.6 (render with
  real data still to be eyeballed against a dev node);
  monitoring/README.md rewritten with the hierarchy + debugging flow.
  (4) Metrics-coverage sweep (closes the "all metrics used by
  dashboards" item): audited every recently-added family — the three
  delivery-arc histograms had NO panels; added a "Delivery pipeline —
  flow pool & HELLO admission" section to bondy-router-wamp (flow
  queue-wait p95/p99 + service p95 by family, HELLO handling p50/p95,
  admission-refusals vs sheds rate). (5) LIVE-VALIDATED on a real
  event: N2 stale rejoin → 6 gap verdicts → 6 re-bootstraps ok →
  converged, all visible in the new metrics. Refined per user
  feedback: L0 overview stats are now STATE-GATED so a healed event
  reads green immediately — "Standing frontier gaps" (gaps gated on
  current divergence), "Re-bootstraps failing" (outcome=error only),
  "Sync error rate (5m)"; event-window history stays on the sync
  dashboard.

- [x] 2026-08-04 — **Fly validation s15 PASSED — final AE state (triad +
  live door) verified at fleet scale.** 3× performance-8x, s14-identical
  load (28k pub + 1k sub VUs, ~14.6k pub/s aggregate, 4.09M publishes).
  AE health (per-node telemetry counters attached at runtime): **1
  frontier-gap verdict cluster-wide, 0 rebootstraps** — the single-strike
  door-fold transient, absorbed by the two-strike debounce as designed;
  door-folds 42/18.7k/28.7k per node (the honest path working under
  load); sync errors 31/28/6. **Full drain: oplog events 0 on all
  nodes**, ETS settled flat at 504/639/682MB (peak 3.5GB on the
  subscriber-heavy node during load). **Convergence: identical frontier
  hash on all 3 nodes.** k6 improved vs s14: delivery avg 722ms→207ms
  (med 25→19ms, p95 3.78s→1.04s), welcome med 477→235ms (p95
  14s→4.1s), subscribe avg 3.71s→2.36s. Data in job tmp
  (`run_s15.log`, `s15_ae*.log`, `s15_mem*.csv`); both Fly apps back
  at 0. Observation logged: door-fold volume (thousands/node) makes
  the integrate-door scan+fold a measurable steady-state path — fine
  functionally, worth a look if integrate latency ever surfaces.

- [x] 2026-08-04 — **Live-event watermark door + shared remote
  delivery point (the AE-arc residual, retired).**
  `do_append_remote`'s below-watermark filter no longer drops a
  never-applied live single event: `append_remote_below_watermark/3`
  judges at-or-below-watermark keys against the applied VV exactly
  like `watermark_door/3` — never-applied events on projection-backed
  instances are ACCEPTED (installed + delivered), only VV-witnessed
  re-ships and no-projection instances keep the idempotent drop. Along
  the way the integrate handler's delivery block was extracted into
  `deliver_remote/1`, now shared by BOTH MST entry paths — which also
  closed a latent adjacent gap: a live-pushed remote event previously
  never reached the projection (no replay cast, no I1 fence bump, even
  above the watermark) until the next AE round; now fused folds inline
  before the handler returns and applier-backed bumps the fence + casts
  the replay. Telemetry: new `[bondy_oplog, instance, append_remote,
  doored]` outcome (registered in `bondy_prometheus_db`). Locks (all
  RED-verified against the old code): `live_door_accepts_*_fused` /
  `_applier`, `live_filter_drops_already_applied_remote_event`,
  `live_append_remote_reaches_projection_fused` / `_applier` in
  `bondy_oplog_compaction_fused_test`. ALSO from this run's gates: the
  sustained case caught a legitimate DOOR-FOLD TRANSIENT the zero-gap
  assertion overclaimed against — a peer's door-fold advances its VV
  past what its truncated MST serves, and a third replica's complete
  round in that window (~63ms observed) records a one-strike deficit
  the origin covers next round (it CANNOT be compacted away:
  peer-confirmed frontier needs the laggard's roots). No loss,
  self-heals, debounce absorbs it. The suite now asserts the SYSTEM
  guarantee instead: no pair gaps twice + every recorded deficit
  healed by end of run; `?GAP_STRIKE_WINDOW_MS` rationale updated.

- [x] 2026-08-04 — **AE DATA LOSS AT DEFAULTS CLOSED — three
  compounding mechanisms found and fixed; the sustained cluster case
  now asserts ZERO frontier-gap verdicts and passes (was 43-64
  gaps + 95-271 silent partial merges per 25s window).**
  (1) THE WATERMARK DOOR: `integrate_peer_root`'s re-truncate used to
  discard never-applied peer events at or below the local watermark.
  Now `watermark_door/3` checks every at-or-below-watermark key
  against the applied VV: fused instances FOLD never-applied events
  into the projection inline (`apply_cell_pairs_mux`, the
  `fused_replay_cell_events` primitive) then truncate; applier-backed
  instances HOLD them (truncate only strictly below the smallest held
  key) for the applier's replay — every later truncation site is
  behind the existing async catch-up gate. Region scan is
  O(candidates): capped `bondy_mst:last_n/3` walk from the watermark's
  successor key, full-scan fallback. Non-projection instances keep the
  legacy truncate (no VV witness; production tables are all
  projection-backed).
  (2) DANGLING-ROOT FAKE-EMPTY: the responder's `get_root` used to
  answer the aae-root guard's `undefined` (dangling root mid
  truncate+page-GC) indistinguishably from a genuinely EMPTY tree, so
  the initiator ran zero-pull "complete" rounds 1-3 fresh events
  behind the honest frontier — ~8-13 guard trips/run, each serving
  several false rounds. Now dangling answers
  `{error, {root_unservable, Id}}` (benign retry next tick) and only
  `root_hash == undefined` answers empty (the joiner /
  compacted-shard convergence path needs that). `chase_refreshed_root`
  propagates a failed root re-request instead of manufacturing a
  false `peer_pages_unavailable` (an immediate rebootstrap flag) from
  a transient serving hiccup.
  (3) GC vs IN-FLIGHT PULLS: pulled peer pages are unreachable from
  the LOCAL root until integrate, and `truncate_below_or_equal`'s
  mark-and-sweep collected them mid-pull; `bondy_mst:merge` then
  silently treated the missing subtrees as EMPTY (95-271 "merge_aux: B
  root dangling, keeping A" per run) while the session recorded the
  round complete and `confirm_root` licensed the origin to truncate —
  loss finalized. Fixed twice over: sync sessions PIN the root they
  pull (`pin_peer_root/2`, consumed by a successful integrate,
  120s TTL against dead sessions; `truncate_below_or_equal/4` passes
  pins as `bondy_mst:gc/2` KeepRoots — the store's mark walk tolerates
  partially-pulled roots), and `integrate_peer_root` re-checks
  `missing_set` ATOMICALLY with the merge (same process as the GC),
  answering retryable `{error, {peer_pages_missing, N}}` instead of
  merging partially (session loops back and re-pulls,
  budget-bounded). Also: inline transport's `get_frontier` aligned to
  the snapshot-VV-then-drain order. TDD anchors in
  `bondy_oplog_compaction_fused_test`:
  `watermark_door_folds_unapplied_peer_event_fused` and
  `watermark_door_holds_unapplied_peer_event_applier` (both RED
  against the old door — `{error, {frontier_gap, _}}` + op absent —
  now assert op present, honest VV, and bounded MST). Scheduler
  `?GAP_STRIKE` comment updated: a gap verdict is now deterministic
  evidence of compacted-past-me history; the two-strike debounce stays
  as a bounded-cost hedge. Architecture doc 06 reconciliation-rule +
  hazard table rewritten. Gates: compaction CT 2/2 (sustained now
  gap-zero-asserting), aae CT 15/15, module 16/16, full eunit + proper
  green.

- [x] 2026-08-03 — **Residual gap-transient forensics COMPLETE — the
  "transient" is the WATERMARK DOOR, i.e. real per-replica data loss at
  defaults (fix is its own open item above).** Instrumented the
  pipeline in three rounds against the sustained compaction cluster
  case: (1) per-origin deficit detail (peer vs local seq) on the
  session gap verdict + `[bondy_oplog, sync_session, frontier_gap]`
  telemetry — 43-64 gaps/25s, deficit almost always exactly +1/+2, ~80%
  on the sync peer's own origin; (2) responder `get_frontier` reordered
  to snapshot-the-VV-then-drain (kept: strictly tighter contract — the
  answered frontier can no longer count events applied mid-call) — did
  NOT reduce gaps, refuting the responder-TOCTOU hypothesis; (3)
  `present_locally` probe on the gap verdict (fold MST+overlay for the
  missing `{Origin, Seq}`) — 105/105 ABSENT locally after a complete
  round + settle, refuting apply-lag and proving the round never
  delivered the events; (4) door instrumentation
  (`report_doored_events` + `integrate_doored` telemetry) — direct hit:
  every node discards the other two nodes' never-applied events at
  integrate, `registry/*` AND `main/*`, same event re-doored on
  consecutive integrates until the origin compacts it away
  (`confirm_root` confirms page-holding, not application), after which
  the VV max-merge masks the hole. The per-node RIB `check/1` cannot
  see this class (both its sides derive from the same merged stream).
  All instrumentation is production-grade and stays. Suite forensics:
  collector now captures gap/doored/sync-outcome telemetry with
  receipt timestamps; `do_gap_forensics/0` dumps per-node.

- [x] 2026-08-03 — **Stale-peer rejoin audit COMPLETE: silent data loss
  bug proven, principled fix BUILT, all gates green.** The new
  `bondy_oplog_compaction_cluster_SUITE:
  silent_peer_truncated_past_recovers_on_rejoin` case (3 real nodes,
  durable `main/*`, fully deterministic: dispatch disabled, manual
  per-instance fused sync+compact, watermark-advance observable — async
  `{ok, compaction_pending}` polled) PROVED the bug: recency-filtered
  truncation past a silent peer worked, but the rejoining peer's live
  rounds "succeeded" against the truncated trees, unconditionally
  ADOPTED the peer frontier, and the oracle reported CONVERGED over
  permanently lost data (4 keys gone, zero rebootstraps). THE FIX
  (adoption-needs-a-witness, all uncommitted): (1) #72's fused rederive
  was already fixed+pinned (stale task label); (2) INSTALLED-CONSISTENCY
  BARRIER — the responder answers `get_frontier` only after
  `await_apply/1` drains the overlay, so the answered frontier counts
  only installed-ever events (zero new state; the frontier is fetched
  before the root, so the round's tree is same-or-newer); (3) the
  frontier-gap check runs for ALL instances, gated on COMPLETE rounds
  (`PeerRoot =/= skip`; capped rounds exempt — and adoption is now ALSO
  gated on completeness, closing a second over-claim), with the
  initiator settling locally before the verdict (overlay drain + new
  `bondy_oplog_applier:barrier/1`, a call served after the
  integrate-time replay cast and running the I1 fence — closes the
  applier replay-lag false positives that broke 20 first-sync tests);
  (4) adoption only at bootstrap finalize (phantom maxima included) or
  deficit-free complete rounds — the phantom-adoption-on-live-rounds
  contract yields (it WAS the loss mechanism; its test rewritten to
  assert refusal + adoption-via-bootstrap:
  `live_sync_refuses_phantom_frontier_bootstrap_adopts`); (5) remedy
  scoping: gap→auto-rebootstrap for applier-backed durable +
  retention-fused instances; fused-without-retention gets an honest
  standing-gap WARNING instead (a single live fused re-bootstrap under
  churn measurably corrupted RIB cells — see the new open item), plus a
  two-strike debounce absorbing a rare uncharacterized single-shot
  transient (second open item). The prepare-fence test now also pins
  the session-side gap verdict (`{error, {frontier_gap, _}}` when the
  whole local settle is stubbed). Gates: eunit 2682/0, proper 69/69,
  CT compaction 2/2 (sustained + rejoin), reclamation 2/2, aae 15/15,
  registry 21/21.

- [x] 2026-08-03 — **R2 BUILT: causal-stabilization folding of nested
  accumulator PO-Logs (`{keep, Reduced}` + write-back).** A struct
  field's dot-store is a pure op-based PO-Log (one entry per sub-op,
  forever — the registration RIB's `count`/`invoke`/`earliest`/`latest`
  growth class). The sweep now folds each origin's causally-stable run
  into ONE synthetic op, bounding every field at `O(origins)`. Pieces:
  new optional behaviour callback `state_to_op/1` (the op that rebuilds
  an equivalent state from bottom — implemented by `pn_counter`
  `{inc, Net}`, `min`/`max_register` `{set, V}`, `lww_register`
  explicit-HLC `{set, H, V}`/`{clear, H}`, covering all four RIB
  fields); per-origin fold engine
  `bondy_oplog_crdt_nested_core:stabilize_fold/2` (replays the run
  through the sub-CRDT's OWN `interpret_cog` — value-preserving by
  construction; rep dot = run's max seq; gated on `order_independent` +
  `state_to_op`); `struct:stabilize/2` now returns `{keep, Reduced}`
  (zero-discard still checked first); the sweep's `{keep, Reduced}`
  branch is implemented as a value-preserving frame rewrite (same
  Hlc/value column, smaller state; `put_batch` + point-cache invalidate
  + A3 OldState write-through; NO ctx-guard co-evict — the contract
  forbids context shrink) behind the same overlay fence as `discard`;
  stat `reduction_skipped` → `rewritten` (cell_utils, applier,
  instance, prometheus_db, docs). The applier's sweep handler also got
  the I1 remote-generation fence (same window as `cell_context`: the
  sweep judges "state at StableHlc"). **License refinement over the
  fence entry's claim below**: HLC-frontier stability licenses folding
  ONLY for dot-stores never partially dropped by observed context —
  struct qualifies (no `put`/`rmv`); aw_map/aw_set do NOT (an in-flight
  pre-certification `{rmv, K}` with HLC above the frontier can observe
  a prefix of a folded run → divergence; counterexample in
  `nested_core`'s moduledoc) and stay unfolded pending vector-stability
  certification (new open item above). Tests: 7 nested_core fold units
  (incl. lww winner-HLC pinning), 4 struct stabilize units (fold ≡ full
  replay, discard precedence), PropEr `prop_stabilize_fold_transparent`
  (any replica, any cut: value preserved + encode roundtrip + suffix
  delivery converges; 300 runs), end-to-end
  `bondy_db_cell_sweep_test:struct_fold_reduces_stable_runs` (RIB
  schema through real stamped tier_2 events: `rewritten` >= 1, value
  identical, idempotent second sweep, post-fold writes keep absorbing
  and re-fold). Review follow-ups (same day): `g_counter` opted in
  (`state_to_op/1` -> `{inc, Total}`); overlay-fence-blocked rewrite
  path covered end-to-end (`overlay_fence_blocks_reduction` —
  established that NO production owner arms the overlay: `bondy_db`
  registers every shard `overlay => disabled`, so the fence is armed
  via passthrough meck of `entry_overlay/1`; blocked -> `skipped`,
  drained -> `rewritten`); representation-divergence constraint
  documented at the STABILIZE section (frames are local — nothing may
  hash-compare them across replicas); failed-fence-catch-up policy
  documented at the applier handler (promptness-not-soundness).
  FOUND while testing (pre-existing, latent, from the nesting rollout):
  **a batch is ONE dot**, so two nested sub-ops on the SAME field/key
  in one `apply_batch` silently collapse to the last (dot-store keys by
  dot); only production batch caller is the RIB (one op per field —
  safe); constraint documented at `bondy_db:apply_batch/4` and
  `struct:batchable/0` AND ENFORCED: both batch entry points
  (sync + async) reject a batch carrying more than one nested sub-op
  per target with `{error, {duplicate_batch_subop, Targets}}` before
  the WAL append (`bondy_db:assert_batch/2` — structural check on the
  shared `{apply, Target, ...}` nested-op convention; flat
  put/rmv/add forms exempt, their one-dot sharing is the documented
  atomic batch semantics). Rejection tests for both op shapes
  (struct 3-tuple in `bondy_db_cell_sweep_test`, collection 4-tuple in
  `bondy_db_aw_map_batch_e2e_test`), plus a distinct-keys
  still-batchable case. Final gates: eunit 2682/0, proper 69/69, CT
  bondy_registry_SUITE 21/21.

- [x] 2026-08-03 — **Prepare-fence (invariant I1) BUILT — `cell_context`
  can no longer lag delivered remote events.** Found while designing R2
  against the pure op-based CRDT literature: on applier-backed
  instances, `integrate_peer_root` advances the MST and casts
  `replay_cell_events`, but the cast is unordered w.r.t. a client's
  `cell_context` call — the tier_2 PREPARE could read a projection
  missing events the replica had already delivered, minting a context
  that under-approximates its causal past (lost causality — the fatal
  direction, unlike the known read-and-stamp false-concurrency which
  CRDT semantics absorb). Fused instances were immune (inline replay);
  local events were immune by construction (projection-before-MST in
  the WAL drain). Fix: a shared per-instance `remote_gen` atomic
  (published via `bondy_oplog_registry`, bumped at the END of the
  integrate handler — the delivery point, provably the only remote
  entry path) + a gen-gated fence in the applier's `cell_context`
  handler that runs the idempotent `replay_pairs` catch-up before
  serving, advancing its recorded generation only on success.
  Steady-state cost: one atomic read. The I1/I2 invariants and the
  "causal stability without causal broadcast" theorem (Baquero/Almeida/
  Shoker §7.2 recovered over containment frontiers) are documented as
  literate comments at `ensure_remote_caught_up/1`, with cross-refs at
  the integrate bump site, the fused handler and the `stabilize/2`
  contract. This makes `StableHlc` full causal stability everywhere —
  existing `discard` reclamation is now provably exact on
  applier-backed instances too, and R2 can fold at the existing sweep
  with NO VV plumbing and no fused-only carve-out. Regression:
  `bondy_db_prepare_fence_test` (deterministic window via swallowed
  replay cast: projection provably lagging → one cell_context call →
  context covers the remote dot AND projection caught up; stable 3/3).
  Gates: eunit 2663/0 (2 documented peer_strategy flakes, 6/0
  isolated), proper 69/69, CT bondy_registry_SUITE 21/21.

- [x] 2026-08-03 — **R1: registration cell `created_times` two_p_set →
  `earliest`/`latest` min/max ratchet registers.** The old field grew
  one element per add and one tombstone per remove, forever
  (~104–237 B/op); the replacement is a scalar per field
  (`bondy_oplog_crdt_min_register`/`max_register`, tier_0, `{set, V}`)
  at the pre-validated (task #20) ratchet cost: removals never shrink
  the watermarks — they record the group's lifetime creation-time
  range, which WAMP dealer semantics permit. Changes:
  `?RIB_REGISTRATION_SCHEMA` (catalog), `bondy_registry_rib` write path
  (adds set both ratchets; removes are count-only now, so
  `apply_removed` collapses to one `apply_async`), `reshape_summary/2`
  is pure shape-normalisation (no derivation), `created_key/2` deleted,
  restart/reap story simplified (ratchets are per-value, not
  per-origin — no force_reap needed; the self_heal doc's reap window
  caveat is gone). The regs lifecycle eunit now asserts ratchet
  retention across removals explicitly. Gates: full eunit green (4
  known-flaky oplog scheduler fails, clean 23/0 on isolated rerun),
  proper 69/69, CT bondy_registry_SUITE 21/21 + registry_meta 8/8,
  catalog+RIB eunit 16/16.

- [x] 2026-08-03 — **Registry correctness sweep (2 fixed, 1
  reclassified).** (1) `bondy_registry_entry:key_pattern/3` accepted
  only binary-or-wildcard session ids, crashing for session-less refs
  whose entries are legitimately stored with `session_id = undefined`
  (internal callback subscribers, see `new/6`) — the guard and spec now
  admit `undefined` as an exact-match value; regression case
  `key_pattern_sessionless` added to `bondy_registry_entry_SUITE`
  (3/3). (2) `bondy_registry:add/5` spec said `{ok, Entry, IsFirst}`
  but the function (and every caller) uses `{ok, {Entry, IsFirst}}` —
  spec and doc corrected. (3) `pick/1` hash widening turned out NOT to
  be mechanical (see the reclassified item under Older pending) —
  partition-owned stores mean it needs the sharding-grain design.
  Gates: compile clean, bondy_registry_SUITE 21/21,
  bondy_registry_meta_SUITE 8/8, bondy_registry_rib_test 5/5.

- [x] 2026-08-03 — **Session-churn durable-write diagnosis: REFUTED the
  RIB-drives-leveled hypothesis.** Method: temporary CT suite (deleted
  after) tracing the full `bondy_db` write API (+ `leveled_bookie:
  book_mput/2`) with a counting tracer, phase-split over 200 anonymous
  TCP sessions x 10 subscriptions. Results — baseline: silence; OPEN:
  one 3-op `apply_batch_async` on the registration RIB (the
  once-per-realm meta-procedure registration, NOT per-session);
  SUBSCRIBE: exactly 1 ephemeral `apply_async` per subscription
  (subscription RIB, memory topology); CLOSE+settle: exactly 1
  ephemeral `apply_async` per entry (RIB removes); **zero `book_mput`,
  zero durable-table writes in every phase**. Session churn touches
  only the ephemeral registry DB, as designed. Consequences: the
  close-batching idea is demoted to an optional dispatch-overhead
  optimization, and the s13 leveled mailboxes need a different
  attribution (new open item above).

- [x] 2026-08-03 — **kill-mode CANCEL infinite INTERRUPT loop FIXED**
  (found by the full-trifecta run; latent bug exposed by the inline
  routing change in `fa879b13`). `bondy_dealer:find_invocations/3`
  recursed with `bondy_rpc_promise:find/1` on the same key pattern
  "until no more pending invocations" — but kill-mode deliberately
  READS the promise without consuming it (it must survive until the
  callee's INTERRUPT ERROR settles it), so the loop re-found the same
  promise forever, machine-gunning INTERRUPTs at the callee (captured:
  461k `{interrupt, ...}` messages in the callee connection's mailbox
  in ~2s) in a race against the very ERROR that would end it. Under
  flow-pool scheduling the callee usually won the race, hiding the
  bug; with CANCEL inline in the caller's connection process the
  spinner wins. Fix: new `bondy_rpc_promise:find_all/1` (one
  `ets:select` pass) + `find_invocations/3` folds over that list —
  exactly one INTERRUPT per pending invocation. Regression coverage:
  `bondy_connect_cancel_SUITE:cancel_kill_interrupts_callee` (was the
  red case; bisected green at `b6c3e21b` → red at `fa879b13`, staged
  admission changes exonerated by stash-bisect). Both previously
  failing suites now 5/5 and 2/2.

- [x] 2026-08-03 — **HELLO admission control BUILT & Fly-verified (s14,
  identical profile).** New `bondy_regulator_load`: a 100ms run-queue
  sampler with hysteresis (busy at high_watermark x schedulers_online,
  normal again at low_watermark; defaults 8x/4x; lock-free `busy/0`
  via persistent_term+atomics, fails open). Gate in
  `bondy_wamp_protocol` HELLO handling (before realm/auth work): when
  busy, refuse with retryable `wamp.error.unavailable` ABORT
  (`abort_message(overload)`), counted as
  `bondy_wamp_dropped_total{reason=admission, family=hello}`. Config:
  `load_regulation.hello.enabled` (default on) +
  `load_regulation.load_monitor.*` (watermarks, sample interval).
  s14 vs s13: welcome med 6.6s → **~500ms** (p95 27.5s → 14.5s — off
  the 30s timeout cliff), admitted publishers 13.3k → **20.8k**,
  publish rate +27% (14.4k/s), events delivered 2x (4.84M @ 17.3k/s),
  delivery avg 3.45s → **722ms** (med 25ms); ~97.6k HELLOs refused
  cheaply (nodes busy through ramp+hold, normal again immediately
  post-load — hysteresis clean, no flapping at 30s sampling). Gates:
  eunit 2665/0, proper 69/69, CT bondy_wamp_protocol 12/12 (incl. new
  busy-refusal + gate-disabled cases; sampler suspended via sys to
  make forced busy deterministic).

- [x] 2026-08-03 — **Relay ingress singleton ELIMINATED (3b) & Fly-verified
  (s13, identical profile).** Cluster peers now address relayed messages
  to `{via, bondy_router_worker, PartitionKey}` — partisan's receiving
  connection process resolves the flow key against the LOCAL pool
  geometry (`bondy_router_worker:whereis_name/1`, which is also the
  shed gate: it claims the worker's usage slot and returns `undefined`
  over the limit) and delivers straight into the owning flow worker's
  mailbox. The `bondy_relay` gen_server is deleted (module reduced to
  egress + routing_opts; sup child removed; `relayed_by` is a
  node-static ref); no mixed-version support by design — lockstep
  deploy. `wamp_relay` channel parallelism 2 → 8 (default + fleet
  config). Bridge relay keeps `cast/3`; family label `bridge_relay`.
  s13 vs s12: delivery med 7.5s → **25ms** (avg 21.5s → 3.45s); flow
  occupancy 0–3, zero sheds, relay service p50 87–99µs, ~275k relay
  tasks/node executed, `bondy_relay` mailbox class gone. Trade
  surfaced: with routing fully unclogged, WELCOME starves harder (open
  item above). Gates: proper 69/69 (2 new via-path properties: keyed
  resolution determinism + FIFO/exactly-once/slot-accounting through
  the real via delivery), eunit 2659 w/ 3 known-flaky oplog fails
  clean on rerun (23/0), CT wamp_protocol 10/10 + meta_events 5/5 +
  retained_message 3/3; end-to-end order assertions live in
  bondy_router_ordering_SUITE (cluster — exercised on Fly, not local).

- [x] 2026-08-03 — **Inline publish routing fix VERIFIED on Fly (s12,
  identical profile)** — the delivery collapse was a regression from
  serialising locally-originated PUBLISH/YIELD/CANCEL/ERROR on the
  16-worker flow pool (commit `9bc267e2`); reverted to synchronous
  handling in the connection process (which already serialises the
  session's messages, preserving per-source order, and exerts natural
  backpressure instead of at-most-once sheds). The keyed flow pool
  remains on relay + bridge-relay ingress, where it fixes a real
  pre-existing ordering bug. s12 vs s11: events delivered 229k →
  **3.61M** (819/s → 12.9k/s, 15.8×); delivery med 2m0s → **7.5s**,
  avg 2m23s → 21.5s, p95 3m46s → 1m22s; sheds 5.08M → **0**; flow-pool
  occupancy pinned-at-cap → 0–2. Follow-on constraints surfaced as the
  two open items above. Gates: eunit 2663/0 (one flaky pass rerun
  clean), proper 67/67, CT bondy_wamp_protocol 10/10 +
  bondy_meta_events 5/5 + bondy_retained_message 3/3;
  bondy_router_ordering_SUITE (cluster) not run locally, assertions
  are behavioral and unchanged.

- [x] 2026-08-03 — **Delivery-pipeline backlog DIAGNOSED** (instrumented
  s11 Fly run, identical s10 profile): added permanent flow-pool
  telemetry — `bondy_router_worker:cast/3` tags tasks by family
  (router | relay) and emits `[bondy, router, flow]` with mailbox wait
  + service time, sunk as `bondy_router_flow_queue_microseconds` /
  `bondy_router_flow_service_microseconds`. Verdict: the flow pool is
  the choke — see the open item above for numbers and fix directions.
  Also ruled out: subscriber-side/client bottleneck (sub LG received
  just 819 events/s at 381 kB/s), transport-queue detour (WS sessions
  have no transport_id), and expensive publish work (service p50
  53–95µs).

- [x] 2026-08-03 — **§9.8 AE auth fence fixed & Fly-verified** (the
  top router bug from the fleet diagnosis): default
  `db.aae.fence.max_lag` 1s → 60s (`?AUTH_MAX_LAG` in bondy_auth.erl +
  schema). The freshness signal is produced by background AE rounds
  whose wall-clock completion stretches under BEAM run-queue pressure
  (the scheduler's fence exemption cannot help — measured worst
  security-shard lag hit ~30.2s at ~29k sessions with ZERO actual
  staleness), so a ~1s bound mass-refused auth under load. Verified
  identical s9 profile: aborts ~33,000 → 113 (99.7% down, the residue
  = moments grazing the interim 30s bound → default set to 60s for 2x
  measured headroom); all 1000 subscriber VUs completed their bursts
  (100%); admitted publish throughput +27% (15.5k → 19.7k/s). Also:
  fence refusals now ABORT with retryable `wamp.error.unavailable`
  ("temporarily unavailable") instead of
  `wamp.error.authentication_failed` — an availability condition must
  not read as a credential failure. Revocation precision still rides
  the per-user token_version fence + merge-reactor RBAC invalidation.

- [x] 2026-08-03 — **Fleet harness fixed & verified storm-free**
  (`harness/k6/fleet_smoke.js`, `run-fleet-lg.sh`): success rates now
  recorded INSIDE socket callbacks (k6 interrupts long-lived successful
  iterations, so post-connect recording undercounted every success —
  root of the perpetual `wamp_session_ok`/`wamp_all_subscribed_ok` 0%);
  welcome timeout (30s default) + exponential per-VU reconnect backoff
  (2s→60s, jittered); split error counters (aborts / proto / parse) +
  sampled ABORT-frame logging; empty-frame parse guard (killed the
  errors==iterations artifact); publisher VUs spread across 4 LG
  machines to stay under the Fly per-IP edge cap. Verified s9: ZERO WS
  handshake failures on all 5 LGs, `wamp_all_subscribed_ok` 99.88%.
  Also ruled out: Bondy's WS listener never crashed (500 acceptors
  healthy through every storm; binds IPv4-only).

- [x] 2026-08-02 — **Session-open (WELCOME) bottleneck DIAGNOSED**
  (instrumented Fly runs): added permanent open-path telemetry —
  `bondy_wamp_hello_duration_microseconds` (connection-process HELLO
  total), `bondy_session_manager_open_{queue,service}_microseconds`
  (mailbox wait vs work, via enqueue timestamp in the open call) and
  `bondy_session_manager_cleanup_microseconds` (kind down|close|error)
  in bondy_telemetry / bondy_wamp_protocol / bondy_session_manager /
  bondy_prometheus. Findings: pool workers exonerated (p99 ≤ 15ms);
  hello time = run-queue scheduling delay under saturation; and the
  saturation is largely the harness's 99.3%-failed-handshake retry
  storm (~5.7k/s), present in all prior runs. Follow-ups above.

- [x] 2026-08-02 — **Async RIB write path** (the 30x subscribe-latency
  regression): the cost was `bondy_db:apply/4`'s read-your-writes
  barrier (`await_apply`) making every SUBSCRIBE/REGISTER pay the
  registry drain's backlog. Added `bondy_db:apply_async/4` /
  `apply_batch_async/4` (no barrier) + `bondy_db:await/3` (explicit
  barrier for read-after-write callers); `bondy_registry_rib` hooks now
  write async — sound because local routing truth is the trie/members
  ETS written synchronously first, and cells only feed AE-replicated
  summaries. Guarded the fused mem-WAL drain against teardown with
  undrained work. Fly: subscribe med 44.9s → 2.45s (18x), p95
  3m3s → 28.6s; memory shape held (ETS drained to 403 MB post-load).
  NOTE: registration cells keep the tier_2 `cell_context` round-trip —
  in-node cross-session concurrency on a cell is real (cell key is
  node-granular, hooks run in the caller's process), so a "single-writer
  stamp opt-out" is unsound.

- [x] 2026-08-02 — **Fleet OOM resolved & Fly-validated** (four-bug
  chain, each masking the next): `bondy_oplog_gc_scheduler` head-of-line
  starvation (least-recently-fired tick ordering); MST page leak
  (`bondy_mst:gc/1` mark-and-sweep in `truncate_below_or_equal/3`, ETS
  backend); `peer_pages_unavailable` re-bootstrap storm
  (`chase_refreshed_root/7` + applied-frontier deficit gate); fused
  rederive no-op (`bondy_oplog_instance:rederive_projection/1` heals
  install clobber). `mst_retention` demoted to opt-in overload backstop,
  defaults OFF — peer-confirmed compaction bounds ephemeral history by
  propagation, same as durable. Fly: ETS 776 MB peak → 274 MB drained
  (previously 6.9 GB pinned forever). Locked by
  `bondy_oplog_compaction_cluster_SUITE` (propagation ceiling +
  drain-to-quiescent + page-bytes + zero RIB divergence, at defaults)
  and `bondy_oplog_compaction_fused_test` (14 cases incl. page
  reclamation and clobber→rederive→idempotent).

## Prefix closure (db.aae.prefix_hold) — 2026-08-05
- Done: hazard proven (Isabelle + TLA+ + CT detector) → hold enforcement built,
  default ON; seq-density fix; metrics + Grafana row; doc_extras SADs (platform
  + storage); bondy_docs concept + config ref; paper draft (proofs/paper/).
- [x] Run full compaction cluster suite (sustained_writes + silent_peer cases)
      under the new default — both PASSED 2026-08-05; all 4 suite cases now
      green under prefix_hold=on.
- [x] Full trifecta — GREEN 2026-08-05: eunit oplog 1185 (1 known
      partisan_source_excludes_self isolation flake, passes isolated) /
      db 349 / router 134; proper 69/69; CT prometheus 5/5 (fixed stale
      wamp_message_metrics_via_telemetry — sized arity-3 form) +
      aae_cluster 15/15 + compaction_cluster 4/4.
- [x] Grafana "Prefix closure" row verified against live data 2026-08-05:
      local node1 daemon + monitoring stack; all 3 families on /metrics with
      HELP/TYPE; Prometheus target up; stat queries evaluate (0 on healthy
      solo node — correct). Visual pass: http://localhost:3000 (node1 left
      running). Non-zero series need fault injection (seen on Fly s24).
- [x] Commits 2026-08-05: user committed fix/proofs/docs sweep; + `96ccb93f`
      (prometheus suite test fix) + bondy_docs `e7d43b5` (concept + config
      ref). Left untracked by design: CLAUDE.md, TODO.md, proofs/paper/
      (pending user pass), scripts/gen_load_regulation_diagram.py.
- [x] 3-replica TLC hold run 2026-08-05 — CLEAN both ways: BFS bounded-
      exhaustive to depth 18 (25.2M distinct; baseline violates at 6) +
      simulation 800k traces / depth 40 / 321M states. Cfg:
      proofs/tla/AaeCausalClosure_Hold3.cfg; results in proofs/tla/README.md.
- [x] Origin-side no-op filler for burned seqs BUILT 2026-08-05 (always on,
      no knob): `release_seq_range` burn -> cast `{fill_burned_seqs,...}` ->
      instance mints signed `seq_fill` events over the burned range (fresh
      HLCs, same seqs, `do_build_events_at/6`), WAL-appends w/ backoff
      retry; `cell_apply` counts `seq_fill` in origin_seqs (frontier/hold/
      detector) & every fold skips it. New metric seqs_filled_total +
      Grafana stat/series; docs updated. EUnit incl. cross-sync hold test.
- [x] FIXED partisan_source_excludes_self isolation flake 2026-08-05:
      `bondy_oplog_transport_partisan_test` peers joined local Partisan
      membership but `peer:stop/1` left the dead nodes in the set; cleanup
      now sweeps non-self members via `partisan_peer_service:leave/1`
      (specs from manager `members_for_orchestration/0`). Full oplog dir
      1187/0 — first fully green run.
- [x] FIXED `truncated_prefix_is_held_and_repaired_by_rebootstrap` flake
      2026-08-05: root cause = ASYMMETRIC truncation (step 4 asserted only
      >=1 instance advanced per node; disjoint sets let the second rejoin
      round fill every held gap on late-key instances -> assertion (b)
      failed despite correct holding). Fix: `truncate_main_until_common/5`
      loops fused sync+compact until a common truncated instance exists
      (13/13 common in validation), plus an honest skip branch when holds
      all legitimately released. Both prefix CT cases green.
- [ ] NOTE: a leftover `make node1`-style daemon makes bondy CT suites fail
      init_per_suite with eaddrinuse (and may perturb eunit under load —
      one unreproducible 10-failure bondy_db run). Stop local nodes before
      test runs.
