# Dynamic Listeners Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Bondy's nine hardcoded listeners with listeners an operator
defines by name in `bondy.conf` via `listeners.$name.*`, each carrying its own
transport, protocol and service set.

**Architecture:** A pure resolver (`bondy_listener_config`) turns an app-env
inventory plus per-listener option blocks into validated listener maps, failing
boot on any static config error. A driver behaviour (`bondy_listener`) hides
whether a listener is a ranch listener or (later) a QUIC one. A plain-module
manager (`bondy_listener_manager`) iterates the inventory to start, stop,
suspend and resume. HTTP listeners assemble their dispatch table by grouping
their declared services by carrier and asking each carrier once for routes.

**Tech Stack:** Erlang/OTP 28+, rebar3, cuttlefish (standalone escript,
pre-boot), Cowboy 2.17.0, ranch 2.2.0, eunit, Common Test, erlfmt 1.8.0.

**Design doc:** `_plans/2026-08-14-dynamic-listeners-design.md`. Read §2
("Verified constraints") before starting — every rule below traces to it.

## Global Constraints

- **OTP 28+.** After any OTP switch, `rm -rf _build`.
- **Do not run `git commit` or `git push`.** Each task ends by leaving the tree
  dirty and reporting what changed; the human commits. Where this plan says
  "Checkpoint", that means stop and report — it is not a commit step.
- **Do not reference this plan or the design doc from source code or comments.**
  Comments state what the code does and cite evidence, never plan documents.
- **erlfmt owns layout.** `print_width` 80, `{files, "apps/*/{src,include,test,examples}/*.{hrl,erl}"}`.
  Never hand-align record fields. Run `rebar3 fmt` on touched files before
  reporting.
- **Every new file starts with the SPDX header** used throughout the tree:
  ```erlang
  %% =============================================================================
  %% SPDX-FileCopyrightText: 2026 Leapsight
  %% SPDX-License-Identifier: Apache-2.0
  %% =============================================================================
  ```
- **Test commands.** eunit: `rebar3 as test eunit --module=<module>`.
  Common Test: `CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=<path>`.
  Never run eunit, ct and proper concurrently. Never run the full CT suite
  unattended — always scope to one suite.
- **No `listeners.$name.*` cuttlefish mapping may carry `{default, ...}`.**
  `cuttlefish_generator:add_fuzzy_default/4` materialises a `$name` default for
  every name mentioned under the prefix, which would make the global carrier
  fallback dead and make the QUIC key-rejection check fire on values nobody
  wrote. Defaults live in `bondy_listener_config`, per driver.
- **App env shape does not change.** Everything stays at
  `bondy_router.<Name>.{enabled, transport_opts, protocol_opts, cors, security_headers, proxy_protocol}`.
  The only new keys are `bondy_router.listeners` and
  `bondy_router.http_services`.
- **Config errors abort boot.** Never skip a misconfigured listener — a node
  that boots serving nothing is worse than one that refuses to boot.
- **Docs:** use `-moduledoc """..."""` and `-doc """..."""` attributes, matching
  the surrounding modules. Do not put benchmark numbers or test results in
  module docs.

## Deviations from the design doc

Both are already patched into the design doc; noted here so a reviewer sees
them.

1. **`listeners.$name.start_phase`** was added. The design doc omitted that
   `bondy_app` starts admin listeners at `:111` before public ones at `:113`, so
   health probes answer while status is `initialising`. Made explicit rather
   than inferred from `services`.
2. **`bondy_listener_manager` is a plain module, not a gen_server.** It holds no
   mutable state; the spec-change rebuild stays with the existing
   `bondy_http_gateway` gen_server.

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `apps/bondy_router/src/bondy_listener_config.erl` | Pure. Inventory + app env → validated listener maps or error. Owns required keys, driver applicability, per-driver defaults, service data, carrier grouping, collision detection. |
| `apps/bondy_router/src/bondy_listener.erl` | Driver behaviour + dispatch to the driver named by a listener's transport. |
| `apps/bondy_router/src/bondy_listener_ranch.erl` | Ranch/Cowboy driver: `tcp`, `tls`, `uds`. |
| `apps/bondy_router/src/bondy_listener_manager.erl` | Plain module. Resolve once, then start by phase / stop / suspend / resume over the inventory. |
| `apps/bondy_router/src/bondy_http_service.erl` | `routes/3` behaviour for carrier route contribution. |
| `apps/bondy_router/src/bondy_http_services.erl` | All in-tree carriers: rest, websocket, sse, longpoll, admin, metrics. |
| `apps/bondy_router/test/bondy_listener_config_test.erl` | eunit for the resolver. |
| `apps/bondy_router/test/bondy_http_services_test.erl` | eunit proving extracted routes compile identically to today's. |
| `apps/bondy_router/test/bondy_listener_SUITE.erl` | CT for lifecycle and per-listener carrier config. |
| `apps/bondy_router/test/bondy_listener_schema_SUITE.erl` | CT rendering `bondy.conf` through cuttlefish; legacy/new equivalence. |

**Modified:**

| File | Change |
|---|---|
| `apps/bondy_router/src/bondy_http_gateway.erl` | Delete `?HTTP`/`?HTTPS`/`?ADMIN_HTTP`/`?ADMIN_HTTPS` (`:102-105`), the ten `*_listeners/0` functions (`:169-232`, `:532-617`), `base_routes/0` (`:995`), `admin_base_routes/0` (`:1023`), `start_listener/1`, `start_admin_listener/1`, `maybe_start_http/2`, `start_http/2`, `maybe_start_https/2`, `start_https/2`, `listener_transport_opts/1` (`:1106`), `rebuild_dispatch_table/2` (`:959`). Keep specs, storage, replication; expose `routes/1` for the api_gateway service and `listeners_with_api_gateway/0`. |
| `apps/bondy_router/src/bondy_wamp_tcp.erl` | Delete entirely; `connections/0`, `tcp_connections/0`, `tls_connections/0` move to `bondy_listener_manager`. |
| `apps/bondy_router/src/bondy_wamp_uds.erl` | Delete entirely; UDS becomes `transport = uds` in `bondy_listener_ranch`. |
| `apps/bondy_router/src/bondy_ranch_listener.erl` | Delete `ref_to_transport/1` (`:113-116`); the module becomes internal to `bondy_listener_ranch` or is absorbed into it. |
| `apps/bondy_router/src/bondy_app.erl` | `:111`, `:113`, `:333-367`, `:459-505` call the manager. |
| `apps/bondy_router/src/bondy_cert_manager.erl` | `?TLS_LISTENERS` (`:47-51`) and `listener_ref/0` (`:76-81`) become inventory-derived. |
| `apps/bondy_router/src/bondy_config.erl` | `setup_wamp/0`'s four literal `dynamic_buffer` paths (`:451-456`) become inventory-derived. |
| `apps/bondy_router/src/bondy_wamp_ws_connection_handler.erl` | `init/2` reads the route's initial state; `select_subprotocol/1` intersects with the listener's protocol set; `:344` and `:463` read resolved carrier config. |
| `schema/bondy.schema` | Add the `listeners.$name.*` block and its translation. The legacy compatibility path is Erlang, not schema — see Task 8 for why a second translation cannot work. |
| `schema/bondy_bridge_relay.schema` | Add the shim translation for `bridge.listener.{tcp,tls}.*`. |
| `apps/bondy_router/test/bondy_ct.erl` | Add `listeners` inventory alongside the existing per-name env (`:284-528`). |
| `config/bondy.conf.defaults` + 6 templates | Regenerate. |

---

### Task 1: Resolver — required keys

**Files:**
- Create: `apps/bondy_router/src/bondy_listener_config.erl`
- Test: `apps/bondy_router/test/bondy_listener_config_test.erl`

**Interfaces:**
- Consumes: nothing.
- Produces: `bondy_listener_config:resolve(Inventory, GetFun) -> {ok, [t()]} | {error, Reason}`
  where `Inventory :: [{atom(), map()}]` and
  `GetFun :: fun((Key :: [atom()], Default :: term()) -> term())` — injected so
  the resolver is pure and testable without app env. In production the caller
  passes `fun bondy_config:get/2`.
  `t() :: #{name := atom(), transport := tcp | tls | uds | quic, protocol := http | wamp_rawsocket | bamp_rawsocket | bridge_relay, services := [atom()], enabled := boolean(), start_phase := early | normal, bind := {port, inet:port_number()} | {path, file:filename()}, carriers := #{atom() => #{protocols := [atom()], config := map()}}}`.
  `Reason :: {invalid_listener, Name :: atom(), Detail :: term()}`.

- [ ] **Step 1: Write the failing test**

Create `apps/bondy_router/test/bondy_listener_config_test.erl`:

```erlang
%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Tests `bondy_listener_config:resolve/2`, the pure boot-time validation of
%% the `bondy_router.listeners` inventory. Most cases here are written to
%% BREAK an invariant rather than confirm it: each asserts that a specific
%% malformed listener is REJECTED, because the resolver exists so that a static
%% config error is reported rather than papered over with a default. Three
%% cases are deliberately confirmatory — the minimal-listener defaults, the
%% accepted half of the uds bind rule, and the port-0 exemption — because each
%% pins behaviour a rejection test cannot express.
%% =============================================================================
-module(bondy_listener_config_test).

-include_lib("eunit/include/eunit.hrl").

%% A GetFun that knows nothing: every option block is empty. Used by the
%% required-key cases, where the inventory entry alone decides the outcome.
empty_get() ->
    fun(_Key, Default) -> Default end.

minimal_http_listener_resolves_test() ->
    Inventory = [
        {pub, #{
            transport => tcp,
            protocol => http,
            port => 18080,
            services => [wamp_ws]
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    ?assertEqual(pub, maps:get(name, L)),
    ?assertEqual(tcp, maps:get(transport, L)),
    ?assertEqual(http, maps:get(protocol, L)),
    ?assertEqual({port, 18080}, maps:get(bind, L)),
    %% Absent `enabled` means enabled: five call sites read
    %% `bondy_config:get([Ref, enabled], true)` today.
    ?assertEqual(true, maps:get(enabled, L)),
    ?assertEqual(normal, maps:get(start_phase, L)).

missing_transport_is_rejected_test() ->
    Inventory = [{pub, #{protocol => http, port => 18080, services => []}}],
    ?assertMatch(
        {error, {invalid_listener, pub, {missing, transport}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

missing_protocol_is_rejected_test() ->
    Inventory = [{pub, #{transport => tcp, port => 18080}}],
    ?assertMatch(
        {error, {invalid_listener, pub, {missing, protocol}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

missing_port_is_rejected_test() ->
    %% A mistyped listener NAME shows up here: the intended block loses its
    %% port, so boot fails naming the listener rather than silently binding a
    %% phantom one.
    Inventory = [
        {pub, #{transport => tcp, protocol => http, services => [wamp_ws]}}
    ],
    ?assertMatch(
        {error, {invalid_listener, pub, {missing, port}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

uds_requires_path_not_port_test() ->
    Ok = [
        {local, #{
            transport => uds,
            protocol => wamp_rawsocket,
            path => "/tmp/bondy_wamp.sock"
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Ok, empty_get()),
    ?assertEqual({path, "/tmp/bondy_wamp.sock"}, maps:get(bind, L)),

    Bad = [{local, #{transport => uds, protocol => wamp_rawsocket}}],
    ?assertMatch(
        {error, {invalid_listener, local, {missing, path}}},
        bondy_listener_config:resolve(Bad, empty_get())
    ).

http_requires_services_test() ->
    Inventory = [{pub, #{transport => tcp, protocol => http, port => 18080}}],
    ?assertMatch(
        {error, {invalid_listener, pub, {missing, services}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

services_on_non_http_is_rejected_test() ->
    %% RawSocket's whole demux surface is a fixed 4-octet header, so a service
    %% LIST is meaningless there. Accepting it silently would mislead.
    Inventory = [
        {raw, #{
            transport => tcp,
            protocol => wamp_rawsocket,
            port => 18082,
            services => [wamp_ws]
        }}
    ],
    ?assertMatch(
        {error, {invalid_listener, raw, {services_not_supported, wamp_rawsocket}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

unknown_transport_is_rejected_test() ->
    Inventory = [{pub, #{transport => sctp, protocol => http, port => 1}}],
    ?assertMatch(
        {error, {invalid_listener, pub, {unknown_transport, sctp}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

unknown_protocol_is_rejected_test() ->
    Inventory = [{pub, #{transport => tcp, protocol => gopher, port => 1}}],
    ?assertMatch(
        {error, {invalid_listener, pub, {unknown_protocol, gopher}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

duplicate_name_is_rejected_test() ->
    Inventory = [
        {pub, #{transport => tcp, protocol => http, port => 1, services => []}},
        {pub, #{transport => tcp, protocol => http, port => 2, services => []}}
    ],
    ?assertMatch(
        {error, {invalid_listener, pub, duplicate_name}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

duplicate_port_is_rejected_test() ->
    Inventory = [
        {a, #{transport => tcp, protocol => http, port => 18080, services => []}},
        {b, #{transport => tcp, protocol => http, port => 18080, services => []}}
    ],
    ?assertMatch(
        {error, {invalid_listener, b, {port_in_use_by, a}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

port_zero_never_clashes_test() ->
    %% Port 0 means "let the OS choose", so two such listeners cannot collide.
    %% Rejecting them would make it impossible to define more than one
    %% ephemeral-port listener, which every CT suite needs.
    Inventory = [
        {a, #{transport => tcp, protocol => http, port => 0, services => []}},
        {b, #{transport => tcp, protocol => http, port => 0, services => []}}
    ],
    ?assertMatch({ok, [_, _]}, bondy_listener_config:resolve(Inventory, empty_get())).
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `rebar3 as test eunit --module=bondy_listener_config_test`
Expected: FAIL — `undef` / `bondy_listener_config` does not exist.

- [ ] **Step 3: Write the minimal implementation**

Create `apps/bondy_router/src/bondy_listener_config.erl`:

```erlang
%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_listener_config).

-moduledoc """
Resolves and validates the listener inventory at boot.

This module is **pure**: it takes the `bondy_router.listeners` inventory and a
function for reading a listener's option block, and returns either a list of
fully resolved listener maps or the first error. It performs no I/O and starts
nothing, so it is exercised directly by `bondy_listener_config_test`.

A static configuration error is *intended* to abort boot: skipping a
misconfigured listener would produce a node that comes up serving nothing an
operator asked for, which is harder to diagnose than a refusal to start. This
module only reports the error — the caller decides what to do with it.

Validation is deliberately strict about required keys. The release renders
`bondy.conf` with `cuttlefish --allow_extra --silent`, so an unrecognised key is
dropped without a warning; requiring `transport`, `protocol`, a bind target and
(for HTTP) `services` turns a mistyped listener name into two named boot errors
rather than a silently bound phantom listener.
""".

-type transport() :: tcp | tls | uds | quic.
-type protocol() :: http | wamp_rawsocket | bamp_rawsocket | bridge_relay.
-type bind() :: {port, inet:port_number()} | {path, file:filename()}.

-type t() :: #{
    name := atom(),
    transport := transport(),
    protocol := protocol(),
    services := [atom()],
    enabled := boolean(),
    start_phase := early | normal,
    bind := bind(),
    carriers := #{atom() => #{protocols := [atom()], config := map()}}
}.

-type get_fun() :: fun((Key :: [atom()], Default :: term()) -> term()).

-type error_reason() :: {invalid_listener, Name :: atom(), Detail :: term()}.

-export_type([t/0, transport/0, protocol/0, get_fun/0, error_reason/0]).

-export([resolve/2]).

