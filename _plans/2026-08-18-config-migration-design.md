# Configuration migration

Give operators a tool that rewrites a `bondy.conf` from ≤ `1.0.0-rc.65` into the
keys this release actually reads, and make the keys it cannot rewrite loud rather
than silent. Removing the legacy listener keys altogether depends on that tool
existing first.

Status: **BUILT** as `scripts/migrate_conf.escript` (check + migrate + selftest),
documented at `doc/guides/configuration/checking_your_configuration.md`, gated by
`just conf-selftest`. §5 records what was built and where the implementation
departed from this design; §9 records what it found. The two decisions in §8 are
still open, and §7 still depends on them — but not on the tool, which now exists.

## 1. Problem

Two hazards, with one shared root: a configuration key that Bondy no longer
reads produces no diagnostic.

**A stale or renamed key is dropped in silence.** The node boots and the
subsystem runs on its default while the operator believes their setting applies.
This is not specific to listeners — it is every key in the file. It is also
already documented wrongly: until this pass,
`doc/guides/configuration/migrating_from_1.0.0-rc.65.md` told operators that an
unrecognised key "fails boot immediately, naming the key and suggesting the
closest valid one", which is the opposite of what happens (§2).

**The listener surface has two spellings of the same thing.** A node whose
`bondy.conf` contains no `listeners.*` key takes the legacy path and gets the
eight historical listeners; a node with even one such key takes the configured
path, where the legacy identity keys are never consulted. That gate is correct
and intended, but it silently drops every listener the operator did not restate.
It has already cost real time: it broke nine cluster tests whose only symptom
was `econnrefused`, and the cause was invisible from the failure.

Sustaining both spellings is not free. Measured on this branch: **306 legacy
listener mappings** (263 in `schema/bondy.schema`, 43 in
`schema/bondy_bridge_relay.schema`) that are substantially the same ~38 keys
repeated across eight listener names, against **90** `listeners.$name.*`
mappings covering the same ground once. Two resolution paths must agree, and a
test asserts they do. Most of the defects found while building the dynamic
listeners traced to the duplication rather than to the new design: a block
arriving as a proplist under one spelling and a map under the other; a bind
address whose legacy target was not a valid ranch option, which refused the
boot; two sibling bridge mappings disagreeing on where an address lives.

## 2. Verified constraints

These are established from the implementation, not from documentation. They
constrain the design, so each names its evidence.

**Bondy cannot fail the boot on an unknown key, and this is structural.** The
generated pre-start hook runs `cuttlefish` three times against the *same*
`etc/bondy.conf` (`_build/default/rel/bondy/bin/hooks/pre_start_cuttlefish`,
invocations at lines 10, 28 and 46; schema sets declared in `rebar.config`'s
`{scuttler, …}` block at :1030-1053). Each run parses the whole file while
knowing only its own subset, so every key owned by another subset looks
unrecognised to it. All three therefore pass `--allow_extra`, and
`cuttlefish_generator.erl:406-411` then does nothing at all for a key it cannot
find. The failure-with-suggestion path exists, at `:412-422`, but only on the
branch the release never takes.

Correction to an earlier reading of this: the three invocations do **not** use
three different `--schema_dir` values. The first passes `releases/<vsn>`, holding
`vm_args.schema` alone; the second and third pass the *identical*
`releases/<vsn>/schema/`, because the release copies riak_sysmon's schema in
beside the application ones. So a release has **two** distinct schema directories
where the rebar.config declaration lists three sets. This does not weaken the
argument above — the vm_args run and the application run still each see most of
the file as foreign — but any check that reasons per set has to count two, not
three.

**The flag cannot simply be removed.** It is hardcoded in the plugin template
(`rebar3_scuttler/priv/pre_start_cuttlefish.tpl:16`), not in Bondy's
`rebar.config`; there is no `{scuttler, …}` option that disables it. Removing it
would require patching or forking the plugin, and would then abort the boot on
the first invocation for essentially every application key in the file.

**A key is dead only if every schema set rejects it.** Confirmed by running the
release's own escript: the VM-arguments invocation rejects `db.aae.interval` — a
valid key — and suggests `vm.ets.max_tables`, while `store.write_buffer_size`, a
key the migration guide lists as removed, is rejected by both invocations. So
any check must intersect the complaints across schema directories. (Caveat: the
release available for that run was `1.0.0-rc.65`, which predates the
`oplog.*` → `db.*` rename, so its per-key verdicts are evidence about the
mechanism, not about current key names.)

