# Listener review fixes — implementation plan

**Goal:** Close the findings from the architect review of the dynamic-listeners
branch, restore the listener defaults the legacy-mapping removal silently
dropped, and normalise the carrier model so a carrier/module inconsistency
cannot be expressed.

**Architecture:** Three kinds of change, in this order. (1) A *behaviour
regression*: defaults that used to arrive from legacy schema mappings vanished
with them; they are restored from one site and the validation that guarded the
gap is deleted because it becomes unreachable. (2) A *normalisation*: `module`
moves from the service table to a carrier table, `rest` splits into the two
route sources it was conflating, and the module is resolved by the resolver
rather than at dispatch — after which two consumers stop re-deriving what the
resolver knew. (3) *Local defects*: one duplicated default policy, one
over-strict bind check, and a cluster of one-line fixes.

**Tech stack:** Erlang/OTP 28, rebar3, cuttlefish 3.0.1, Cowboy 2.17 / ranch 2.2,
eunit + PropEr + Common Test.

## Global Constraints

- **Never run `git commit`, `git add` or `git push`.** Every task ends with a
  dirty tree and a report. The user commits.
- **No plan or design-doc references in source code or comments.** Comments
  state the mechanism, never "see the plan" or "task 3".
- **No `Co-Authored-By` trailer** anywhere.
- **Comments and docs state only what is verified.** Name the test, probe or
  source that establishes each claim, or phrase it as an intention.
- **erlfmt owns layout**, width 80. `rebar3 fmt --check` must be clean before a
  task is reported done. `scripts/*.escript` and `schema/*.schema` are NOT in
  the erlfmt glob — hand-format those at 80 columns.
- **Never run eunit, ct and proper in parallel.** Sequentially, and all three
  before claiming a task done.
- **Several CT suites = ONE comma-separated `--suite=`.** Repeated `--suite=`
  flags run only one and report a clean pass for the rest.
- **Never `rm` the dialyzer PLT.**
- `CMAKE_POLICY_VERSION_MINIMUM=3.5` must be exported for every rebar3
  invocation.
- One mechanism per task, verified in isolation before the next begins.
- After restoring a mutated file during mutation testing, `touch` it — `mv`
  preserves the old mtime and rebar3 skips recompiling, so the mutant keeps
  running.

---

## File structure

| File | Responsibility after this work |
|---|---|
| `apps/bondy_router/src/bondy_listener_config.erl` | Resolves and validates the inventory. Gains: transport/protocol option defaults and their precedence, the carrier→module table, module resolution, address-aware bind clash. Loses: `ping_siblings_of/1`. |
| `apps/bondy_router/src/bondy_http_services.erl` | Route contributions only. Loses `carrier_module/2` and its only call into `bondy_listener_config`. |
| `apps/bondy_router/src/bondy_http_service.erl` | Behaviour. Callback takes the resolved carrier. |
| `apps/bondy_router/src/bondy_config.erl` | Splats a GIVEN inventory's option blocks (`splat_listener_blocks/1`). Decides nothing about which inventory that is. |
| `apps/bondy_router/src/bondy_listener_manager.erl` | Owns the effective inventory: operator's + reserved + internal, with option defaults applied, and publishes it before resolving. |
| `apps/bondy_router/src/bondy_listener_ranch.erl` | Driver. Effects hoisted out of `protocol_opts/1`; `alarms/1` folded. |
| `apps/bondy_router/src/bondy_wamp_ws_connection_handler.erl` | Unrepresentable-sentinel for the protocol family. |
| `apps/bondy_router/src/bondy_listener_wamp_api.erl` | **New.** WAMP admin procedures for listener suspend/resume. |
| `schema/bondy.schema` | Loses the CORS / security-header default completion; keeps the conversions. |
| `_plans/2026-08-14-dynamic-listeners-design.md` | Corrected: `listener_transport_opts/2`, the carrier model, the defaults audit. |

---

## Task 1: Audit and restore the defaults the legacy removal dropped

The review found two: raw-socket server-initiated ping (`wamp.tcp.ping.enabled`
defaulted to `on`, its replacement is default-free, no shipped template sets it,
so keepalive is now off everywhere) and the raw-socket `idle_timeout` (defaulted
to `8h`, the handler now falls back to `infinity`). Both were found by accident.
The removal deleted 331 mappings, so the first step is to find out whether there
is a third.

**Files:**
- Audit only: `git show 73c7644c:schema/bondy.schema`,
  `git show 73c7644c:schema/bondy_bridge_relay.schema`
- Modify: `apps/bondy_router/src/bondy_listener_config.erl`
- Modify: `apps/bondy_router/src/bondy_config.erl`
- Modify: `CHANGELOG.md`
- Test: `apps/bondy_router/test/bondy_listener_config_test.erl`

**Interfaces:**
- Produces: `bondy_listener_config:option_defaults(Transport, Protocol) -> map()`
  and `bondy_listener_config:with_option_defaults(Spec) -> Spec`, consumed by
  `bondy_listener_manager:init/0`.
- Produces: `bondy_config:splat_listener_blocks(Inventory) -> ok`, replacing the
  arity-0 form.

**Deviations from this plan, as built.** Three, each with its reason:

1. **The defaults table is keyed on transport AND protocol**, not protocol
   alone, and precedence lives beside it as `with_option_defaults/1` rather
   than in `bondy_config`. HSTS belongs to `tls` + `http` together and to
   neither axis alone; keeping the merge next to the table leaves both pure and
   eunit-testable, and leaves `bondy_config` with no deep-merge of its own.
2. **`splat_listener_blocks/0` became `/1`, and the call moved into
   `bondy_listener_manager:init/0`.** `bondy_router.listeners` holds only the
   operator's half of the inventory, so splatting from it reached neither the
   `default_inventory/0` listeners — which is what `prod`, `prod_named` and
   `docker` boot on, the three releases this task exists to fix — nor the
   injected `admin` and `admin_local`. The manager already decides what the
   effective inventory is; it now also publishes it. `bondy_config:init/1`
   loses its own splat call, and the splat-before-resolve ordering it
   documented becomes internal to one function.
3. **The ping-validation cluster is KEPT, not deleted** (Step 7 below said
   delete five functions). The defaults make an incomplete enabled ping block
   unrepresentable only for an inventory routed through
   `bondy_listener_manager:init/0`. `resolve/2` is a public entry point that
   bypasses `with_option_defaults/1` — every case in
   `bondy_listener_config_test` uses it that way — so the check still catches
   something. What DID collapse is `ping_siblings_of/1`: now that the
   raw-socket handler reads `ping.idle_timeout`, both stream protocols require
   the same three siblings, so the per-protocol function is gone and the list
   is inline. `assert_ping_complete/3` and `ping_siblings/1` stay untouched:
   they guard the CARRIER ping block, whose defaults come from the global
   `wamp.<carrier>.*` mappings and are unaffected by any of this.

**One lost default deliberately not restored:** `wamp.{tcp,tls}.linger.timeout`.
Its datatype was `[{duration, ms}, integer]`, so `{default, "1s"}` rendered
`1000`, and `bondy_config:normalise_socket_opts/1` passes that value straight
into `{linger, {true, 1000}}` — whose second component `inet` documents as
SECONDS (`kernel/src/inet.erl:1124`, OTP 28.5). What shipped was a 1000-second
linger on close. Restoring `1000` restores the defect; restoring `1` gives the
default a different unit from every operator value for the same key. The unit is
a defect of the KEY, fixed on its own, and the default goes back on top of that
fix. `rawsocket_linger_default_is_deliberately_not_restored_test` holds the
decision.

- [ ] **Step 1: Enumerate every default that was deleted**

For each mapping removed from `schema/bondy.schema` and
`schema/bondy_bridge_relay.schema` under the `api_gateway.*`, `admin_api.*`,
`wamp.{tcp,tls}.*`, `wamp.uds.*` and `bridge.listener.*` prefixes, record: the
conf key, its `{default, …}` if any, its app-env target, and where that value
comes from today (a `listeners.$name.*` mapping the templates set, a
`bondy_config` default, a handler fallback, or **nowhere**).

Write the table to `_plans/2026-08-19-lost-defaults-audit.md`. Every row whose
"today" column is *nowhere* is a behaviour change to restore or to accept
deliberately.

**A shipped template setting the key is not coverage.** `rebar3_scuttler`
generates `etc/bondy.conf` from the schemas for every release
(`rebar.config:1030-1032`), writing each non-fuzzy default as an ACTIVE line —
verified in `_build/docker/rel/bondy/etc/bondy.conf` (2026-07-31, pre-branch),
which carries `wamp.tcp.ping.enabled = on`. A *schema* default therefore reached
every release. A *template* value reaches only the releases overlaying that
template: `dev`, `node1`, `node2`, `node3`, `edge_1`, `bridge` and `fly`.
`prod`, `prod_named` and `docker` overlay none, so for those three a legacy
default is reproduced today only if CODE reproduces it. They are the most
exposed, not the least.