-define(TRANSPORTS, [tcp, tls, uds, quic]).
-define(PROTOCOLS, [http, wamp_rawsocket, bamp_rawsocket, bridge_relay]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Resolves `Inventory` into validated listener maps.

`GetFun` reads a per-listener option path, e.g.
`GetFun([pub, transport_opts, socket_opts, backlog], undefined)`. Production
callers pass `fun bondy_config:get/2`.

Returns the FIRST error encountered, so boot failure names one listener and one
problem rather than a list the operator has to unpick.
""".
-spec resolve(Inventory :: [{atom(), map()}], GetFun :: get_fun()) ->
    {ok, [t()]} | {error, error_reason()}.

resolve(Inventory, GetFun) ->
    try
        {Resolved, _} = lists:foldl(
            fun({Name, Spec}, {Acc, Seen}) ->
                ok = assert_unique(Name, Spec, Seen),
                Listener = resolve_one(Name, Spec, GetFun),
                {[Listener | Acc], [{Name, Listener} | Seen]}
            end,
            {[], []},
            Inventory
        ),
        {ok, lists:reverse(Resolved)}
    catch
        throw:{invalid_listener, _, _} = Reason ->
            {error, Reason}
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
resolve_one(Name, Spec, _GetFun) ->
    Transport = required(Name, transport, Spec),
    lists:member(Transport, ?TRANSPORTS) orelse
        invalid(Name, {unknown_transport, Transport}),

    Protocol = required(Name, protocol, Spec),
    lists:member(Protocol, ?PROTOCOLS) orelse
        invalid(Name, {unknown_protocol, Protocol}),

    Services = resolve_services(Name, Protocol, Spec),

    #{
        name => Name,
        transport => Transport,
        protocol => Protocol,
        services => Services,
        enabled => maps:get(enabled, Spec, true),
        start_phase => maps:get(start_phase, Spec, normal),
        bind => resolve_bind(Name, Transport, Spec),
        carriers => #{}
    }.

%% @private
%% `services` is meaningful only for HTTP: it is HTTP's path multiplexing that
%% makes a LIST of reachable things possible. A raw socket carries exactly one
%% protocol, named by the `protocol` key, so a service list there is an error
%% rather than a silently ignored value.
resolve_services(Name, http, Spec) ->
    case maps:find(services, Spec) of
        {ok, Services} when is_list(Services) -> Services;
        _ -> invalid(Name, {missing, services})
    end;
resolve_services(Name, Protocol, Spec) ->
    case maps:is_key(services, Spec) of
        true -> invalid(Name, {services_not_supported, Protocol});
        false -> []
    end.

%% @private
resolve_bind(Name, uds, Spec) ->
    case maps:find(path, Spec) of
        {ok, Path} -> {path, Path};
        error -> invalid(Name, {missing, path})
    end;
resolve_bind(Name, _Transport, Spec) ->
    case maps:find(port, Spec) of
        {ok, Port} -> {port, Port};
        error -> invalid(Name, {missing, port})
    end.

%% @private
assert_unique(Name, Spec, Seen) ->
    lists:keymember(Name, 1, Seen) andalso invalid(Name, duplicate_name),
    case maps:find(port, Spec) of
        %% Port 0 delegates the choice to the OS, so any number of listeners may
        %% ask for it without colliding.
        {ok, 0} -> ok;
        {ok, Port} -> assert_port_free(Name, Port, Seen);
        error -> ok
    end.

%% @private
%% Two listeners on one port would race at bind time and the loser's error is
%% reported by ranch, out of context. Catching it here names both listeners.
assert_port_free(Name, Port, Seen) ->
    Clash = [
        Other
     || {Other, #{bind := {port, P}}} <- Seen, P =:= Port
    ],
    case Clash of
        [] -> ok;
        [Other | _] -> invalid(Name, {port_in_use_by, Other})
    end.

%% @private
required(Name, Key, Spec) ->
    case maps:find(Key, Spec) of
        {ok, Value} -> Value;
        error -> invalid(Name, {missing, Key})
    end.

%% @private
-spec invalid(atom(), term()) -> no_return().

invalid(Name, Detail) ->
    throw({invalid_listener, Name, Detail}).
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `rebar3 as test eunit --module=bondy_listener_config_test`
Expected: PASS. Count the `_test() ->` functions in the test file and
report that number — do not trust a count written in this plan, and never
delete a test to make a stated count match.

- [ ] **Step 5: Format and checkpoint**

Run: `rebar3 fmt apps/bondy_router/src/bondy_listener_config.erl apps/bondy_router/test/bondy_listener_config_test.erl`
Then stop and report: new module + test, 11 tests passing. Do not commit.

---

### Task 2: Resolver — driver applicability and TLS rules

**Files:**
- Modify: `apps/bondy_router/src/bondy_listener_config.erl`
- Test: `apps/bondy_router/test/bondy_listener_config_test.erl` (append)

**Interfaces:**
- Consumes: `resolve/2` and `t()` from Task 1.
- Produces: no signature change. Adds rejection of driver-inapplicable keys and
  TLS-key misuse, and a `driver` field on `t()`:
  `driver := bondy_listener_ranch | bondy_listener_quic`.

- [ ] **Step 1: Write the failing test**

Append to `apps/bondy_router/test/bondy_listener_config_test.erl`:

```erlang
%% A GetFun that answers a fixed set of option paths and defaults the rest.
%% Mirrors `bondy_config:get/2`'s contract: the path is a list of atoms.
get_with(Paths) ->
    fun(Key, Default) ->
        case lists:keyfind(Key, 1, Paths) of
            {Key, Value} -> Value;
            false -> Default
        end
    end.

tcp_listener_gets_ranch_driver_test() ->
    Inventory = [
        {pub, #{
            transport => tcp, protocol => http, port => 1, services => []
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    ?assertEqual(bondy_listener_ranch, maps:get(driver, L)).

quic_listener_gets_quic_driver_test() ->
    Inventory = [
        {h3, #{
            transport => quic, protocol => http, port => 1, services => []
        }}
    ],
    Get = get_with([
        {[h3, tls, certfile], "/tmp/cert.pem"},
        {[h3, tls, keyfile], "/tmp/key.pem"}
    ]),
    {ok, [L]} = bondy_listener_config:resolve(Inventory, Get),
    ?assertEqual(bondy_listener_quic, maps:get(driver, L)).

stream_socket_key_on_quic_is_rejected_test() ->
    %% `cowboy:start_quic/3` does not use ranch: it spawns its own listener with
    %% 20 hardcoded acceptors and accepts only `#{socket_opts => ...}`. So
    %% `backlog` cannot take effect, and silently ignoring it would leave an
    %% operator believing they had tuned something.
    Inventory = [
        {h3, #{
            transport => quic, protocol => http, port => 1, services => []
        }}
    ],
    Get = get_with([
        {[h3, tls, certfile], "/tmp/cert.pem"},
        {[h3, tls, keyfile], "/tmp/key.pem"},
        {[h3, transport_opts, socket_opts, backlog], 4096}
    ]),
    ?assertMatch(
        {error, {invalid_listener, h3, {key_not_supported, backlog, quic}}},
        bondy_listener_config:resolve(Inventory, Get)
    ).

max_connections_on_quic_is_rejected_test() ->
    Inventory = [
        {h3, #{
            transport => quic, protocol => http, port => 1, services => []
        }}
    ],
    Get = get_with([
        {[h3, tls, certfile], "/tmp/cert.pem"},
        {[h3, tls, keyfile], "/tmp/key.pem"},
        {[h3, transport_opts, max_connections], 1000}
    ]),
    ?assertMatch(
        {error,
            {invalid_listener, h3, {key_not_supported, max_connections, quic}}},
        bondy_listener_config:resolve(Inventory, Get)
    ).

tls_keys_on_plain_tcp_are_rejected_test() ->
    Inventory = [
        {pub, #{
            transport => tcp, protocol => http, port => 1, services => []
        }}
    ],
    Get = get_with([{[pub, tls, certfile], "/tmp/cert.pem"}]),
    ?assertMatch(
        {error, {invalid_listener, pub, {tls_not_supported, tcp}}},
        bondy_listener_config:resolve(Inventory, Get)
    ).

tls_transport_requires_cert_and_key_test() ->
    Inventory = [
        {sec, #{
            transport => tls, protocol => http, port => 1, services => []
        }}
    ],
    ?assertMatch(
        {error, {invalid_listener, sec, {missing, [tls, certfile]}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ),
    OnlyCert = get_with([{[sec, tls, certfile], "/tmp/cert.pem"}]),
    ?assertMatch(
        {error, {invalid_listener, sec, {missing, [tls, keyfile]}}},
        bondy_listener_config:resolve(Inventory, OnlyCert)
    ),
    Both = get_with([
        {[sec, tls, certfile], "/tmp/cert.pem"},
        {[sec, tls, keyfile], "/tmp/key.pem"}
    ]),
    ?assertMatch({ok, [_]}, bondy_listener_config:resolve(Inventory, Both)).

uds_rejects_tls_test() ->
    Inventory = [
        {local, #{
            transport => uds, protocol => wamp_rawsocket, path => "/tmp/s.sock"
        }}
    ],
    Get = get_with([{[local, tls, certfile], "/tmp/cert.pem"}]),
    ?assertMatch(
        {error, {invalid_listener, local, {tls_not_supported, uds}}},
        bondy_listener_config:resolve(Inventory, Get)
    ).
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `rebar3 as test eunit --module=bondy_listener_config_test`
Expected: FAIL — `driver` key missing from the resolved map; the rejection tests
return `{ok, _}`.

- [ ] **Step 3: Write the minimal implementation**

In `bondy_listener_config.erl`, add the driver table, the stream-socket key
list, and two validation passes. Add to the exports of private helpers as
needed and extend `resolve_one/3`:

```erlang
%% Keys that only a ranch stream listener can honour. Verified against
%% `cowboy:start_quic/3`, which spawns its own quicer listener with 20 hardcoded
%% acceptors and accepts only `#{socket_opts => [...]}`. None of these reach
%% it, and `ranch:suspend_listener/1`, `resume_listener/1`, `procs/2` and
%% `set_max_connections/2` do not apply to it either.
-define(STREAM_ONLY_KEYS, [
    {[transport_opts, socket_opts, backlog], backlog},
    {[transport_opts, socket_opts, keepalive], keepalive},
    {[transport_opts, socket_opts, nodelay], nodelay},
    {[transport_opts, socket_opts, sndbuf], sndbuf},
    {[transport_opts, socket_opts, recbuf], recbuf},
    {[transport_opts, socket_opts, buffer], buffer},
    {[transport_opts, socket_opts, reuseport], reuseport},
    {[transport_opts, max_connections], max_connections},
    {[transport_opts, num_acceptors], acceptors_pool_size},
    {[protocol_opts, linger_timeout], linger_timeout},
    {[proxy_protocol, enabled], proxy_protocol}
]).

-define(TLS_REQUIRED_KEYS, [certfile, keyfile]).
-define(TLS_KEYS, [certfile, keyfile, cacertfile, versions, verify]).
```

Then in `resolve_one/3`, after `Protocol` is validated:

```erlang
    Driver = driver(Transport),
    ok = assert_driver_keys(Name, Transport, Driver, GetFun),
    ok = assert_tls_keys(Name, Transport, GetFun),
```

and add `driver => Driver` to the returned map. Note `resolve_one/3` now uses
`GetFun`, so rename the parameter from `_GetFun`.

```erlang
%% @private
%% `transport` selects a listener DRIVER, not merely a ranch transport module:
%% QUIC is served by `cowboy:start_quic/3`, which creates no ranch listener at
%% all, so its option set and lifecycle operations are disjoint from the stream
%% transports'.
driver(quic) -> bondy_listener_quic;
driver(_) -> bondy_listener_ranch.

%% @private
assert_driver_keys(_Name, Transport, bondy_listener_ranch, _GetFun) when
    Transport =/= quic
->
    ok;
assert_driver_keys(Name, quic, bondy_listener_quic, GetFun) ->
    Offenders = [
        Label
     || {Path, Label} <- ?STREAM_ONLY_KEYS,
        GetFun([Name | Path], undefined) =/= undefined
    ],
    case Offenders of
        [] -> ok;
        [Label | _] -> invalid(Name, {key_not_supported, Label, quic})
    end.

%% @private
%% TLS material is only meaningful where the driver terminates TLS. Setting it
%% elsewhere is an error, not a no-op: an operator who wrote a certfile on a
%% plaintext listener believes that port is encrypted.
assert_tls_keys(Name, Transport, GetFun) when
    Transport =:= tls; Transport =:= quic
->
    Missing = [
        K
     || K <- ?TLS_REQUIRED_KEYS, GetFun([Name, tls, K], undefined) =:= undefined
    ],
    case Missing of
        [] -> ok;
        [K | _] -> invalid(Name, {missing, [tls, K]})
    end;
assert_tls_keys(Name, Transport, GetFun) ->
    Set = [K || K <- ?TLS_KEYS, GetFun([Name, tls, K], undefined) =/= undefined],
    case Set of
        [] -> ok;
        _ -> invalid(Name, {tls_not_supported, Transport})
    end.
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `rebar3 as test eunit --module=bondy_listener_config_test`
Expected: PASS. Count the `_test() ->` functions in the test file and
report that number — do not trust a count written in this plan, and never
delete a test to make a stated count match.

- [ ] **Step 5: Format and checkpoint**

Run `rebar3 fmt` on both files. Report: driver selection plus applicability
rejection, 18 tests passing.

---

### Task 3: Resolver — per-driver defaults and carrier config

**Files:**
- Modify: `apps/bondy_router/src/bondy_listener_config.erl`
- Test: `apps/bondy_router/test/bondy_listener_config_test.erl` (append)

**Interfaces:**
- Consumes: `resolve/2`, `t()` from Tasks 1–2.
- Produces: the `carriers` field is populated:
  `#{websocket => #{protocols => [wamp], config => #{idle_timeout => 60000, ...}}}`.
  Carrier config resolution is per-listener value first, global
  `wamp.<carrier>.*` second, and the resolver's own default last.
  New export: `bondy_listener_config:service_spec(atom()) -> #{carrier := atom(), protocol := atom() | undefined, module := module()} | error`.

- [ ] **Step 1: Write the failing test**

Append:

```erlang
websocket_carrier_is_grouped_from_services_test() ->
    %% Two services on one carrier must UNION their protocols into a single
    %% carrier entry: both mount `/ws`, and two routes on one path would make
    %% the second unreachable.
    Inventory = [
        {mix, #{
            transport => tcp,
            protocol => http,
            port => 1,
            services => [wamp_ws, bamp_ws]
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    #{websocket := #{protocols := Protos}} = maps:get(carriers, L),
    ?assertEqual([bamp, wamp], lists:sort(Protos)).

restricting_a_carrier_to_one_protocol_test() ->
    %% The operator requirement: offer BAMP over WebSocket WITHOUT offering
    %% WAMP on the same port.
    Inventory = [
        {bamp, #{
            transport => tcp, protocol => http, port => 1, services => [bamp_ws]
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    #{websocket := #{protocols := Protos}} = maps:get(carriers, L),
    ?assertEqual([bamp], Protos).

unknown_service_is_rejected_test() ->
    Inventory = [
        {pub, #{
            transport => tcp, protocol => http, port => 1,
            services => [wamp_ws, smtp]
        }}
    ],
    ?assertMatch(
        {error, {invalid_listener, pub, {unknown_service, smtp}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).

carrier_config_falls_back_to_global_test() ->
    %% A listener that sets NOTHING must receive the global value. This is the
    %% regression guard for the default-free rule: if anyone gives
    %% `listeners.$name.websocket.idle_timeout` a cuttlefish default, the key
    %% becomes always-present for every listener and this fallback dies
    %% silently.
    Inventory = [
        {pub, #{
            transport => tcp, protocol => http, port => 1, services => [wamp_ws]
        }}
    ],
    Get = get_with([{[wamp_websocket, idle_timeout], 90000}]),
    {ok, [L]} = bondy_listener_config:resolve(Inventory, Get),
    #{websocket := #{config := Cfg}} = maps:get(carriers, L),
    ?assertEqual(90000, maps:get(idle_timeout, Cfg)).

per_listener_carrier_value_beats_global_test() ->
    Inventory = [
        {iot, #{
            transport => tcp, protocol => http, port => 1, services => [wamp_ws]
        }}
    ],
    Get = get_with([
        {[wamp_websocket, idle_timeout], 90000},
        {[iot, websocket, idle_timeout], 600000}
    ]),
    {ok, [L]} = bondy_listener_config:resolve(Inventory, Get),
    #{websocket := #{config := Cfg}} = maps:get(carriers, L),
    ?assertEqual(600000, maps:get(idle_timeout, Cfg)).

nested_carrier_key_resolves_test() ->
    %% Carrier settings are not flat: `ping.enabled' and `deflate_opts.level'
    %% are nested under the carrier block, and the resolved config must mirror
    %% that shape. A flat implementation would silently drop every nested key —
    %% 11 of WebSocket's 15 overridable settings.
    Inventory = [
        {pub, #{
            transport => tcp, protocol => http, port => 1, services => [wamp_ws]
        }}
    ],
    Get = get_with([
        {[wamp_websocket, ping, enabled], true},
        {[pub, websocket, deflate_opts, level], 9}
    ]),
    {ok, [L]} = bondy_listener_config:resolve(Inventory, Get),
    #{websocket := #{config := Cfg}} = maps:get(carriers, L),
    ?assertEqual(true, maps:get(enabled, maps:get(ping, Cfg))),
    ?assertEqual(9, maps:get(level, maps:get(deflate_opts, Cfg))).

carrier_key_set_nowhere_is_absent_test() ->
    %% Neither listener nor global set anything, so the resolved config is
    %% EMPTY rather than populated with values invented in this module. The
    %% schema owns defaults; a value fabricated here would silently override
    %% the handler's own default.
    Inventory = [
        {pub, #{
            transport => tcp, protocol => http, port => 1, services => [wamp_ws]
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    #{websocket := #{config := Cfg}} = maps:get(carriers, L),
    ?assertEqual(#{}, Cfg).

websocket_dynamic_buffer_is_not_overridable_test() ->
    %% `wamp.websocket.buffer.{min,max}' cannot take effect: since Cowboy 2.13 a
    %% WebSocket inherits the listener's dynamic_buffer and cowboy_websocket
    %% overrides any handler-supplied value. Offering it per listener would be a
    %% knob that does nothing, so it must NOT appear in the resolved config even
    %% when an operator sets it.
    Inventory = [
        {pub, #{
            transport => tcp, protocol => http, port => 1, services => [wamp_ws]
        }}
    ],
    Get = get_with([
        {[pub, websocket, protocol_opts, dynamic_buffer, min], 1024}
    ]),
    {ok, [L]} = bondy_listener_config:resolve(Inventory, Get),
    #{websocket := #{config := Cfg}} = maps:get(carriers, L),
    ?assertNot(maps:is_key(protocol_opts, Cfg)).

admin_listener_defaults_to_loopback_test() ->
    %% Today's admin listeners default their bind address to loopback (schema
    %% comment "D-1: default to loopback"). That default moves here.
    Inventory = [
        {admin, #{
            transport => tcp, protocol => http, port => 18081,
            services => [admin, metrics]
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    ?assertEqual({127, 0, 0, 1}, maps:get(ip, L)).

explicit_ip_overrides_the_default_test() ->
    Inventory = [
        {admin, #{
            transport => tcp, protocol => http, port => 18081,
            services => [admin], ip => {0, 0, 0, 0}
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    ?assertEqual({0, 0, 0, 0}, maps:get(ip, L)).
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `rebar3 as test eunit --module=bondy_listener_config_test`
Expected: FAIL — `carriers` is `#{}`; no `ip` key.

- [ ] **Step 3: Write the minimal implementation**

Add the service table and carrier resolution to `bondy_listener_config.erl`:

```erlang
-export([service_spec/1]).

%% Carrier and carried protocol are INTRINSIC to a service name, so this is
%% data, not a compatibility matrix to keep in step with anything. A service
%% whose carrier already appears on the listener contributes its protocol to
%% that carrier's set rather than a second route on the same path.
service_spec(api_gateway) ->
    #{carrier => rest, protocol => undefined, module => bondy_http_services};
service_spec(wamp_ws) ->
    #{carrier => websocket, protocol => wamp, module => bondy_http_services};
service_spec(bamp_ws) ->
    #{carrier => websocket, protocol => bamp, module => bondy_http_services};
service_spec(wamp_sse) ->
    #{carrier => sse, protocol => wamp, module => bondy_http_services};
service_spec(wamp_longpoll) ->
    #{carrier => longpoll, protocol => wamp, module => bondy_http_services};
service_spec(admin) ->
    #{carrier => admin, protocol => undefined, module => bondy_http_services};
service_spec(metrics) ->
    #{carrier => metrics, protocol => undefined, module => bondy_http_services};
service_spec(Other) ->
    %% Extension point: an app outside bondy_router (e.g. bondy_mcp) registers
    %% its services here rather than in this table.
    case lists:keyfind(Other, 1, external_services()) of
        {Other, Spec} -> Spec;
        false -> error
    end.

%% @private
external_services() ->
    application:get_env(bondy_router, http_services, []).

%% The carrier settings an operator may override per listener, as key PATHS
%% relative to the carrier's block.
%%
%% Each path is the TARGET of the corresponding global `wamp.<carrier>.*'
%% mapping in schema/bondy.schema, which is NOT always the mapping's conf key
%% name: `wamp.websocket.compression_enabled' targets `compress', and
%% `wamp.websocket.buffer.min' targets `protocol_opts.dynamic_buffer.min'. The
%% target is what reaches application env, so the target is what belongs here.
%%
%% `wamp.websocket.buffer.{min,max}' are deliberately EXCLUDED. Since Cowboy
%% 2.13 a WebSocket connection inherits the listener's `dynamic_buffer' and
%% `cowboy_websocket' overrides any handler-supplied value, so a WS-specific
%% setting cannot take effect (see the comment at bondy_config:setup_wamp/0).
%% Exposing them per listener would ship two knobs that do nothing.
-define(CARRIER_KEYS, #{
    websocket => [
        [compress],
        [hibernate],
        [idle_timeout],
        [max_frame_size],
        [ping, enabled],
        [ping, idle_timeout],
        [ping, max_attempts],
        [ping, timeout],
        [deflate_opts, level],
        [deflate_opts, mem_level],
        [deflate_opts, strategy],
        [deflate_opts, server_context_takeover],
        [deflate_opts, client_context_takeover],
        [deflate_opts, server_max_window_bits],
        [deflate_opts, client_max_window_bits]
    ],
    sse => [
        [idle_timeout],
        [reset_idle_timeout_on_send],
        [ping, enabled],
        [ping, interval]
    ],
    longpoll => [
        [idle_timeout],
        [poll_timeout],
        [reset_idle_timeout_on_send]
    ],
    rest => [],
    admin => [],
    metrics => []
}).

%% Global block each carrier falls back to. These are today's keys.
carrier_global(websocket) -> wamp_websocket;
carrier_global(sse) -> wamp_sse;
carrier_global(longpoll) -> wamp_longpoll;
carrier_global(_) -> undefined.
```

Add to `resolve_one/3` before building the map:

```erlang
    Carriers = resolve_carriers(Name, Services, GetFun),
```

and include `carriers => Carriers, ip => resolve_ip(Name, Services, Spec)` in
the returned map. Then:

```erlang
%% @private
resolve_carriers(Name, Services, GetFun) ->
    lists:foldl(
        fun(Service, Acc) ->
            case service_spec(Service) of
                error ->
                    invalid(Name, {unknown_service, Service});
                #{carrier := Carrier, protocol := Protocol} ->
                    Entry = maps:get(
                        Carrier,
                        Acc,
                        #{
                            protocols => [],
                            config => resolve_carrier_config(
                                Name, Carrier, GetFun
                            )
                        }
                    ),
                    Protos = maps:get(protocols, Entry),
                    Protos1 = add_protocol(Protocol, Protos),
                    maps:put(Carrier, Entry#{protocols => Protos1}, Acc)
            end
        end,
        #{},
        Services
    ).

%% @private
add_protocol(undefined, Protos) -> Protos;
add_protocol(Protocol, Protos) ->
    case lists:member(Protocol, Protos) of
        true -> Protos;
        false -> [Protocol | Protos]
    end.

%% @private
%% Precedence has exactly two levels: the per-listener value if the operator set
%% one, otherwise the global `wamp.<carrier>.*' value. There is deliberately no
%% third tier of defaults in this module — every global mapping in
%% schema/bondy.schema carries its own `{default, ...}', so the schema is the
%% single source of truth for what a setting defaults to. A key set in neither
%% place is left ABSENT from the resolved map, so the handler's own default (or
%% Cowboy's) applies rather than a value invented here.
%%
%% Resolved ONCE per listener rather than per connection, so the connection
%% handler performs no configuration lookup on the accept path.
resolve_carrier_config(Name, Carrier, GetFun) ->
    Paths = maps:get(Carrier, ?CARRIER_KEYS, []),
    Global = carrier_global(Carrier),
    lists:foldl(
        fun(Path, Acc) ->
            case resolve_carrier_key(Name, Carrier, Global, Path, GetFun) of
                undefined -> Acc;
                Value -> put_path(Path, Value, Acc)
            end
        end,
        #{},
        Paths
    ).

%% @private
resolve_carrier_key(Name, Carrier, Global, Path, GetFun) ->
    case GetFun([Name, Carrier | Path], undefined) of
        undefined when Global =:= undefined -> undefined;
        undefined -> GetFun([Global | Path], undefined);
        Value -> Value
    end.

%% @private
%% Carrier keys are nested (`ping.enabled', `deflate_opts.level'), so the
%% resolved config is a nested map mirroring the key path.
put_path([Key], Value, Map) ->
    maps:put(Key, Value, Map);
put_path([Key | Rest], Value, Map) ->
    Inner = maps:get(Key, Map, #{}),
    maps:put(Key, put_path(Rest, Value, Inner), Map).

%% @private
%% A listener exposing `admin` or `metrics` defaults to loopback, matching the
%% present admin listeners. An explicit `ip` always wins.
resolve_ip(_Name, Services, Spec) ->
    case maps:find(ip, Spec) of
        {ok, Ip} ->
            Ip;
        error ->
            Privileged = [S || S <- Services, S =:= admin orelse S =:= metrics],
            case Privileged of
                [] -> {0, 0, 0, 0};
                _ -> {127, 0, 0, 1}
            end
    end.
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `rebar3 as test eunit --module=bondy_listener_config_test`
Expected: PASS. Count the `_test() ->` functions in the test file and
report that number — do not trust a count written in this plan, and never
delete a test to make a stated count match.

- [ ] **Step 5: Format and checkpoint**

Report: carrier grouping, three-level config precedence, loopback default. 25
tests passing.

---

### Task 4: `bondy_http_services` — extract the route sets

**Files:**
- Create: `apps/bondy_router/src/bondy_http_service.erl`
- Create: `apps/bondy_router/src/bondy_http_services.erl`
- Create: `apps/bondy_router/test/bondy_http_services_test.erl`
- Modify: `apps/bondy_router/src/bondy_http_gateway.erl` — **add** `routes/1` only. Do NOT delete `base_routes/0` or `admin_base_routes/0`, and do NOT touch `load_dispatch_tables/0`; see Step 4.

**Interfaces:**
- Consumes: `bondy_listener_config:t()`, `service_spec/1` from Task 3.
- Produces:
  `bondy_http_services:routes(Carrier :: atom(), Protocols :: [atom()], Listener :: bondy_listener_config:t()) -> [{Path :: string(), module(), map()}]`
  and `bondy_http_service` behaviour with that one callback.
  Also `bondy_http_services:dispatch(Listener) -> cowboy_router:routes()`,
  merging every carrier's contribution into one `{'_', Routes}` group and
  raising `{route_collision, Path, CarrierA, CarrierB}` on a clash.

- [ ] **Step 1: Write the failing test**

Create `apps/bondy_router/test/bondy_http_services_test.erl`:

```erlang
%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Tests that the route sets extracted out of `bondy_http_gateway` produce
%% exactly the paths the hardcoded `base_routes/0` and `admin_base_routes/0`
%% produced, and that a listener declaring fewer services mounts strictly
%% fewer paths — the property the old fixed route sets could not express.
%% =============================================================================
-module(bondy_http_services_test).

-include_lib("eunit/include/eunit.hrl").

listener(Services) ->
    {ok, [L]} = bondy_listener_config:resolve(
        [
            {test, #{
                transport => tcp,
                protocol => http,
                port => 18080,
                services => Services
            }}
        ],
        fun(_K, D) -> D end
    ),
    L.

paths(Listener) ->
    [{'_', Routes}] = bondy_http_services:dispatch(Listener),
    lists:sort([Path || {Path, _Mod, _St} <- Routes]).

full_public_service_set_matches_the_old_base_routes_test() ->
    %% These are the nine paths `bondy_http_gateway:base_routes/0` mounted
    %% unconditionally on every public listener.
    Expected = lists:sort([
        "/ws",
        "/wamp/sse/open",
        "/wamp/sse/:transport_id/receive",
        "/wamp/sse/:transport_id/send",
        "/wamp/sse/:transport_id/close",
        "/wamp/longpoll/open",
        "/wamp/longpoll/:transport_id/receive",
        "/wamp/longpoll/:transport_id/send",
        "/wamp/longpoll/:transport_id/close"
    ]),
    L = listener([wamp_ws, wamp_sse, wamp_longpoll]),
    ?assertEqual(Expected, paths(L)).

admin_service_set_matches_the_old_admin_base_routes_test() ->
    Expected = lists:sort([
        "/ws", "/ping", "/ready", "/cluster/topology", "/metrics/[:registry]"
    ]),
    L = listener([wamp_ws, admin, metrics]),
    ?assertEqual(Expected, paths(L)).

dropping_longpoll_drops_only_its_paths_test() ->
    L = listener([wamp_ws, wamp_sse]),
    Paths = paths(L),
    ?assert(lists:member("/ws", Paths)),
    ?assert(lists:member("/wamp/sse/open", Paths)),
    ?assertNot(lists:member("/wamp/longpoll/open", Paths)).

websocket_route_carries_the_listener_protocol_set_test() ->
    L = listener([bamp_ws]),
    [{'_', Routes}] = bondy_http_services:dispatch(L),
    {"/ws", bondy_wamp_ws_connection_handler, State} = lists:keyfind(
        "/ws", 1, Routes
    ),
    ?assertEqual(test, maps:get(listener, State)),
    ?assertEqual([bamp], maps:get(protocols, State)).

sse_and_longpoll_routes_carry_the_right_handlers_test() ->
    %% `paths/1` deliberately discards the handler module, so path equality alone
    %% would stay green if `bondy_http_sse_handler` and
    %% `bondy_http_sse_stream_handler` were swapped, or if an `action` key were
    %% dropped. Assert the full tuple for the two carriers whose routes differ in
    %% handler and in state.
    L = listener([wamp_sse, wamp_longpoll]),
    [{'_', Routes}] = bondy_http_services:dispatch(L),
    Mod = fun(Path) ->
        {Path, M, _} = lists:keyfind(Path, 1, Routes),
        M
    end,
    ?assertEqual(bondy_http_sse_handler, Mod("/wamp/sse/open")),
    ?assertEqual(
        bondy_http_sse_stream_handler, Mod("/wamp/sse/:transport_id/receive")
    ),
    ?assertEqual(bondy_http_sse_handler, Mod("/wamp/sse/:transport_id/send")),
    ?assertEqual(bondy_http_longpoll_handler, Mod("/wamp/longpoll/open")),

    %% The `action` a handler dispatches on must survive route assembly.
    {_, _, OpenSt} = lists:keyfind("/wamp/longpoll/open", 1, Routes),
    ?assertEqual(open, maps:get(action, OpenSt)),
    {_, _, RecvSt} = lists:keyfind(
        "/wamp/longpoll/:transport_id/receive", 1, Routes
    ),
    ?assertEqual(receive_msgs, maps:get(action, RecvSt)).

route_order_is_deterministic_test() ->
    %% The assembled table is stored in `persistent_term`, so order churn between
    %% boots would be noise. `dispatch/1` sorts carrier keys and reverses once at
    %% the end; nothing else pins that, and `paths/1` sorts before comparing, so
    %% a change that stopped reversing would leave every other test green.
    L = listener([wamp_ws, wamp_sse, admin]),
    [{'_', Routes}] = bondy_http_services:dispatch(L),
    Order = [Path || {Path, _, _} <- Routes],
    ?assertEqual(Order, [Path || {Path, _, _} <- element(2, hd(
        bondy_http_services:dispatch(L)
    ))]),
    %% Carriers are visited in sorted key order (admin, sse, websocket) and each
    %% carrier's own contributed order is preserved, so the first path is the
    %% first route `routes(admin, ...)` lists, not its last.
    ?assertEqual("/ping", hd(Order)),
    ?assertEqual("/ws", lists:last(Order)).

everything_compiles_through_cowboy_router_test() ->
    %% A dispatch table that cowboy_router cannot compile would fail at
    %% listener start, far from the cause.
    L = listener([wamp_ws, wamp_sse, wamp_longpoll, admin, metrics]),
    ?assertMatch([_ | _], cowboy_router:compile(bondy_http_services:dispatch(L))).

two_carriers_claiming_one_path_is_an_error_test() ->
    %% Two services on the SAME carrier union their protocols into one route;
    %% two DIFFERENT carriers claiming one path must raise. Keeping the first
    %% silently would make the second carrier unreachable with no diagnostic.
    %%
    %% No built-in carrier pair collides, so the collision is induced by
    %% registering an external service whose carrier mounts a path `admin`
    %% already owns — the same mechanism a third-party app would use.
    ok = application:set_env(bondy_router, http_services, [
        {clashing, #{
            carrier => clashing,
            protocol => undefined,
            module => ?MODULE
        }}
    ]),
    try
        L = listener([admin, clashing]),
        ?assertError(
            {route_collision, "/ping", _, _}, bondy_http_services:dispatch(L)
        )
    after
        ok = application:unset_env(bondy_router, http_services)
    end.

%% Stands in for a third-party `bondy_http_service` implementation. Deliberately
%% mounts a path `admin` already owns.
routes(clashing, _Protocols, _Listener) ->
    [{"/ping", bondy_admin_ping_http_handler, #{}}].
```

Note the test module must export `routes/3` for the collision case:
add `-export([routes/3]).` to `bondy_http_services_test`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `rebar3 as test eunit --module=bondy_http_services_test`
Expected: FAIL — `bondy_http_services` does not exist.

- [ ] **Step 3: Write the minimal implementation**

Create `apps/bondy_router/src/bondy_http_service.erl`:

```erlang
%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_service).

-moduledoc """
Behaviour for a carrier's contribution to an HTTP listener's dispatch table.

A *carrier* is a way of reaching Bondy over HTTP — WebSocket, SSE, long poll,
REST — and it is the carrier, not the service name, that owns a path. Several
services may name the same carrier while carrying different protocols
(`wamp_ws` and `bamp_ws` both mount `/ws`), so the callback receives the UNION
of that carrier's protocols for the listener and is called once.

In-tree carriers are implemented by `bondy_http_services`. This behaviour exists
so an application outside `bondy_router` can supply its own, registered through
the `bondy_router.http_services` env consulted by
`bondy_listener_config:service_spec/1`.
""".

-doc """
Returns the Cowboy route rules `Carrier` contributes to `Listener`.

`Protocols` is the union of the protocols the listener's services named for this
carrier, and may be `[]` for a carrier that carries no wire protocol (REST,
admin, metrics).
""".
-callback routes(
    Carrier :: atom(),
    Protocols :: [atom()],
    Listener :: bondy_listener_config:t()
) -> [{Path :: string(), module(), State :: map()}].
```

Create `apps/bondy_router/src/bondy_http_services.erl`:

```erlang
%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_services).

-moduledoc """
Route contributions for every carrier built into `bondy_router`.

One module rather than one per carrier: each contribution is a handful of route
rules, and keeping them together makes the whole HTTP surface of a listener
readable in one place.

`dispatch/1` assembles a listener's full table. A path claimed by two different
carriers raises `{route_collision, Path, CarrierA, CarrierB}` — silently keeping
the first would make the second carrier unreachable with no diagnostic.

Routes contributed by API Gateway specifications are NOT here: they are dynamic
(a spec can arrive by anti-entropy at any time) and come from
`bondy_http_gateway`.
""".

-behaviour(bondy_http_service).

-export([dispatch/1]).
-export([routes/3]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Assembles the complete Cowboy dispatch table for `Listener`.

Carriers are asked in a stable order so the resulting table — and therefore the
`persistent_term` it is stored in — does not churn between boots.
""".
-spec dispatch(bondy_listener_config:t()) -> cowboy_router:routes().

dispatch(Listener) ->
    Carriers = maps:get(carriers, Listener),
    Ordered = lists:sort(maps:keys(Carriers)),

    Routes = lists:foldl(
        fun(Carrier, Acc) ->
            #{protocols := Protocols} = maps:get(Carrier, Carriers),
            Module = carrier_module(Carrier, Listener),
            Contributed = Module:routes(Carrier, Protocols, Listener),
            merge_routes(Contributed, Carrier, Acc)
        end,
        [],
        Ordered
    ),

    [{'_', [Route || {Route, _Carrier} <- lists:reverse(Routes)]}].

-doc "Route rules for a built-in carrier. See `bondy_http_service`.".
-spec routes(atom(), [atom()], bondy_listener_config:t()) ->
    [{string(), module(), map()}].

routes(websocket, Protocols, Listener) ->
    [{"/ws", bondy_wamp_ws_connection_handler, carrier_state(
        websocket, Protocols, Listener
    )}];
routes(sse, Protocols, Listener) ->
    St = carrier_state(sse, Protocols, Listener),
    [
        {"/wamp/sse/open", bondy_http_sse_handler, St#{action => open}},
        {"/wamp/sse/:transport_id/receive", bondy_http_sse_stream_handler, St},
        {"/wamp/sse/:transport_id/send", bondy_http_sse_handler, St#{
            action => send
        }},
        {"/wamp/sse/:transport_id/close", bondy_http_sse_handler, St#{
            action => close
        }}
    ];