**`bin/cuttlefish` is directly executable.** It carries
`#!/usr/bin/env escript`, so an operator can invoke it without `relx_escript`,
which the hook uses only because a release may bundle its own erts.

## 3. What the tool migrates

Five kinds of change, because they need different machinery. The first four act
on `bondy.conf`; the fifth acts on `advanced.config`.

**Exact renames — 19, enumerated.** Eleven `oplog.aae.*` → `db.aae.*`; four
`oplog.core.*` → bare `db.*` (`gc_interval`, `gc_heap_delta`,
`pack_auto_seal_bytes`, `pack_seal_mode`); four `oplog.core.*` → `db.main.*`
(`shard_count`, `partition_strategy`, `realm_prefix_depth`,
`on_topology_mismatch`). Value and meaning are unchanged in every case.

**Prefix rename — one rule, not a table.** `rpc_gateway.` →
`http_connector.`, preserving everything after the prefix, including the
`$service` and `$proc` wildcard segments. A lookup table cannot express this.

**Removals — three classes.** `oplog.catalog` and
`oplog.core.scan_max_concurrency` (neither ever had a consumer) and any `store.*`
key (the RocksDB tuning surface, which has no equivalent). These are dropped
with a report line, never rewritten.

**The new surface is now complete (`auth_timeout` closed).** Comparing the two
spellings key by key — 66 distinct legacy leaf keys against 90 new-style ones —
every legacy key has a new-style equivalent once the deliberate prefixing is
accounted for (Cowboy-level settings gain `http.`, certificate material gains
`tls.`) and two spelling changes are applied: legacy `ping` is now
`ping.enabled`, and legacy `ping.interval` is now `ping.idle_timeout`. The single
exception was `bridge.listener.{tcp,tls}.auth_timeout`
(`schema/bondy_bridge_relay.schema:802`), which had no `listeners.$name.*`
counterpart: a bridge listener under a *new* name could not set it, and removal
would have made it unreachable. `listeners.$name.auth_timeout` has since been
added, so every legacy listener key now has a new-style equivalent and removal
deletes no capability. The value reaches its consumer because
`bondy_listener_ranch:stream_protocol_opts/2` hands a `bridge_relay` handler the
whole listener block (`:158`), where `bondy_bridge_relay_server:init/1` reads it
with `key_value:get(auth_timeout, Opts, 5000)` — the same 5s the legacy mappings
default to.

**Listener restructuring — eight names.** The structural keys (`enabled`,
`transport`, `protocol`, `services`, the bind target, and the bind address) move
to `listeners.<name>.*`; everything else — socket tuning, CORS, security
headers, TLS material, `ping`, `proxy_protocol` — stays on its historical key,
because a listener's option block is read at `[Name, …]` and the historical key
is what populates it. Suggested names are in the listeners guide's migration
table.

**`advanced.config` edits.** Rename a `{bondy, …}` stanza to
`{bondy_router, …}`, and delete any `{plum_db, …}` stanza. Both are silently
inert today rather than errors, which is why they need a tool rather than a boot
check.

## 4. The cases that need judgment

**`admin_api.http` → `admin` is the one row where everything moves.** Because
config is read by the listener's *current* name, once the listener is called
`admin` nothing reads `bondy_router.admin_api_http.*` any more — so every
`admin_api.http.*` key an operator kept, including `cors.*` and
`security_headers.*`, is dead. For this row alone the tool must move the
non-structural keys too, or say plainly that the defaults will apply.

**A partial migration is the dangerous input, not a legacy file.** A file with
no `listeners.*` key is safe: it takes the legacy path whole. A file that
already declares one listener and leaves the rest on historical keys is the
broken state. The tool must therefore treat an input that already contains
`listeners.*` keys as a migration in progress and complete it, not assume it is
already done.

**`wamp_uds` has no mappings at all.** It was reachable only through
application environment, defaulted to disabled, and bound
`/tmp/bondy_wamp.sock`. There is nothing in a `bondy.conf` to migrate; it is
mentioned so its absence is not read as an omission.

## 5. Interface

A script under `scripts/`, in the spirit of the existing
`check_layering.escript`, with two modes:

- **check** — read a `bondy.conf`, report every key that is renamed, removed, or
  requires restructuring, and exit non-zero if any are found. Nothing is
  written. This is the mode that belongs in an upgrade runbook and in CI.
- **migrate** — write the converted file to a new path (never in place), plus a
  report of every change made and every key dropped.

