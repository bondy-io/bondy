%% =============================================================================
%% EUnit suite for `bondy_app:start_services/1` — the boot dispatch on
%% `bondy_namespace_catalog:main_status/0`.
%%
%% `bondy_namespace_catalog:open_main_into/1` deliberately survives a failure
%% to open the durable `main` DB, and `bondy_admin_ready_http_handler` already
%% answers 503 for as long as `main_status/0` is `failed`. That contract was
%% not honoured on the way up: every step after `setup_event_handlers/0`
%% needs durable tables, and `configure_services/0` raises
%% `bondy_realm_table_unavailable` on its first `bondy_realm:get/1`, which
%% escaped `start/2` and terminated the VM — observed in production, both
%% nodes, 2026-09-02.
%%
%% These cases pin the dispatch from both sides: `failed` must NOT enter
%% `configure_services/0` and must still bring up the early listeners;
%% anything else must enter it. `bondy_message_id:init/0` is the first call
%% `configure_services/0` makes, so it is the probe for "did we go down the
%% durable path".
%% =============================================================================

-module(bondy_app_degraded_boot_test).

-include_lib("eunit/include/eunit.hrl").

%% A sentinel raised from the mocked `bondy_message_id:init/0` so a test can
%% tell that `configure_services/0` was entered without having to stand up
%% realms, the registry, the HTTP gateway and every listener behind them.
-define(ENTERED_CONFIGURE_SERVICES, '$entered_configure_services').

setup() ->
    ok = meck:new(bondy_namespace_catalog, [passthrough, non_strict]),
    ok = meck:new(bondy_listener_manager, [passthrough, non_strict]),
    ok = meck:new(bondy_message_id, [passthrough, non_strict]),
    ok = meck:expect(bondy_listener_manager, start, fun(_Phase) -> ok end),
    ok = meck:expect(bondy_message_id, init, fun() ->
        error(?ENTERED_CONFIGURE_SERVICES)
    end),
    ok.

cleanup(_) ->
    _ = meck:unload(bondy_message_id),
    _ = meck:unload(bondy_listener_manager),
    _ = meck:unload(bondy_namespace_catalog),
    ok.

degraded_boot_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"a failed main store starts the early listeners",
            fun early_listeners_started/0},
        {"a failed main store never opens a client listener",
            fun no_normal_listeners/0},
        {"a failed main store never enters configure_services",
            fun configure_services_skipped/0},
        {"open and idle DO enter configure_services",
            fun configure_services_entered/0}
    ]}.

%% The whole point of surviving: the node stays inspectable. `/ping` and the
%% `/ready` probe are served by the early-phase listeners.
early_listeners_started() ->
    ok = meck:reset(bondy_listener_manager),
    ?assertEqual(ok, bondy_app:start_services(failed)),
    ?assert(meck:called(bondy_listener_manager, start, [early])).

%% ...but it must not take traffic it cannot serve. `start_normal_listeners/0`
%% is also what promotes `bondy_config:get(status)` to `ready`, so skipping it
%% is what keeps the readiness probe answering 503 on BOTH of its conditions.
no_normal_listeners() ->
    ok = meck:reset(bondy_listener_manager),
    ?assertEqual(ok, bondy_app:start_services(failed)),
    ?assertNot(meck:called(bondy_listener_manager, start, [normal])).

%% The regression itself: reaching `configure_services/0` with no durable
%% tables is what killed the VM.
configure_services_skipped() ->
    ok = meck:reset(bondy_message_id),
    ?assertEqual(ok, bondy_app:start_services(failed)),
    ?assertNot(meck:called(bondy_message_id, init, [])).

%% The control. Without it, `start_services/1` returning `ok` for everything
%% would pass every case above while having broken normal boot entirely.
%% `idle` is a legitimate configuration, not a fault, so it takes the durable
%% path exactly like `open`.
configure_services_entered() ->
    lists:foreach(
        fun(Status) ->
            ok = meck:reset(bondy_message_id),
            ?assertError(
                ?ENTERED_CONFIGURE_SERVICES,
                bondy_app:start_services(Status)
            ),
            ?assert(meck:called(bondy_message_id, init, []))
        end,
        [open, idle]
    ).