routes(longpoll, Protocols, Listener) ->
    St = carrier_state(longpoll, Protocols, Listener),
    [
        {"/wamp/longpoll/open", bondy_http_longpoll_handler, St#{action => open}},
        {"/wamp/longpoll/:transport_id/receive", bondy_http_longpoll_handler,
            St#{action => receive_msgs}},
        {"/wamp/longpoll/:transport_id/send", bondy_http_longpoll_handler, St#{
            action => send
        }},
        {"/wamp/longpoll/:transport_id/close", bondy_http_longpoll_handler, St#{
            action => close
        }}
    ];
routes(admin, _Protocols, _Listener) ->
    [
        {"/ping", bondy_admin_ping_http_handler, #{}},
        {"/ready", bondy_admin_ready_http_handler, #{}},
        {"/cluster/topology", bondy_admin_cluster_topology_http_handler, #{}}
    ];
routes(metrics, _Protocols, _Listener) ->
    [{"/metrics/[:registry]", prometheus_cowboy2_handler, []}];
routes(rest, _Protocols, Listener) ->
    %% API Gateway specification routes are dynamic; the gateway supplies them.
    bondy_http_gateway:routes(Listener).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% `dispatch/1` accepts any `bondy_listener_config:t()`, which is a plain map
%% with nothing at runtime proving it came from `resolve/2`. A listener assembled
%% by hand whose `carriers` key is not backed by a matching service would
%% otherwise fail inside `hd/1` with `bad argument`, naming neither the carrier
%% nor the listener. Failing with the carrier named does not hide the bug — it
%% fails just as hard, at the place that can describe it.
carrier_module(Carrier, Listener) ->
    Services = maps:get(services, Listener),
    Match = [
        Module
     || S <- Services,
        #{carrier := C, module := Module} <-
            [bondy_listener_config:service_spec(S)],
        C =:= Carrier
    ],
    case Match of
        [Module | _] -> Module;
        [] -> error({no_module_for_carrier, Carrier})
    end.

%% @private
%% The handler receives its listener's name and resolved carrier configuration
%% in the route state, so it performs no configuration lookup per connection.
carrier_state(Carrier, Protocols, Listener) ->
    #{Carrier := #{config := Config}} = maps:get(carriers, Listener),
    #{
        listener => maps:get(name, Listener),
        protocols => lists:sort(Protocols),
        config => Config
    }.

%% @private
merge_routes(Contributed, Carrier, Acc) ->
    lists:foldl(
        fun({Path, _, _} = Route, Inner) ->
            case lists:keyfind(Path, 1, [{P, C} || {{P, _, _}, C} <- Inner]) of
                {Path, Other} when Other =/= Carrier ->
                    error({route_collision, Path, Other, Carrier});
                _ ->
                    [{Route, Carrier} | Inner]
            end
        end,
        Acc,
        Contributed
    ).
```

- [ ] **Step 4: Add `bondy_http_gateway:routes/1` — and delete nothing**

This task is **purely additive** to `bondy_http_gateway`. Do **not** delete
`base_routes/0` or `admin_base_routes/0`, and do not change
`load_dispatch_tables/0`. `admin_base_routes/0` is called at `:554` inside
`do_start_listeners(admin)`, which survives until Task 6 — deleting it here
stops the module compiling. `base_routes/0` is likewise still used by
`load_dispatch_tables/0` at `:939`, `:945` and `:946`. Task 6 removes all of
them together with their call sites.

Two consequences of that, both deliberate and transitional:

- The `rest` carrier's routes will **double-count** the base routes until Task 6,
  because `load_dispatch_tables/0` still appends `base_routes()` while the
  `websocket`/`sse`/`longpoll` carriers now contribute the same paths. Nothing
  calls `bondy_http_services` at runtime until Task 6, so this is latent, not
  live.
- **No test in this task may declare the `api_gateway` service.** That is what
  keeps the `rest` carrier — and therefore `bondy_db`, which
  `load_dispatch_tables/0` reads — out of a pure eunit run. The brief's tests
  are written accordingly; keep it that way.

Add to `bondy_http_gateway.erl`:

```erlang
-export([routes/1]).

-doc """
Cowboy route rules compiled from the stored API Gateway specifications, for the
scheme `Listener` serves.

`bondy_http_gateway_api_spec_parser:dispatch_table/2` keys its result by the
scheme declared in each specification, so a listener takes the table matching
its own scheme: `https` when it terminates TLS, `http` otherwise.
""".
-spec routes(bondy_listener_config:t()) -> [{string(), module(), any()}].

routes(Listener) ->
    Scheme = scheme(maps:get(transport, Listener)),
    Tables = load_dispatch_tables(),
    case lists:keyfind(Scheme, 1, Tables) of
        {Scheme, Rules} -> flatten_rules(Rules);
        false -> []
    end.

%% @private
scheme(tls) -> ~"https";
scheme(quic) -> ~"https";
scheme(_) -> ~"http".

%% @private
%% `dispatch_table/2` returns `[{'_', Routes}]` groups; a carrier contributes a
%% flat route list, so unwrap.
flatten_rules(Rules) ->
    lists:append([Routes || {_Host, Routes} <- Rules]).
```

Leave `load_dispatch_tables/0` exactly as it is. Task 6 changes it to pass `[]`
instead of `base_routes()`, at the point where the carriers become the only
source of those paths.

- [ ] **Step 5: Run the test to verify it passes**

Run: `rebar3 as test eunit --module=bondy_http_services_test`
Expected: PASS. Count the `_test() ->` functions in the test file and
report that number — do not trust a count written in this plan, and never
delete a test to make a stated count match.

- [ ] **Step 6: Format and checkpoint**

Report: behaviour + carriers module, old fixed route sets deleted, 5 tests
proving path-for-path equivalence with the deleted functions.

---

### Task 5: `bondy_listener` behaviour and the ranch driver

**Files:**
- Create: `apps/bondy_router/src/bondy_listener.erl`
- Create: `apps/bondy_router/src/bondy_listener_ranch.erl`
- Modify: `apps/bondy_router/src/bondy_ranch_listener.erl` — delete `ref_to_transport/1` (`:113-116`)

**Interfaces:**
- Consumes: `bondy_listener_config:t()` (Tasks 1–3), `bondy_http_services:dispatch/1` (Task 4).
- Produces:
  `bondy_listener:start(t()) -> ok | {error, term()}`, `stop(t()) -> ok`,
  `suspend(t()) -> ok`, `resume(t()) -> ok`,
  `connections(t()) -> [pid()]`.
  Each dispatches to `maps:get(driver, Listener)`. `bondy_listener_ranch`
  implements all five for `tcp`, `tls` and `uds`.

- [ ] **Step 1: Write the failing test**

Create `apps/bondy_router/test/bondy_listener_SUITE.erl`:

```erlang
%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Exercises the listener driver against real sockets: a listener that starts
%% accepts a connection, a suspended one refuses new connections while keeping
%% existing ones, and a stopped one releases its port.
%% =============================================================================
-module(bondy_listener_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([tcp_listener_accepts/1]).
-export([suspend_refuses_new_connections/1]).
-export([stop_releases_the_port/1]).
-export([uds_listener_accepts/1]).

all() ->
    [
        tcp_listener_accepts,
        suspend_refuses_new_connections,
        stop_releases_the_port,
        uds_listener_accepts
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(ranch),
    {ok, _} = application:ensure_all_started(cowboy),
    Config.

end_per_suite(Config) ->
    Config.

%% A raw-socket listener on an ephemeral port. `port => 0` makes the OS choose,
%% which keeps parallel CT runs from colliding.
listener(Name, Extra) ->
    ok = set_listener_env(Name),
    Spec = maps:merge(
        #{transport => tcp, protocol => wamp_rawsocket, port => 0}, Extra
    ),
    {ok, [L]} = bondy_listener_config:resolve(
        [{Name, Spec}], fun(_K, D) -> D end
    ),
    L.

%% `bondy_listener_ranch` builds its ranch options through
%% `bondy_config:listener_transport_opts/1`. That resolves via `app_config`,
%% which reads `persistent_term` — NOT application environment — so
%% `application:set_env/3` is invisible to it. And `bondy_config:get/1` has no
%% default, so a listener with no block raises rather than returning `undefined`,
%% and `key_value:to_map/1` has no clause for `undefined` either. Each test
%% listener therefore needs its block installed before the driver starts it.
%%
%% A full boot does this from application env via `bondy_config:init/1`; this
%% suite starts only ranch and cowboy, so it installs the block directly.
set_listener_env(Name) ->
    %% `ip_version` and `proxy_protocol` are not optional padding: pre-existing
    %% code paths in `bondy_config` and `bondy_http_proxy_protocol` read them
    %% without a default and crash when they are absent.
    bondy_config:set(Name, [
        {transport_opts, [
            {num_acceptors, 2},
            {max_connections, 128},
            {socket_opts, [{ip_version, inet}]}
        ]},
        {proxy_protocol, [{enabled, false}]}
    ]).

%% The server-side connection process is spawned asynchronously after
%% `gen_tcp:connect/4` returns, so poll rather than assume it is counted already.
await_connections(L, N) ->
    await_connections(L, N, 50).

await_connections(L, N, 0) ->
    ?assertEqual(N, length(bondy_listener:connections(L))),
    ok;
await_connections(L, N, Retries) ->
    case length(bondy_listener:connections(L)) of
        N ->
            ok;
        _ ->
            ok = timer:sleep(20),
            await_connections(L, N, Retries - 1)
    end.

tcp_listener_accepts(_Config) ->
    L = listener(ct_accept, #{}),
    ok = bondy_listener:start(L),
    Port = ranch:get_port(ct_accept),
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary], 5000),
    ok = gen_tcp:close(Sock),
    ok = bondy_listener:stop(L).

suspend_refuses_new_connections(_Config) ->
    L = listener(ct_suspend, #{}),
    ok = bondy_listener:start(L),
    Port = ranch:get_port(ct_suspend),
    {ok, Existing} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary], 5000),

    %% Count the connection server-side BEFORE suspending, so the assertion after
    %% it can prove survival.
    ok = await_connections(L, 1),

    ok = bondy_listener:suspend(L),
    ?assertMatch(
        {error, econnrefused},
        gen_tcp:connect({127, 0, 0, 1}, Port, [binary], 1000)
    ),
    %% The established connection must survive suspension. `gen_tcp:send/2`
    %% cannot show this: it is a local kernel-buffer write that returns `ok`
    %% whether or not the peer is gone, so it would pass even if `suspend/1` had
    %% torn the connection down — a remote close only surfaces on a LATER
    %% send/recv. Worse, the only bytes available to send are a WAMP protocol
    %% violation, which makes the handler log an `invalid_handshake` crash
    %% report. Counting the connection process instead proves the property and
    %% provokes nothing.
    ok = await_connections(L, 1),

    ok = bondy_listener:resume(L),
    %% `ranch:resume_listener/1` re-listens from the transport options stored at
    %% `start/1` time, which still say `port => 0`: it binds a NEW ephemeral port
    %% rather than reclaiming the original. Verified by observation — reusing
    %% `Port` here reproducibly yields `econnrefused` even though `resume/1`
    %% returned `ok`.
    ResumedPort = ranch:get_port(ct_suspend),
    {ok, After} = gen_tcp:connect({127, 0, 0, 1}, ResumedPort, [binary], 5000),
    ok = gen_tcp:close(After),
    ok = gen_tcp:close(Existing),
    ok = bondy_listener:stop(L).

stop_releases_the_port(_Config) ->
    L = listener(ct_stop, #{}),
    ok = bondy_listener:start(L),
    Port = ranch:get_port(ct_stop),
    ok = bondy_listener:stop(L),
    ?assertMatch(
        {error, econnrefused},
        gen_tcp:connect({127, 0, 0, 1}, Port, [binary], 1000)
    ).

uds_listener_accepts(_Config) ->
    %% The path must include the OS pid: parallel CT runs share /tmp.
    %% `sockaddr_un.sun_path` is 104 bytes on Darwin and CT's `priv_dir` path
    %% alone can exceed that, so bind under /tmp; the pid suffix still keeps it
    %% unique against parallel CT runs sharing the directory.
    Path = filename:join("/tmp", "bondy_ct_" ++ os:getpid() ++ ".sock"),
    L = listener(ct_uds, #{transport => uds, path => Path}),
    ok = bondy_listener:start(L),
    {ok, Sock} = gen_tcp:connect({local, Path}, 0, [binary], 5000),
    ok = gen_tcp:close(Sock),
    ok = bondy_listener:stop(L).
```

Note `listener/2` passes `port => 0`, so remove the `path`/`port` conflict by
having the UDS case override `transport` and supply `path`; `resolve_bind/3`
ignores `port` for `uds`.

- [ ] **Step 2: Run the suite to verify it fails**

Run: `CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_listener_SUITE.erl`
Expected: FAIL — `bondy_listener` does not exist.

- [ ] **Step 3: Write the behaviour**

Create `apps/bondy_router/src/bondy_listener.erl`:

```erlang
%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_listener).

-moduledoc """
Lifecycle operations on one listener, dispatched to the driver its transport
selects.

A driver exists because `transport` is not merely a choice of ranch transport
module. `tcp`, `tls` and `uds` are ranch stream listeners; QUIC is served by
`cowboy:start_quic/3`, which creates no ranch listener at all — it spawns its own
process around `quicer:listen/2`. Their option sets and lifecycle primitives are
disjoint, so the manager must not branch on transport itself.
""".

-callback start(bondy_listener_config:t()) -> ok | {error, term()}.
-callback stop(bondy_listener_config:t()) -> ok.
-callback suspend(bondy_listener_config:t()) -> ok.
-callback resume(bondy_listener_config:t()) -> ok.
-callback connections(bondy_listener_config:t()) -> [pid()].

-export([start/1]).
-export([stop/1]).
-export([suspend/1]).
-export([resume/1]).
-export([connections/1]).

-spec start(bondy_listener_config:t()) -> ok | {error, term()}.
start(Listener) -> (driver(Listener)):start(Listener).

-spec stop(bondy_listener_config:t()) -> ok.
stop(Listener) -> (driver(Listener)):stop(Listener).

-spec suspend(bondy_listener_config:t()) -> ok.
suspend(Listener) -> (driver(Listener)):suspend(Listener).

-spec resume(bondy_listener_config:t()) -> ok.
resume(Listener) -> (driver(Listener)):resume(Listener).

-spec connections(bondy_listener_config:t()) -> [pid()].
connections(Listener) -> (driver(Listener)):connections(Listener).

%% @private
driver(#{driver := Driver}) -> Driver.
```

- [ ] **Step 4: Write the ranch driver**

Create `apps/bondy_router/src/bondy_listener_ranch.erl`. It carries over the
logic currently in `bondy_http_gateway:start_http/2`, `start_https/2`,
`listener_transport_opts/1` and `bondy_ranch_listener:start/3`:

```erlang
%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_listener_ranch).

-moduledoc """
Listener driver for the ranch stream transports: `tcp`, `tls` and `uds`.

An HTTP listener is started through Cowboy (`start_clear/3` for a plaintext
socket, `start_tls/3` for a TLS one — they differ only in the ranch transport
module); a raw-socket or bridge-relay listener is started through
`ranch:start_listener/5` with the protocol's own connection handler.

A Unix-domain listener is a `gen_tcp` stream socket bound to `{local, Path}`
rather than a host and port, so it uses the same driver with a different listen
address. A socket file left by a previous run makes `gen_tcp:listen/2` fail with
`eaddrinuse`, so it is removed first.
""".

-behaviour(bondy_listener).

-include_lib("kernel/include/logger.hrl").

-export([start/1]).
-export([stop/1]).
-export([suspend/1]).
-export([resume/1]).
-export([connections/1]).

%% =============================================================================
%% bondy_listener CALLBACKS
%% =============================================================================

start(#{enabled := false, name := Name}) ->
    ?LOG_NOTICE(#{
        description => "Listener disabled by configuration, not starting",
        listener => Name
    }),
    ok;
start(#{protocol := http} = L) ->
    start_http(L);
start(L) ->
    start_stream(L).

stop(#{protocol := http, name := Name} = L) ->
    catch cowboy:stop_listener(Name),
    ok = bondy_http_security_headers:cleanup(Name),
    %% Symmetric with `start_http/1`: an HTTP listener bound to a Unix domain
    %% socket must not leave its socket file behind.
    ok = maybe_unlink_socket(L),
    ok;
stop(#{name := Name} = L) ->
    catch ranch:stop_listener(Name),
    ok = maybe_unlink_socket(L),
    ok.

suspend(#{name := Name}) ->
    catch ranch:suspend_listener(Name),
    ok.

resume(#{name := Name}) ->
    catch ranch:resume_listener(Name),
    ok.

connections(#{name := Name}) ->
    try
        ranch:procs(Name, connections)
    catch
        _:_ -> []
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
start_http(#{name := Name, transport := Transport} = L) ->
    %% An HTTP listener can bind a Unix domain socket too — the resolver does not
    %% forbid `transport => uds` with `protocol => http`, and Cowboy reaches
    %% `ranch:start_listener/5` on the same `{local, Path}` socket — so a stale
    %% socket file has to be cleared here as well, not only on the stream path.
    ok = maybe_unlink_socket(L),
    TransportOpts = transport_opts(L),
    ProtoOpts = protocol_opts(L),
    LogMeta = #{
        listener => Name,
        transport => Transport,
        transport_opts => TransportOpts,
        protocol_opts => maps:without([env], ProtoOpts)
    },
    Result =
        case Transport of
            tls -> cowboy:start_tls(Name, TransportOpts, ProtoOpts);
            _ -> cowboy:start_clear(Name, TransportOpts, ProtoOpts)
        end,
    log_result(Result, LogMeta).

%% @private
start_stream(#{name := Name, transport := Transport} = L) ->
    ok = maybe_unlink_socket(L),
    Module = ranch_transport(Transport),
    TransportOpts = transport_opts(L),
    Protocol = maps:get(protocol, L),
    Handler = connection_handler(Protocol),
    ProtocolOpts = stream_protocol_opts(Protocol, Name),
    Result = ranch:start_listener(
        Name, Module, TransportOpts, Handler, ProtocolOpts
    ),
    log_result(Result, #{
        listener => Name,
        transport => Transport,
        transport_opts => TransportOpts,
        protocol => Handler
    }).

%% @private
ranch_transport(tls) -> ranch_ssl;
ranch_transport(_) -> ranch_tcp.

%% @private
%% Options handed to the connection handler. `bondy_bridge_relay_server:init/1`
%% reads `auth_timeout', `idle_timeout', `hibernate' and `ping' out of these
%% (see bondy_bridge_relay_server.erl:128-144), so passing an empty list would
%% reset its three timeouts to their defaults and disable its ping monitoring
%% altogether. The WAMP raw-socket handler takes no options.
stream_protocol_opts(bridge_relay, Name) -> bondy_config:get(Name, []);
stream_protocol_opts(_Protocol, _Name) -> [].

%% @private
connection_handler(wamp_rawsocket) -> bondy_wamp_tcp_connection_handler;
connection_handler(bamp_rawsocket) -> bondy_bamp_tcp_connection_handler;
connection_handler(bridge_relay) -> bondy_bridge_relay_server.

%% @private
%% Carries over `bondy_http_gateway:listener_transport_opts/1`: the connection
%% alarms and the reuseport listen-socket fan-out.
transport_opts(#{name := Name, bind := Bind} = L) ->
    Opts0 = bondy_config:listener_transport_opts(Name),
    Opts1 = with_bind(Bind, maps:get(ip, L, undefined), Opts0),
    MaxConnections = key_value:get(max_connections, Opts1, infinity),
    Opts2 = Opts1#{alarms => alarms(MaxConnections)},
    maybe_reuseport(Opts2).

%% @private
with_bind({path, Path}, _Ip, Opts) ->
    %% Merge rather than replace: `backlog`, `keepalive`, `nodelay`, `sndbuf`,
    %% `recbuf`, `buffer` and `reuseport` are generic stream-socket options and
    %% are just as meaningful on a Unix domain socket, so an operator who set
    %% them must not have them silently dropped. A UDS listener has no port, but
    %% ranch still requires the key.
    %%
    %% The bare `inet`/`inet6` family atom that
    %% `bondy_config:normalise_socket_opts/1` always prepends is dropped first: a
    %% Unix domain socket is family-less (`AF_UNIX`), and combining that atom
    %% with `{ip, {local, Path}}` makes `gen_tcp:listen/2` raise `badarg`.
    %% `bondy_wamp_uds.erl:118` never sets one either.
    SocketOpts0 = key_value:get(socket_opts, Opts, []),
    SocketOpts1 = lists:delete(inet, lists:delete(inet6, SocketOpts0)),
    SocketOpts2 = lists:keystore(ip, 1, SocketOpts1, {ip, {local, Path}}),
    SocketOpts = lists:keystore(port, 1, SocketOpts2, {port, 0}),
    key_value:put(socket_opts, SocketOpts, Opts);
with_bind({port, Port}, undefined, Opts) ->
    SocketOpts = key_value:get(socket_opts, Opts, []),
    key_value:put(
        socket_opts, lists:keystore(port, 1, SocketOpts, {port, Port}), Opts
    );
with_bind({port, Port}, Ip, Opts) ->
    SocketOpts0 = key_value:get(socket_opts, Opts, []),
    SocketOpts1 = lists:keystore(port, 1, SocketOpts0, {port, Port}),
    SocketOpts = lists:keystore(ip, 1, SocketOpts1, {ip, Ip}),
    key_value:put(socket_opts, SocketOpts, Opts).

%% @private
alarms(infinity) ->
    #{};
alarms(MaxConnections) ->
    #{
        num_connections_75 => #{
            type => num_connections,
            threshold => trunc(MaxConnections * 0.75),
            cooldown => timer:seconds(5),
            callback => fun(LName, AlarmName, _SupPid, Pids) ->
                ?LOG_WARNING(#{
                    description => "Connection 75% threshold exceeded",
                    listener => LName,
                    alarm_name => AlarmName,
                    connections => length(Pids)
                })
            end
        },
        num_connections_90 => #{
            type => num_connections,
            threshold => trunc(MaxConnections * 0.90),
            cooldown => timer:seconds(5),
            callback => fun(LName, AlarmName, _SupPid, Pids) ->
                ?LOG_ALERT(#{
                    description => "Connection 90% threshold exceeded",
                    listener => LName,
                    alarm_name => AlarmName,
                    connections => length(Pids)
                })
            end
        }
    }.

%% @private
maybe_reuseport(Opts) ->
    SocketOpts = key_value:get(socket_opts, Opts, []),
    case key_value:get(reuseport, SocketOpts, false) of
        true ->
            NumAcceptors = key_value:get(num_acceptors, Opts, 10),
            Schedulers = erlang:system_info(schedulers),
            Opts#{
                num_listen_sockets =>
                    max(Schedulers, trunc(NumAcceptors / 15))
            };
        false ->
            Opts
    end.

%% @private
protocol_opts(#{name := Name} = L) ->
    Opts = bondy_config:listener_protocol_opts(Name),
    ok = compile_dispatch(L),
    ok = bondy_http_security_headers:init(Name),
    Opts#{
        env => #{
            bondy => #{auth => #{schemes => [basic, bearer]}},
            dispatch => {persistent_term, dispatch_key(Name)}
        },
        metrics_callback => fun bondy_prometheus_cowboy_collector:observe/1,
        %% cowboy_metrics_h must be first on the list
        stream_handlers => [
            cowboy_metrics_h, cowboy_compress_h, cowboy_stream_h
        ],
        middlewares => [cowboy_router, cowboy_handler],
        hibernate => true
    }.

%% @private
compile_dispatch(#{name := Name} = L) ->
    Routes = bondy_http_services:dispatch(L),
    _ = persistent_term:put(dispatch_key(Name), cowboy_router:compile(Routes)),
    ok.

%% @private
dispatch_key(Name) -> {bondy_http_gateway, dispatch, Name}.

%% @private
maybe_unlink_socket(#{bind := {path, Path}}) ->
    case file:delete(Path) of
        ok ->
            ok;
        {error, enoent} ->
            ok;
        {error, Reason} ->
            ?LOG_WARNING(#{
                description => "Could not remove stale Unix domain socket file",
                path => Path,
                reason => Reason
            }),
            ok
    end;
maybe_unlink_socket(_) ->
    ok.

%% @private
log_result({ok, _}, LogMeta) ->
    ?LOG_NOTICE(LogMeta#{description => "Started listener"}),
    ok;
log_result({error, eaddrinuse = Reason} = Error, LogMeta) ->
    ?LOG_ERROR(LogMeta#{
        description => "Failed to start listener, address already in use",
        reason => Reason
    }),
    Error;
log_result({error, Reason} = Error, LogMeta) ->
    ?LOG_ERROR(LogMeta#{
        description => "Failed to start listener", reason => Reason
    }),
    Error.
```

`connection_handler(bamp_rawsocket)` names a module that does not exist yet.
Delete that clause for now — `bamp_rawsocket` is accepted by the resolver but
has no handler until BAMP lands, and a missing clause gives a clear
`function_clause` at start rather than a confusing `undef` later.

- [ ] **Step 5: Leave `bondy_ranch_listener` in place**

Do **not** delete or modify `bondy_ranch_listener.erl` in this task, and do not
touch `bondy_bridge_relay_manager`. `bondy_listener_ranch` is additive here: it
duplicates that module's job, and both coexist until Task 6 introduces the
inventory that bridge-relay listeners need in order to migrate. Deleting
`ref_to_transport/1` now would break `bondy_bridge_relay_manager:start_listeners/0`
with no replacement available, and `bondy_bridge_relay_sync_SUITE` would fail
from here until Task 8.

The duplication is deliberate and short-lived. Task 6 deletes
`bondy_ranch_listener` once every caller has an inventory entry.

- [ ] **Step 6: Run the suite to verify it passes**

Run: `CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_listener_SUITE.erl`
Expected: PASS, 4 cases.

- [ ] **Step 7: Format and checkpoint**

Report: driver behaviour + ranch driver, `bondy_ranch_listener` deleted, 4 CT
cases covering accept, suspend-keeps-existing, stop-releases-port, UDS.

---

### Task 6: `bondy_listener_manager` and the hardcoded inventory

**Files:**
- Create: `apps/bondy_router/src/bondy_listener_manager.erl`
- Modify: `apps/bondy_router/src/bondy_app.erl:111,113,333-367,459-505`
- Modify: `apps/bondy_router/src/bondy_http_gateway.erl` — delete `:102-105`, `:169-232`, `:532-617`, `:753-884`, `:959-976`, `:1106-1156`
- Delete: `apps/bondy_router/src/bondy_wamp_tcp.erl`, `apps/bondy_router/src/bondy_wamp_uds.erl`, `apps/bondy_router/src/bondy_ranch_listener.erl`
- Modify: `apps/bondy_router/src/bondy_bridge_relay_manager.erl` — its four `*_listeners/0` functions delegate to `bondy_listener_manager`
- Modify: `apps/bondy_router/src/bondy_cert_manager.erl:47-51,76-81`
- Modify: `apps/bondy_router/src/bondy_config.erl:451-456`
- Modify: `apps/bondy_router/test/bondy_ct.erl` — add the inventory
- Test: `apps/bondy_router/test/bondy_listener_SUITE.erl` (append)

**Interfaces:**
- Consumes: `bondy_listener:start/1` etc. (Task 5), `bondy_listener_config:resolve/2` (Tasks 1–3).
- Produces:
  `bondy_listener_manager:init() -> ok | no_return()` (resolve inventory into
  `persistent_term`, abort boot on error);
  `start(early | normal | all) -> ok | {error, term()}`;
  `stop() -> ok`; `suspend() -> ok`; `resume() -> ok`;
  `listeners() -> [bondy_listener_config:t()]`;
  `listener(Name) -> {ok, t()} | {error, not_found}`;
  `connections() -> [pid()]`;
  `tls_listeners() -> [atom()]` (replaces `bondy_cert_manager:?TLS_LISTENERS`);
  `http_listeners() -> [atom()]` (replaces the four literal `dynamic_buffer`
  paths and drives `rebuild_dispatch_tables/0`).

- [ ] **Step 1: Write the failing test**

Append to `bondy_listener_SUITE.erl`:

```erlang
%% add to all/0: manager_resolves_and_starts_by_phase,
%%               manager_aborts_boot_on_invalid_config,
%%               tls_listeners_are_derived

manager_resolves_and_starts_by_phase(_Config) ->
    Inventory = [
        {ct_early, #{
            transport => tcp, protocol => wamp_rawsocket, port => 0,
            start_phase => early
        }},
        {ct_late, #{
            transport => tcp, protocol => wamp_rawsocket, port => 0
        }}
    ],
    %% `init/0` reads the inventory through `bondy_config`, which resolves
    %% against persistent_term — `application:set_env/3` is invisible to it
    %% unless `bondy_config:init/1` has since re-cached. Set it directly.
    ok = bondy_config:set(listeners, Inventory),
    ok = bondy_listener_manager:init(),

    ok = bondy_listener_manager:start(early),
    ?assertMatch(Port when is_integer(Port), ranch:get_port(ct_early)),
    %% The normal-phase listener must NOT be up yet: `bondy_app` starts the
    %% early phase while `status` is still `initialising` and only then the
    %% normal phase (`bondy_app.erl:108-110`), so probe endpoints answer before
    %% any public listener accepts a client.
    ?assertExit(_, ranch:get_port(ct_late)),

    ok = bondy_listener_manager:start(normal),
    ?assertMatch(Port when is_integer(Port), ranch:get_port(ct_late)),

    ok = bondy_listener_manager:stop().

manager_aborts_boot_on_invalid_config(_Config) ->
    %% A static config error must abort, not skip the listener. A node that
    %% boots serving nothing is harder to diagnose than one that refuses to.
    ok = bondy_config:set(listeners, [{ct_bad, #{protocol => http}}]),
    ?assertError(
        {invalid_listener, ct_bad, {missing, transport}},
        bondy_listener_manager:init()
    ).

tls_listeners_are_derived(_Config) ->
    Inventory = [
        {ct_plain, #{transport => tcp, protocol => wamp_rawsocket, port => 0}},
        {ct_secure, #{transport => tls, protocol => wamp_rawsocket, port => 0}}
    ],
    ok = application:set_env(bondy_router, listeners, Inventory),
    ok = bondy_config:set(ct_secure, [
        {tls, [{certfile, "/tmp/c.pem"}, {keyfile, "/tmp/k.pem"}]}
    ]),
    ok = bondy_listener_manager:init(),
    ?assertEqual([ct_secure], bondy_listener_manager:tls_listeners()).
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_listener_SUITE.erl`
Expected: FAIL — `bondy_listener_manager` does not exist.

- [ ] **Step 3: Write the manager**

Create `apps/bondy_router/src/bondy_listener_manager.erl`:

```erlang
%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_listener_manager).

-moduledoc """
Starts, stops, suspends and resumes every configured listener.

Not a process: it holds no mutable state. `init/1` resolves the
`bondy_router.listeners` inventory once and stores the result in
`persistent_term`; every other function reads it. The one event-driven duty
around listeners — rebuilding dispatch tables when an API Gateway specification
changes — belongs to the `bondy_http_gateway` gen_server, which already owns
specification storage and its own debounce.

Startup is two-phase. Listeners marked `start_phase => early` come up before the
registry is initialised so that liveness and readiness probes answer while the
node is still `initialising`; everything else comes up afterwards, once it is
safe for clients to connect.

A configuration error raises. Boot must fail rather than continue with a node
that serves nothing the operator asked for.
""".

-include_lib("kernel/include/logger.hrl").

-define(KEY, {?MODULE, listeners}).

-export([init/0]).
-export([start/1]).
-export([stop/0]).
-export([suspend/0]).
-export([resume/0]).
-export([listeners/0]).
-export([listener/1]).
-export([connections/0]).
-export([connections/1]).
-export([tls_listeners/0]).
-export([http_listeners/0]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Resolves and caches the listener inventory. Raises on any configuration error.
""".
-spec init() -> ok | no_return().

init() ->
    %% Read through `bondy_config` rather than `application:get_env/3`: the
    %% per-listener option blocks are only reachable that way (app_config caches
    %% application env into persistent_term and `bondy_config:get/2` reads the
    %% cache), so taking the inventory from the same accessor keeps one source of
    %% truth. `bondy_config:init/1` populates the cache before calling this.
    Inventory = bondy_config:get(
        listeners, bondy_listener_config:default_inventory()
    ),
    case bondy_listener_config:resolve(Inventory, fun bondy_config:get/2) of
        {ok, Listeners} ->
            _ = persistent_term:put(?KEY, Listeners),
            ok = log_inventory(Listeners);
        {error, Reason} ->
            ?LOG_ERROR(#{
                description => "Invalid listener configuration",
                reason => Reason
            }),
            error(Reason)
    end.

-doc "Starts the listeners in `Phase` (`early`, `normal`, or `all`).".
-spec start(early | normal | all) -> ok | {error, term()}.

start(Phase) ->
    Selected = [L || L <- listeners(), in_phase(Phase, L)],
    fold_until_error(fun bondy_listener:start/1, Selected).

-spec stop() -> ok.
stop() ->
    _ = [bondy_listener:stop(L) || L <- listeners()],
    ok.

-spec suspend() -> ok.
suspend() ->
    _ = [bondy_listener:suspend(L) || L <- listeners()],
    ok.

-spec resume() -> ok.
resume() ->
    _ = [bondy_listener:resume(L) || L <- listeners()],
    ok.

-spec listeners() -> [bondy_listener_config:t()].
listeners() ->
    persistent_term:get(?KEY, []).

-spec listener(atom()) -> {ok, bondy_listener_config:t()} | {error, not_found}.
listener(Name) ->
    case [L || #{name := N} = L <- listeners(), N =:= Name] of
        [L | _] -> {ok, L};
        [] -> {error, not_found}
    end.

-spec connections() -> [pid()].
connections() ->
    lists:append([bondy_listener:connections(L) || L <- listeners()]).

-doc """
Connections of one listener. Distinct from `connections/0` because a caller
that wants the connections of a *named* listener cannot filter the aggregate:
the pids carry no listener identity. Returns `[]` for an unknown name, matching
`bondy_listener:connections/1` on a listener that is not running.
""".
-spec connections(atom()) -> [pid()].
connections(Name) ->
    case listener(Name) of
        {ok, L} -> bondy_listener:connections(L);
        {error, not_found} -> []
    end.

-doc """
Names of the listeners that terminate TLS. Replaces the hardcoded list
`bondy_cert_manager` carried, so a new TLS listener needs no code change.
""".
-spec tls_listeners() -> [atom()].
tls_listeners() ->
    [
        Name
     || #{name := Name, transport := T} <- listeners(),
        T =:= tls orelse T =:= quic
    ].

-doc "Names of the listeners serving HTTP.".
-spec http_listeners() -> [atom()].
http_listeners() ->
    [Name || #{name := Name, protocol := http} <- listeners()].

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
in_phase(all, _) -> true;
in_phase(Phase, #{start_phase := Phase}) -> true;
in_phase(_, _) -> false.

%% @private
fold_until_error(_Fun, []) ->
    ok;
fold_until_error(Fun, [H | T]) ->
    case Fun(H) of
        ok -> fold_until_error(Fun, T);
        {error, _} = Error -> Error
    end.

%% @private
%% One line per listener at boot. The release renders `bondy.conf` with
%% `--allow_extra --silent`, so a consistently mistyped listener NAME is
%% indistinguishable from a deliberate one; printing the resolved inventory is
%% what lets an operator notice it.
log_inventory(Listeners) ->
    _ = [
        ?LOG_NOTICE(#{
            description => "Listener configured",
            listener => maps:get(name, L),
            transport => maps:get(transport, L),
            protocol => maps:get(protocol, L),
            bind => maps:get(bind, L),
            services => maps:get(services, L),
            start_phase => maps:get(start_phase, L),
            enabled => maps:get(enabled, L)
        })
     || L <- Listeners
    ],
    ok.
```

- [ ] **Step 4: Add the transitional default inventory**

The schema does not supply `bondy_router.listeners` until Task 7, and even then
only for an operator who writes `listeners.*` keys, so a release built at this
task would boot with no listeners at all. Add a default to
`bondy_listener_config` reproducing today's nine listeners, so this task is a
pure refactor for a real boot as well as for the test suites.

**This is not scaffolding to be deleted later.** Task 8 promotes it to the
documented legacy path: an absent `bondy_router.listeners` key is exactly the
signal that an operator has not adopted the new block, so this default becomes
the compatibility layer rather than being replaced by one. Name it and document
it accordingly — the nine names it carries are load-bearing, because a
listener's name is its option-block key in the application environment.

```erlang
-export([default_inventory/0]).

-doc """
The listener set Bondy started before listeners became configurable.

TRANSITIONAL: this exists so a boot with no `bondy_router.listeners` behaves
exactly as it did before the inventory was introduced. Once the schema always
supplies an inventory this function is removed, and a node with no listeners
configured starts none.
""".
-spec default_inventory() -> [{atom(), map()}].

default_inventory() ->
    [
        {admin_api_http, #{
            transport => tcp,
            protocol => http,
            port => 18081,
            start_phase => early,
            services => [api_gateway, wamp_ws, admin, metrics]
        }},
        {admin_api_https, #{
            transport => tls,
            protocol => http,
            port => 18084,
            start_phase => early,
            services => [api_gateway, wamp_ws, admin, metrics]
        }},
        {api_gateway_http, #{
            transport => tcp,
            protocol => http,
            port => 18080,
            services => [api_gateway, wamp_ws, wamp_sse, wamp_longpoll]
        }},
        {api_gateway_https, #{
            transport => tls,
            protocol => http,
            port => 18083,
            services => [api_gateway, wamp_ws, wamp_sse, wamp_longpoll]
        }},
        {wamp_tcp, #{
            transport => tcp, protocol => wamp_rawsocket, port => 18082
        }},
        {wamp_tls, #{
            transport => tls, protocol => wamp_rawsocket, port => 18085
        }},
        %% The ninth listener, and the only one disabled by default. That
        %% reproduces today's behaviour exactly: `bondy_wamp_uds:start_listeners/0`
        %% (`bondy_wamp_uds.erl:49-50`) is a no-op unless `[wamp_uds, enabled]`
        %% is `true`, and it defaults to `false`. `path` is that module's
        %% `?DEFAULT_PATH` (`:28`). Omitting this entry would NOT be equivalent:
        %% `bondy_ct` enables the UDS listener (`bondy_ct.erl:337-346`) and
        %% `bondy_connect_transport_uds_SUITE` connects over it.
        {wamp_uds, #{
            transport => uds,
            protocol => wamp_rawsocket,
            path => "/tmp/bondy_wamp.sock",
            enabled => false
        }},
        {bridge_relay_tcp, #{
            transport => tcp, protocol => bridge_relay, port => 18086
        }},
        {bridge_relay_tls, #{
            transport => tls, protocol => bridge_relay, port => 18087
        }}
    ].
```

Take each port from the corresponding legacy mapping's default in
`schema/bondy.schema` and `schema/bondy_bridge_relay.schema` rather than the
numbers above — grep the legacy `*.port` mapping for each listener and use its
`{default, N}`. `wamp_uds` is deliberately absent: it was opt-in and disabled by
default, so no default entry reproduces its behaviour.

- [ ] **Step 5: Rewire `bondy_app`**

Replace `bondy_app.erl:111` and `:113` with:

```erlang
                ok ?= start_early_listeners(),
                %% Finally we allow clients to connect
                ok ?= start_normal_listeners(),
```

Replace `start_admin_listeners/0` (`:333-338`) and `start_public_listeners/0`
(`:341-367`) with:

```erlang
%% @private
%% Listeners marked `start_phase => early' come up first so the liveness
%% (`/ping'), readiness (`/ready') and metrics paths answer while
%% `bondy_config:get(status)' is still `initialising'.
start_early_listeners() ->
    %% The inventory was resolved during `bondy_config:init/1`, which had to
    %% happen there because `bondy_cert_manager:init/0` and `setup_wamp/0` both
    %% consume it.
    ?LOG_NOTICE(#{description => "Starting early-phase listeners"}),
    bondy_listener_manager:start(early).

%% @private
start_normal_listeners() ->
    ?LOG_NOTICE(#{description => "Starting listeners"}),

    %% WAMP in-VM (local) transport: register the router-side adapter so a
    %% co-located bondy_connect_sdk client can use `transport => local'. On a peer
    %% node (no bondy app) no handler is registered and local is unavailable.
    ok = bondy_connect_local:register_handler(bondy_connect_local_handler),

    ok = bondy_listener_manager:start(normal),

    %% We flag the status, the HTTP /ready path will now return true.
    ok = bondy_config:set(status, ready),

    %% Bondy Router Bridge Relay (client) connections
    bondy_bridge_relay_manager:start_bridges().
```

Replace `suspend_listeners/0` (`:459-483`) and `stop_listeners/0` (`:485-505`):

```erlang
suspend_listeners() ->
    %% We stop accepting new connections on all listeners.
    %% Existing connections are unaffected.
    ?LOG_NOTICE(#{
        description =>
            "Suspending all client listeners. "
            "No new connections will be accepted from now on."
    }),
    bondy_listener_manager:suspend().

stop_listeners() ->
    %% We force all listeners to stop.
    %% All existing connections will be terminated.
    ?LOG_NOTICE(#{description => "Terminating all client connections."}),
    ok = bondy_listener_manager:stop(),
    bondy_connect_local:unregister_handler().
```

- [ ] **Step 6: Strip `bondy_http_gateway` and delete the two transport modules**

In `bondy_http_gateway.erl` delete: the four listener macros (`:102-105`), the
`listener()` type (`:121-125`), the ten lifecycle exports and functions
(`:135-143`, `:169-232`), `do_start_listeners/1`, `do_suspend_listeners/1`,
`do_resume_listeners/1`, `do_stop_listeners/1` (`:532-617`),
`start_listener/1`, `start_admin_listener/1`, `maybe_start_http/2`,
`start_http/2`, `maybe_start_https/2`, `start_https/2`,
`listener_protocol_opts/2` (`:753-884`), `rebuild_dispatch_table/2` (`:959-976`),
`listener_transport_opts/1` (`:1106-1156`), `admin_spec/0`, `parse_specs/2`,
`compile_dispatch/2`, and the `?DISPATCH_KEY` macro.

Task 4 deliberately left these two behind, because their callers were still
alive; delete them now, in this order:

- `admin_base_routes/0` (`:1023-1033`) — its only caller is
  `do_start_listeners(admin)` at `:554`, which you are deleting above.
- `base_routes/0` (`:995-1020`) — used by `load_dispatch_tables/0` at `:939`,
  `:945` and `:946`. Change those three uses to pass `[]`, so the function
  becomes `bondy_http_gateway_api_spec_parser:dispatch_table(Parsed, [])` and
  the empty-result fallback returns `[{~"http", []}, {~"https", []}]`.

That last change is what removes the transitional **double-count** Task 4
introduced: from Task 4 until now, `load_dispatch_tables/0` appended
`base_routes()` while the `websocket`/`sse`/`longpoll` carriers contributed the
same paths. After this change the carriers are the only source of them. Verify
it: a listener declaring `api_gateway` plus `wamp_ws` must yield exactly one
`/ws` route, not two.

Rewrite `rebuild_dispatch_tables/0` to iterate the inventory:

```erlang
-doc """
Rebuilds the Cowboy dispatch table of every HTTP listener that exposes the
API Gateway.

A listener that does not include the `api_gateway` service has no
specification-derived routes, so a specification change cannot affect it.
""".
rebuild_dispatch_tables() ->
    ?LOG_NOTICE(#{description => "Rebuilding HTTP Gateway dispatch tables"}),
    _ = [
        bondy_listener_ranch:recompile_dispatch(L)
     || L <- bondy_listener_manager:listeners(),
        maps:get(protocol, L) =:= http,
        lists:member(api_gateway, maps:get(services, L))
    ],
    ok.
```

Export `recompile_dispatch/1` from `bondy_listener_ranch` as a synonym for its
private `compile_dispatch/1`.

Delete `apps/bondy_router/src/bondy_wamp_tcp.erl` and
`apps/bondy_router/src/bondy_wamp_uds.erl`.

Their callers are **not** confined to `bondy_app`, and not all of them are
connection queries. Three live call sites, two of them in a *different
application*, so the suite list in Step 9 cannot catch them — `bondy_connect_sdk`
compiles against `bondy_router` and a missing function is a compile error there,
not a test failure here:

| Call site | Replace with |
|---|---|
| `bondy_app.erl:346,349,475,476,498,499` | delete the calls (the manager starts/stops/suspends these) |
| `apps/bondy_connect_sdk/test/bondy_connect_resilience_SUITE.erl:723,732` — `bondy_wamp_tcp:tcp_connections()` | `bondy_listener_manager:connections(wamp_tcp)` |
| `apps/bondy_connect_sdk/test/bondy_connect_transport_uds_SUITE.erl:110` — `bondy_wamp_uds:path()` | see below |

Use `connections/1`, **not** `connections/0`, for the resilience suite. It takes
a set difference of the connection list across a connect to identify the new
server-side handler pid (`connect_and_server/1`, `new_server_conn/2`); pids carry
no listener identity, so an aggregate over all nine listeners would let a
connection arriving on any other listener be returned as "the" new pid.

For the UDS path, take the bind from the inventory rather than reintroducing an
accessor — the listener map already carries it:

```erlang
connect() ->
    {ok, #{bind := {path, Path}}} =
        bondy_listener_manager:listener(wamp_uds),
    {ok, Conn} = bondy_connect_client:connect(#{
        transport => uds,
        endpoint => {local, Path},
```

Also update that suite's moduledoc (`:10-11`), which names `bondy_wamp_uds:path/0`.

Do not edit anything under `apps/bondy_connect_sdk/_build/` — `grep` will show
copies of both suites there (e.g.
`apps/bondy_connect_sdk/_build/test/lib/bondy_connect_sdk/test/`). They are build
artifacts of a nested rebar3 build and are regenerated from the sources above.

Now that bridge-relay listeners have inventory entries (Step 4), migrate them and
delete the old driver. In `bondy_bridge_relay_manager.erl`, its
`start_listeners/0`, `stop_listeners/0`, `suspend_listeners/0` and
`resume_listeners/0` (`:177-199`) currently call `bondy_ranch_listener` for
`?TCP`/`?TLS` (`:24-25`). The manager now starts those listeners along with every
other, so delete all four functions and their calls from `bondy_app`. Keep
`start_bridges/0` — outbound bridges are clients, not listeners, and are
unaffected.

Then delete `apps/bondy_router/src/bondy_ranch_listener.erl`. Confirm nothing
references it:

```
grep -rn "bondy_ranch_listener" apps/ --include="*.erl"
```

Expected: no output.

- [ ] **Step 7: Derive the two remaining hardcoded lists**

In `bondy_cert_manager.erl`, delete `?TLS_LISTENERS` (`:47-51`) and replace its
uses with `bondy_listener_manager:tls_listeners()`. Change `listener_ref/0`
(`:76-81`) to `-type listener_ref() :: atom().`

In `bondy_config.erl:451-456`, replace the four literal paths:

```erlang
    Keys = [
        [Name, protocol_opts, dynamic_buffer]
     || Name <- bondy_listener_manager:http_listeners()
    ],
```

**Then fix the ordering, which is the load-bearing part of this step.** Both
`?TLS_LISTENERS` and the `dynamic_buffer` list are consumed during
`bondy_config:init/1`, so the manager must be resolved *inside* that function —
not later in `bondy_app`:

- `bondy_config:init/1` calls `app_config:init/2` at `:243`, which caches
  application env into persistent_term. Nothing before that line can read
  configuration.
- It calls `bondy_cert_manager:init/0` at `:245`, which calls
  `load_all_server_certs/0` (`bondy_cert_manager.erl:416`) and
  `load_all_client_auth/0` (`:618`) — **both iterate `?TLS_LISTENERS`**. If the
  manager is not resolved by then, `tls_listeners/0` returns `[]` and no server
  certificate or mTLS configuration is loaded for any TLS listener, silently.
- It calls `setup_wamp/0` at `:247`, which needs `http_listeners/0`.

So insert the call between `app_config:init/2` and `bondy_cert_manager:init/0`:

```erlang
    %% We read bondy env and cache the values
    ok = app_config:init(?BONDY, #{callback_mod => ?MODULE}),

    %% Resolve the listener inventory before anything consumes it:
    %% `bondy_cert_manager:init/0` below loads server certificates and client
    %% auth per TLS listener, and `setup_wamp/0` normalises `dynamic_buffer` per
    %% HTTP listener. Both ask the manager which listeners exist.
    ok = bondy_listener_manager:init(),

    ok = bondy_cert_manager:init(),
```

Leave `setup_wamp/0` where it is; it keeps its single job and simply derives its
key list from the manager. `bondy_app:start_early_listeners/0` then calls only
`bondy_listener_manager:start(early)` — **not** `init/0`, which has already run.

- [ ] **Step 8: Add the inventory to `bondy_ct`**

`bondy_ct` sets listener config as app env keyed by listener name (`:284-528`)
because test boots never render cuttlefish. Those per-name option blocks are what
the resolver reads through `bondy_config:get/2`, so leave them exactly as they
are and add only the inventory.

Do not retype the listener list — it would then exist in two places and drift.
Derive it from the transitional default and override only the ports to match the
option blocks already in `bondy_ct`:

```erlang
%% The inventory mirrors `bondy_listener_config:default_inventory/0`; only the
%% bind target and `enabled` differ, because the suites bind the ports the
%% option blocks below already declare.
listener_inventory() ->
    [
        {Name, ct_bind(Name, Spec)}
     || {Name, Spec} <- bondy_listener_config:default_inventory()
    ].

%% @private
%% `wamp_uds` is bound by path, not port, and is the one listener
%% `default_inventory/0` ships disabled. `bondy_ct` enables it and overrides the
%% path, because `bondy_connect_transport_uds_SUITE` connects over it and
%% parallel CT runs share /tmp.
ct_bind(wamp_uds, Spec) ->
    Spec#{path => "/tmp/bondy_ct_wamp_uds.sock", enabled => true};
ct_bind(Name, Spec) ->
    Spec#{port => ct_port(Name)}.
```

Write `ct_port/1` with one clause per port-bound listener, taking each number
from the `socket_opts.port` value already present in that listener's block at
`:284-528`. If a port-bound listener in `default_inventory/0` has no block
there, omit it from the inventory rather than inventing a port.

Add `{listeners, listener_inventory()}` to the `bondy_router` env `bondy_ct`
sets.

**Then fix `node_env/2` (`:1234-1256`), which this task silently breaks.** It
disables every client listener on a CT *peer* node by setting
`[bondy_router, <Name>, enabled]` to `false` for the nine listener names,
because — per its own comment — they are "irrelevant to AAE and would clash
across same-host nodes". Those nine flags become **inert** under the manager:
`bondy_listener_config:resolve_one/3` reads `enabled` from the inventory *spec
map* (`enabled => maps:get(enabled, Spec, true)`), never through `GetFun`, so
nothing consults `[bondy_router, <Name>, enabled]` any more. Every peer node
would then start all nine listeners on the same host and collide on every port.

Replace the nine-name fold with an empty inventory, which states the same intent
directly and cannot drift as listeners are added or renamed:

```erlang
%% No listeners on a peer node: they are irrelevant to AAE and would clash on
%% every port with the primary node's, which share this host. Setting the
%% inventory empty is what disables them — a per-listener `enabled` flag in the
%% option blocks is not read (`bondy_listener_config` takes `enabled` from the
%% inventory spec, not from config).
E3 = key_value:set([bondy_router, listeners], [], E2),
```

Delete the now-unused `Disabled` list and the fold that consumed it.

- [ ] **Step 9: Run the new suite, then existing ones**

Run:
```
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_listener_SUITE.erl
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_http_api_gateway_SUITE.erl
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_http_security_headers_SUITE.erl
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_bridge_relay_sync_SUITE.erl
```
Expected: all PASS. The last three are the falsification target for this task —
they exercised the deleted hardcoded listeners, so if the inventory is not a
faithful reproduction they fail. The bridge-relay suite specifically proves the
migration of `bridge_relay_tcp`/`bridge_relay_tls` onto the inventory.

Then compile the `bondy_connect_sdk` suites, which is the *only* check that catches
the two cross-app call sites from Step 6 — they are compile errors in another
application, invisible to every command above:

```
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct \
  --suite=apps/bondy_connect_sdk/test/bondy_connect_transport_uds_SUITE.erl
```

Expected: PASS. This suite is the falsification target for the `wamp_uds`
inventory entry: it connects over the live UDS listener, so it fails if the
entry is missing, disabled, or bound to a different path than `bondy_ct`
configures. If `bondy_connect_sdk`'s own suites cannot be run from this build, at
minimum compile them and report which command you used — do not report the
call-site changes as verified on the strength of a grep.

- [ ] **Step 10: Format and checkpoint**

Report: manager added, `bondy_wamp_tcp`, `bondy_wamp_uds` and
`bondy_ranch_listener` deleted, `bondy_http_gateway` reduced to specs and
storage, three hardcoded lists derived. Name the three suites that passed.

---

### Task 6b: The built-in Admin API, the reserved admin listener, and the local safety net

Task 6 left the built-in HTTP Admin API served nowhere. `do_start_listeners(admin)`
used to parse `priv/specs/bondy_admin_api.json` inline and mount it on the admin
listeners only; that call site is gone and nothing stores the spec, so its ~38
paths (`/realms`, `/realms/:realm_uri/users`, `/grants`, `/sources`,
`/services/create_backup`, `/api_specs`, …) are unreachable. The file still ships
in `priv/`, referenced by no module. No suite exercises those paths, so this is
invisible to CI.

Task 6 also gave both admin listeners `services => [api_gateway, …]`, so they
serve every *stored* specification — which they never did before.

This task restores the disjoint split and makes the administrable endpoint
impossible for an operator to remove. See design §2.9 and §3.1.

**Files:**
- Modify: `apps/bondy_router/src/bondy_http_gateway.erl` (add `admin_api_routes/1`, restore `admin_spec/0`)
- Modify: `apps/bondy_router/src/bondy_http_services.erl` (add the `admin_api` service)
- Modify: `apps/bondy_router/src/bondy_listener_config.erl` (reserved-name rules)
- Modify: `apps/bondy_router/src/bondy_listener_manager.erl` (inject the reserved entries)
- Modify: `apps/bondy_router/test/bondy_http_services_test.erl`
- Modify: `apps/bondy_router/test/bondy_listener_config_test.erl`
- Create: `apps/bondy_router/test/bondy_admin_listener_SUITE.erl`

**Interfaces:**
- Consumes: `bondy_listener_config:resolve/2`, `service_spec/1`;
  `bondy_listener_manager:listener/1`, `listeners/0`;
  `bondy_http_gateway_api_spec_parser:parse/1`, `dispatch_table/2`.
- Produces: `bondy_http_gateway:admin_api_routes(bondy_listener_config:t()) -> [{string(), module(), map()}]`;
  the `admin_api` service name; the reserved listener names `admin` and
  `admin_local`.

- [ ] **Step 1: Write the failing resolver tests**

Add to `apps/bondy_router/test/bondy_listener_config_test.erl`. Both cases are
rejections — the point of the reserved names is that certain configurations are
refused:

```erlang
admin_listener_cannot_be_disabled_test() ->
    %% `enabled => false` on the reserved name is the exact configuration that
    %% would leave a node unadministrable, so it is refused rather than honoured.
    ?assertMatch(
        {error, {invalid_listener, admin, reserved_cannot_be_disabled}},
        bondy_listener_config:resolve(
            [
                {admin, #{
                    transport => tcp,
                    protocol => http,
                    port => 18081,
                    enabled => false,
                    services => [admin_api, admin]
                }}
            ],
            fun(_K, D) -> D end
        )
    ).

operator_cannot_define_admin_local_test() ->
    %% `listeners.$name` is a cuttlefish FUZZY mapping, so
    %% `listeners.admin_local.transport` is accepted by the schema and reaches
    %% the inventory. Rejecting it explicitly is what stops an operator's block
    %% being silently overridden by the injected internal listener.
    ?assertMatch(
        {error, {invalid_listener, admin_local, reserved_name}},
        bondy_listener_config:resolve(
            [
                {admin_local, #{
                    transport => tcp, protocol => http, port => 19999,
                    services => [admin]
                }}
            ],
            fun(_K, D) -> D end
        )
    ).
```

- [ ] **Step 2: Run them to verify they fail**

Run:
```
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test eunit --module=bondy_listener_config_test
```
Expected: the two new cases FAIL. `admin_listener_cannot_be_disabled_test` fails
because `resolve/2` currently returns `{ok, _}` — nothing rejects it.

Count the `_test() ->` functions in the file and report that number. Never delete
a test to make a count match.

- [ ] **Step 3: Add the reserved-name rules to the resolver**

`admin_local` is internal, so an operator naming it is an error. `admin` may be
overridden but not disabled.

```erlang
-define(RESERVED_INTERNAL, [admin_local]).
-define(RESERVED_NAMES, [admin, admin_local]).
```

In `resolve_one/3`, before anything else:

```erlang
resolve_one(Name, Spec, GetFun) ->
    ok = assert_reserved(Name, Spec),
    ...
```

```erlang
%% @private
%% `admin_local' is injected by `bondy_listener_manager' and has no
%% `listeners.$name' mappings, but `listeners.$name' is a cuttlefish fuzzy
%% mapping, so an operator CAN write `listeners.admin_local.transport' and have
%% it reach the inventory. Rejecting the name is what turns that into a
%% diagnosable error instead of a block that is silently discarded.
assert_reserved(Name, _Spec) when Name == admin_local ->
    invalid(Name, reserved_name);
assert_reserved(admin, #{enabled := false}) ->
    invalid(admin, reserved_cannot_be_disabled);
assert_reserved(_Name, _Spec) ->
    ok.
```

Export the two name lists so the manager and the schema task can use them
without retyping:

```erlang
-export([reserved_names/0]).

-doc """
Listener names an operator may not use freely: `admin` may be overridden but
not removed or disabled, `admin_local` is internal.
""".
-spec reserved_names() -> [atom()].
reserved_names() -> ?RESERVED_NAMES.
```

- [ ] **Step 4: Run the resolver tests to verify they pass**

Run the same command as Step 2. Expected: PASS, with the count from Step 2 plus
the two new cases.

- [ ] **Step 5: Restore the built-in Admin API spec as routes**

In `bondy_http_gateway.erl`, add `admin_api_routes/1` beside the existing
`routes/1` and export it. It mirrors `routes/1` exactly except that it parses one
specification from `priv/` rather than reading the stored dispatch tables:

```erlang
-doc """
Routes compiled from the built-in Admin API specification, for one listener.

Distinct from `routes/1`, which returns the routes of every specification stored
in `bondy_db`. This specification ships in `priv/` and is mounted only on
listeners that declare the `admin_api` service, which is what keeps realm, user,
grant and backup administration off a listener that declares only
`api_gateway`.
""".
-spec admin_api_routes(bondy_listener_config:t()) ->
    [{string(), module(), map()}].

admin_api_routes(Listener) ->
    Scheme = scheme(maps:get(transport, Listener)),
    Spec = bondy_http_gateway_api_spec_parser:parse(admin_spec()),
    ok = maybe_init_groups(maps:get(~"realm_uri", Spec)),
    %% No base routes: the service route sets in `bondy_http_services' supply
    %% those, and each is mounted by naming its own service.
    Tables = bondy_http_gateway_api_spec_parser:dispatch_table([Spec], []),
    case lists:keyfind(Scheme, 1, Tables) of
        {Scheme, Rules} -> flatten_rules(Rules);
        false -> []
    end.
```

Restore `admin_spec/0` as it was before Task 6 deleted it — read it back with
`git show 8100c86d~1:apps/bondy_router/src/bondy_http_gateway.erl` and copy the
function verbatim, including its `exit(enoent)` and `exit(invalid_json_format)`
branches. It is mandatory, not best-effort: a missing or malformed built-in spec
means the node cannot serve its own admin API, which must not degrade silently.

- [ ] **Step 6: Write the failing service test**

Add to `apps/bondy_router/test/bondy_http_services_test.erl`. This asserts the
service is *registered and routed to*, not what the spec contains — the spec's
paths need a booted node and are covered by the CT suite in Step 9:

```erlang
admin_api_is_a_distinct_service_from_api_gateway_test() ->
    %% Both mount HTTP paths, but from different sources: `api_gateway` from
    %% storage, `admin_api` from `priv/`. If they collapsed into one service an
    %% operator could not offer stored specs without also offering the admin
    %% API, which is the exposure this separation prevents.
    ?assertNotEqual(
        bondy_listener_config:service_spec(api_gateway),
        bondy_listener_config:service_spec(admin_api)
    ),
    ?assertMatch(#{carrier := rest}, bondy_listener_config:service_spec(admin_api)).
```

- [ ] **Step 7: Register the service**

Services are registered as clauses of `bondy_listener_config:service_spec/1`,
not in a macro table. Add a clause beside `api_gateway`'s, which reads
`#{carrier => rest, protocol => undefined, module => bondy_http_services}`:

```erlang
service_spec(admin_api) ->
    #{carrier => rest, protocol => undefined, module => bondy_http_services};
```

In `bondy_http_services.erl`, the `rest` carrier currently ignores its protocol
argument entirely — `routes(rest, _Protocols, Listener)` calls
`bondy_http_gateway:routes(Listener)` unconditionally. Both REST services share
this carrier, so `routes/3` must union the two sources and decide each from the
listener's **`services`** list:

```erlang
routes(rest, _Protocols, Listener) ->
    %% Both REST services share this carrier and must be distinguished by
    %% SERVICE, not by protocol: `resolve_carriers/3` builds a carrier's
    %% `protocols` from `service_spec/1`'s `protocol` field, and both
    %% `api_gateway` and `admin_api` declare `undefined` there — so the protocol
    %% set cannot tell them apart. `services` can.
    Services = maps:get(services, Listener),
    Stored =
        case lists:member(api_gateway, Services) of
            true -> bondy_http_gateway:routes(Listener);
            false -> []
        end,
    Admin =
        case lists:member(admin_api, Services) of
            true -> bondy_http_gateway:admin_api_routes(Listener);
            false -> []
        end,
    Stored ++ Admin;
```

Do not change `service_spec(api_gateway)`'s `protocol` to disambiguate instead:
`protocol` feeds the carrier protocol sets that Task 9 uses to restrict WAMP vs
BAMP over a shared carrier, and `rest` carries neither.

- [ ] **Step 8: Run the service tests**

Run:
```
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test eunit --module=bondy_http_services_test
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test eunit --module=bondy_listener_config_test
```
Expected: PASS. Task 4's
`admin_service_set_matches_the_old_admin_base_routes_test` must still pass
unchanged — the `admin` service keeps its three paths; `admin_api` is additive.

- [ ] **Step 9: Inject the reserved listeners in the manager**

In `bondy_listener_manager.erl`, append the reserved entry to the inventory
before resolving. Injection belongs here, not in the resolver: `admin_local`'s
path needs `bondy_config:get(platform_tmp_dir)`, and the resolver is pure.

**Inject `admin_local` only. The port-bound reserved `admin` listener lands in
Task 8, not here.** A listener's name is simultaneously its app-env option-block
key and the Cowboy `ref` that `bondy_http_security_headers` and the cors
configuration read, so renaming a listener relocates its whole configuration and
no alias can bridge it. The legacy `admin_api.http.*` mappings target
`bondy_router.admin_api_http.*`, so introducing a listener named `admin` before
those mappings move would leave an operator's admin tuning — port, acceptors,
backlog, proxy_protocol, cors — pointing at a block nothing reads. It would fail
*silently*, because Task 6 made a missing option block resolve to defaults rather
than crash.

Task 8 resolves this **without renaming anything**: the legacy path keeps the
historical `admin_api_http` name, so its mappings' targets stay correct, and the
reserved `admin` is injected only for an operator who has adopted `listeners.*`.
The two spellings are mutually exclusive, so no port collision arises and no
mapping has to move.

`admin_local` has no such constraint: it is new, no schema key targets it, and it
needs no port, certificate or DNS — which is the half of the guarantee that
survives a botched TLS config, and therefore the half worth landing first.

Keep the reserved-name *validation* from Step 3 (`listeners.admin.enabled = off`
rejected, an operator-supplied `admin_local` rejected). Those are pure, collide
with nothing, and Task 8 depends on them.

```erlang
%% @private
%% An operator-defined inventory can omit every administrable endpoint, so this
%% one is not the operator's to remove: `admin_local` is appended unconditionally
%% and cannot be expressed in `bondy.conf` at all (`assert_reserved/2` rejects
%% the name), so there is no operator value to merge and nothing to override.
with_reserved(Inventory) ->
    Inventory ++ [{admin_local, admin_local_spec()}].

%% @private
%% A Unix domain socket needs no certificate, no DNS and no port, so no
%% `bondy.conf` value can stop it binding — which a reserved NAME alone does not
%% achieve: `listeners.admin.transport = tls` with an unresolvable certfile
%% fails to bind and locks the operator out by a different route.
admin_local_spec() ->
    %% `platform_tmp_dir` (`schema/bondy.schema:6160`), not `platform_data_dir`:
    %% a socket file is ephemeral, is recreated on every boot, and must not sit
    %% among the durable stores. It is also where the listener this replaces put
    %% its socket — `bondy_wamp_uds`'s default path was `/tmp/bondy_wamp.sock`.
    %% There is no `platform_run_dir` in this schema.
    Dir = bondy_config:get(platform_tmp_dir),
    #{
        transport => uds,
        protocol => http,
        path => filename:join(Dir, "bondy_admin.sock"),
        start_phase => early,
        services => [admin_api, admin, wamp_ws, metrics]
    }.
```

Call it in `init/0`: `Inventory = with_reserved(transitional_inventory())` (use
whatever the inventory-producing expression is named after Task 6's fix rounds).

`admin_local` needs a `transport_opts` block like every other listener —
Task 6's defect (3) found that `bondy_config:listener_transport_opts/1` raises
`badarg` without one. Give it one in the same place Task 6 gives the others, with
`socket_opts => [{ip_version, inet}]` and `proxy_protocol => [{enabled, false}]`.
Verify by starting it, not by inspection.

- [ ] **Step 10: Write the CT suite**

Create `apps/bondy_router/test/bondy_admin_listener_SUITE.erl`. Two of the four
cases are the falsification targets for the exposure split — they fail if the
services collapse:

```erlang
%% Case 1: the admin listener serves the built-in Admin API.
admin_api_is_served_on_the_admin_listener(_Config) ->
    %% Asserts NOT 404: the path is routed. Whether it returns 200, 401 or 403
    %% depends on authentication, which this case does not exercise — a 404
    %% would mean the route does not exist at all, which is the regression.
    {ok, Status, _, _} = get_path(admin, "/realms"),
    ?assertNotEqual(404, Status).

%% Case 2: a listener declaring only `api_gateway` does NOT serve it.
admin_api_is_absent_from_the_public_listener(_Config) ->
    {ok, Status, _, _} = get_path(api_gateway_http, "/realms"),
    ?assertEqual(404, Status).

%% Case 3: the reserved listener exists with no `listeners.admin.*` config.
admin_listener_is_injected_when_absent(_Config) ->
    ?assertMatch(
        {ok, #{name := admin, services := Services}}
            when Services =/= [],
        bondy_listener_manager:listener(admin)
    ).

%% Case 4: the safety net is present and bound to a socket file.
admin_local_is_always_present(_Config) ->
    {ok, #{transport := uds, bind := {path, Path}}} =
        bondy_listener_manager:listener(admin_local),
    ?assertEqual(true, filelib:is_file(Path)).
```

Write `get_path/2` to resolve the listener's port from
`bondy_listener_manager:listener/1` rather than hardcoding it, and use the same
HTTP client `bondy_http_verify_SUITE` uses — read that suite for the pattern
rather than inventing one.

Case 4 is the one that proves the guarantee: if `filelib:is_file/1` is false the
socket never bound, and the safety net does not exist.

- [ ] **Step 11: Run the suite and the regression set**

Run each separately:
```
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_admin_listener_SUITE.erl
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_http_verify_SUITE.erl
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_http_security_headers_SUITE.erl
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_listener_SUITE.erl
```
Expected: all PASS.

Then update `bondy_ct`'s inventory: the `admin_api_http`/`admin_api_https`
entries must drop `api_gateway` from their services and gain `admin_api`, or
Case 2's premise (public-only exposure) is not what production will do. State in
your report what those two entries' services are before and after.

- [ ] **Step 12: Format and checkpoint**

Report: which source `Protocols` vs `services` you used in Step 7 and why; the
before/after services of the two admin entries in `bondy_ct`; and the evidence
that `admin_local` actually bound (Case 4), not merely that it appears in the
inventory.

---

### Task 7: Schema — the `listeners.$name.*` block

**Files:**
- Modify: `schema/bondy.schema`
- Create: `apps/bondy_router/test/bondy_listener_schema_SUITE.erl`

**Interfaces:**
- Consumes: nothing at runtime.
- Produces: `bondy_router.listeners` as `[{atom(), map()}]`, where each map
  carries both the inventory keys and that listener's option block nested
  inside it. This is the only app-env key the schema writes.
- Does **not** produce `bondy_router.<name>.*`. Cuttlefish cannot address it
  (see Step 3); Task 7b splats it out of the inventory at boot. Nothing in this
  task makes a listener's options reach `bondy_config:listener_transport_opts/1`,
  so do not claim in a comment or the report that it does.

- [ ] **Step 1: Write the failing test**

Create `apps/bondy_router/test/bondy_listener_schema_SUITE.erl`:

```erlang
%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Renders `bondy.conf` fragments through cuttlefish exactly as the release's
%% pre-start hook does, and asserts on the resulting application environment.
%%
%% This is the only place the schema's behaviour can be checked: cuttlefish runs
%% as a standalone escript BEFORE the VM boots the release, so no runtime code
%% path exercises a translation.
%% =============================================================================
-module(bondy_listener_schema_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([new_style_block_produces_inventory/1]).
-export([omitted_carrier_key_is_absent/1]).
-export([port_has_no_default/1]).

all() ->
    [
        new_style_block_produces_inventory,
        omitted_carrier_key_is_absent,
        port_has_no_default
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(cuttlefish),
    [{schema_dir, "schema"} | Config].

end_per_suite(Config) ->
    Config.

%% Renders `Lines` (a bondy.conf fragment) and returns the generated app env.
render(Config, Lines) ->
    Dir = ?config(priv_dir, Config),
    File = filename:join(Dir, "bondy_" ++ os:getpid() ++ ".conf"),
    ok = file:write_file(File, iolist_to_binary(Lines)),
    Schema = cuttlefish_schema:files(
        filelib:wildcard(filename:join(?config(schema_dir, Config), "*.schema"))
    ),
    Conf = cuttlefish_conf:file(File),
    cuttlefish_generator:map(Schema, Conf).

get_env(AppEnv, App, Key) ->
    proplists:get_value(Key, proplists:get_value(App, AppEnv, []), undefined).

new_style_block_produces_inventory(Config) ->
    AppEnv = render(Config, [
        "listeners.pub.transport = tcp\n",
        "listeners.pub.protocol = http\n",
        "listeners.pub.port = 18080\n",
        "listeners.pub.services = api_gateway, wamp_ws\n"
    ]),
    Inventory = get_env(AppEnv, bondy_router, listeners),
    ?assertMatch([{pub, #{transport := tcp, protocol := http}}], Inventory),
    [{pub, Spec}] = Inventory,
    ?assertEqual(18080, maps:get(port, Spec)),
    ?assertEqual([api_gateway, wamp_ws], maps:get(services, Spec)),
    %% The option block lands at the shape every existing consumer reads.
    Block = proplists:get_value(pub, proplists:get_value(bondy_router, AppEnv)),
    ?assertEqual(
        18080,
        key_value:get(
            [transport_opts, socket_opts, port], Block, undefined
        )
    ).

omitted_carrier_key_is_absent(Config) ->
    %% The regression guard for the default-free rule. If any
    %% `listeners.$name.*` mapping gains a `{default, ...}`,
    %% `cuttlefish_generator:add_fuzzy_default/4` materialises it for EVERY
    %% listener name, the key becomes always-present, and the global
    %% `wamp.websocket.*` fallback silently dies.
    AppEnv = render(Config, [
        "listeners.pub.transport = tcp\n",
        "listeners.pub.protocol = http\n",
        "listeners.pub.port = 18080\n",
        "listeners.pub.services = wamp_ws\n"
    ]),
    Block = proplists:get_value(pub, proplists:get_value(bondy_router, AppEnv)),
    ?assertEqual(
        undefined, key_value:get([websocket, idle_timeout], Block, undefined)
    ).

port_has_no_default(Config) ->
    %% A default port would silently collide across listeners, so `port` must be
    %% absent when unset and rejected by the resolver rather than guessed.
    AppEnv = render(Config, [
        "listeners.pub.transport = tcp\n",
        "listeners.pub.protocol = http\n",
        "listeners.pub.services = wamp_ws\n"
    ]),
    [{pub, Spec}] = get_env(AppEnv, bondy_router, listeners),
    ?assertNot(maps:is_key(port, Spec)).
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_listener_schema_SUITE.erl`
Expected: FAIL — no `listeners` key in the rendered env.

- [ ] **Step 3: Add the mappings**

Add to `schema/bondy.schema`, before the legacy `admin_api.*` block. **No
mapping below carries `{default, ...}`.**

```erlang
%% =============================================================================
%% LISTENERS
%% =============================================================================
%% Operator-defined listeners. Each `listeners.$name' block is one socket.
%%
%% NOTE: no mapping in this section may declare a `{default, ...}'.
%% cuttlefish materialises a $name mapping's default for EVERY name mentioned
%% under the `listeners' prefix (cuttlefish_generator:add_fuzzy_default/4),
%% which would (a) make the global `wamp.<carrier>.*' fallback permanently
%% dead, and (b) materialise stream-socket keys on a `quic' listener so that
%% the resolver's applicability check fires on values nobody wrote. Defaults
%% live in bondy_listener_config, per driver.

%% @doc The transport the listener binds. Selects the listener DRIVER: `tcp',
%% `tls' and `uds' are ranch stream listeners; `quic' is served by
%% cowboy:start_quic/3, which creates no ranch listener and shares none of the
%% stream-socket options.
{mapping, "listeners.$name.transport", "bondy_router.listeners", [
  {datatype, {enum, [tcp, tls, uds, quic]}}
]}.

%% @doc What frames the wire. `http' takes a `services' list; a raw-socket
%% protocol carries exactly one protocol and takes none.
{mapping, "listeners.$name.protocol", "bondy_router.listeners", [
  {datatype, {enum, [http, wamp_rawsocket, bamp_rawsocket, bridge_relay]}}
]}.

%% @doc The TCP/UDP port. Required for tcp, tls and quic. Deliberately has no
%% default: a default would silently collide between listeners.
{mapping, "listeners.$name.port", "bondy_router.listeners", [
  {datatype, integer}
]}.

%% @doc Filesystem path for a `uds' listener, instead of a port.
{mapping, "listeners.$name.path", "bondy_router.listeners", [
  {datatype, file}
]}.

%% @doc Comma-separated services reachable on this listener. Valid only when
%% protocol = http. Each entry names a protocol over a carrier, so BAMP can be
%% offered over WebSocket without also offering WAMP.
{mapping, "listeners.$name.services", "bondy_router.listeners", [
  {datatype, string}
]}.

%% @doc Whether the listener starts. Absent means enabled.
{mapping, "listeners.$name.enabled", "bondy_router.listeners", [
  {datatype, flag}
]}.

%% @doc `early' starts the listener before any `normal' one and while the node
%% still reports `initialising', so liveness and readiness probes answer before
%% clients are accepted. Absent means `normal'.
{mapping, "listeners.$name.start_phase", "bondy_router.listeners", [
  {datatype, {enum, [early, normal]}}
]}.

{translation, "bondy_router.listeners", fun(Conf0) ->
    Conf = cuttlefish_variable:filter_by_prefix("listeners", Conf0),

    Add = fun(Name0, Key, Value, Acc) ->
        Name = list_to_atom(Name0),
        Update = #{Key => Value},
        maps:update_with(
            Name,
            fun(Spec) -> maps:merge(Spec, Update) end,
            Update,
            Acc
        )
    end,

    Specs = lists:foldl(
        fun
            ({["listeners", Name, "transport"], V}, Acc) ->
                Add(Name, transport, V, Acc);
            ({["listeners", Name, "protocol"], V}, Acc) ->
                Add(Name, protocol, V, Acc);
            ({["listeners", Name, "port"], V}, Acc) ->
                Add(Name, port, V, Acc);
            ({["listeners", Name, "path"], V}, Acc) ->
                Add(Name, path, V, Acc);
            ({["listeners", Name, "enabled"], V}, Acc) ->
                Add(Name, enabled, V, Acc);
            ({["listeners", Name, "start_phase"], V}, Acc) ->
                Add(Name, start_phase, V, Acc);
            ({["listeners", Name, "services"], V}, Acc) ->
                Services = [
                    list_to_atom(string:trim(S))
                 || S <- string:tokens(V, ","), string:trim(S) =/= ""
                ],
                Add(Name, services, Services, Acc);
            ({_, _}, Acc) ->
                %% Every other listeners.$name.* key is an option block read
                %% through bondy_config:get/2, not part of the inventory.
                Acc
        end,
        maps:new(),
        Conf
    ),

    maps:to_list(Specs)
end}.
```

Then add the per-listener option-block mappings.

**Every one of them targets the single fixed key `"bondy_router.listeners"`.**
Cuttlefish substitutes a fuzzy match into the conf-file *variable* only, never
into the mapping *target*: `cuttlefish_generator.erl:153` tokenises the target
string as written and `set_value/3` (`:257-267`) calls `list_to_atom/1` on each
token, so `"bondy_router.$name.transport_opts..."` writes to the literal atom
`'$name'`. Probed end-to-end through `cuttlefish_schema:files/1` →
`cuttlefish_generator:map/2` with two listeners:

```erlang
{'$name',[{websocket,[{idle_timeout,undefined}]},
          {transport_opts,[{socket_opts,[{backlog,undefined}]}]}]}
```

One literal `'$name'` key, every value `undefined`, every operator-set option
silently discarded. Every existing fuzzy block in this repository already works
around this the same way — `bridge.$name.endpoint`,
`broker_bridge.kafka.clients.$name.*` — one fixed target plus a translation.

So the option block is carried *inside the inventory value*, and the translation
places each key. Extend the `Specs` fold to route every non-inventory key to its
path within that listener's spec, using this table. `Spec` paths below are
relative to the listener's map; the leading segment is the app-env key the splat
in Task 7b will write to `bondy_router.<name>.<segment>`:

| conf key (`listeners.$name.`…) | Spec path |
|---|---|
| `acceptors_pool_size` | `transport_opts.num_acceptors` |
| `max_connections` | `transport_opts.max_connections` |
| `backlog`, `keepalive`, `nodelay`, `sndbuf`, `recbuf`, `buffer`, `reuseport`, `linger.timeout` | `transport_opts.socket_opts.<key>` |
| `ip_version` | `transport_opts.socket_opts.ip_version` |
| `proxy_protocol` | `proxy_protocol.enabled` |
| `proxy_protocol.mode` | `proxy_protocol.mode` |
| `http.<key>` (the 23 of group 2) | `protocol_opts.<key>` |
| `tls.<key>` | `tls.<key>` |
| `websocket.*`, `sse.*`, `longpoll.*` | `<carrier>.<key>` |
| `server_header` | `server_header` |

**`ip` is an inventory key, not a socket option.**
`bondy_listener_config:resolve_ip/3` reads `ip` from the spec and the resolved
type wants an `inet:ip_address()` tuple, so the translation must parse the
string — `inet:parse_address/1` — and place it at `ip`, top level, beside
`transport` and `protocol`. Do not put it under `transport_opts.socket_opts`.

**`cors.*` and `security_headers.*` are not leaf keys.** Each is consumed as one
map — `bondy_http_cors:config_from_req/1` reads `bondy_config:get([Ref, cors], …)`
and `bondy_http_security_headers:init/1` reads `[ListenerName, security_headers]`
— and today each listener has its own aggregating translation for them
(`schema/bondy.schema:2485`, `:2560`). The `listeners` translation must build
those two maps and place them at `cors` and `security_headers`, mirroring what
those per-listener translations produce. Read one of them before writing this.

Note on group 2's `http.` prefix: it is no longer *forced* by cuttlefish, since
one translation can now route a key anywhere. It is kept deliberately, so one
conf key has one meaning — routing a bare `idle_timeout` to two different
places depending on the listener's protocol would make the key's effect
depend on a sibling key, and the translation would have to become
protocol-aware. Keep the prefix; the earlier "one mapping has one target"
justification no longer applies and should not be repeated.

The example mappings below show the shape; note the identical target on each:

```erlang
{mapping, "listeners.$name.acceptors_pool_size", "bondy_router.listeners", [
  {datatype, integer}
]}.

{mapping, "listeners.$name.max_connections", "bondy_router.listeners", [
  {datatype, integer}
]}.

{mapping, "listeners.$name.backlog", "bondy_router.listeners", [
  {datatype, integer}
]}.

{mapping, "listeners.$name.ip", "bondy_router.listeners", [
  {datatype, string}
]}.

{mapping, "listeners.$name.keepalive",
"bondy_router.listeners", [
  {datatype, flag}
]}.

{mapping, "listeners.$name.nodelay",
"bondy_router.listeners", [
  {datatype, flag}
]}.

{mapping, "listeners.$name.tls.certfile", "bondy_router.listeners", [
  {datatype, file}
]}.

{mapping, "listeners.$name.tls.keyfile", "bondy_router.listeners", [
  {datatype, file}
]}.

{mapping, "listeners.$name.tls.cacertfile",
"bondy_router.listeners", [
  {datatype, file}
]}.

{mapping, "listeners.$name.tls.verify", "bondy_router.listeners", [
  {datatype, {enum, [verify_none, verify_peer]}}
]}.

{mapping, "listeners.$name.tls.versions", "bondy_router.listeners", [
  {datatype, string}
]}.

{mapping, "listeners.$name.websocket.idle_timeout",
"bondy_router.listeners", [
  {datatype, {duration, ms}}
]}.

{mapping, "listeners.$name.websocket.max_frame_size",
"bondy_router.listeners", [
  {datatype, [bytesize, {atom, infinity}]}
]}.

{mapping, "listeners.$name.websocket.compression_enabled",
"bondy_router.listeners", [
  {datatype, flag}
]}.

{mapping, "listeners.$name.sse.idle_timeout",
"bondy_router.listeners", [
  {datatype, {duration, ms}}
]}.

{mapping, "listeners.$name.longpoll.idle_timeout",
"bondy_router.listeners", [
  {datatype, {duration, ms}}
]}.

{mapping, "listeners.$name.longpoll.poll_timeout",
"bondy_router.listeners", [
  {datatype, {duration, ms}}
]}.
```

The mappings above are the subset the tests cover. Complete the set
mechanically — this is a transcription, not a design step. For each legacy
mapping in these four ranges:

- `api_gateway.http.*` — `schema/bondy.schema:3173-3644` (51 mappings)
- `wamp.tcp.*` — `:4993-5210` (21 mappings)
- `wamp.websocket.*` — `:4624-4857` (17 mappings)
- `wamp.longpoll.*` — `:4934-4949` (3 mappings)
- `wamp.sse.*` — `:4959-4979` (4 mappings)

**These four ranges are not disjoint in key space, so a per-range transcription
produces duplicate keys.** `api_gateway.http.*` and `wamp.tcp.*` share **17**
key suffixes:

```
acceptors_pool_size  backlog  buffer  enabled  idle_timeout  ip  ip_version
keepalive  linger.timeout  max_connections  nodelay  port  proxy_protocol
proxy_protocol.mode  recbuf  reuseport  sndbuf
```

Transcribe the **union** of key suffixes, one `listeners.$name.*` mapping per
distinct key — never one per legacy mapping. Three disjoint groups:

**Group 1 — shared stream keys.** Every key above except `enabled`,
`ip_version`, `idle_timeout` and `linger.timeout`, plus the `wamp.tcp.*`-only
`ping.{enabled,idle_timeout,max_attempts,timeout}`. Their targets already agree
in shape between the two protocols (`transport_opts.*`, `proxy_protocol.*`), so
one mapping serves both. Two need the **wider** of the two legacy datatypes, or
a configuration that is valid today becomes an error:

| Key | `api_gateway.http.*` | `wamp.tcp.*` | Use |
|---|---|---|---|
| `idle_timeout` | `{duration, ms}` | `[{duration, ms}, {atom, infinity}]` | the `wamp.tcp` one |
| `linger.timeout` | `{duration, ms}` | `[{duration, ms}, integer]` | the `wamp.tcp` one |

**Group 2 — HTTP protocol-level keys, under a `http.` prefix.** The 23
`api_gateway.http.*` mappings whose target is `api_gateway_http.protocol_opts.*`
become `listeners.$name.http.<key>` targeting `$name.protocol_opts.<key>`:

```
active_n  buffer.max  buffer.min  idle_timeout  inactivity_timeout
initial_stream_flow_size  invalid_response_headers  linger.timeout
max_authority_length  max_authorization_header_value_length
max_concurrent_streams  max_cookie_header_value_length  max_empty_lines
max_header_name_length  max_header_value_length  max_headers  max_keepalive
max_method_length  max_request_line_length  max_skip_body_length
request_timeout  reset_idle_timeout_on_send  sendfile
```

The prefix exists because two of these keys — `idle_timeout` and
`linger.timeout` — target a structurally *different* app-env path than their
`wamp.tcp.*` namesakes, and a cuttlefish mapping has exactly one target:

| Key | HTTP target | Raw-socket target |
|---|---|---|
| `idle_timeout` | `$name.protocol_opts.idle_timeout` | `$name.idle_timeout` |
| `linger.timeout` | `$name.protocol_opts.linger_timeout` | `$name.transport_opts.socket_opts.linger_timeout` |

So `listeners.$name.idle_timeout` (group 1) targets `$name.idle_timeout` and
`listeners.$name.http.idle_timeout` (group 2) targets
`$name.protocol_opts.idle_timeout`. Prefix all 23, not only the two that clash:
a group split on whether a name happens to collide is arbitrary and drifts as
keys are added.

Do **not** "fix" this by normalising the app-env layout instead. Design §2.7
records that the app-env contract stays unchanged, and every consumer of these
paths is outside this task.

**Group 3 — HTTP-only keys that already carry their own target prefix.**
`security_headers.*` (5), `cors.*` (5) and `server_header` (1) collide with
nothing, so they stay flat: `listeners.$name.security_headers.*`,
`listeners.$name.cors.*`, `listeners.$name.server_header`.

Note that `listeners.$name.buffer` (a socket bytesize, group 1) and
`listeners.$name.http.buffer.{min,max}` (the cowboy dynamic buffer, group 2)
coexist. A leaf and a subtree at one path is already how the legacy schema is
written — `api_gateway.http.buffer` sits beside `api_gateway.http.buffer.max`
today — so this needs no special handling.

apply exactly this transformation, and nothing else:

1. Take the legacy mapping's **target**, e.g.
   `"bondy_router.api_gateway_http.transport_opts.socket_opts.backlog"`.
2. The new mapping's target is always `"bondy_router.listeners"`. Strip the
   `bondy_router.<listener-name>.` prefix from the legacy target and use what
   remains — `transport_opts.socket_opts.backlog` — as this key's **Spec path**
   in the translation's fold. That is the only place the old target's structure
   survives.
   For `wamp.websocket.*` / `wamp.sse.*` / `wamp.longpoll.*`, the Spec path's
   first segment becomes the carrier name: `wamp_websocket.idle_timeout` →
   `websocket.idle_timeout`.
3. Name the new key by replacing the legacy prefix with `listeners.$name`:
   `api_gateway.http.backlog` → `listeners.$name.backlog`;
   `wamp.websocket.idle_timeout` → `listeners.$name.websocket.idle_timeout`.
4. Copy the `{datatype, ...}` verbatim.
5. **Drop `{default, ...}`, `{commented, ...}` and `hidden`.** Nothing else
   changes.
6. Copy the `@doc` comment, deleting any sentence that names a specific
   listener.

Skip both legacy `enabled` mappings (`api_gateway.http.enabled` at `:3173` and
`wamp.tcp.enabled` at `:4993`) — `listeners.$name.enabled` already exists above.

Both `ip_version` mappings (`api_gateway.http.ip_version` at `:3199`,
`wamp.tcp.ip_version` at `:5018`) carry a `{translation, ...}` that turns the
string into an atom. There is no separate translation to write here: the single
`bondy_router.listeners` translation is the only one, so fold that conversion
into it at the Spec path `transport_opts.socket_opts.ip_version`. Confirm the two
legacy translations are equivalent before merging their logic; if they are not,
say so in your report rather than picking one.

The same applies to every other legacy `{translation, ...}` in the four ranges,
including the `cors` and `security_headers` aggregators: they all collapse into
the one `listeners` translation. Enumerate them before you start —
`grep -n 'translation, "bondy_router\.\(api_gateway_http\|wamp_tcp\)' schema/bondy.schema`
— and report how many you folded in, so none is silently dropped.

**Do not verify this step against a mapping count.** Three earlier tasks in this
plan shipped a wrong count in the brief, and here two of my errors happened to
cancel — the arithmetic was wrong in both directions and still reached the same
total, which is precisely the failure a count check cannot catch. Derive the
number yourself, state the derivation in your report, and verify the two
properties that actually matter:

**No duplicate key.** This must print nothing. If it prints, the union rule was
not applied:

```
grep -o '^{mapping, "listeners\.\$name\.[^"]*"' schema/bondy.schema \
  | sort | uniq -d
```

**No default, no `commented`, no `hidden`.** This must print nothing:

```
awk '/^\{mapping, "listeners\.\$name\./,/^\]\}\./' schema/bondy.schema \
  | grep -E 'default|commented|hidden'
```

**Every legacy key is accounted for.** Produce the union of key suffixes from
the five legacy prefixes, subtract `enabled`, and diff it against the
`listeners.$name.*` keys you wrote — remembering that the 23 group-2 keys gained
an `http.` prefix. Report any key in the legacy union with no counterpart, and
any `listeners.$name.*` key with no legacy origin. Both directions matter: the
first is a dropped setting, the second is an invented one.

- [ ] **Step 4: Run the suite to verify it passes**

Run: `CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_listener_schema_SUITE.erl`
Expected: PASS, 3 cases.

- [ ] **Step 5: Format and checkpoint**

Report: the new schema block renders to a single `bondy_router.listeners` value
whose entries carry their option blocks nested; no `bondy_router.<name>.*` key is
produced (that is Task 7b); `port` has no default; an omitted carrier key stays
absent; and the output of all three property checks.

---

### Task 7b: Splat the per-listener option blocks into app env

Task 7 renders one key, `bondy_router.listeners`, with each listener's option
block nested inside its spec — because cuttlefish cannot write to
`bondy_router.<name>.*` (Task 7 Step 3). But every consumer reads exactly that:
`bondy_config:listener_transport_opts/1` and `listener_protocol_opts/1` read
`[Name, transport_opts]` and `[Name, protocol_opts]`;
`bondy_cert_manager:load_server_cert_from_config/1` reads
`[Ref, transport_opts]`; `bondy_http_cors:config_from_req/1` reads `[Ref, cors]`;
`bondy_http_security_headers:init/1` reads `[ListenerName, security_headers]`;
`bondy_http_proxy_protocol:init/1` and `bondy_tcp_proxy_protocol:init/2` read
`[Ref, proxy_protocol]`.

This task moves the block from the inventory value to where those consumers look.

**Files:**
- Modify: `apps/bondy_router/src/bondy_config.erl`
- Test: `apps/bondy_router/test/bondy_listener_SUITE.erl` (append)

**Interfaces:**
- Consumes: `bondy_router.listeners` as Task 7 renders it.
- Produces: `bondy_router.<name>.{transport_opts,protocol_opts,tls,cors,
  security_headers,proxy_protocol,websocket,sse,longpoll}` in the
  `bondy_config` cache, for every listener in the inventory.

- [ ] **Step 1: Write the failing test**

Append to `bondy_listener_SUITE`. The falsification is that a listener's
operator-set option must reach the consumer, not merely sit in the inventory:

```erlang
option_block_reaches_the_consumer(_Config) ->
    %% The schema renders ONE key; a listener's options arrive nested inside its
    %% inventory entry. Nothing else in the system reads them there, so a splat
    %% that silently did nothing would leave every listener on defaults —
    %% indistinguishable from a working system until an operator's tuning is
    %% ignored. Assert through the accessor the driver actually calls.
    ok = bondy_config:set(listeners, [
        {ct_splat, #{
            transport => tcp,
            protocol => wamp_rawsocket,
            port => 0,
            transport_opts => [
                {num_acceptors, 7},
                {socket_opts, [{ip_version, inet}, {backlog, 321}]}
            ],
            proxy_protocol => [{enabled, false}],
            %% A key that lands at the spec's TOP level, not inside a block.
            %% `bondy_wamp_tcp_connection_handler.erl:118' reads it flat, so a
            %% splat that only moved the named blocks would drop it — and drop
            %% `ping' and `server_header' with it.
            idle_timeout => 12345
        }}
    ]),
    ok = bondy_config:splat_listener_blocks(),
    Opts = bondy_config:listener_transport_opts(ct_splat),
    ?assertEqual(7, maps:get(num_acceptors, Opts)),
    ?assertEqual(
        321, key_value:get(backlog, maps:get(socket_opts, Opts))
    ),
    ?assertEqual(12345, bondy_config:get([ct_splat, idle_timeout], undefined)),
    %% A structural key stays in the inventory and is NOT splatted: nothing
    %% reads `[Name, transport]`, and writing it would create a second place
    %% where a listener's transport is recorded.
    ?assertEqual(
        undefined, bondy_config:get([ct_splat, transport], undefined)
    ).
```

- [ ] **Step 2: Run it to verify it fails**

Run: `CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_listener_SUITE.erl`
Expected: FAIL — `bondy_config:splat_listener_blocks/0` is undefined.

- [ ] **Step 3: Write the splat**

In `bondy_config.erl`, add `splat_listener_blocks/0` and export it. For every
`{Name, Spec}` in the inventory, write every spec key that is **not**
structural to `[Name, Key]`:

```erlang
%% The keys `bondy_listener_config' reads from the spec itself: `transport'
%% and `protocol' via `assert_required/2', then `port'/`path'/`ip' through
%% `resolve_bind/3' and `resolve_ip/3', and `services', `enabled' and
%% `start_phase' directly. Everything else in a spec is an option block
%% belonging to a consumer that reads it from `bondy_router.<name>.*'.
-define(SPEC_KEYS, [
    transport, protocol, port, path, ip, services, enabled, start_phase
]).

splat_listener_blocks() ->
    _ = [
        set([Name, Key], Value)
     || {Name, Spec} <- get(listeners, []),
        {Key, Value} <- maps:to_list(Spec),
        not lists:member(Key, ?SPEC_KEYS)
    ],
    ok.
```

**Exclude the structural keys rather than listing the block keys.** An
inclusion list is a second place to record what the schema already records, and
it fails silently in the direction that hurts: a key added to the route table
but forgotten here renders into the inventory and is dropped, so an operator's
setting is ignored with no error anywhere. Three of Task 7's 89 routed keys
already land at the spec's top level rather than inside a block —
`idle_timeout`, `ping` (four conf keys) and `server_header` — and their
consumers read them flat: `bondy_wamp_tcp_connection_handler.erl:118` reads
`[Ref, idle_timeout]`, `:577` reads `[Ref, ping]`, and
`bondy_http_security_headers.erl:52` reads `[ListenerName, server_header]`. An
inclusion list of the nine block names would have dropped all six.

Exclusion is safe here only because of a guard Task 7 built: `Path/1` in the
translation calls `cuttlefish:invalid/1` on any key not in the route table, so
no unrecognised key can reach a rendered spec in the first place. A spec set
directly by a test can still carry anything, and splatting a stray key there is
harmless.

The structural set is closed and small; verify it against the resolver rather
than copying it. As of Task 6b, `resolve_one/3` reads exactly these eight and
`?SPEC_KEYS` above lists them.

Write only the keys the spec actually carries — iterating the spec's own
entries means an absent key stays absent, so the defaults added in Task 6 still
apply. Do **not** write an empty block for a listener that configured nothing:
that would replace "absent, so default" with "present but empty", and
`key_value:get(num_acceptors, #{})` has no default.

**Absence must survive this step end to end**, and that constrains Task 7's
translation as much as the splat: a spec carrying `{backlog, undefined}` for a
key the operator never wrote would be faithfully copied here, and `undefined` is
not absence. It would silently defeat the global carrier fallback (§3), the
QUIC inapplicable-key check, and the `cors`/`security_headers` map defaults —
while every test in Task 7 and this task still passed, because each asserts on
what *is* configured. If Task 7's rendered inventory contains any `undefined`
value, fix it there rather than filtering here; a filter in the splat would hide
the defect from the schema suite that ought to catch it.

Note the state this task closes: after Task 7 alone, a **new-style TLS listener
aborts boot** rather than being ignored. `listeners.x.tls.certfile` renders into
the inventory correctly, but `bondy_listener_config:tls_material/3` reads app
env, so `assert_tls_keys/3` still reports `{missing, [tls, certfile]}`. Task 7's
commit is therefore not independently safe for TLS, which is why this task
follows immediately.

- [ ] **Step 4: Call it at the right point in `init/1`**

`bondy_config:init/1` must splat **before** anything reads a per-listener block.
The order is load-bearing and already tight:

- `app_config:init/2` (`:255`) caches application env into `persistent_term`.
  Nothing before this line can read configuration, so the splat cannot precede
  it.
- `bondy_listener_manager:init/0` (`:261`) resolves the inventory, and
  `resolve/2`'s `GetFun` reads `[Name, tls, …]` and
  `[Name, transport_opts, socket_opts, …]` for its TLS-material check.
- `bondy_cert_manager:init/0` (`:263`) iterates `tls_listeners/0` and reads
  `[Ref, transport_opts]` for each.
- `setup_wamp/0` (`:265`) normalises `dynamic_buffer` per HTTP listener.

So the splat goes immediately after `app_config:init/2` and before the manager —
between `:255` and `:261`. Add a comment saying why it cannot move either way.
Confirm those three line numbers against the file before you rely on them: they
have already drifted once during this plan's execution, and the comment already
sitting above `bondy_listener_manager:init/0` records the same ordering
argument in prose, which is the durable version.

- [ ] **Step 5: Run the suite, then the regression set**

Run each separately:
```
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_listener_SUITE.erl
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_admin_listener_SUITE.erl
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_http_cors_SUITE.erl
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_http_security_headers_SUITE.erl
```
Expected: all PASS. The cors and security-headers suites are the falsification
target for the two map-valued block keys — they read `[Ref, cors]` and
`[Ref, security_headers]`, so they fail if the splat mishandles either.

- [ ] **Step 6: Prove the ordering, do not assume it**

Move the splat call to *after* `bondy_cert_manager:init/0` and report what
breaks. Then move it back. A test cannot easily cover boot ordering, so this
mutation is the evidence that the placement in Step 4 is required rather than
merely plausible.

- [ ] **Step 7: Format and checkpoint**

Report: the splat's placement and the mutation result from Step 6; which block
keys were present in the rendered inventory versus which stayed absent; and
confirmation that a listener configuring nothing gets no empty block.

---

### Task 8: The legacy compatibility path

**Files:**
- Modify: `apps/bondy_router/src/bondy_listener_config.erl` — `resolve_ip/3`
  accepts a string, reserved-`admin` injection, `legacy` marker carried through
- Modify: `apps/bondy_router/src/bondy_listener_manager.erl` — promote the
  transitional inventory to the documented legacy path; deprecation warning
- Modify: `schema/bondy_bridge_relay.schema` — fix
  `bridge.listener.tcp.ip_version`'s target
- Test: `apps/bondy_router/test/bondy_listener_config_test.erl` (append)
- Test: `apps/bondy_router/test/bondy_listener_SUITE.erl` (append)

**Interfaces:**
- Consumes: `bondy_router.listeners` from Task 7 when the operator wrote any
  `listeners.*` key; the legacy per-listener application-environment blocks
  otherwise.
- Produces: one resolved inventory, whichever spelling the operator used, so
  there is a single runtime path from `resolve/2` onward.

**Why the conversion is in Erlang and not in the schema.** A schema-side shim
cannot run. Cuttlefish decides per translation whether to apply it:
`apply_mappings/2` builds `Keep` and `MaybeDrop` from the *mapping* records and
computes `TranslationsToDrop = MaybeDrop -- Keep`
(`cuttlefish_generator.erl:139-168`); a target enters `Keep` only when some
mapping pointing at it has a `{default, ...}` or is set in the conf file. All 89
of Task 7's mappings target `bondy_router.listeners` and are default-free by
this plan's own constraint, so a conf file containing only legacy keys leaves
that target unclaimed and the translation is discarded before it runs. Task 7's
passing `no_listener_configured_renders_no_inventory_key` case asserts exactly
that drop. Any legacy-synthesis branch inside that translation would be dead
code.

Two further facts make the schema route worse rather than merely impossible.
Only one translation may exist per target: `cuttlefish_translation:parse_and_merge/2`
does `lists:keyreplace/4` on the mapping name, so a second
`{translation, "bondy_router.listeners", ...}` — in `bondy.schema` or in
`bondy_bridge_relay.schema`, since all schema files fold into one translation
list — silently *replaces* Task 7's, taking all 89 keys with it. Cuttlefish's
own `cuttlefish_schema.erl:411-425` pins this override behaviour. And a
translation suppresses the direct write of every mapping sharing its target
(`apply_mappings/2`'s `{true, true}` clause), so retargeting the legacy mappings
to keep the translation alive would move every existing deployment's option
blocks onto the Task 7b splat on upgrade.

**The gate is free, and it is the same mechanism.** Because the translation is
dropped when no `listeners.*` key is written, `bondy_router.listeners` is absent
for exactly the deployments that need the legacy path — so
`bondy_config:get(listeners, undefined)` returning `undefined` *is* the
provenance signal, and `bondy_listener_manager:init/0` already branches on it.
Do not add a second gate. In particular do not gate on the legacy keys being
present: every legacy mapping carries a `{default, ...}`, and `add_defaults/2`
runs before translations, so a legacy block always looks configured.

**Legacy listeners keep their historical names.** `api_gateway_http`,
`api_gateway_https`, `admin_api_http`, `admin_api_https`, `wamp_tcp`,
`wamp_tls`, `wamp_uds`, `bridge_relay_tcp`, `bridge_relay_tls` — the nine names
`bondy_listener_config:default_inventory/0` already carries. A listener's name
is simultaneously its application-environment option-block key and the Cowboy
`ref` that `bondy_http_cors` and `bondy_http_security_headers` read, so renaming
`admin_api_http` to the reserved `admin` would relocate ~30 keys' worth of
configuration that the legacy mappings still write to
`bondy_router.admin_api_http.*`. Nothing would read it.

The reserved `admin` name is therefore injected **only on the configured path**.
The two never coexist: the gate is all-or-nothing, so a legacy deployment gets
`admin_api_http` on 18081 exactly as today, and a `listeners.*` deployment gets
an injected `admin` on 18081. That is also why no port collision arises —
`assert_unique/3` never sees both.

**A compatibility break to avoid.** Legacy `ip` accepts a **hostname**; Task 7's
new block does not. Verified at source: `{mapping, "api_gateway.http.ip"}` and
`{mapping, "wamp.tcp.ip"}` are `{datatype, string}` with the `ip_address`
validator, which is `inet:getaddr(Term, inet)` falling back to `inet6` — it
accepts any name that resolves, stores the string, and `bondy_utils:get_ipaddr/2`
resolves it at boot (its own doc states it takes "an `inet:ip_address()` or a
string or binary representation of it"). Task 7's `Address` is
`inet:parse_address/1`, which accepts only literals.

**Hostnames are the sole divergence, in one direction.** An earlier draft of this
paragraph also claimed the legacy validator rejected IPv6 literals; that was
wrong, and the error reached a test comment before being caught. The validator's
`inet6` fallback accepts them — probed: `inet:getaddr("::1", inet)` is
`{error, nxdomain}`, but `inet:getaddr("::1", inet6)` is
`{ok, {0,0,0,0,0,0,0,1}}`, so the validator returns `true`. Do not describe IPv6
support as new.

Under this task's design a legacy `ip` never passes through the schema at all —
it is read from application environment — so `resolve_ip/3` becomes
the single place both spellings converge, and it must accept a string. Resolve
at boot, never at render time: cuttlefish runs from
`bin/hooks/pre_start_cuttlefish` before the VM starts, and a name that resolves
on the operator's workstation need not resolve in the container.

- [ ] **Step 1: Write the failing tests for string `ip`**

Append to `apps/bondy_router/test/bondy_listener_config_test.erl`:

```erlang
legacy_hostname_ip_is_resolved_test() ->
    %% `localhost` is in /etc/hosts on every supported platform, so this does
    %% not depend on a live resolver.
    Inventory = [
        {pub, #{
            transport => tcp,
            protocol => http,
            port => 18080,
            services => [wamp_ws],
            ip => "localhost"
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    ?assertEqual({127, 0, 0, 1}, maps:get(ip, L)).

literal_ip_string_is_parsed_not_resolved_test() ->
    %% The falsification, and the reason parse_address must be tried FIRST: a
    %% resolver with a wildcard record can answer a lookup for "0.0.0.0" with
    %% some other address entirely. A literal must never reach DNS.
    Inventory = [
        {pub, #{
            transport => tcp,
            protocol => http,
            port => 18080,
            services => [wamp_ws],
            ip => "0.0.0.0"
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    ?assertEqual({0, 0, 0, 0}, maps:get(ip, L)).

ipv6_literal_string_is_accepted_test() ->
    %% Accepted by `inet:parse_address/1` and REJECTED by the legacy
    %% `ip_address` validator's `inet:getaddr(Term, inet)` first clause, so this
    %% pins a widening, not a preserved behaviour.
    Inventory = [
        {pub, #{
            transport => tcp,
            protocol => http,
            port => 18080,
            services => [wamp_ws],
            ip => "::1"
        }}
    ],
    {ok, [L]} = bondy_listener_config:resolve(Inventory, empty_get()),
    ?assertEqual({0, 0, 0, 0, 0, 0, 0, 1}, maps:get(ip, L)).

unresolvable_ip_is_rejected_test() ->
    %% `.invalid` is reserved by RFC 2606 and cannot resolve, so this asserts
    %% the error path without depending on any particular resolver's answer.
    Inventory = [
        {pub, #{
            transport => tcp,
            protocol => http,
            port => 18080,
            services => [wamp_ws],
            ip => "no-such-host.invalid"
        }}
    ],
    ?assertMatch(
        {error, {invalid_listener, pub, {unresolvable_ip, _, _}}},
        bondy_listener_config:resolve(Inventory, empty_get())
    ).
```

- [ ] **Step 2: Run them to verify they fail**

Run: `rebar3 as test eunit --module=bondy_listener_config_test`
Expected: FAIL. `resolve_ip/3` returns the string unchanged, so the first three
compare a list against a tuple and the fourth resolves successfully.

- [ ] **Step 3: Accept a string in `resolve_ip/3`**

In `bondy_listener_config.erl`, route the found value through a converter:

```erlang
resolve_ip(Name, Services, Spec) ->
    case maps:find(ip, Spec) of
        {ok, Ip} ->
            to_address(Name, Ip);
        error ->
            Privileged = [S || S <- Services, S =:= admin orelse S =:= metrics],
            case Privileged of
                [] -> {0, 0, 0, 0};
                _ -> {127, 0, 0, 1}
            end
    end.

%% @private
%% Both spellings of a listener converge here. A `listeners.$name.ip` arrives
%% already parsed, as an address tuple, because the schema's translation calls
%% `inet:parse_address/1`. A legacy `ip` arrives as a STRING and may be a
%% hostname: `{mapping, "api_gateway.http.ip"}` is `{datatype, string}` with the
%% `ip_address` validator, which is `inet:getaddr/2` and accepts any name that
%% resolves.
%%
%% A literal is parsed before anything is resolved. `inet:getaddr/2` on a
%% resolver holding a wildcard record can answer a lookup for a literal with a
%% different address, so trying DNS first would silently move a listener.
to_address(_Name, Ip) when is_tuple(Ip) ->
    Ip;
to_address(Name, Ip0) ->
    Ip = unicode:characters_to_list(Ip0),
    case inet:parse_address(Ip) of
        {ok, Address} ->
            Address;
        {error, einval} ->
            %% `inet` then `inet6`, the order the legacy `ip_address` validator
            %% used, so a name with both records resolves the way it does today.
            case inet:getaddr(Ip, inet) of
                {ok, Address} ->
                    Address;
                {error, _} ->
                    case inet:getaddr(Ip, inet6) of
                        {ok, Address} ->
                            Address;
                        {error, Reason} ->
                            invalid(Name, {unresolvable_ip, Ip0, Reason})
                    end
            end
    end.
```

- [ ] **Step 4: Run them to verify they pass**

Run: `rebar3 as test eunit --module=bondy_listener_config_test`
Expected: PASS, all cases.

- [ ] **Step 5: Write the failing tests for the legacy path**

Append to `apps/bondy_router/test/bondy_listener_SUITE.erl`, adding each to
`all/0`.

Two things to establish before writing them, because both silently change what
the cases mean:

- **`bondy_config` state persists across cases in one suite run.** These cases
  write listener configuration, so each must set every value it asserts on
  rather than inheriting one. Where a case below sets a value defensively, the
  comment says which earlier case would otherwise leak into it.
- **Two cases call `bondy_listener_manager:init/0`, which injects `admin_local`
  and therefore reads `bondy_config:get(platform_tmp_dir)` with no default.**
  Check whether this suite's existing setup provides it. If it does not, either
  set it in the case or assert through `bondy_listener_config:resolve/2` plus
  `with_reserved/1` instead of `init/0` — and say in your report which you chose,
  because "the case crashed on an unrelated missing key" and "the injection does
  not work" look identical from the failure output.

```erlang
legacy_app_env_produces_the_historical_inventory(_Config) ->
    %% Absent `listeners` is the provenance signal: cuttlefish drops the
    %% inventory translation when no `listeners.*` key is written, so a
    %% pre-`listeners.*` deployment reaches boot with no such key at all.
    ok = bondy_config:set(listeners, undefined),
    Inventory = bondy_listener_manager:legacy_inventory(),
    Names = [N || {N, _} <- Inventory],
    %% The historical names, because a name IS the app-env option-block key
    %% that the legacy mappings still write to.
    ?assert(lists:member(api_gateway_http, Names)),
    ?assert(lists:member(admin_api_http, Names)),
    ?assert(lists:member(wamp_tcp, Names)),
    ?assertNot(lists:member(admin, Names)),
    %% Every entry is marked, so the deprecation warning can be per listener.
    ?assert(lists:all(fun({_, S}) -> maps:get(legacy, S, false) end, Inventory)).

legacy_operator_overrides_are_honoured(_Config) ->
    %% The keys an operator actually edits per listener are whether it is on and
    %% where it binds. Both are read from app env here, NOT from the inventory
    %% defaults, so a legacy `wamp.tcp.port` must survive.
    ok = bondy_config:set([wamp_tcp, transport_opts, socket_opts, port], 19999),
    Inventory = bondy_listener_manager:legacy_inventory(),
    ?assertEqual(19999, maps:get(port, proplists:get_value(wamp_tcp, Inventory))).

configured_inventory_gets_the_reserved_admin(_Config) ->
    %% An operator who adopted `listeners.*` and did not write an admin listener
    %% still gets one: otherwise a single conf edit can lock them out.
    ok = bondy_config:set(listeners, [
        {pub, #{
            transport => tcp,
            protocol => http,
            port => 18080,
            services => [wamp_ws]
        }}
    ]),
    ok = bondy_listener_manager:init(),
    ?assertMatch({ok, _}, bondy_listener_manager:listener(admin)),
    %% ...and it is NOT marked legacy, because nothing deprecated produced it.
    {ok, Admin} = bondy_listener_manager:listener(admin),
    ?assertEqual(false, maps:get(legacy, Admin)).

legacy_and_new_style_resolve_identically(_Config) ->
    %% THE load-bearing test for the compatibility path (design §6, target 4).
    %% Two spellings of the same listener must produce the same resolved map;
    %% nothing else proves the legacy path cannot drift from the block it is
    %% compatible with. `legacy` is the only field that MUST differ, so it is
    %% the only one removed before comparing — do not widen that exemption to
    %% make a failure go away, because every field it hides is a real
    %% divergence an operator would meet on upgrade.
    %%
    %% Same NAME on both sides deliberately: the name selects the app-env option
    %% blocks, so using two names would compare two different listeners and pass
    %% regardless.
    %% Set the port explicitly rather than relying on the inventory default:
    %% `legacy_operator_overrides_are_honoured` above sets it to 19999 and
    %% `bondy_config` state persists for the whole suite, so without this the
    %% result depends on case order.
    ok = bondy_config:set([wamp_tcp, transport_opts, socket_opts, port], 18082),
    {wamp_tcp, LegacySpec} = lists:keyfind(
        wamp_tcp, 1, bondy_listener_manager:legacy_inventory()
    ),
    {ok, [FromLegacy]} = bondy_listener_config:resolve(
        [{wamp_tcp, LegacySpec}], fun bondy_config:get/2
    ),
    %% What an operator writes by hand for the same listener.
    {ok, [FromNew]} = bondy_listener_config:resolve(
        [
            {wamp_tcp, #{
                transport => tcp,
                protocol => wamp_rawsocket,
                port => 18082
            }}
        ],
        fun bondy_config:get/2
    ),
    ?assertEqual(
        maps:remove(legacy, FromLegacy), maps:remove(legacy, FromNew)
    ),
    %% And the marker really is set on one side only, so the comparison above
    %% was not trivially true.
    ?assertEqual(true, maps:get(legacy, FromLegacy)),
    ?assertEqual(false, maps:get(legacy, FromNew)).

operator_admin_block_wins_over_the_injected_one(_Config) ->
    %% Reserved means "cannot be removed", not "cannot be configured": an
    %% operator must be able to move the admin port or put it behind TLS.
    ok = bondy_config:set(listeners, [
        {admin, #{
            transport => tcp,
            protocol => http,
            port => 18099,
            services => [admin_api, admin]
        }}
    ]),
    ok = bondy_listener_manager:init(),
    {ok, Admin} = bondy_listener_manager:listener(admin),
    ?assertEqual({port, 18099}, maps:get(bind, Admin)),
    %% Exactly one, not the operator's plus an injected default.
    Names = [maps:get(name, L) || L <- bondy_listener_manager:listeners()],
    ?assertEqual(1, length([N || N <- Names, N =:= admin])).
```

- [ ] **Step 6: Run the suite to verify it fails**

Run: `CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_listener_SUITE.erl`
Expected: FAIL — `bondy_listener_manager:legacy_inventory/0` is undefined and no
`admin` is injected.

- [ ] **Step 7: Promote the legacy inventory and inject the reserved name**

In `bondy_listener_manager.erl`, rename `transitional_inventory/0` to
`legacy_inventory/0`, export it, mark its entries, and rewrite the `init/0`
branch. Replace the "TRANSITIONAL" comment: this is no longer scaffolding
waiting on the schema, it is the compatibility path for one release.

```erlang
init() ->
    Get = fun bondy_config:get/2,
    Inventory =
        case bondy_config:get(listeners, undefined) of
            undefined ->
                %% No `listeners.*` key was written, so cuttlefish dropped the
                %% inventory translation (a translation is discarded unless a
                %% mapping targeting it has a default or is set, and every
                %% `listeners.$name.*` mapping is default-free). An absent key
                %% therefore means a pre-`listeners.*` deployment.
                legacy_inventory();
            Configured ->
                with_reserved(Configured)
        end,
    ...
```

and:

```erlang
-doc """
The nine listeners Bondy configured before `listeners.$name.*` existed, read
from the application environment the legacy mappings still write.

Each entry is marked `legacy => true` so `init/0` can warn per listener. The
names are the historical ones on purpose: a listener's name is its option-block
key in the application environment and the Cowboy `ref` that `bondy_http_cors`
and `bondy_http_security_headers` read, so renaming one would orphan every
option the legacy mappings wrote for it.
""".
legacy_inventory() ->
    [
        {Name,
            legacy_ip(
                Name, legacy_bind(Name, legacy_enabled(Name, Spec#{legacy => true}))
            )}
     || {Name, Spec} <- bondy_listener_config:default_inventory()
    ].

%% @private
%% An operator's explicit bind address. Without this the services-derived default
%% in `bondy_listener_config:resolve_ip/3` wins and
%% `bondy_listener_ranch:with_bind/3` writes it over whatever the operator asked
%% for — `lists:keystore(ip, 1, SocketOpts, {ip, Ip})` is unconditional. That
%% fails OPEN in one direction: an `api_gateway.http.ip` naming one interface
%% would be widened to all of them.
%%
%% Three different paths, because the legacy mappings target three different
%% shapes. Note `bridge.listener.tcp.ip` sits at top level while its `tls`
%% sibling sits under `socket_opts` — the same asymmetry as the `ip_version`
%% pair, left alone here because retargeting a mapping is operator-visible.
%%
%% Written only when present: `api_gateway.http.ip` carries no default, and an
%% `{ip, undefined}` in the spec would defeat the fallback rather than yield to
%% it.
legacy_ip(Name, Spec) ->
    Path =
        case Name of
            wamp_tcp -> [Name, transport_opts, ip];
            wamp_tls -> [Name, transport_opts, ip];
            bridge_relay_tls -> [Name, transport_opts, socket_opts, ip];
            _ -> [Name, ip]
        end,
    case bondy_config:get(Path, undefined) of
        undefined -> Spec;
        Ip -> Spec#{ip => Ip}
    end.

%% @private
%% Reserved names an operator did not write are added, so adopting
%% `listeners.*` cannot silently remove the administrable endpoint. An operator
%% who DID write one keeps it: reserved means it cannot be removed or disabled,
%% not that it cannot be configured — `bondy_listener_config:assert_reserved/2`
%% enforces that half.
%%
%% Only the configured path needs this. The legacy path carries
%% `admin_api_http`, and injecting `admin` beside it would put two listeners on
%% 18081 — both defaults — which `assert_unique/3` rejects, so every legacy
%% deployment would fail to boot.
with_reserved(Configured) ->
    lists:foldl(
        fun(Name, Acc) ->
            case lists:keymember(Name, 1, Acc) of
                true -> Acc;
                false -> Acc ++ [{Name, reserved_spec(Name)}]
            end
        end,
        Configured,
        [admin]
    ).

%% @private
%% Defaults chosen to match what `admin_api.http` binds today, so an operator
%% adopting `listeners.*` finds the admin API where it has always been.
reserved_spec(admin) ->
    #{
        transport => tcp,
        protocol => http,
        port => 18081,
        start_phase => early,
        services => [admin_api, wamp_ws, admin, metrics]
    }.
```

Copy `default_inventory/0`'s `admin_api_http` entry field for field — same port,
same `start_phase`, same service list in the same order. It is the listener this
replaces on the configured path, and any difference is a behaviour change for an
operator who adopts `listeners.*` without asking for one. The absent `ip` is part
of that: `resolve_ip/3` defaults a listener carrying `admin` or `metrics` to
loopback, which is where the admin API binds today.

```erlang
```

`bondy_listener_config:resolve_one/3` must carry the marker into the resolved
map for the warning to work — add `legacy => maps:get(legacy, Spec, false)` to
the map it returns. `?SPEC_KEYS` in `bondy_config` must gain `legacy` too, or
the splat will write a `bondy_router.<name>.legacy` key nothing reads; state in
your report which you did and why.

Then warn, after `log_inventory/1`:

```erlang
%% @private
warn_legacy(Listeners) ->
    _ = [
        ?LOG_WARNING(#{
            description =>
                "Listener configured through deprecated keys; these will be "
                "removed in a future release. Use the listeners.<name>.* "
                "equivalents.",
            listener => maps:get(name, L)
        })
     || L <- Listeners, maps:get(legacy, L, false)
    ],
    ok.
```

- [ ] **Step 8: Run the suite to verify it passes**

Run: `CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_listener_SUITE.erl`
Expected: PASS.

Then the regression set, since `resolve_one/3` and `init/0` both changed:

```
rebar3 as test eunit --module=bondy_listener_config_test
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_admin_listener_SUITE.erl
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_listener_schema_SUITE.erl
```

- [ ] **Step 9: Fix the bridge-relay `ip_version` target**

`{mapping, "bridge.listener.tcp.ip_version"}` in `schema/bondy_bridge_relay.schema`
targets a **top-level** `bondy_router.bridge_relay_tcp.ip_version` rather than
`...transport_opts.socket_opts.ip_version`, so `bridge.listener.tcp = on`
crashes in `bondy_utils:get_ipaddr(any, any)` — bridge-relay TCP is unusable at
HEAD and no suite starts one. Correct the target to match its `tls` sibling.

Verify the two are now consistent, and say in your report what each target was
before and after:

```
grep -n -A4 'mapping, "bridge.listener.\(tcp\|tls\).ip_version"' schema/bondy_bridge_relay.schema
```

- [ ] **Step 10: Boot with an unmodified config**

Run `rebar3 as dev release`, then start the node with
`config/dev/bondy.conf.template` untouched. This is the check that an existing
deployment upgrades without a config edit — the only one that exercises real
cuttlefish rendering, since test boots render none.

`bondy_listener_manager:log_inventory/1` prints one line per listener. Read
them; do not infer. Report the full list, and confirm:

- the historical names appear, **not** `admin`
- exactly one listener binds 18081
- `bridge_relay_tcp` and `bridge_relay_tls` are `enabled => false` by their
  schema defaults
- `admin_local` is present, bound to a socket path, and carries **no**
  deprecation warning — nothing deprecated produced it
- every other listener does carry one

- [ ] **Step 11: Format and checkpoint**

Run `rebar3 fmt` on the touched Erlang files. Report: the legacy path, the
reserved-`admin` injection, string `ip` support, the bridge-relay target fix,
and the dev node booting on an unmodified config.

---
### Task 9: Per-listener carrier config and protocol restriction

**Files:**
- Modify: `apps/bondy_router/src/bondy_wamp_ws_connection_handler.erl:84-92,344,463,501-518`
- Modify: `apps/bondy_router/src/bondy_http_sse_stream_handler.erl` — `:101-107`
  and `:233-235` still read globals
- Modify: `apps/bondy_router/src/bondy_http_longpoll_handler.erl` — `:343-356`
  still read globals
- Test: `apps/bondy_router/test/bondy_listener_SUITE.erl` (append)

**All three carriers, not just WebSocket.** An earlier draft of this task listed
only the WS handler, which left the seven `sse`/`longpoll` keys in `?CARRIER_KEYS`
resolved, shipped into the route state, and then discarded by handlers still
reading globals. Wiring SSE also retires a dead namespace: `http_sse` appears
nowhere in `schema/`, so `[http_sse, keepalive_interval]` has always returned its
hardcoded default, while `wamp.sse.ping.{enabled,interval}` exist with defaults
and nothing reads them. Route the keepalive through the resolved carrier config
and both levels become live. `ping.enabled = off` is a new capability — the
keepalive is currently unconditional — so honour the flag.

**Interfaces:**
- Consumes: route state `#{listener := atom(), protocols := [atom()], config := map()}`
  from `bondy_http_services:carrier_state/3` (Task 4).
- Produces: no new exported functions. `select_subprotocol/2` gains the
  listener's protocol list as a second argument.

- [ ] **Step 1: Write the failing test**

Append to `bondy_listener_SUITE.erl`:

```erlang
%% add to all/0: ws_listener_restricted_to_one_protocol,
%%               ws_carrier_config_is_per_listener

%% Opens a WebSocket handshake against `Port' offering `Subprotocol' and
%% returns the response status line.
ws_handshake(Port, Subprotocol) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false}], 5000
    ),
    Req = [
        "GET /ws HTTP/1.1\r\n",
        "Host: localhost\r\n",
        "Upgrade: websocket\r\n",
        "Connection: Upgrade\r\n",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n",
        "Sec-WebSocket-Version: 13\r\n",
        "Sec-WebSocket-Protocol: ", Subprotocol, "\r\n",
        "\r\n"
    ],
    ok = gen_tcp:send(Sock, Req),
    {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
    ok = gen_tcp:close(Sock),
    hd(binary:split(Data, <<"\r\n">>)).

ws_listener_restricted_to_one_protocol(_Config) ->
    %% A WAMP subprotocol that is valid globally must be REFUSED on a listener
    %% whose services do not include it. This is the operator requirement:
    %% offering BAMP over WebSocket without offering WAMP.
    Inventory = [
        {ct_wamp_only, #{
            transport => tcp, protocol => http, port => 0,
            services => [wamp_ws]
        }},
        {ct_bamp_only, #{
            transport => tcp, protocol => http, port => 0,
            services => [bamp_ws]
        }}
    ],
    %% `init/0` reads the inventory through `bondy_config`, which resolves
    %% against persistent_term — `application:set_env/3` is invisible to it
    %% unless `bondy_config:init/1` has since re-cached. Set it directly.
    ok = bondy_config:set(listeners, Inventory),
    ok = bondy_listener_manager:init(),
    ok = bondy_listener_manager:start(all),

    WampPort = ranch:get_port(ct_wamp_only),
    BampPort = ranch:get_port(ct_bamp_only),

    ?assertMatch(
        <<"HTTP/1.1 101", _/binary>>, ws_handshake(WampPort, "wamp.2.json")
    ),
    %% Same subprotocol, different listener: refused.
    ?assertMatch(
        <<"HTTP/1.1 400", _/binary>>, ws_handshake(BampPort, "wamp.2.json")
    ),

    ok = bondy_listener_manager:stop().

ws_carrier_config_is_per_listener(_Config) ->
    %% Two listeners, same carrier, different resolved config. Before this
    %% change the handler read a single global `wamp_websocket' block, so this
    %% was inexpressible.
    Inventory = [
        {ct_big, #{
            transport => tcp, protocol => http, port => 0,
            services => [wamp_ws]
        }},
        {ct_small, #{
            transport => tcp, protocol => http, port => 0,
            services => [wamp_ws]
        }}
    ],
    ok = application:set_env(bondy_router, listeners, Inventory),
    ok = bondy_config:set(ct_small, [{websocket, [{max_frame_size, 1024}]}]),
    ok = bondy_config:set(wamp_websocket, [{max_frame_size, 1048576}]),
    ok = bondy_listener_manager:init(),

    {ok, Big} = bondy_listener_manager:listener(ct_big),
    {ok, Small} = bondy_listener_manager:listener(ct_small),
    #{websocket := #{config := BigCfg}} = maps:get(carriers, Big),
    #{websocket := #{config := SmallCfg}} = maps:get(carriers, Small),

    %% Silent listener inherits the global; explicit listener overrides it.
    ?assertEqual(1048576, maps:get(max_frame_size, BigCfg)),
    ?assertEqual(1024, maps:get(max_frame_size, SmallCfg)).
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_listener_SUITE.erl`
Expected: FAIL — `ct_bamp_only` returns 101 for `wamp.2.json` because
`select_subprotocol/1` consults only the global validator.

- [ ] **Step 3: Thread the route state through the handler**

In `bondy_wamp_ws_connection_handler.erl`, `init/2` currently receives the
route's initial state and ignores it. Capture the listener's protocol set and
resolved carrier config, and pass the protocol set into subprotocol selection:

```erlang
init(Req0, RouteState) ->
    %% The route state is built once per listener by
    %% `bondy_http_services:carrier_state/3', so the handler performs no
    %% configuration lookup per connection.
    %% No defaults on either lookup. `carrier_state/3` always sets both keys,
    %% so a default could never fire and would only hide a route state built
    %% some other way — and defaulting `protocols` in particular would silently
    %% restore the unrestricted behaviour this task exists to remove.
    Protocols = maps:get(protocols, RouteState),
    Config = maps:get(config, RouteState),
    Subprotocols = cowboy_req:parse_header(?SUBPROTO_HEADER, Req0),

    try
        {ok, Subproto, BinProto} = select_subprotocol(Subprotocols, Protocols),
        %% ... existing body, with Config carried into the state record
```

Replace `select_subprotocol/1` (`:501-518`) with the version below.

The filter must key off the **binary subprotocol id**, not the validated tuple.
`bondy_wamp_protocol:subprotocol/1` (`bondy_wamp_protocol.erl:1198-1209`) maps
each `?WAMP2_*` id to a `{Transport, Framing, Encoding}` tuple — `<<"wamp.2.json">>`
becomes `{ws, text, json}` — so the protocol family is **discarded** by
validation and survives only in the id's prefix. Filtering before validation is
therefore the only correct order, and it has the side benefit of not validating
ids the listener would refuse anyway.

```erlang
-spec select_subprotocol(list(binary()) | undefined, [atom()]) ->
    {ok, bondy_wamp_protocol:subprotocol(), binary()}
    | no_return().

select_subprotocol(undefined, _Allowed) ->
    throw(missing_subprotocol);
select_subprotocol(L, Allowed) when is_list(L) ->
    %% A subprotocol this build supports is not necessarily one THIS listener
    %% offers: the operator chooses per listener which protocols it carries, so
    %% an offer outside that set is refused even though it would validate.
    Offered = [X || X <- L, lists:member(protocol_family(X), Allowed)],

    case Offered of
        [] ->
            throw(invalid_subprotocol);
        _ ->
            select_valid(Offered)
    end.

%% @private
select_valid([]) ->
    throw(invalid_subprotocol);
select_valid([X | T]) ->
    case bondy_wamp_protocol:validate_subprotocol(X) of
        {ok, Proto} -> {ok, Proto, X};
        {error, invalid_subprotocol} -> select_valid(T)
    end.

%% @private
%% The protocol family lives only in the subprotocol id's prefix:
%% `bondy_wamp_protocol:subprotocol/1' resolves `wamp.2.json' to
%% `{ws, text, json}', dropping the family, so it cannot be recovered from the
%% validated tuple.
protocol_family(<<"wamp.", _/binary>>) -> wamp;
protocol_family(<<"bamp.", _/binary>>) -> bamp;
protocol_family(_) -> undefined.
```

Replace the two global reads. At `:344`:

```erlang
    Timeout = maps:get(idle_timeout, State#state.config),
```

and at `:463`, use `State#state.config` in place of
`bondy_config:get(wamp_websocket)`. Add a `config` field to the state record.

- [ ] **Step 4: Run the suite to verify it passes**

Run: `CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_listener_SUITE.erl`
Expected: PASS, 9 cases.

- [ ] **Step 5: Run the WebSocket-facing existing suites**

Run:
```
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_http_sse_SUITE.erl
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_http_longpoll_SUITE.erl
```
Expected: PASS. These exercise the carriers whose config resolution just moved.

- [ ] **Step 6: Format and checkpoint**

Report: per-listener protocol restriction and carrier config, with the
subprotocol-refusal case as the evidence. Name the suites run.

---

### Task 10: Regenerate shipped configuration and document

**Files:**
- Modify: `config/bondy.conf.defaults`
- Modify: `config/dev/bondy.conf.template`, `config/bridge/bondy.conf.template`,
  `config/test/node_1_bondy.conf.template`, `config/test/node_2_bondy.conf.template`,
  `config/test/node_3_bondy.conf.template`, `config/test/edge_1_bondy.conf.template`
- Modify: `apps/bondy_router/test/bondy_ct.erl` (the `?ENV` `bondy_router` block)
- Create: a listeners page under the documentation extras used by `rebar3 ex_doc`

**Interfaces:**
- Consumes: the schema from Tasks 7–8.
- Produces: no code.

**The documentation surface, verified — and a live example of getting it wrong.**
`rebar.config` carries two independent lists and a page must be in **both**:
`{extras, [...]}` (from `:810`) and `{groups_for_extras, #{...}}` (from `:840`).
The groups are `Introduction`, `Architecture`, `Tutorials` (empty),
`How-to Guides`, `Deployment` (empty) and `Technical Reference`. The existing
configuration guides are split across two of them — `migrating_from_1.0.0-rc.65.md`
under `How-to Guides` (`:862`), `reclamation_options.md` and
`load_regulation_and_rate_limiting.md` under `Technical Reference` (`:872-873`).
A `listeners.$name.*` reference page belongs under `Technical Reference`; if you
also write migration prose for operators moving off the legacy keys, that belongs
under `How-to Guides`.

**`doc/guides/configuration/http_security_headers.md` exists on disk and appears
zero times in `rebar.config`** — in neither list, so it is not published at all. A
written guide nobody can read is the exact failure mode to avoid here, and it is
already in the tree. Also note ex_doc **flattens** every extra to a page named by
its basename, so a new `listeners.md` must not collide with an existing basename.
After adding the page, confirm it actually renders rather than assuming: `rebar3
ex_doc` and then check the generated output contains the page.

**Regeneration will not document the new block — measured, not assumed.**
`_build/default/bin/cuttlefish effective -s schema/` (what `make conf` runs)
emits 523 lines and **zero** `listeners.*` keys. That is correct and expected:
a fuzzy `$name` mapping materialises nothing until some name is mentioned, and
`effective` is given no conf file. So `config/bondy.conf.defaults` — the
reference an operator reads to discover what is configurable — cannot show the
new block at all, and an operator reading it would not learn the block exists.
Every `listeners.$name.*` example in the templates and in the documentation page
has to be **hand-written**. Do not expect the generator to produce it, and do not
conclude from an unchanged defaults file that Task 7 failed to land.

**`config/bondy.conf.defaults` is already stale at HEAD, for reasons unrelated to
this plan.** Diffing a fresh `effective` run against the committed file shows 25
lines of pre-existing drift:

- `cluster.channels.wamp_relay.parallelism` is `8` in the schema and `2` in the
  committed file
- 23 `db.leveled.*` keys plus `db.journal_trim_interval` are absent from the
  committed file, and `db.primary_scan_limit` too

Regenerating therefore produces a diff containing those 25 lines. That is
**correct** — the file is generated output and should match the schema — but it
is not this plan's work. Do not revert it, and say so explicitly in your report
so the reviewer does not read it as unrequested scope.

**Fix the dev template's TLS paths while you are here.** Task 8 found that
`config/dev/bondy.conf.template`'s `wamp.tls.{certfile,keyfile,cacertfile}` point
at `${BONDY_ETC_DIR}/ssl/*.pem` while the actual files are under
`.../ssl/server/`, unlike the `admin_api.https` and `api_gateway.https` entries in
the same file, which were corrected at some point. Task 8 only worked around it in
the build directory in order to observe a clean boot; the template is still wrong.
A template that cannot boot a TLS listener undermines the very check Step 1 makes.

All six templates named above were confirmed present.

**Carry over from Task 7b — the ordering nothing pins yet.** Task 7b's whole
purpose is a boot-time ordering dependency: `splat_listener_blocks/0` must run
between `app_config:init/2` and `bondy_listener_manager:init/0`. Task 7b
demonstrated the dependency (moving the call after the manager makes a
new-style TLS listener fail with
`{error, {invalid_listener, tls_x, {missing, [tls, certfile]}}}`) but only
through an out-of-band probe against the compiled beams: **no suite in the repo
fails when the call is moved.** `bondy_listener_SUITE` never calls
`bondy_config:init/1`, and the only enabled TLS listener in the test
environment takes its material from `bondy_ct`'s legacy top-level `wamp_tls`
proplist, which `app_config:init/2` caches regardless of where the splat sits.

This task is the deadline for closing that, because it is where the new style
becomes the shipped default and the latent break becomes a real one. Add a
new-style TLS listener — material **only** in its nested `tls` block — to the
`bondy_router` block of `bondy_ct`'s `?ENV`. Every suite that boots then
exercises the ordering, and a future reordering of `bondy_config:init/1` aborts
boot loudly instead of silently disabling TLS.

Two hazards, both verified against the current file:

1. `start_bondy/0` asserts
   `length(BondyEnv) == length(application:get_all_env(bondy_router))` and calls
   `exit(configuration_error)` on mismatch
   (`apps/bondy_router/test/bondy_ct.erl:749-751`). So the listener cannot be
   injected by a suite before boot — it has to go into `?ENV` itself, and the
   assertion means adding the key changes what every booting suite sees.
2. The new listener binds a port in the shared test environment. Pick one
   outside every range already in use and outside bondy_ct's Partisan base
   (`18086`), and reuse the existing test certificates rather than generating
   new ones — `./etc/ssl/server/keycert.pem` and its `cacert.pem` are already
   referenced from `?ENV` (`bondy_ct.erl:127-135`).

- [ ] **Step 1: Convert one template and boot it**

Rewrite `config/dev/bondy.conf.template`'s 45 legacy listener keys as
`listeners.*` blocks. The dev template's public HTTP listener becomes:

```
listeners.api_gateway_http.transport            = tcp
listeners.api_gateway_http.protocol             = http
listeners.api_gateway_http.port                 = 18080
listeners.api_gateway_http.services             = api_gateway, wamp_ws, wamp_sse, wamp_longpoll
listeners.api_gateway_http.acceptors_pool_size  = 200
listeners.api_gateway_http.backlog              = 4096
listeners.api_gateway_http.max_connections      = 500000
listeners.api_gateway_http.keepalive            = off
listeners.api_gateway_http.nodelay              = on

listeners.admin_api_http.transport    = tcp
listeners.admin_api_http.protocol     = http
listeners.admin_api_http.ip           = 127.0.0.1
listeners.admin_api_http.port         = 18081
listeners.admin_api_http.start_phase  = early
listeners.admin_api_http.services     = api_gateway, wamp_ws, admin, metrics

listeners.wamp_tcp.transport           = tcp
listeners.wamp_tcp.protocol            = wamp_rawsocket
listeners.wamp_tcp.port                = 18082
listeners.wamp_tcp.acceptors_pool_size = 200
listeners.wamp_tcp.backlog             = 1024
listeners.wamp_tcp.max_connections     = 100000
listeners.wamp_tcp.keepalive           = on
listeners.wamp_tcp.nodelay             = on

listeners.wamp_tls.transport    = tls
listeners.wamp_tls.protocol     = wamp_rawsocket
listeners.wamp_tls.port         = 18085
listeners.wamp_tls.tls.certfile = ./etc/ssl/server/keycert.pem
listeners.wamp_tls.tls.keyfile  = ./etc/ssl/server/key.pem
listeners.wamp_tls.tls.cacertfile = ./etc/ssl/server/cacert.pem
listeners.wamp_tls.tls.versions = 1.2,1.3
listeners.wamp_tls.tls.verify   = verify_none
```

Keep the existing key names as listener names so port numbers and any external
tooling that greps the template still line up.

- [ ] **Step 2: Boot the dev release on the converted template**

Run: `rebar3 as dev release`, then start the node.
Expected: the boot log shows each listener once, with no deprecation warning
(they are all new-style now), and `curl -s localhost:18081/ping` answers.

- [ ] **Step 3: Convert the remaining five templates and the defaults file**

Apply the same conversion to `config/bridge/bondy.conf.template` (40 keys),
`config/test/node_{1,2,3}_bondy.conf.template` (57, 57, 43) and
`config/test/edge_1_bondy.conf.template` (33). In
`config/bondy.conf.defaults`, replace the 212 legacy listener keys with the
`listeners.$name.*` documentation. Because none of the new mappings has a
default, every line in that file is a **commented** example — mark them so
cuttlefish does not treat them as set:

```
## The transport this listener binds. `tls` and `quic` terminate TLS and
## require listeners.<name>.tls.certfile and .keyfile.
## Acceptable values:
##   - one of: tcp, tls, uds, quic
# listeners.$name.transport = tcp
```

- [ ] **Step 4: Run the three-node cluster suite**

Run: `CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_aae_cluster_SUITE.erl`
Expected: PASS. This is the check that the converted `node_{1,2,3}` templates
still produce a working cluster.

- [ ] **Step 5: Write the documentation page**

Add a listeners page to the doc extras, covering: the four required keys; the
service table; that TLS is a transport rather than a protocol; that `services`
is HTTP-only; the `start_phase` rule; and that legacy keys are deprecated with
the mapping to their replacements. Follow the house style — behaviour and
contracts only, no benchmark numbers or test results.

Run: `rebar3 ex_doc`
Expected: builds clean. Remember ex_doc flattens extras, so the new file's
basename must not collide with an existing one.

- [ ] **Step 6: Final verification**

Run all three test kinds, sequentially, never in parallel:
```
rebar3 as test eunit --module=bondy_listener_config_test
rebar3 as test eunit --module=bondy_http_services_test
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_listener_SUITE.erl
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_listener_schema_SUITE.erl
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_http_api_gateway_SUITE.erl
```
Then `rebar3 dialyzer`. Do not delete the PLT — it is an accumulated cache and
warning counts are not a stable metric; compare against the pre-change run.

- [ ] **Step 7: Checkpoint**

Report: every template converted and booted, defaults file rewritten, docs page
building, and the exact output of each command above. State plainly anything
that failed or was skipped.

---

## Out of scope

Carried from the design doc §9, so no task above attempts them:

- **`quicer` and `bondy_listener_quic`.** `transport = quic` resolves and is
  rejected at start with a clear error until the driver exists. Adding the
  msquic NIF is a build-system change that must land and be verified on its own.
- **QUIC certificate rotation.** The ssl `sni_fun` path does not apply.
- **Per-listener rate limiting and CIDR allow-lists.** `security.rate_limit.*`
  stays global.
- **Runtime add/remove of listeners.** Boot-time only.
- **`bamp_rawsocket` and the `bamp_ws` handler.** The resolver accepts the
  service and protocol names; no handler exists until BAMP lands.
### Task 11: Make the per-listener TLS block reach the socket

**Files:**
- Modify: `apps/bondy_router/src/bondy_config.erl` — `listener_transport_opts/1`,
  `splat_listener_blocks/0`
- Modify: `doc/guides/configuration/listeners.md` and
  `config/bondy.conf.listeners.example` — drop the caveat once it is false
- Test: `apps/bondy_router/test/bondy_listener_SUITE.erl` (append)

**Interfaces:**
- Consumes: the resolved `tls` block at `bondy_router.<name>.tls` that
  `splat_listener_blocks/0` already writes.
- Produces: no new exported functions.

**The defect.** `listeners.$name.tls.*` is recognised, validated, and never
reaches the socket ranch binds with, so a new-style TLS listener fails to bind
with `no_cert` — **after** validation has approved it, which is the most
confusing order for a failure to happen in. Measured:

- `bondy_config:listener_transport_opts/1` reads **only**
  `[Name, transport_opts]`. It never reads `[Name, tls]`.
- `bondy_listener_config:tls_material/3` reads `[Name, tls, K]` and falls back
  to `[Name, transport_opts, socket_opts, K]`, but it is used only by
  `assert_tls_keys/3` — validation, not binding. Its own comment says the
  fallback "goes with `default_inventory/0`" once the schema renders a `tls`
  block per listener; the schema now does, and the bind path was never wired.

**The shapes, probed rather than assumed.** Rendering

```
listeners.probe.transport = tls
listeners.probe.tls.certfile = /tmp/keycert.pem
listeners.probe.tls.versions = 1.3
```

yields the spec

```erlang
#{port => 19999, protocol => wamp_rawsocket, transport => tls,
  tls => #{certfile => "/tmp/keycert.pem", versions => ['tlsv1.3']}}
```

— a **map**, values already converted by the translation. The legacy app-env
block is a **proplist** with a nested `socket_opts` proplist:

```erlang
[{handshake_timeout, 5000},
 {socket_opts, [{reuseport, false}, {nodelay, true}, {backlog, 4096},
                {port, 18080}, {ip_version, inet}]},
 {max_connections, 10000}, {num_acceptors, 50}]
```

The key names need **no translation**: `listeners.$name.tls.verify` is
`{enum, [verify_peer, verify_none]}` and legacy `wamp.tls.verify` targets
`transport_opts.socket_opts.verify` with the same enum, so `certfile`,
`keyfile`, `cacertfile`, `versions` and `verify` fold straight into
`socket_opts` as ssl expects them.

**Precedence must mirror `tls_material/3`:** the `tls` block wins over anything
in the legacy `socket_opts`, so validation and binding cannot disagree about
which certificate is in force. A listener that sets neither is already rejected
by `assert_tls_keys/3`.

**Second defect, same plumbing.** `splat_listener_blocks/0` does
`set([Name, Key], Value)` — a **replace**. So a listener that needs historical
socket tuning cannot also use any new-style `transport_opts`-level key: setting
`listeners.x.acceptors_pool_size` discards the legacy `backlog`, `keepalive` and
`nodelay` for that listener. Every shipped template works around this by keeping
all five transport keys on one spelling, with a comment explaining why. Make the
splat **merge** into the existing block instead, nested `socket_opts` included —
a shallow merge is not enough, because a spec carrying any socket-level key
would then wipe the legacy `socket_opts` wholesale.

Keep the absence rule intact: only keys the spec actually carries are written,
and `undefined` is never written for an absent key.

**Note a gap, do not close it here.** Legacy has `wamp.tls.fail_if_no_peer_cert`
with no counterpart in the five-key new block, so an operator using
`listeners.$name.tls.*` cannot set it. Decide whether to add the mapping or
document the omission, and say which you chose.

- [ ] **Step 1: Write the failing test**

Append to `bondy_listener_SUITE`. The falsification is that a listener whose
certificate is declared **only** in the new-style block must actually bind and
terminate TLS — the existing suites all put material on the historical key, which
is exactly why this went unnoticed:

```erlang
new_style_tls_listener_binds(_Config) ->
    %% The certificate is in the `tls` block and NOWHERE else, so this fails
    %% with `no_cert` until the block reaches ranch's socket options. Port 0:
    %% the bind target is irrelevant to what is being tested and an ephemeral
    %% port cannot collide with a parallel run.
    ok = bondy_config:set(listeners, [
        {ct_new_tls, #{
            transport => tls,
            protocol => wamp_rawsocket,
            port => 0,
            tls => #{
                certfile => "./etc/ssl/server/keycert.pem",
                keyfile => "./etc/ssl/server/key.pem",
                cacertfile => "./etc/ssl/server/cacert.pem"
            }
        }}
    ]),
    ok = bondy_config:splat_listener_blocks(),
    ok = bondy_listener_manager:init(),
    ok = bondy_listener_manager:start(normal),
    {ok, L} = bondy_listener_manager:listener(ct_new_tls),
    ?assertMatch(#{transport := tls}, L),
    %% Bound, not merely resolved: ask ranch for the port it actually got.
    ?assert(is_integer(ranch:get_port(ct_new_tls))).

legacy_socket_tuning_survives_a_new_style_transport_key(_Config) ->
    %% Both spellings target `transport_opts`; a replacing splat drops the
    %% legacy three silently, which is the failure every shipped template
    %% currently works around by hand.
    ok = bondy_config:set(
        [ct_merge, transport_opts],
        [{socket_opts, [{backlog, 4096}, {nodelay, true}]}]
    ),
    ok = bondy_config:set(listeners, [
        {ct_merge, #{
            transport => tcp,
            protocol => wamp_rawsocket,
            port => 0,
            transport_opts => #{num_acceptors => 7}
        }}
    ]),
    ok = bondy_config:splat_listener_blocks(),
    Opts = bondy_config:listener_transport_opts(ct_merge),
    ?assertEqual(7, maps:get(num_acceptors, Opts)),
    SocketOpts = maps:get(socket_opts, Opts),
    ?assertEqual(4096, key_value:get(backlog, SocketOpts)),
    ?assertEqual(true, key_value:get(nodelay, SocketOpts)).
```

- [ ] **Step 2: Run them to verify they fail**

Run: `CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_listener_SUITE.erl`
Expected: FAIL — the first on the bind (`no_cert`), the second because the splat
replaced the legacy block.

- [ ] **Step 3: Fold the `tls` block into the socket options**

In `listener_transport_opts/1`, after `SocketOpts0` is normalised and before
`maybe_inject_sni_fun/2`, fold the resolved `tls` map in, letting it win:

```erlang
    SocketOpts1 = with_tls_material(Name, SocketOpts0),
    SocketOpts = bondy_cert_manager:maybe_inject_sni_fun(Name, SocketOpts1),
```

```erlang
%% @private
%% The per-listener `tls` block is where a listener declares its certificate.
%% It has to reach ranch's socket options, not just the validation in
%% `bondy_listener_config:assert_tls_keys/3` — otherwise a listener passes its
%% certificate check and then fails to bind with `no_cert`.
%%
%% The block wins over anything of the same name in `socket_opts`, matching the
%% precedence `bondy_listener_config:tls_material/3` uses, so validation and
%% binding cannot disagree about which certificate is in force. `certfile`,
%% `keyfile`, `cacertfile`, `versions` and `verify` are already the names and
%% value shapes ssl expects, so nothing is translated here.
with_tls_material(Name, SocketOpts) ->
    maps:fold(
        fun(K, V, Acc) -> lists:keystore(K, 1, Acc, {K, V}) end,
        SocketOpts,
        key_value:to_map(get([Name, tls], #{}))
    ).
```

- [ ] **Step 4: Make the splat merge**

Replace the wholesale `set([Name, Key], Value)` with a merge of the spec's value
into whatever is already at that path, recursing so a nested `socket_opts` is
merged rather than replaced. Write only the keys the spec carries.

- [ ] **Step 5: Run them to verify they pass**

Run the suite above, then the regression set:

```
rebar3 as test eunit --module=bondy_listener_config_test
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_admin_listener_SUITE.erl
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_listener_schema_SUITE.erl
```

and the two batched in one invocation, since `bondy_config` is shared:

```
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=apps/bondy_router/test/bondy_listener_SUITE.erl,apps/bondy_router/test/bondy_admin_listener_SUITE.erl
```

- [ ] **Step 6: Retire the caveat**

`doc/guides/configuration/listeners.md` and
`config/bondy.conf.listeners.example` both tell operators the five `tls.*` keys
"do not yet reach the running listener". Once Step 3 lands that sentence is
false — remove it from both, and remove the paragraph advising `transport = tcp`
for a listener with no historical counterpart, since such a listener can now be
given a certificate directly.

Then convert one shipped template to prove it end to end: give
`config/dev/bondy.conf.template`'s TLS listener its material through
`listeners.$name.tls.*` instead of the historical key, boot the dev release, and
confirm with `openssl s_client` that it terminates TLS.

- [ ] **Step 7: Format and checkpoint**

Run `rebar3 fmt` on the touched Erlang files. Report: the bind proven with a real
TLS handshake, the merge test, the `fail_if_no_peer_cert` decision, and the
template converted.

---