The check mode subsumes the manual `cuttlefish` recipe now documented in the
migration guide: it should run the release's own escript against each schema
directory, intersect the complaints, and attribute each surviving unknown key to
a rename, a removal, or neither. "Neither" is the interesting output — a key the
tool has no rule for.

Report content matters more than the rewriting. An operator needs to know which
of their settings will stop taking effect, and the current answer is that
nothing tells them.

### What was built, and where it departs from the above

**It does not shell out to `cuttlefish`, and does not intersect per-set
complaints.** It loads cuttlefish's own modules and calls them directly:
`cuttlefish_conf:file/1` for the conf, `cuttlefish_schema:files/1` for the
schemas, `cuttlefish_variable:is_fuzzy_match/2` for `$name` matching, and
`cuttlefish_datatypes:from_string/2` for flag values. So there is no second
parser to drift, and the union of all mappings gives the same verdict directly —
a key is unknown iff nothing anywhere maps it. The intersection was only ever an
artifact of the hook running three invocations that each see two-thirds of the
file as foreign.

Two facts made that possible, both probed rather than assumed: cuttlefish's beams
are at `_build/default/plugins/cuttlefish/ebin` in a checkout, and in a release
they are recoverable from `bin/cuttlefish` with `escript:extract/2`, which yields
an `archive` section that can be written to a `.ez` and put on the code path.
Only `cuttlefish_schema:files/1` may be used, not `file/1` — `file/1` is absent
from the release's older bundled copy, and picking the API both versions export
removes the version guard entirely.

**The runtime layout is two schema directories, not three.** The generated hook's
second and third invocations pass the *identical* `--schema_dir`
(`releases/<vsn>/schema/`), because the release copies riak_sysmon's schema in
beside the application ones. §2's "three schema sets" is true of the rebar.config
declaration, not of what runs.

**The listener table is called, not copied.** `bondy_listener_config:default_inventory/0`
and `reserved_names/0` are invoked directly from the loaded beam, so the nine
historical names, their ports, services and start phases cannot drift from what
the node does. Same two-layout lookup as cuttlefish.

**Legacy structural keys are derived from mapping TARGETS, not from a table.**
For each historical listener the tool finds the conf key whose target is
`bondy_router.<name>.enabled`, and the keys that own it by target prefix
`bondy_router.<name>.`. This is required rather than tidy: `bridge.listener.tcp`
is the key that enables `bridge_relay_tcp` and does not contain the listener's
name at all, and `bridge_relay_tcp`'s port targets `<name>.port` where every
other listener's targets `<name>.transport_opts.socket_opts.port`. It is the §6
target-vs-key lesson applied as a mechanism.

**`oplog.aae.*` is a prefix rule, not the eleven enumerated rows.** Every rule's
destination is checked against the schema before it is reported, so a member with
no `db.aae.` counterpart reports as unmapped rather than being renamed onto
nothing. That check also makes the count moot: `db.aae.*` has ten keys, not the
eleven §3 claims, and the prefix rule needs no reconciliation.

**Migrate never activates an inert key except by rename.** Renames are rewritten
in place; every other verdict is commented out with its reason wrapped above it.
Commenting out an unknown key changes nothing at runtime — cuttlefish was already
discarding it — so the migration's only behavioural change is the renames, which
is what makes them worth listing separately in the report. This is also what gives
the round-trip property.

**A rename onto a key the file already sets is withheld.** `cuttlefish_conf`'s
`remove_duplicates/1` folds left through
`cuttlefish_util:replace_proplist_value/3`, so of two lines for one key the LAST
wins. Renaming `erlang.async_threads` in a file that also sets
`vm.async_thread.number` would therefore discard one of the two values silently,
and if the legacy line sat lower it would override the new-style value the
operator wrote deliberately. Both values are reported instead, and migrate
comments the legacy line out — which leaves the explicit setting in force and
changes nothing.

**Migrate does not synthesise listener blocks.** It derives the block and prints
it for the operator to paste. Getting an inventory wrong produces a node with no
way in, which is the failure mode §8 names as the argument against removal; that
is not a decision to automate.

**`advanced.config` is check-only, and generalised.** Rather than the two stanzas
§3 names, it reports any stanza whose application does not exist — derived from
OTP's lib dir plus `apps/`, `_build/default/lib/` and `lib/` — with specific
advice for `bondy` and `plum_db`. Rewriting is deliberately not done: it is a
term file, and consulting and re-printing would discard every comment.