A `listeners.$name.*` mapping cannot appear in a generated conf at all — a fuzzy
mapping has no concrete name to enumerate — which is both why the defaults must
live in code and why `bondy_router.listeners` stays unclaimed so that
`default_inventory/0` applies.

- [ ] **Step 2: Write the failing tests, one per restored default**

In `bondy_listener_config_test.erl`. The shape, for ping:

```erlang
rawsocket_ping_is_enabled_by_default_test() ->
    %% wamp.tcp.ping.enabled defaulted to `on' and every render materialised
    %% it, so raw-socket keepalive was on for every node. The replacement
    %% mapping is default-free, so the default has to come from here.
    Defaults = bondy_listener_config:protocol_option_defaults(wamp_rawsocket),
    ?assertMatch(#{ping := #{enabled := true}}, Defaults),
    ?assertMatch(#{ping := #{timeout := 10000}}, Defaults),
    ?assertMatch(#{ping := #{max_attempts := 2}}, Defaults).

operator_ping_setting_beats_the_default_test() ->
    %% deployment/fly/config/bondy.conf.template:105 sets this off; it must
    %% stay off.
    Spec = #{
        transport => tcp, protocol => wamp_rawsocket, port => 0,
        ping => #{enabled => false}
    },
    ok = bondy_config:set([raw, ping, enabled], false),
    ...
```

- [ ] **Step 3: Run them to verify they fail**

`CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 eunit --module=bondy_listener_config_test`
Expected: `undef` on `protocol_option_defaults/1`.

- [ ] **Step 4: Add the defaults, defined in one place**

In `bondy_listener_config.erl`. Values come from the Step 1 audit — do not
invent numbers.

```erlang
%% The option-block defaults a listener's PROTOCOL implies, restored from the
%% legacy mappings they used to arrive from. Each entry names the mapping it
%% came from and that mapping's own default:
%%
%%   ping.enabled      was wamp.tcp.ping.enabled      = on
%%   ping.timeout      was wamp.tcp.ping.timeout      = 10s
%%   ping.max_attempts was wamp.tcp.ping.max_attempts = 2
%%   idle_timeout      was wamp.tcp.idle_timeout      = 8h
%%
%% They live here rather than on the `listeners.$name.*' mappings because a
%% fuzzy mapping's default materialises for EVERY listener name mentioned under
%% the prefix, which would make the global carrier fallback permanently dead and
%% fire the driver-inapplicability checks on values nobody wrote.
-define(PROTOCOL_DEFAULTS, #{
    wamp_rawsocket => #{
        idle_timeout => 28800000,
        ping => #{enabled => true, timeout => 10000, max_attempts => 2}
    },
    bridge_relay => #{...}   %% from the audit
}).

-spec protocol_option_defaults(protocol()) -> map().

protocol_option_defaults(Protocol) ->
    maps:get(Protocol, ?PROTOCOL_DEFAULTS, #{}).
```

- [ ] **Step 5: Apply them where they reach the consumers**

The raw-socket handler reads `bondy_config:get([Listener, ping], …)` and
`bondy_config:get([Ref, idle_timeout], infinity)` — that is **application
environment**, not the resolved listener map, so a default added to the resolved
map alone would not reach it. `bondy_config:splat_listener_blocks/0` is the one
place that writes those paths, and it already has the spec's `protocol` in hand.

In `bondy_config.erl`, deep-merge the defaults UNDER the operator's spec so an
operator value always wins:

```erlang
splat_listener_blocks() ->
    ...
    _ = [
        splat(Name, [Key], Value)
     || {Name, Spec0} <- Inventory,
        Spec <- [with_protocol_defaults(Spec0)],
        {Key, Value} <- maps:to_list(Spec),
        not lists:member(Key, ?SPEC_KEYS)
    ],
    ok.

%% @private
%% Deep, and the SPEC wins: an operator who set `ping.enabled = off' keeps it,
%% and one who set only `ping.timeout' still gets the other siblings.
with_protocol_defaults(#{protocol := Protocol} = Spec) ->
    deep_merge(
        bondy_listener_config:protocol_option_defaults(Protocol), Spec
    );
with_protocol_defaults(Spec) ->
    Spec.
```

`deep_merge/2` must recurse only into maps, matching `splat/3`'s own rule that a
list-valued leaf is a value and not a nested block.

- [ ] **Step 6: Run the tests to verify they pass**

- [ ] **Step 7: Delete the ping-validation cluster, which is now unreachable**

With Step 5 in place an enabled ping block always carries its siblings, so the
state these five functions detect cannot occur. Delete from
`bondy_listener_config.erl`: `assert_ping_complete/3`, `assert_listener_ping/3`,
`assert_ping_keys/4`, `ping_siblings/1`, `ping_siblings_of/1`, and the calls to
the first two. Delete the corresponding cases from
`bondy_listener_config_test.erl`
(`partial_ping_*`, `partial_listener_ping_*`, `malformed_ping_enabled_*`,
`ping_off_is_the_handler_fall_through_test`).

Keep the four-clause `maybe_enable_ping/2` in all three handlers, including the
`error({invalid_ping_enabled, Invalid})` clause: it is now the only rejection of
a non-boolean `enabled` from `sys.config` or an embedded caller. Keep the
`-ifdef(TEST)` export and replace its comment, which cites the deleted
`assert_ping_keys/4`, with one naming what the clause protects.

- [ ] **Step 8: Falsify the restoration**

Revert `with_protocol_defaults/1` to the identity and confirm
`rawsocket_ping_is_enabled_by_default_test` fails. `touch` the file after
restoring it.

- [ ] **Step 9: CHANGELOG**

A Fixes entry per restored default, stating the old mapping, its default, and
the releases affected. No test counts.

- [ ] **Step 10: Verify and report**

`rebar3 fmt --check`, then
`rebar3 eunit --module=bondy_listener_config_test`, then
`rebar3 as test ct --suite=apps/bondy_router/test/bondy_listener_SUITE,apps/bondy_router/test/bondy_listener_boot_SUITE`.
Stop. Report the audit table and the diff. Do not commit.

---

## Task 2: Normalise carrier → module

`module` currently rides on each service, so two services naming one carrier can
carry two values for a field that depends on `carrier` alone — which is what
lets an operator's service list be internally inconsistent, and what forces
`bondy_http_services:carrier_module/2` to re-derive the module by re-scanning
`services` and taking the first match.

**Files:**
- Modify: `apps/bondy_router/src/bondy_listener_config.erl`
- Modify: `apps/bondy_router/src/bondy_http_services.erl`
- Modify: `apps/bondy_router/src/bondy_http_service.erl`
- Test: `apps/bondy_router/test/bondy_listener_config_test.erl`,
  `apps/bondy_router/test/bondy_http_services_test.erl`

**Interfaces:**
- Produces: `carrier()` type = `#{module := module(), protocols := [atom()],
  config := map()}`; `-callback routes(Carrier :: atom(), carrier(),
  Listener :: t())`.
- Consumes: nothing new.

- [ ] **Step 1: Write the failing tests**

```erlang
resolved_carrier_carries_its_module_test() ->
    %% The module is resolved once, by the resolver, so nothing downstream has
    %% to re-derive it from the service list.
    {ok, [L]} = resolve([{pub, #{transport => tcp, protocol => http,
                                 port => 0, services => [wamp_ws, bamp_ws]}}]),
    #{websocket := #{module := Module, protocols := Protos}} =
        maps:get(carriers, L),
    ?assertEqual(bondy_http_services, Module),
    ?assertEqual([bamp, wamp], lists:sort(Protos)).

api_gateway_and_admin_api_are_separate_carriers_test() ->
    %% They differ by ROUTE SOURCE, not by protocol, so they cannot share a
    %% carrier: a carrier's protocol union cannot tell them apart.
    {ok, [L]} = resolve([{pub, #{transport => tcp, protocol => http,
                                 port => 0,
                                 services => [api_gateway, admin_api]}}]),
    Carriers = maps:get(carriers, L),
    ?assert(maps:is_key(api_gateway, Carriers)),
    ?assert(maps:is_key(admin_api, Carriers)),
    ?assertNot(maps:is_key(rest, Carriers)).

unknown_carrier_is_a_boot_error_test() ->
    %% A service registered by an application whose carrier table is absent
    %% fails at BOOT naming the listener, not at dispatch time inside a
    %% listener start or a spec rebuild.
    ok = application:set_env(bondy_router, http_services,
                             [{ghost, #{carrier => nowhere,
                                        protocol => undefined}}]),
    ?assertMatch(
        {error, {invalid_listener, pub, {unknown_carrier, nowhere, ghost}}},
        resolve([{pub, #{transport => tcp, protocol => http, port => 0,
                         services => [ghost]}}])
    ).

http_listener_with_no_services_is_rejected_test() ->
    %% An empty list resolves today and yields a listener that binds a socket
    %% and 404s every request, with no diagnostic.
    ?assertMatch(
        {error, {invalid_listener, pub, {missing, services}}},
        resolve([{pub, #{transport => tcp, protocol => http, port => 0,
                         services => []}}])
    ).
```

- [ ] **Step 2: Run them to verify they fail**

- [ ] **Step 3: Split the service table in two**

```erlang
%% carrier -> implementing module. One row per carrier, because a carrier owns
%% a path and a path is served by one handler. Keeping it here rather than on
%% each service is what makes two services naming one carrier unable to
%% disagree about who serves it.
carrier_module(websocket)   -> bondy_http_services;
carrier_module(sse)         -> bondy_http_services;
carrier_module(longpoll)    -> bondy_http_services;
carrier_module(admin)       -> bondy_http_services;
carrier_module(metrics)     -> bondy_http_services;
carrier_module(api_gateway) -> bondy_http_services;
carrier_module(admin_api)   -> bondy_http_services;
carrier_module(Other) ->
    case lists:keyfind(Other, 1, external_carriers()) of
        {Other, Module} -> Module;
        false -> undefined
    end.

%% service -> the carrier it is reachable on and the protocol it carries.
%% Both are intrinsic to the service NAME, which is why the legal
%% (protocol, carrier) pairs are exactly the atoms listed here: an operator
%% cannot name a pair nothing implements.
service_spec(api_gateway)   -> #{carrier => api_gateway, protocol => undefined};
service_spec(admin_api)     -> #{carrier => admin_api,   protocol => undefined};
service_spec(wamp_ws)       -> #{carrier => websocket,   protocol => wamp};
service_spec(bamp_ws)       -> #{carrier => websocket,   protocol => bamp};
service_spec(wamp_sse)      -> #{carrier => sse,         protocol => wamp};
service_spec(wamp_longpoll) -> #{carrier => longpoll,    protocol => wamp};
service_spec(admin)         -> #{carrier => admin,       protocol => undefined};
service_spec(metrics)       -> #{carrier => metrics,     protocol => undefined};
service_spec(Other) -> ...
```

`external_carriers/0` reads `application:get_env(bondy_router, http_carriers,
[])`. Add `?CARRIER_KEYS` entries for `api_gateway` and `admin_api` (both `[]`,
replacing `rest`).

- [ ] **Step 4: Resolve the module in `resolve_carriers/3`**

Replace the `maps:get/3`-with-eager-default fold with `maps:find/2`, so
`resolve_carrier_config/3` runs once per carrier instead of once per service:

```erlang
resolve_carriers(Name, Services, GetFun) ->
    lists:foldl(
        fun(Service, Acc) ->
            case service_spec(Service) of
                error ->
                    invalid(Name, {unknown_service, Service});
                #{carrier := Carrier, protocol := Protocol} ->
                    add_service(
                        Name, Service, Carrier, Protocol, Acc, GetFun
                    )
            end
        end,
        #{},
        Services
    ).

%% @private
add_service(Name, Service, Carrier, Protocol, Acc, GetFun) ->
    case maps:find(Carrier, Acc) of
        {ok, #{protocols := Protos} = Entry} ->
            Acc#{Carrier := Entry#{protocols := add_protocol(Protocol, Protos)}};
        error ->
            Module =
                case carrier_module(Carrier) of
                    undefined ->
                        invalid(Name, {unknown_carrier, Carrier, Service});
                    M ->
                        M
                end,
            Acc#{
                Carrier => #{
                    module => Module,
                    protocols => add_protocol(Protocol, []),
                    config => resolve_carrier_config(Name, Carrier, GetFun)
                }
            }
    end.
```

Update the `t()` type's `carriers` field. Reject an empty `services` list for an
HTTP listener in `resolve_services/3`.

- [ ] **Step 5: Change the callback to take the resolved carrier**

`bondy_http_service.erl`:

```erlang
-callback routes(
    Carrier :: atom(),
    CarrierSpec :: bondy_listener_config:carrier(),
    Listener :: bondy_listener_config:t()
) -> [{Path :: string(), module(), State :: map()}].
```

`bondy_http_services.erl`: `dispatch/1` reads `module` out of the entry and
passes the entry; `carrier_state/3` takes the entry instead of looking `carriers`
up a second time; `carrier_module/2` and its comment are **deleted**; the `rest`
clause becomes two clauses with no membership test and no comment about protocol
not distinguishing them:

```erlang
routes(api_gateway, _Spec, Listener) -> bondy_http_gateway:routes(Listener);
routes(admin_api, _Spec, Listener) -> bondy_http_gateway:admin_api_routes(Listener);
```

`service_spec/1` now has no non-test caller outside `bondy_listener_config`.
Leave it exported (`migrate_conf.escript`-style tooling reads the table) but
drop it from the moduledoc's list of things `bondy_http_services` consults.

- [ ] **Step 6: Keep dynamic route collisions non-fatal**

Splitting `rest` moves the `api_gateway` / `admin_api` path overlap from
*within* one carrier (where `merge_routes/3` permits duplicates and Cowboy takes
the first) to *between* two carriers (where it raises). It must not raise: API
specifications arrive by anti-entropy after boot, which is why
`bondy_http_gateway_api_spec_parser:dispatch_table/2` is already lenient about
absent realms. Make `merge_routes/3` distinguish static contributions (raise —
a code-level mistake) from the two spec-derived carriers (log at
`?LOG_WARNING`, keep the first — matching current behaviour).

Test: `overlapping_spec_routes_are_logged_not_raised_test`.

- [ ] **Step 7: Run the tests to verify they pass**

- [ ] **Step 8: Falsify the normalisation**

Four mutations, each restoring one thing this task removed. `touch` after
restoring each.

1. Point `carrier_module(websocket)` at a second module. The result is the
   demonstration: 8 cases fail because the module changed for EVERY service on
   that carrier at once. No case can report a "conflict" — there is no longer
   anywhere for one to be written down.
2. Make the `undefined` clause of `module_for/3` unreachable (add a guard that
   cannot hold; a bare deletion orphans `Name` and `Service` and
   `warnings_as_errors` rejects it). `unknown_carrier_is_a_boot_error_test`
   fails. NOTE: deleting a `carrier_module/1` clause, as this plan first said,
   does NOT falsify that case — the deleted carrier falls through to the
   external lookup and every OTHER case fails instead.
3. Restore `{ok, Services} when is_list(Services)` in `resolve_services/3`.
   `http_listener_with_no_services_is_rejected_test` fails.
4. Restore the eager `maps:get/3` default in `add_service/6`.
   `carrier_config_is_resolved_once_per_carrier_test` fails, measuring 2 reads
   where it requires 1.

- [ ] **Step 9: Verify and report**

`rebar3 fmt --check`; `rebar3 eunit --dir=apps/bondy_router/test`;
`rebar3 as test ct --suite=` with `bondy_listener_SUITE`,
`bondy_listener_boot_SUITE`, `bondy_listener_schema_SUITE`,
`bondy_admin_listener_SUITE` and `bondy_http_security_headers_SUITE` in ONE
comma-separated list. Stop and report. Do not commit.

**Deviations from this plan, as built.** Two:

1. **Step 6's leniency is a `spec_derived/1` predicate in
   `bondy_http_services`, not a check on route provenance.** It is a property of
   the CARRIER — the same normalisation this task is about — so it is a table of
   one row per specification-derived carrier, beside `merge_routes/3` which is
   its only consumer. It does NOT live in `bondy_listener_config`: the resolver
   has no interest in where a carrier's routes come from. An extension's carrier
   is deliberately not spec-derived; its routes are code, so a collision
   involving it stays a raise.
2. **A tolerated collision DROPS the later contribution** rather than appending
   it. The shared-carrier version appended, but Cowboy's router answers with the
   first matching rule, so the appended duplicate never ran — dropping it is the
   same routing with a smaller table.

**Also changed, not in this plan:** 14 `services => []` values in
`bondy_listener_config_test` were "don't care" placeholders and an empty list is
now itself an error, so each became `[wamp_ws]`. Without that, six cases would
report `{missing, services}` instead of the error they exist to pin — most
sharply `tls_keys_on_plain_tcp_are_rejected_test`, since `resolve_services/3`
runs before `assert_tls_keys/4`.

---

## Task 2b: An API specification's `host` is discarded (REGRESSION, found in Task 2) — DONE

**Not a review finding — the architect review missed this.** Found while deciding
whether a duplicate path WITHIN the `api_gateway` carrier should warn: it should
not, and the reason it currently occurs at all is this defect.

`bondy_http_gateway_api_spec_parser:dispatch_table/2` returns
`[{Scheme, [route_rule()]}]` with `route_rule() :: {Host, [{Path, Mod, State}]}`,
documented as "ready to be compiled with `cowboy_router:compile/1`". Before this
branch it went to `cowboy_router:compile/1` with the hosts intact
(`compile_dispatch/2` at `73c7644c:apps/bondy_router/src/bondy_http_gateway.erl`
:952). Commit `89ff9c1b` added `flatten_rules/1` —
`lists:append([Routes || {_Host, Routes} <- Rules])` — and
`bondy_http_services:dispatch/1` wraps the result in `[{'_', ...}]`. So:

- a specification declaring `"host": "api.example.com"` is now served on EVERY
  host;
- two specifications for different hosts declaring the same path now collide, and
  the second is silently unreachable.

**Files:**
- Modify: `apps/bondy_router/src/bondy_http_service.erl` (callback return type)
- Modify: `apps/bondy_router/src/bondy_http_services.erl` (`dispatch/1`,
  `merge_routes/3`, every `routes/3` clause)
- Modify: `apps/bondy_router/src/bondy_http_gateway.erl` (drop `flatten_rules/1`)
- Test: `apps/bondy_router/test/bondy_http_services_test.erl`, plus a CT case
  driving two hosts over real HTTP

**The shape to move to** (option chosen 2026-08-19: host-aware, statics on every
host).

The callback returns `[{Host, [{Path, Module, State}]}]`. Static carriers return
`[{'_', [...]}]`; the two specification carriers return the parser's rules
unchanged, so `bondy_http_gateway:flatten_rules/1` is deleted.

Four properties, each with the reason it is not optional:

1. **`'_'` is emitted LAST.** `cowboy_router:match/3` walks host entries in order
   and its `'_'` clause matches unconditionally without falling through, and
   `match_path([], _, _, _)` answers `{error, notfound, path}` rather than trying
   the next host (`cowboy_router.erl:225`, `:253`, cowboy 2.17). A `'_'` entry
   placed first therefore shadows every named host completely.
2. **Every `'_'` route is REPLICATED into each named host entry.** Same
   no-backtracking rule read the other way: a route living only under `'_'` is
   unreachable on any request whose Host header matches a named entry. This is
   what pre-branch did NOT do — `dispatch_table/2` put base routes under their
   own `'_'` host (`A0`'s `H` is the base rule's host, not the spec's) — so on a
   named host `/ws` and `/metrics` would have answered 404. Replication is the
   part that makes the feature work rather than merely exist.
3. **Carriers are assembled statics-first**, by sorting on
   `{spec_derived(Carrier), Carrier}`. Then "first claim wins" IS "a static
   route wins over a specification route", structurally, with no precedence
   branch. Alphabetical order alone gets this wrong: `api_gateway` sorts before
   `websocket`, so a specification claiming `/ws` would have taken it.
4. **A collision raises only when NEITHER side is specification-derived**
   (`orelse`, not Task 2's `andalso`). Task 2 left spec-vs-static raising, which
   is a second defect of the same family: a stored specification declaring
   `/ping` or `/ws` would abort this node's dispatch rebuild over a document
   another node accepted. Static-vs-static stays a raise — it is a code bug.

Collisions are keyed on `{Host, Path}`, so two specifications for different hosts
declaring one path stop looking like a collision at all — which is what removes
the within-carrier asymmetry Task 2 had to leave silent.

Replication never overwrites a claim the named host already has: a specification
that declares `/ws` for its own host keeps it there, and the skip is logged. On
`'_'` the static wins by (3); on a named host the more specific declaration wins.

**Severity, measured before starting.** Every shipped and example specification
uses `"host": "_"` (`apps/bondy_router/priv/specs/bondy_admin_api.json`, all three
in `examples/config/`), which the parser's validator turns into the atom `'_'`.
So no shipped configuration is affected and the flattening is lossless for all of
them. The field is `required => true` with a `binary` datatype, so an operator
must fill it in and may legitimately put a hostname there.

- [x] **Step 1:** Write the failing tests in `bondy_http_services_test` — host
preserved; `'_'` replicated into a named host; `'_'` emitted last; same path on
two named hosts is not a collision; spec-vs-static logs instead of raising;
statics assembled first.
- [x] **Step 2:** Change the callback and the five in-tree `routes/3` clauses.
- [x] **Step 3:** Rewrite `dispatch/1` to claim per `{Host, Path}`, then
replicate, then emit. Always emit a `'_'` entry even when empty — a listener
declaring only `api_gateway` with no stored specification contributes no routes,
and today that yields `[{'_', []}]`; an empty dispatch list would change its
answer from `{error, notfound, path}` to `{error, notfound, host}`.
- [x] **Step 4:** Delete `flatten_rules/1`; `routes/1` and `admin_api_routes/1`
return the parser's rules unchanged.
- [x] **Step 5:** CT in `bondy_listener_SUITE` over real sockets, using an
external carrier registered by the suite on a named host: `/ping` answers on that
host (replication), the carrier's own path answers there and 404s elsewhere. This
is the falsification of property (1) — with `'_'` first, the named path 404s.
- [x] **Step 6:** CHANGELOG, under Fixes, naming what a specification's `host`
did and does, and the spec-vs-static collision.
- [x] **Step 7:** Verify and report. Do not commit.

---

## Task 3: Consumers own the CORS and security-header defaults — DONE

The schema translation builds a total `cors` / `security_headers` map, hardcoding
ten default values. Its justification — that a partial map raises `badkey` in
`build_headers/2` — was true before this branch, when `config_from_req/1` read
`bondy_config:get([Ref, cors], default_config())`. This branch changed both
consumers to `maps:merge(default_config(), Configured)`, so the workaround is now
a second copy of a security-relevant policy.

**Files:**
- Modify: `schema/bondy.schema` (the `bondy_router.listeners` translation)
- Test: `apps/bondy_router/test/bondy_listener_schema_SUITE.erl`

- [x] **Step 1: Write the failing test**

In `bondy_listener_schema_SUITE`: render a `bondy.conf` that sets exactly one
CORS member and one security-header member, and assert the rendered inventory
carries **only** those members — not a completed map.

```erlang
partial_cors_block_is_not_completed_by_the_schema(_) ->
    Conf = [
        "listeners.pub.transport = tcp", "listeners.pub.protocol = http",
        "listeners.pub.port = 18080", "listeners.pub.services = api_gateway",
        "listeners.pub.cors.max_age = 60"
    ],
    [{pub, Spec}] = render_listeners(Conf),
    %% The consumers merge their own default_config/0 over whatever arrives, so
    %% the schema must not restate those defaults.
    ?assertEqual(#{max_age => <<"60">>}, maps:get(cors, Spec)).
```

- [x] **Step 2: Run it to verify it fails** — it will report the full five-key map.

- [x] **Step 3: Move the conversions into `Value`, delete the completion**

Add clauses beside the existing `["cors", "max_age"]` one:

```erlang
        ([\"cors\", \"allowed_origins\"] = Tail, V, Name) ->
            Origins(FullKey(Name, Tail), V);
        ([\"cors\", \"allowed_methods\"], V, _Name) ->
            Bin(V);
        ([\"cors\", \"allowed_headers\"], V, _Name) ->
            Bin(V);
        ([\"security_headers\", \"hsts\"], V, _Name) ->
            Undef(V);
        ([\"security_headers\", \"frame_options\"], V, _Name) ->
            Undef(V);
        ([\"security_headers\", \"content_type_options\"], V, _Name) ->
            Undef(V);
        ([\"security_headers\", \"content_security_policy\"], V, _Name) ->
            Undef(V);
```

Delete `Cors`, `SecurityHeaders` and `Complete`, and the two `Complete(...)`
calls in the returned list comprehension. Keep `Origins`, `Bin` and `Undef` —
they are render-time conversions, which is the translation's job. Give `Bin` a
binary clause so it is total. `max_age` keeps its `Min(…, 0)` range check and
gains the `integer_to_binary/1` the deleted `Cors` was applying.

Hand-format at 80 columns; `schema/*.schema` is not in the erlfmt glob.

- [x] **Step 4: Run the test to verify it passes**

- [x] **Step 5: Prove the consumers still totalise**

Run `bondy_http_cors_SUITE` and `bondy_http_security_headers_SUITE` unchanged —
they exercise `headers/2` and `init/1` on partial configuration. Then falsify:
remove `maps:merge(default_config(), …)` from `bondy_http_cors:config_from_req/1`
and confirm a suite fails with `badkey`. `touch` after restoring.

- [x] **Step 6: Verify and report** — `fmt --check`, the two suites plus
`bondy_listener_schema_SUITE`, one comma-separated `--suite=`. Stop. Report.

---


**Deviations and findings, as built.**

1. **`Undef` is DELETED, not moved.** Its `("") -> undefined` clause existed only
   to convert the completion's OWN default of `""` into the `undefined` that
   `bondy_http_security_headers:build_headers/1` drops. No operator value can be
   an empty string — measured: `key =` with nothing after it is a cuttlefish
   conf SYNTAX error (`{errorlist, [{error, {conf_syntax, _}}]}` from
   `cuttlefish_conf:file/1`, which `render/2` then crashes on with `case_clause`
   rather than returning an error tuple), and `key = ""` renders the
   two-character string `""`. So the clause would be dead and `Undef` collapses
   into `Bin`. Pinned by `an_empty_security_header_value_is_a_syntax_error`.
2. **`Bin` keeps its single `is_list` clause.** The plan said to add a binary
   clause for totality; every key it serves has `{datatype, string}` and
   cuttlefish delivers a string for that datatype, so a second clause would
   guard a state that cannot arise.
3. **This task fixes a live defect that Task 1 introduced**, which is why it is
   not merely a de-duplication. `option_defaults(tls, http)` supplies HSTS and
   `with_option_defaults/1` merges it UNDER the operator's block; a COMPLETED
   block carries `hsts => undefined`, an operator value, which wins. So a TLS
   listener stating any one header lost HSTS.
   `a_rendered_partial_block_does_not_defeat_the_hsts_default` spans render →
   defaults and failed before this task, measuring `undefined`.
4. **Step 5 found the safety net missing.** Removing
   `maps:merge(default_config(), …)` from `bondy_http_cors:config_from_req/1`
   left all nineteen `bondy_http_cors_SUITE` cases GREEN: the suite's own
   `config/1` helper merges `default_config/0`, so no case drove a partial block
   through the function the schema deletion now depends on.
   `a_partial_listener_block_is_totalised_on_read` closes that, and the same
   mutation now fails. The security-headers side already had
   `partial_block_keeps_the_default_headers`, which fails with
   `{badkey, frame_options}`.

**Still open, and a consequence of Task 1 rather than this task:** with HSTS on by
default for TLS HTTP listeners, there is no `bondy.conf` spelling that turns off
one security header. `security_headers.enabled = off` disables all of them. That
asymmetry predates this work — `frame_options` and `content_type_options` had no
individual off switch either — but HSTS-by-default is what makes it worth
deciding.
## Task 4: Address-aware bind clash — DONE

**Deviations, as built.**

1. **`assert_bind_free/2`, not `/4`.** The planned
   `assert_bind_free(Name, Bind, Ip, Seen)` would have made both call sites read
   `assert_bind_free(Name, maps:get(bind, L), maps:get(ip, L, any), Seen)`,
   duplicating the `any` default — a policy decision — at each. It takes the
   resolved listener, which already carries `name`, `bind` and `ip`, so the
   default lives in one place.

2. **The address comparison is reached only for a `port` bind.** The planned
   `overlaps/2` filter ran for every bind kind, which would have let two uds
   listeners on ONE path with two different `ip` values through. `clashes/2`
   dispatches on the bind kind instead, so the path rule is address-independent
   by construction. `a_path_clash_ignores_the_address_test` is the mutant test.

3. **An explicit wildcard address widens too.** `wildcard/1` treats `0.0.0.0`
   and `::` as `any`, because `resolve_ip/3`'s absent `ip` and an operator's
   written-out `0.0.0.0` are the same socket. The plan's `overlaps/2` matched
   only the `any` atom, so the two spellings would have got different verdicts.

4. **Step 5 uses `127.0.0.1` and `::1`, not `127.0.0.1` and `127.0.0.2`.**
   Measured: `gen_tcp:listen(0, [{ip, {127,0,0,2}}])` answers `eaddrnotavail`
   on darwin 25.5 — only `127.0.0.1` is on `lo0`, unlike Linux where all of
   127.0.0.0/8 is local. A 127.0.0.0/8 pair would have passed on Linux CI and
   failed on every developer mac. The chosen pair was probed first: it shares a
   port in either order, and repeating either address is `eaddrinuse`.

5. **Step 6's falsification had the polarity backwards.** `overlaps/2 -> true`
   for every pair IS the pre-change behaviour, so it fails
   `distinct_addresses_may_share_a_port_test` and passes the wildcard test —
   the opposite of what the plan predicted, and already established by Step 2.
   The two mutants run instead were `wildcard(_) -> false` (kills both widening
   tests) and folding `clashes/2` into one address-aware clause (kills the path
   test).

**Also:** the "Bind address and IP version" section of the listeners guide
repeated "neither key has a default" and the hostname rule in two separate
paragraphs. Consolidated while adding the port-sharing rule.

---

## Task 4 (original text): Address-aware bind clash

`assert_bind_free/3` compares the port alone, so two listeners on distinct
interfaces sharing a port abort the boot — a configuration the OS accepts, and
the per-tenant-TLS case the design names as motivation.

**Files:**
- Modify: `apps/bondy_router/src/bondy_listener_config.erl`
- Test: `apps/bondy_router/test/bondy_listener_config_test.erl`,
  `apps/bondy_router/test/bondy_listener_SUITE.erl`

- [ ] **Step 1: Write the failing tests**

```erlang
distinct_addresses_may_share_a_port_test() ->
    ?assertMatch(
        {ok, [_, _]},
        resolve([
            {a, #{transport => tcp, protocol => wamp_rawsocket,
                  port => 18099, ip => {127, 0, 0, 1}}},
            {b, #{transport => tcp, protocol => wamp_rawsocket,
                  port => 18099, ip => {127, 0, 0, 2}}}
        ])
    ).

a_wildcard_conflicts_with_every_address_on_its_port_test() ->
    %% Both orders: the wildcard may be either the incumbent or the newcomer.
    ?assertMatch(
        {error, {invalid_listener, b, {port_in_use_by, a}}},
        resolve([
            {a, #{transport => tcp, protocol => wamp_rawsocket, port => 18099}},
            {b, #{transport => tcp, protocol => wamp_rawsocket,
                  port => 18099, ip => {127, 0, 0, 1}}}
        ])
    ),
    ?assertMatch(
        {error, {invalid_listener, b, {port_in_use_by, a}}},
        resolve([
            {a, #{transport => tcp, protocol => wamp_rawsocket,
                  port => 18099, ip => {127, 0, 0, 1}}},
            {b, #{transport => tcp, protocol => wamp_rawsocket, port => 18099}}
        ])
    ).
```

Keep `two_listeners_on_one_path_are_refused` unchanged: a UDS path clash stays
strict, because `maybe_unlink_socket/1` deletes the socket node before binding,
so the second listener silently takes the path over with no runtime error at
all.

- [ ] **Step 2: Run them to verify the first fails**

- [ ] **Step 3: Compare the resolved address alongside the port**

```erlang
assert_bind_free(Name, Bind, Ip, Seen) ->
    Clash = [
        Other
     || {Other, #{bind := B} = L} <- Seen,
        B =:= Bind,
        overlaps(Ip, maps:get(ip, L, any))
    ],
    ...

%% @private
%% The OS's uniqueness domain for a stream socket is (address, port), not port:
%% two listens on distinct literal addresses and one port both succeed, while a
%% wildcard listen excludes every address on that port. A `path' bind has no
%% address, and `resolve_ip/3' leaves `ip' ABSENT when none was configured and
%% none derived, which `bondy_config:normalise_socket_opts/1' reads as the
%% wildcard of the configured family -- hence `any'.
overlaps(any, _) -> true;
overlaps(_, any) -> true;
overlaps(Ip, Ip) -> true;
overlaps(_, _) -> false.
```

`resolve/2` and `resolve_internal/4` pass `maps:get(ip, Listener, any)`. Leave
the `{port, 0}` clause first and unchanged.

- [ ] **Step 4: Run the tests to verify they pass**

- [ ] **Step 5: Bind two real sockets**

In `bondy_listener_SUITE`, start two raw-socket listeners on one port with
`127.0.0.1` and `127.0.0.2` and assert both bind and both accept a connection.
This is the step that establishes the OS actually permits what the resolver now
permits — the resolver agreeing with itself proves nothing.

- [ ] **Step 6: Falsify** — revert `overlaps/2` to `true` for every pair and
confirm `distinct_addresses_may_share_a_port_test` still passes while
`a_wildcard_conflicts_with_every_address_on_its_port_test` fails. `touch` after
restoring.

- [ ] **Step 7: Verify and report.** Stop. Do not commit.

---

## Task 5: The mechanical cluster — DONE

**Deviations, as built.**

1. **Step 1 was four instances, not one.** `listener_transport_opts/2` merges
   `?DEFAULT_TRANSPORT_OPTS` and writes `socket_opts` back unconditionally
   (`bondy_config.erl:399-417`), so `max_connections`'s `infinity` in
   `transport_opts/1` and the two `socket_opts` `[]` defaults in `with_bind/2`
   and `maybe_reuseport/1` were unreachable and duplicated for the same reason
   `num_acceptors`'s `10` was. All four dropped; `key_value:get/2` raises
   `badkey`, which is the wanted failure if the invariant breaks. `reuseport`
   keeps its default — that one is an operator option and genuinely absent.
   Also removed the now-false claim in `bondy_config` that
   `maybe_reuseport/1` "assumes" the 10.

2. **Step 3 grew a test, and the alarm names stay literal.** `alarms/1` had NO
   coverage — not the thresholds, not the level mapping — so folding it was an
   unverified behaviour change. `bondy_listener_SUITE:connection_alarms_reach_ranch`
   reads the map back through `ranch:get_transport_options/1` and invokes each
   callback under a capturing logger handler.
   - `max_connections` is **125**, not the 128 `set_listener_env/1` uses: at 128
     a `round`-for-`trunc` mutant SURVIVES (115.2 truncates and rounds alike).
     At 125 both thresholds sit above a half and it fails. Measured, not reasoned.
   - A swapped-levels mutant also fails.
   - The names are rows in `?CONNECTION_ALARMS` rather than built with
     `list_to_atom/1`: they reach the operator through the alarm callback and
     the log, so they must stay greppable in the source.

3. **Step 7 reports `cowboy_default`, it does not omit the field.** The plan
   said omit when the carrier config carries no `idle_timeout`. But the WebSocket
   carrier config is commonly empty, so omitting would drop the field in the
   common case and tell the operator nothing. It logs the atom `cowboy_default`
   instead — no copied constant, and the reader still learns which of the two
   applied. (The old comment's citation was checked and was accurate:
   `cowboy_websocket.erl:444` is `maps:get(idle_timeout, Opts, 60000)`. The
   defect was duplicating a third-party constant, not being wrong.)

4. **Step 5 says more than `normal`.** "Suspending the normal-phase listeners"
   plus a clause stating that readiness and metrics stay up, since that is the
   thing an operator reading a drain log needs to know and the comment above the
   call already explains why.

---

## Task 5 (original text): The mechanical cluster

Seven independent one-line-to-ten-line fixes. Each is its own step and each
carries its own verification; none depends on another.

**Files:** `bondy_listener_ranch.erl`, `bondy_wamp_ws_connection_handler.erl`,
`bondy_app.erl`, `bondy_listener_manager.erl`

- [ ] **Step 1: `maybe_reuseport/1`'s unreachable default**

`bondy_config:listener_transport_opts/2` merges `?DEFAULT_TRANSPORT_OPTS`
(`num_acceptors => 10`) before returning, so `key_value:get(num_acceptors, Opts,
10)` in `bondy_listener_ranch.erl:246` can never apply its default, and the `10`
duplicates `bondy_config`'s. Restore the no-default read the pre-branch code had
(`key_value:get(num_acceptors, Opts)`) and restore the comment the move dropped:
`%% 15 acceptors per listen socket with at least 1 per scheduler`.

- [ ] **Step 2: Hoist the effects out of `protocol_opts/1`**

`bondy_listener_ranch:protocol_opts/1` calls `recompile_dispatch/1` and
`bondy_http_security_headers:init/1` — two `persistent_term` writes under a name
that reads as an options builder. Move both to `start_http/1`, before
`protocol_opts/1` is called, so the sequencing is visible at the call site.

- [ ] **Step 3: Fold `alarms/1`**

Two near-identical 14-line map entries differing only in threshold and log
level. Build from `[{75, warning}, {90, alert}]` using `?LOG(Level, Report)`,
which keeps the location metadata the level-specific macros provide.

- [ ] **Step 4: Make the protocol-family sentinel unrepresentable**

`bondy_wamp_ws_connection_handler:protocol_family/1` returns `undefined` for an
unknown prefix, which is safe only because `bondy_listener_config:add_protocol/2`
drops `undefined` from a carrier's protocol set — an invariant stated at neither
end. Return `'$unknown'`, a value no `service_spec/1` protocol can be, so the
filter cannot admit an unknown prefix regardless of what reaches `Allowed`.

- [ ] **Step 5: Correct the drain log**

`bondy_app:suspend_listeners/0` logs "Suspending all client listeners" while
suspending `normal` only — the comment above it explains why `early` stays up.
Say `normal` in the message.

- [ ] **Step 6: `bondy_listener_manager` moduledoc**

"Not a process a bare module." is missing a word.

- [ ] **Step 7: Drop the reconstructed Cowboy default from a log line**

`bondy_wamp_ws_connection_handler:terminate/3` restates Cowboy's `60000` idle
default to print it. Log the configured value when the carrier config carries
one and omit the field when it does not, rather than guessing.

- [ ] **Step 8: Verify and report**

`rebar3 fmt --check`; `rebar3 eunit --dir=apps/bondy_router/test`;
`rebar3 as test ct --suite=apps/bondy_router/test/bondy_listener_SUITE`.
Stop. Report. Do not commit.

---

## Task 6: WAMP admin procedures for listener suspend and resume — DONE

**Deviations, as built.**

1. **The test is a new `bondy_listener_api_SUITE`, not `bondy_listener_SUITE`.**
   Driving `bondy_wamp_api:handle_call/3` needs a booted node, and
   `bondy_listener_SUITE` deliberately does not boot one — it fakes
   `partisan_config:init/0` and a `platform_tmp_dir` instead. The new suite
   follows `bondy_mail_api_SUITE`: everything goes through the dispatcher, so the
   `bondy.listener.` prefix clause is covered by every case.

2. **`validate_admin_call_args/3`, not the `validate_call_args/3` the sibling
   modules use.** Discovered by the test, not by reading: the first version
   returned `wamp.error.not_authorized` for every case. Both helpers read the
   first positional argument as a REALM URI; the non-admin one additionally
   admits a caller whose own realm URI equals that argument — so with the phase
   in that slot, a realm named `com.example.normal` could have suspended every
   listener on the node. `a_non_master_realm_is_refused` pins it.

3. **Step 4's "reuse `bondy_listener_manager:phase/0`" does not exist.**
   `phase()` is a TYPE, and Erlang cannot reflect one at runtime. The decode is
   three literal clauses plus a total fallback in the API module — the only
   binary-to-phase decode in the tree, so it duplicates nothing. Not
   `binary_to_existing_atom/1`, which raises `badarg` (reported to the caller as
   an internal error) and would admit any atom the VM happens to hold, which
   `in_phase/1` then answers with `[]` — success for having suspended nothing.

4. **`?BONDY_LISTENER_LIST` was written and then removed.** A third wire
   procedure nobody asked for. An operator knows their own phases; they wrote
   them.

5. **A mutant corrected a test NAME.** `too_few_arguments_is_reported` was
   wrong: `validate_admin_call_args/3` SUBSTITUTES the master realm URI for a
   missing first argument, so a no-argument call never fails on arity — it
   arrives at `phase/1` carrying `com.leapsight.bondy`. Renamed
   `no_arguments_is_refused_rather_than_defaulted`, which is what it checks.

6. **Added a NOTICE log on the state change.** Neither the manager nor
   `bondy_listener` logs, and a suspended listener is indistinguishable from one
   that never started, so an operator action with no other trace left none.

**Falsified:** a `binary_to_existing_atom/1` phase decode fails 3 cases; ignoring
the phase argument (`Op(early)`) fails `suspending_normal_refuses_new_connections`.

---

## Task 6 (original text): WAMP admin procedures for listener suspend and resume

Gives `bondy_listener_manager:resume/1` a caller and a test, and gives an
operator a way to take a phase out of rotation and put it back.

**Files:**
- Create: `apps/bondy_router/src/bondy_listener_wamp_api.erl`
- Modify: wherever the node's other WAMP admin procedures are registered —
  locate it by reading an existing `*_wamp_api` module and its registration
  site; do not guess.
- Test: `apps/bondy_router/test/bondy_listener_SUITE.erl`

- [ ] **Step 1: Read how an existing admin procedure is registered**

`bondy_cert_manager_wamp_api.erl` exists; read it and its registration site, and
follow that pattern exactly — argument decoding, error shape, URI naming.

- [ ] **Step 2: Write the failing test**

Call `bondy.listener.suspend` with `normal` over a real session, assert a new
connection is refused while an established one survives, then call
`bondy.listener.resume` and assert a new connection succeeds. Note in the test
which case it exercises and which it does not: it covers the `normal` phase
only, because suspending `early` would take `/ping` and `/ready` down with it.

- [ ] **Step 3: Run it to verify it fails**

- [ ] **Step 4: Implement the two procedures**

Validate the phase argument against `early | normal | all` and return a named
error for anything else. Do not add a third mechanism for phase parsing — reuse
`bondy_listener_manager:phase/0`.

- [ ] **Step 5: Run the test to verify it passes**

- [ ] **Step 6: Remove the "no in-tree caller" note**

`bondy_listener_manager:resume/1`'s docstring says it has no caller and that its
phase selection is untested. Both are now false. Replace with what it does.

- [ ] **Step 7: Verify and report.** Stop. Do not commit.

---

## Task 7: Documentation — DONE

**Steps 1–3, design doc.** All three corrections written in the doc's own
labelled-retraction idiom, with the original claim left visible.

- §2.7 gets the `listener_transport_opts/1` → `/2` retraction, plus the general
  lesson: "the app-env shape is unchanged" bounds what CONSUMERS OF APP ENV must
  do and says nothing about a value reaching the socket from the inventory. §4
  gets a one-line pointer to it.
- §5's `bondy_http_service` paragraph rewritten: the callback is
  `routes(Carrier, CarrierSpec, Listener)`, and carrier/protocol are keyed by
  SERVICE while module is keyed by CARRIER. Records why that split makes a
  disagreement unrepresentable rather than detectable, and the `rest` case that
  proved it — one carrier standing for two route SOURCES, so the route builder had
  to read `services` back to decide which to fetch.
- The lost-defaults audit added to the legacy-removal section as its THIRD
  correction, with the scope rule (schema default = every release; template value
  = seven releases) and the ping/`idle_timeout` coupling that no per-key audit row
  could show. Names the common thread of all three: reasoning about the keys being
  replaced and not about what else the mapping carried — a validator, a name
  binding, a default.

**Beyond the plan: two dead passages in that same section.** Found while editing,
both now false and both corrected in place rather than deleted.

- `bondy_listener_manager:legacy_inventory/0` "synthesises the nine historical
  entries" — the function does not exist (grep: no hits). An absent
  `bondy_router.listeners` selects `default_inventory/0`. The provenance-signal
  reasoning around it is still live, so it is kept and labelled.
- "The reserved `admin` listener is therefore injected only for an operator who
  has adopted `listeners.*`" — `with_reserved/1` now runs on BOTH paths, which is
  safe only because the default inventory names its admin listener `admin`.

**Step 4, operator guide.** The service table and the collision, virtual-host,
CORS, bind-address and suspend/resume sections were already written in Tasks 2–6.
Added here: the `services` non-empty rule (including that
`listeners.<name>.services =` renders as an empty list, so it is an error rather
than a default set) and its mirror image, that declaring `services` on a
raw-socket or bridge-relay listener is itself refused; and a new "Keepalive and
idle timeouts" subsection giving the five restored raw-socket defaults and, more
importantly, why `idle_timeout` and `ping.idle_timeout` are separate. Also split
the 18-line services paragraph, which had become a wall.

**Step 5, docs build.** `rebar3 ex_doc` exits 0. Warning count 65 → **61**;
**zero in any file this branch touched**, verified by cross-checking the warning
modules against the dirty file list. The four this branch introduced:

- three stale `bondy_config:splat_listener_blocks/0` references (Task 2b made it
  `/1`) in `bondy_http_cors`, `bondy_http_security_headers` and
  `bondy_listener_config`;
- two module-qualified autolinks to PRIVATE functions —
  `bondy_listener_config:driver/1` and `bondy_app:start_normal_listeners/0`. Both
  references were purely explanatory (neither module calls the function), so both
  were rephrased to keep the information without the dangling link. Exporting a
  function to satisfy a doc link would have been the wrong trade.

**Step 5's "zero warnings" is not reachable and was not attempted.** The other 61
are pre-existing, in `bondy_connect_sdk`, `bondy_db`, `bondy_oplog` and `bondy_mail`.
One of them — `bondy_mail_api.erl:18` referencing
`bondy_wamp_api:do_handle_call/3` — is a one-line fix in the same app, but it
belongs to the mail feature and not to this branch. Left alone; flagged.

---

## Task 7 (original text): Documentation

**Files:**
- Modify: `_plans/2026-08-14-dynamic-listeners-design.md`
- Modify: `doc/guides/configuration/listeners.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Correct §2.7 and §4 of the design doc**

Both state that because the app-env shape is unchanged,
`bondy_config:listener_transport_opts/1` needs no change. It became `/2`, to
fold the resolved address into `socket_opts` before `normalise_socket_opts/1`
reconciles it with `ip_version`. Correct it in the doc's own idiom — a labelled
retraction, as §2.9 and §4.1 already do — rather than silently editing the
claim away.

- [ ] **Step 2: Replace §5's service/carrier description**

It says a service atom's "carrier, carried protocol and implementing module are
*data* in `bondy_listener_config`". After Task 2 the module is data keyed by
*carrier*, not by service, and that is what makes a carrier/module inconsistency
unrepresentable rather than merely detectable. Record the reasoning: `rest` was
conflating two route sources under one carrier, which is why it needed a special
case.

- [ ] **Step 3: Record the lost-defaults audit**

Add a section stating that removing the legacy mappings removed the defaults
they carried, listing what Task 1 restored and anything deliberately not
restored. This is the third correction in the same family as the two the doc
already records (the `*.ip` hostname capability and the 26 orphaned
`admin_api.http.*` options), so state it as the pattern it is.

- [ ] **Step 4: Update the operator guide**

`doc/guides/configuration/listeners.md` — the service table if `rest` splitting
changed anything operator-visible, the new `services` non-empty requirement, and
the restored ping defaults. Behaviour and contracts only: no test counts, no
benchmark numbers.

- [ ] **Step 5: Check the docs build** — `rebar3 ex_doc`, zero warnings, and
confirm any newly referenced function is not `@private`.

- [ ] **Step 6: Report.** Do not commit.

---

## Task 7b: `linger.timeout` is in the wrong unit — DONE

**Decision: `{duration, s}`.** Chosen by the user. Two of the objections this
plan raised against it turned out to be false, both measured rather than reasoned:

1. **"It would be the only `s`-valued duration in the file."** Wrong.
   `schema/bondy.schema` already has 8, plus 4 in `oauth2.schema`, 4 in
   `bondy_broker_bridge.schema`, 2 in `bondy_http_connector.schema` and 1 in
   `hidden/vm_args.schema`.
2. **The floor-to-zero hazard belonged to the OTHER option, and does not exist
   here.** `cuttlefish_duration:parse/2` uses `cuttlefish_util:ceiling/1`
   (`:65`), so `500ms` → 1 and `1ms` → 1. A sub-second value can never reach the
   socket as `{linger, {true, 0}}` — abort on close — by rounding.

**Also established before writing code:** a bare integer is returned unconverted
(`cuttlefish_datatypes.erl:232`), so that form already meant seconds and no
operator using it is affected; and `"-1"`/`"0"` as duration STRINGS are parse
errors, so the sentinel only ever arrives through the datatype's `integer`
alternative — which therefore has to stay.

**Beyond the plan.**

- The default lives in `stream_keepalive_defaults/0`, covering `wamp_rawsocket`
  AND `bridge_relay`: `bridge.listener.{tcp,tls}.linger.timeout` carried the same
  `1s`, so it belongs to the raw-socket shape rather than to one protocol.
- Three tests, not one, because the value crosses three seams and the plan's
  "pin the value reaching the socket" only covers the last: the schema render
  (`linger_timeout_is_in_seconds`), the defaults table
  (`rawsocket_linger_default_is_one_second_test`,
  `both_stream_protocols_get_the_linger_default_test`) and the socket itself
  (`rawsocket_linger_reaches_the_socket_as_one_second`, which goes through the
  MANAGER because `resolve/2` does not apply option defaults).
- Two pre-existing schema cases asserted the millisecond rendering and were
  updated. `http_and_stream_idle_timeout_are_distinct` is now a sharper statement
  of its own thesis: the two `linger.timeout` spellings differ in UNIT as well as
  path, so `2s` → 2 on one and `4s` → 4000 on the other.
- `config/bondy.conf.listeners.example` is hand-maintained; its linger stanza now
  states the unit and the default. Its header claim "None of the keys below has a
  default" was already misleading after Task 1 put defaults in code, and now
  distinguishes "no default in the schema" from "no default".
- **Not done:** teaching `scripts/migrate_conf.escript` to flag the changed
  meaning. The key still exists under the same name and is still read, so
  `check`'s existing no-longer-read reporting does not cover it, and a
  "changed meaning" mechanism is a new mechanism this task did not ask for. The
  CHANGELOG entry carries an explicit **Action required** instead.

**Falsified:** default back to `1000` fails the socket case and both unit tests;
datatype back to `{duration, ms}` fails three schema cases.

---

## Task 7b (original text): `linger.timeout` is in the wrong unit

Found while restoring the defaults in Task 1, which is why it is not in the
original set. It is a live defect independent of this branch.

`listeners.$name.linger.timeout` has datatype `[{duration, ms}, integer]`, so an
operator writing `1s` yields `1000`. `bondy_config:normalise_socket_opts/1` puts
that value into `{linger, {true, 1000}}`, and `inet` documents the second
component as SECONDS (`kernel/src/inet.erl:1124`, OTP 28.5) — so `1s` requests a
1000-second linger on close, and the legacy `{default, "1s"}` requested the same
on every raw-socket listener. The `-1` sentinel (`{false, 0}`, abort on close) is
unaffected: it is matched before the conversion.

**Files:**
- Modify: `apps/bondy_router/src/bondy_config.erl` (`normalise_socket_opts/1`)
- Modify: `apps/bondy_router/src/bondy_listener_config.erl` (restore the default
  once the unit is right)
- Test: `apps/bondy_router/test/bondy_config_test.erl`,
  `apps/bondy_router/test/bondy_listener_config_test.erl`

**The decision to make first:** convert in `normalise_socket_opts/1`
(`{linger, {true, Ms div 1000}}`, keeping the `ms` datatype every other duration
key in the schema uses, at the cost of silently flooring sub-second values to 0 —
which means "abort on close", a different behaviour) or change the schema
datatype to `{duration, s}` (honest at the key, but a silent behaviour change for
any operator who has already tuned it, and it would be the only `s`-valued
duration in the file). Ask before implementing.

- [ ] **Step 1: Write the failing test** for whichever conversion is chosen,
including the `-1` sentinel and the sub-second case.
- [ ] **Step 2: Implement, and restore the `1s` default** in
`protocol_option_defaults(wamp_rawsocket)`, replacing
`rawsocket_linger_default_is_deliberately_not_restored_test` with one that pins
the value reaching the socket.
- [ ] **Step 3: CHANGELOG**, under Fixes, stating the old and new meaning of the
key.
- [ ] **Step 4: Report.** Do not commit.

---

## Task 8: Full verification

- [ ] **Step 1: Sequentially, never in parallel**

```
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 eunit
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test proper
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct
CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 as test ct --suite=<the 8 cluster suites, ONE comma-separated flag>
```

- [ ] **Step 2: Read the counts, not the exit codes**

A CT invocation can exit 0 having silently skipped a suite. Extract the
`Passed`/`Failed`/`Skipped` line from each log, confirm every named cluster
suite appears in the output, and account for every skip.

- [ ] **Step 3: Report**

The four numbers, the skip reasons, and the full list of modified files. Leave
the tree dirty. Do not commit.

---

## Task 9: the pending-items sweep — DONE

Settled by the user after Task 8. Numbering is that list's.

**1. Per-header off switch — DONE.** `[{atom, off}, string]` on the four
`security_headers` value keys, and a `Header/1` fun in the translation mapping
`off` to `undefined`. Not a new convention: the consumer already emits only the
members that are not `undefined`, and the merge in `init/1` fills only ABSENT
keys, so a present `undefined` beats the TLS listener's HSTS default.
- `{atom, off}` is an EXTENDED cuttlefish datatype — parse as `atom`, accept only
  if it equals `off`, else fall through to `string`
  (`cuttlefish_generator:transform_extended_type/2`). Calling
  `cuttlefish_datatypes:from_string("off", {atom, off})` DIRECTLY returns an
  error, which is a probe at the wrong layer; the generator is the real path.
  `office` is a value, not a typo for `off`.
- Fixed a comment that documented a spelling which does not exist:
  `an_explicit_undefined_hsts_still_disables_it_test` claimed an operator writes
  `security_headers.hsts =` with no value. Measured in Task 3: that is a conf
  SYNTAX error. `off` is the spelling, and now exists.

**2. `ping.max_attempts` — no work.** It is already a per-listener key
(`listeners.$name.ping.max_attempts`) and no global raw-socket ping mapping
survives. What was unified at 2 is only the DEFAULT in `option_defaults/2`. My
earlier report named the deleted legacy key and so implied a global; corrected.

**3. Dead `tls_opts` reads — DONE.** Both sites now `ranch:handshake(Ref)`
(`ranch:handshake/1` exists, `ranch.erl:298`).

**4. One config-resolution site for the stream handlers — DONE.**
`stream_protocol_opts/2` collapses to one clause handing both stream protocols the
listener's resolved block, and `bondy_wamp_tcp_connection_handler` reads
`idle_timeout` and `ping` out of it instead of calling
`bondy_config:get([Ref, _])` on every accepted connection. Its `init/1` had been
taking the opts and discarding them (`_Opts0`). Falsified: reverting to `[]` for
`wamp_rawsocket` fails `rawsocket_ping_interval_comes_from_the_ping_block`.

**5. `assert_transport_protocol/3` — closed, no work.** Three clauses for one
rejected pair is right; data would be an abstraction guessed rather than earned.

**6. `bondy_mail_api.erl:18` — DONE.** Rephrased to drop the autolink to a private
function rather than exporting it.

**7. `migrate_conf` and the linger unit — DONE, after a wrong costing.** I first
told the user this was one table entry because rule selectors support `$name`
wildcards. True but irrelevant: `classify/2` only examines keys that are **not**
in the schema, and `listeners.$name.linger.timeout` IS a live mapping — so a
`rules()` entry for it would never fire. Dead code, not a fix. Built as the third
finding kind it actually needs: `reinterpreted/0` (one whole-key pattern, its
one-line summary, its advice), `reinterpretations/1`, a `CHANGED MEANING` report
section, and a selftest check. Reported by `check` AND by `migrate`, for the
reason already documented beside the listener report — an operator who only runs
`migrate` would otherwise never see it.
- **Advisory, exit code untouched.** A changed-meaning key is spelled correctly
  and may need no edit. Making it exit 1 would put `clean` permanently out of
  reach for any file that legitimately sets the key, and a gate that cannot be
  satisfied gets ignored. The verdict line names the count instead, so `clean`
  cannot be read as silence.
- **A depth assertion was written and then deleted.** It required every flagged
  key to sit at the depth of the entry that flagged it — the property that keeps
  Cowboy's 5-segment `http.linger.timeout` out of a section about the 4-segment
  socket key. It could not be made to fail: `is_fuzzy_match/2` compares segment
  counts first, so the flagged key and its pattern are already the same length.
  Excluded by construction, cited in the comment, not tested.
- Falsified what remains: mutating one segment of the pattern fails BOTH
  invariants at once (`…linger.timeout_x` is not read → dead entry, and the
  corpus count drops to 0). The widened 5-segment mutant fails on the liveness
  invariant, not on depth — which is how the vacuous assertion was found.
- Corpus: the 12 shipped files carry 2 flagged lines and 2 `http.linger.timeout`
  siblings that are correctly not flagged, so the check is non-vacuous both ways.
- Also fixed here: `protocol_option_defaults/1`'s doc comment still said the
  `linger.timeout` default was "deliberately NOT restored", directly above the
  clause that restores it (Task 7b changed the code and left the rationale).

**8. Stale "legacy keys below" prose — DONE, and larger than reported.** NINE
comment blocks across five templates, not five: `config/dev/` (1),
`config/bridge/` (1), `config/test/node_1` (3), `node_2` (3), `edge_1` (1). All
claimed keys "stay on the legacy keys below" directly above keys already in the
new spelling, TLS material included. One also carried the stale
`splat_listener_blocks/0` arity. 52 lines removed, all comments — verified by
filtering the diff for non-comment deletions.
- Same family, same sweep: `config/bondy.conf.listeners.example` claimed the TLS
  block "wins" if a "historical per-scheme certificate" is also present. That is
  now impossible; an enabled TLS listener with no material is refused at boot.

**9. `linger.timeout = 0` in two test templates — DONE.** Confirmed the mapping
is: absent → no `linger` option at all; `-1` → `{linger, {false, 0}}`; `N >= 0` →
`{linger, {true, N}}`. So `0` was abort-on-close/RST, discarding unsent data.
Both templates now read `-1` with a comment saying why the line is there at all
(the default is `1s`, so it is load-bearing) and what `0` would have meant. The
`-1` rendering is covered end to end by `linger_timeout_is_in_seconds`.

**10. Mailpit — DONE.** Started; the 13 previously-skipped
`bondy_mail_mailpit_SUITE` cases run in this gate.

---

## Found, not in scope — your call

- **`bondy_config:get([Ref, tls_opts], [])`** in
  `bondy_wamp_tcp_connection_handler.erl:97` and
  `bondy_bridge_relay_server.erl:201` is a dead read: the old `wamp.tls.*`
  mappings targeted `transport_opts.socket_opts.*`, never `tls_opts`, so it
  returned `[]` before this branch too. Pre-existing, harmless (ranch already
  has the material from the listen socket's transport options), and two lines to
  delete if wanted.
- **The raw-socket and bridge-relay handlers read their configuration from
  application environment**, while the WebSocket carrier receives it in the
  route state. Threading the resolved listener through
  `bondy_listener_ranch:stream_protocol_opts/2` — which currently passes `[]`
  for `wamp_rawsocket`, and whose `Opts` argument the handler ignores — would
  give all three handlers one resolution site and delete both app-env reads.
  Task 1 does not require it; it is the same consolidation increment 5 did for
  the carriers.
- **`assert_transport_protocol/3` rejects exactly one pair.** A three-clause
  denylist is fine; if it grows past that it wants to be data.