## 6. Validation

Two corpora already exist, which is the main reason to build this now.

**Oracle — the six shipped templates.** Verified in this pass: every template
declares every listener it configures, with `admin_api.http` correctly mapped to
`admin`. Migrating them must be a no-op for the listener sections, and check
mode must report them clean.

**Dirty corpus — our own rotted templates, now verified.** Method: extract every
`{mapping, "…"}` key from the three schema sets `rebar.config`'s `{scuttler, …}`
block declares (`schema/*.schema`, `schema/hidden/vm_args.schema`, and
riak_sysmon's `priv/riak_sysmon.schema`), treat a `$name`-style segment as a
wildcard, and match every assignment in each template against the union — so a
key reported dead is rejected by every set, which is the intersection rule of
§2. Run against every `bondy.conf` and `*.conf.template` in the tree: **28
distinct dead keys across seven files**, and clean for the seven that matter most
— `deployment/fly`, all three `examples/custom_config` files, and the three
`harness/*` templates.

The families, with the live key where one exists:

| Dead key | Live equivalent |
|---|---|
| `erlang.async_threads` | `vm.async_thread.number` |
| `erlang.max_ports` | `vm.port.limit` |
| `erlang.process_limit` | `vm.process.limit` |
| `erlang.distribution_buffer_size` | `vm.distribution.buffer_size` |
| `erlang.dirty_io_schedulers.number` | `vm.io.dirty_scheduler.number` |
| `erlang.time_correction`, `erlang.time_correction.warp_mode` | `vm.time_correction`, `vm.time_correction.warp_mode` |
| `erlang.sbwt` | `vm.cpu.scheduler.busy_wait_threshold` — same erts flag (`+sbwt`) and the template's value `none` is in its enum |
| `erlang.kernel_polling` | none in any active set |
| `vm.io.dirty_schedulers` | `vm.io.dirty_scheduler.number` — a misspelling of a live key, not an old one |
| `nodename`, `distributed_cookie` | only in the disabled `schema/erlang_vm.schema_bak` |
| `log.console`, `log.console.level`, `log.syslog`, `log.error.redirect`, `log.async_threshold.size`, `log.async_threshold.window` | none — the surface is now `log.handlers.$id.*`, which is not a per-key rename |
| `leveldb.maximum_memory.percent` | none (predates even RocksDB) |
| `platform_etc_dir` | none — only `platform_{data,lib,log,tmp}_dir` have mappings |
| `admin_api.http.dynamic_buffer.min`, `.max` | none — no schema in the tree maps `dynamic_buffer` at all |
| `bridge.listener.tls.ping.interval`, `.max_retries` | `.ping.idle_timeout`, `.ping.max_attempts` |
| `wamp.websocket.ping.interval` | `wamp.websocket.ping.idle_timeout` |
| `bridge.edge.timeout` | none — there is no `bridge.$name.timeout`; the live neighbours are `connect_timeout`, `idle_timeout` and `network_timeout`, so this one needs a human, not a table |

Two observations fall out of the same run. The seven affected files are
`config/dev/bondy.conf.template`, `config/bridge/bondy.conf.template`, the
`config/test/{node_1,node_2,node_3,edge_1}_bondy.conf.template` release-overlay
inputs for the `node1`/`node2`/`node3`/`edge1` profiles — hand-run clusters, not
CT — so the VM tuning they appear to set has never applied; and
`config/test/bondy.conf`, which has no consumer anywhere in the tree.

Only the last two rows of that table overlap the rc.65 migration guide (they are
the two ping spelling changes §3 already names). Everything above them predates
rc.65, so they belong to check mode's report rather than to the guide's tables —
which is the argument for check mode existing at all: a rename table sized to
one release upgrade would have found none of them.

**The corpus has since been cleaned by hand**, which is what turned it into an
oracle for the tool rather than only a dirty input. All 28 keys are gone: renamed
where a live key exists, dropped where none does. Three of the fixes are cases a
mechanical rename table would have got wrong, and they are the ones worth
carrying into the tool's design:

- `admin_api.http.dynamic_buffer.{min,max}` looked equivalent-less because no
  schema maps `dynamic_buffer` as a *key*; it is the *target*, and the live key
  is `admin_api.http.buffer.{min,max}`. A tool that matches on target paths
  rather than key names finds this; one that greps for the key name does not.
- `bridge.edge.timeout` resolves to `connect_timeout`, not `idle_timeout` or
  `network_timeout`, because `connect_timeout` carries `{commented, "5s"}` and
  the template's value was `5s`. The evidence is the schema's own default, not
  the name.
- `erlang.max_ports = 65536` was renamed and then **dropped** in the five
  templates that declare `max_connections` above 65536. Activating a
  previously-inert key is not automatically the right migration: here it would
  have capped total ports below the connection limits in the same file. The tool
  must report an activation whose value contradicts the rest of the file rather
  than perform it silently.

Verification, in three layers. Zero dead keys remain (same matcher as above).
Every file passes `cuttlefish` against both schema sets, which is what checks
datatypes and validators rather than key existence — proven able to fail by
feeding it `vm.port.limit = 5`, rejected as *"must be 1024 to 134217727"*. And
diffing the generated `vm.generated.args` before against after shows exactly
which erts flags changed: `+A 1→64` in all seven files, plus `+P 2097152→2000000`
and `+zdbbl 32768` (new) in `dev`/`bridge`, `+SDio 128→160` in `dev`, and
`+Q 2097152→500000` in `bridge`. For `dev` and `bridge` that removes a
contradiction rather than creating one — their `vm.args` already set `+A 64`,
`+P 2000000` and `+zdbbl 32768` inline, and the generated file, which loads last
via `-args_file`, had been supplying the schema defaults `+A 1` and `+P 2097152`
against them. The app-config side was checked the same way: the renamed ping keys
produce `{max_attempts,3},{idle_timeout,30000}` where the untouched sibling
listener still shows the defaults `2`/`20000`, `admin_api.http.buffer.*` produces
`{dynamic_buffer,[{max,131072},{min,1024}]}`, `bridge.edge.connect_timeout`
produces `connect_timeout => 5000`, and `dev`'s replacement logger keys produce
`logger_level => debug` with the default handler at `level => debug` on
`standard_io`.

A round-trip property is available too: a migrated file, fed back to check mode,
must report clean.

## 7. Removing the legacy keys

Only after the tool ships, and in this order:

1. **Deprecation.** Legacy keys keep working; each one an operator sets logs a
   warning naming its replacement. The listener half of this is already built —
   `bondy_listener_manager:warn_ignored_legacy/2` reports legacy identity keys
   that the configured path is ignoring, detected by diffing what the legacy
   readers produce against the hardcoded default table.
2. **Removal, in a major version.** Delete `legacy_inventory/0`, the provenance
   gate in `bondy_listener_manager:init/0`, `legacy_ip/2`, `legacy_bind/2`,
   `legacy_enabled/2`, and the 306 legacy listener mappings. §4 records that no
   capability is lost by doing so.
3. **Collapse what the duplication forced.** With one spelling left, a listener's
   option block has one shape, so the `key_value:to_map/1` normalisation in
   `bondy_http_cors` and `bondy_http_security_headers` — added because the two
   spellings disagreed — can go, along with the test asserting the two paths
   resolve identically.

Step 3 is the payoff: it removes the mechanism behind a defect class, not just
some lines.

## 8. Decisions — RESOLVED

Both were resolved 2026-08-18: **legacy listener support is removed, now.**
Removal proceeds in the increments below.

### The constraint that shapes the removal

`prod`, `prod_named` and `docker` overlay **no `bondy.conf` at all** — only
`sys.config` and `vm.args` (`rebar.config:363-378`). So the three listeners a
production node runs today (`admin_api_http` 18081, `api_gateway_http` 18080,
`wamp_tcp` 18082) exist *solely* because the legacy mappings carry
`{default, on}`. Deleting the 311 mappings with nothing in their place leaves
every production node with no API gateway and no WAMP listener — precisely the
failure the old §8 warned about.

Therefore the no-`listeners.*` fallback must come from **code**, not from a
parallel schema surface: `bondy_listener_config:default_inventory/0`. That is not
"keeping legacy" — it removes the 311 mappings and the second resolution path,
leaving one default in one place.

### Increments

1. **Migrate the remaining conf files.** ✅ DONE. Four files still set legacy
   listener keys — `deployment/fly` and the three `harness/*` templates — and
   would have silently lost them. All now declare `listeners.*`; verified by
   rendering and comparing the resulting inventory against the old effective
   app-env block. Fly keeps its `${FLY_PRIVATE_IP}` binding (substituted by
   `bin/replace-env-vars` in the `pre_start` hook before cuttlefish runs, so the
   new-style `ip` sees a literal), and the harness three render exactly
   `[admin, api_gateway_http]`. The tool's corpus was widened from 7 files to 12
   to include `deployment/`, `harness/` and `examples/` — leaving them out is
   what let this go unnoticed.
2. **Switch the fallback and delete the legacy readers.** ✅ DONE.
   `init/0` has one path; `legacy_inventory/0`, `legacy_enabled/2`,
   `legacy_bind/2`, `legacy_ip/2`, `with_ip/2`, `warn_legacy/1`,
   `warn_ignored_legacy/2`, `ignored_legacy/0` and
   `ignored_legacy_description/1` are gone, as is the `legacy` field of a
   resolved listener. `default_inventory/0` is three plaintext entries named
   `admin`, `api_gateway_http`, `wamp_tcp`; both open questions resolved as
   anticipated, and both were forced rather than chosen — see the module doc.
   Net −363 lines across 9 files.
3. **Delete the legacy mappings.** ✅ DONE. **331**, not 311: 281 in
   `schema/bondy.schema` (264 mappings + 17 translations) and 50 in
   `schema/bondy_bridge_relay.schema` (47 + 3). The earlier count missed the
   three multi-line declarations, which a line-anchored grep does not see.
   `schema/bondy.schema` 7398 → 4716 lines, the bridge schema 1176 → 695, and
   `cuttlefish effective` drops from 523 keys to 272.

   Four things came out of the deletion that the plan did not anticipate:

   - **`listeners.$name.hibernate` had to be ADDED.** `bondy_bridge_relay_server`
     reads `hibernate` from its listener's option block, and no
     `listeners.$name.*` key rendered it — deleting `bridge.listener.*.hibernate`
     would have removed the capability outright. `max_frame_size`, by contrast,
     had no reader at all and is a genuine drop.
   - **Nine boot failures in the shipped templates.** Every `transport = tls`
     listener with `enabled = off` relied on the legacy `certfile` schema
     default; `assert_tls_keys/3` had no `enabled` guard, so all nine refused the
     boot once the default was gone. Patched by stating the material, then
     resolved properly in increment 6 below — the material came back out.
   - **Two dead code paths the removal exposed**, both with a scheduled
     retirement their own comments named: `tls_material/3`'s
     `transport_opts.socket_opts` fallback, and
     `bondy_cert_manager:load_user_cacerts/0`'s `api_gateway_https` CA fallback.
   - **`bondy_ct`'s four TLS listeners** declared their material in
     `transport_opts.socket_opts`, the legacy app-env layout. Moved into `tls`
     blocks; `wamp_tls` kept TLS 1.2, which a careless move would have narrowed.
4. **Collapse what the duplication forced.** ✅ DONE, and smaller than expected.
   `key_value:to_map/1` stays in both `bondy_http_cors` and
   `bondy_http_security_headers`: the splat writes nested proplists, so the
   conversion is still needed. What collapses is the *justification* — the two
   consumers no longer handle two shapes — and the tests that asserted the two
   paths resolve identically, which cannot be written with one path.
5. **Tests, tool and docs.** ✅ DONE.
   - Tests: 6 CT cases and 3 unit tests deleted, 2 CT cases renamed, 1 CT case
     (`bridge_listener_ip_renders_symmetrically`) deleted because one Routes
     table makes its asymmetry unrepresentable. The `verify`-only sub-case of a
     deleted test was moved into its surviving sibling rather than lost.
     `all_91_keys_reach_their_documented_paths` → `all_92_...` with `hibernate`.
   - Tool: 181 rules, of which the legacy listener families are derived from an
     8-row table rather than written out, because the destination is computable
     from each block's prefix length. Two new checks, both falsified before being
     trusted: a legacy block in a shipped file, and a declared listener with no
     identity. The listener analysis was rebuilt — the old one asked "which
     listeners did the legacy schema enable?", which post-removal answers
     "none" and passed vacuously; the selftest now has a shape guard so that
     failure mode cannot recur. 194 lines of now-unreachable comparison
     machinery pruned.
   - Docs: `listeners.md` migration section rewritten, `http_security_headers.md`
     moved off the four legacy prefixes entirely, `checking_your_configuration.md`
     rewritten around the two real failures, step 8 added to the rc.65 guide, and
     three CHANGELOG entries (one feature, two breaking).

6. **Skip TLS validation for a disabled listener.** ✅ DONE, on the user's
   instruction after increment 3 raised it. `assert_tls_keys/4`'s first clause
   returns `ok` when `Enabled = false`.

   The argument that settled it is about blast radius, not tidiness: `resolve/2`
   fails the whole inventory on the first bad entry, so one certificate-less
   disabled listener stopped every *other* listener from starting. `enabled = off`
   has to mean the listener does not participate.

   Nothing is lost, only deferred — enabling runs the same check at that boot,
   which is what
   `disabling_a_listener_defers_the_tls_check_it_does_not_lose_it_test` asserts
   (one spec, resolved twice, differing only in `enabled`). Both new tests were
   falsified by mutating the guard clause away before being trusted. The
   symmetric case is deliberate and pinned: a disabled PLAINTEXT listener
   carrying TLS keys resolves, and is rejected when enabled.

   Consequences carried through: the nine template certificate lines added in
   increment 3 are back out (commented, as they were), `default_inventory/0`'s doc
   no longer claims the absence of a guard, and the listeners guide, rc.65 guide
   and CHANGELOG all said "even when disabled" and now do not.

   Still asymmetric, and deliberately left: `assert_listener_ping/3` and the
   identity checks (`transport`, `protocol`, bind, `services`) still run for a
   disabled listener. Ping has the same argument available — a disabled listener
   accepts no connections — but was not in scope. The identity checks should
   stay: `assert_bind_free/3` treats a disabled listener as holding its port, so
   it has to be resolvable enough to know which port that is.

### One general result worth keeping

For any HTTP listener moved off its historical name, **exactly two** settings
change: `idle_timeout` (Bondy's schema said 15s, Cowboy's own default is 60s) and
`active_n` (100 vs **1**) — `cowboy_http.erl:214,336`. Everything else the legacy
mappings defaulted matches its Cowboy or ranch equivalent, verified from source:
`inactivity_timeout` 300000, `request_timeout` 5000, `max_keepalive` 1000,
`linger_timeout` 1000, `initial_stream_flow_size` 65535,
`reset_idle_timeout_on_send` false, `invalid_response_headers` error_terminate,
`sendfile` true, `nodelay` true (`ranch_tcp.erl:107`), and
`max_concurrent_streams` **100** — cowlib applies 100 when the option is absent
even though the protocol default is infinity, with its own comment saying so
(`cow_http2_machine.erl:248-249`, `setting_from_opt/6`).

## 9. What the tool verified, and what it found

The selftest (`just conf-selftest`) is the evidence, and it is built to fail
rather than to pass: every check names an answer established independently of the
script, and a corpus that cannot be read is a failure rather than a skip.

| Check | Answer, and where it came from |
|---|---|
| rule table | 38 rules, every destination matched by a live mapping. Head and tail rewrites are checked by requiring some mapping to start or end with the fragment. |
| clean corpus | the 7 shipped conf files, 0 unknown keys |
| dirty corpus | the same 7 files at `8dd090bf^`, **28 distinct unknown keys across 53 occurrences** — the count from §6, reproduced through a different mechanism (cuttlefish's parsers rather than the Python matcher that produced it) |
| rule coverage | all 53 findings classified, none falling through: 32 rename, 11 by hand, 5 drop, 5 contested |
| migrate no-op | all 7 clean files migrate byte-identically |
| round trip | all 7 migrated dirty files re-check clean |
| listeners | no shipped file drops a listener with nothing on its port; only `admin_api_http` orphans option keys |

Each was falsified as well as run: injecting a dead key into a shipped template
fails the clean corpus; an adversarial fixture confirmed the line rewriter
preserves `=` alignment, tab indentation, trailing comments, escaped dots in
keys, a missing final newline, and both commented-out and live neighbours, while
rewriting only the keys it should; and a hand-written half-migrated file produced
the dropped-listener finding with the block to restore it.

The wider corpus §6 lists as clean — `deployment/fly`, all three
`examples/custom_config` files and the three `harness/*` templates — exits 0,
now including the listener and `advanced.config` dimensions.

### Three findings

**The shipped templates had a real regression, now FIXED.** Six of the seven
declare `listeners.admin` — correctly replacing `admin_api_http` — and still
carried 26 `admin_api.http.*` option keys between them that nothing read.

An earlier version of this section called that "rot" and declined to fix it, on
the grounds that restoring the keys would activate settings that had been inert,
as with `erlang.max_ports`. **That reasoning was wrong, and the analogy does not
hold.** `erlang.max_ports` was never mapped by any schema, so it had never taken
effect in any release. These keys were mapped and *were* in force: at
`b6e04aad`, immediately before the listeners work, every one of these templates
contained no `listeners.*` key at all, so the node took the legacy path,
`admin_api_http` was a real listener, and `admin_api.http.backlog = 65535` and
its siblings applied. Renaming the listener to the reserved `admin` silently
switched them off, because a listener's options are read under its *current*
name. Restoring them is not an activation; it is repairing a regression the
migration introduced.

Two further settings were lost the same way without ever appearing in a template:
`admin_api.http.*`'s own schema mappings supplied `idle_timeout = 15s` and
`active_n = 100`, and a declared listener with no `protocol_opts` block gets
Cowboy's defaults instead — 60s and **1** respectively
(`bondy_config:listener_protocol_opts/1`, `cowboy_http.erl:214,336`, read from
source). `active_n` dropping from 100 to 1 is a throughput change and was not
noted anywhere. Both are now set explicitly.

What is NOT affected, established rather than assumed:

- **Every other listener.** They kept their historical names, so their legacy
  option blocks still populate `bondy_router.<name>.*` and their TLS material,
  backlog and connection limits still reach them. A first pass at this diff
  reported lost certificates for four TLS listeners; that was a false positive
  from reading the inventory entry while ignoring the still-present app-env
  block.
- **CORS and security headers on `admin`.** `bondy_http_cors:default_config/0`
  and `bondy_http_security_headers:default_config/0` are merged *under* the
  listener's own settings and are byte-identical to the schema defaults the
  legacy mappings supplied (`enabled => true`, `'*'`, the same method and header
  lists, `86400`; `SAMEORIGIN`, `nosniff`). So the admin listener's CORS and
  security-header behaviour is unchanged.
- **`nodelay`, `ip`, `ip_version`, `handshake_timeout`, `inactivity_timeout`,
  `request_timeout`, `linger_timeout`, `max_keepalive`,
  `initial_stream_flow_size`, `reset_idle_timeout_on_send`.** Each new default
  equals the old effective value — `ranch_tcp.erl:107` defaults `nodelay` to
  true, `resolve_ip/3` defaults an `admin`-carrying listener to loopback, and the
  rest match Cowboy's own defaults.
- `max_concurrent_streams` (schema 100) was not established against Cowboy's
  default and is HTTP/2 only, which the plain-TCP admin listener does not
  negotiate. Left alone rather than guessed at.

The selftest's listener invariant was correspondingly tightened from "only
`admin_api_http` may orphan option keys" to **no shipped file may orphan any**.
The weaker form accommodated this regression instead of catching it.

**Three defects in the tool, every one found by running it rather than reading
it.** The worst was in the generated listener block: it carried
`default_inventory/0`'s port rather than the operator's own, so a deployment that
had moved `wamp.tcp.port` to 9999 was told to write
`listeners.wamp_tcp.port = 18082` — pasting the suggestion would have moved the
listener. Fixed by reading the bind port and address from the file through the
same target paths `bondy_listener_manager:legacy_bind/2` and `legacy_ip/2` use,
which also handles `bridge_relay_tcp`'s irregular `<name>.port` target. Then:
Erlang's `~-14s` truncates rather than merely padding, so an early report showed
`multi_time_warp` back to the operator as `multi_time_war`, altering the value it
was quoting. And the "same port" test for a replaced listener called the
multi-node test templates silent drops, because they deliberately move `admin` to
18181/18281/19081 — `admin_api_http` -> `admin` is structural via
`with_reserved/1` and must not be inferred from a port at all.

The first of those is the argument for §5's decision that migrate does not
synthesise listener blocks. A tool that had written the block instead of printing
it would have moved a production listener silently.

**The rc.65 release's own `etc/bondy.conf` has 41 of 511 keys that this release
would not read** — the whole `oplog.*` and `rpc_gateway.*` surfaces, with the
`$service` and `$proc` wildcard tails preserved by the prefix rules, plus the two
`oplog` removals. That is the tool's reason for existing, measured on a real file.

## 10. Not verified

- Whether `advanced.config` needs anything beyond the two stanza edits in §3.
- The behaviour of the check recipe against a *current* release; §2 records the
  caveat.
Resolved since this section was written: `erlang.kernel_polling` has no live
equivalent because `+K` is inert in erts 16.4 — it is absent from the emulator's
usage output, and both `+K true` and `+K false` leave
`erlang:system_info(kernel_poll)` at `true`. The key was dropped from the
templates and the flag removed from every `vm.args`. See
`2026-08-18-vm-args-flag-audit.md`.
