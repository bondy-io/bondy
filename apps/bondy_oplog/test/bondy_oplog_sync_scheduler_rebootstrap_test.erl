%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Tests the `peer_pages_unavailable` → re-bootstrap consumer in
%% `bondy_oplog_sync_scheduler`.
%%
%% A live pull that fails with `{peer_pages_unavailable, _}` is terminal —
%% the peer physically reclaimed pages this replica needs — so the scheduler
%% must flag the instance and replace its live dispatch with a snapshot
%% re-bootstrap against (preferentially) the same peer. Any other live
%% failure stays self-healing: no flag, normal re-dispatch.
%%
%% The module doubles as the sync-session transport (`request/4`), driven by
%% a small mode table: `unavailable` answers page requests with
%% `{ok, {unavailable, _}}` (the reclaimed-peer shape); `error` refuses
%% `get_root` outright (the ordinary transient failure).
%% =============================================================================
-module(bondy_oplog_sync_scheduler_rebootstrap_test).

-include_lib("eunit/include/eunit.hrl").

-define(MODE_TAB, ?MODULE).
-define(PEER, <<"reclaimed-peer">>).
-define(EVENTS, [
    [bondy_oplog, sync_scheduler, rebootstrap_scheduled],
    [bondy_oplog, sync_scheduler, dispatch_bootstrap],
    [bondy_oplog, sync_scheduler, live, ended]
]).

%% Transport callbacks (used via `sync_session_opts`)
-export([request/4]).

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    _ = ets:new(?MODE_TAB, [named_table, set, public]),
    ets:insert(?MODE_TAB, {root, crypto:strong_rand_bytes(32)}),
    ok = bondy_oplog_sync_scheduler:set_interval_ms(0),
    ok = bondy_oplog_sync_scheduler:set_dispatch(
        fun bondy_oplog_sync_scheduler:default_dispatch/2
    ),
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => [?PEER]}
    ),
    ok = application:set_env(
        bondy_oplog, sync_session_opts, #{transport => ?MODULE}
    ),
    ok.

cleanup(_) ->
    ok = application:unset_env(bondy_oplog, sync_session_opts),
    ok = bondy_oplog_sync_scheduler:set_interval_ms(500),
    ok = bondy_oplog_sync_scheduler:set_peer_source(
        bondy_oplog_peer_source_static, #{peers => []}
    ),
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ets:delete(?MODE_TAB),
    ok.

rebootstrap_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 30, fun unavailable_flags_and_rebootstraps/0},
        {timeout, 30, fun other_failures_do_not_flag/0}
    ]}.

%% A live instance whose pull dies on `peer_pages_unavailable` is flagged
%% (rebootstrap_scheduled fires from the scheduler's DOWN handling) and the
%% NEXT tick dispatches a catalogue bootstrap against the flagging peer
%% instead of another doomed live sync.
unavailable_flags_and_rebootstraps() ->
    set_mode(unavailable),
    Inst = mk_inst(),
    ?assertEqual(live, bondy_oplog_instance:lifecycle_state(Inst)),
    with_telemetry(fun() ->
        bondy_oplog_sync_scheduler:trigger(),
        #{instance_id := Inst, peer := ?PEER} =
            await([bondy_oplog, sync_scheduler, rebootstrap_scheduled], Inst),

        %% The flag is consumed by a bootstrap dispatch, not another live
        %% sync.
        bondy_oplog_sync_scheduler:trigger(),
        Meta = await([bondy_oplog, sync_scheduler, dispatch_bootstrap], Inst),
        ?assertMatch(#{peer := ?PEER, mode := catalogue}, Meta)
    end),
    bondy_oplog:stop_instance(Inst).

%% An ordinary transient live failure (transport refuses `get_root`) leaves
%% no re-bootstrap state: the session ends, nothing schedules a bootstrap.
other_failures_do_not_flag() ->
    set_mode(error),
    Inst = mk_inst(),
    with_telemetry(fun() ->
        bondy_oplog_sync_scheduler:trigger(),
        #{instance_id := Inst} =
            await([bondy_oplog, sync_scheduler, live, ended], Inst),

        %% The DOWN that emitted `ended` is the same handling that would
        %% have flagged; give any (wrong) follow-up a moment, then assert
        %% silence and that the next tick does NOT route to bootstrap.
        bondy_oplog_sync_scheduler:trigger(),
        receive
            {telemetry, [bondy_oplog, sync_scheduler, rebootstrap_scheduled], _,
                #{instance_id := Inst}} ->
                error(unexpected_rebootstrap_flag);
            {telemetry, [bondy_oplog, sync_scheduler, dispatch_bootstrap], _, #{
                    instance_id := Inst
                }} ->
                error(unexpected_bootstrap_dispatch)
        after 500 ->
            ok
        end
    end),
    bondy_oplog:stop_instance(Inst).

%% =============================================================================
%% Transport — the "peer" the sessions talk to
%% =============================================================================

request(_Peer, _Instance, get_frontier, _Opts) ->
    %% A VV strictly ahead of the (empty) local instance's. Load-bearing
    %% for `unavailable_flags_and_rebootstraps/0`: `peer_pages_unavailable`
    %% is terminal (→ rebootstrap) only under a GENUINE applied-frontier
    %% deficit — with no deficit the session ends benign (the unpullable
    %% pages cover only already-applied events; see
    %% `bondy_oplog_sync_session:chase_refreshed_root/7`).
    {ok, #{<<"rb_test_peer_origin">> => 1}};
request(_Peer, _Instance, get_root, _Opts) ->
    case mode() of
        unavailable ->
            [{root, Root}] = ets:lookup(?MODE_TAB, root),
            {ok, Root};
        error ->
            {error, econnrefused}
    end;
request(_Peer, _Instance, {get_pages, Hashes}, _Opts) ->
    {ok, {unavailable, Hashes}};
request(_Peer, _Instance, {get_pages, _Self, _Root, Hashes}, _Opts) ->
    {ok, {unavailable, Hashes}};
request(_Peer, _Instance, get_catalogue_snapshot_init, _Opts) ->
    %% The dispatched re-bootstrap session immediately falls through to a
    %% plain pull (which fails again); the test asserts the ROUTING, the
    %% bootstrap session internals are covered elsewhere.
    {ok, no_snapshot};
request(_Peer, _Instance, Req, _Opts) ->
    {error, {unexpected_request, Req}}.

%% =============================================================================
%% Helpers
%% =============================================================================

set_mode(Mode) ->
    true = ets:insert(?MODE_TAB, {mode, Mode}),
    ok.

mode() ->
    [{mode, Mode}] = ets:lookup(?MODE_TAB, mode),
    Mode.

mk_inst() ->
    Id = iolist_to_binary([
        "rb_", integer_to_binary(erlang:unique_integer([positive]))
    ]),
    {ok, _} = bondy_oplog:start_instance(Id, #{}),
    Id.

%% Attaches the telemetry forwarder in the TEST process (a fixture-level
%% attach would forward to the setup process instead) and always detaches.
with_telemetry(Fun) ->
    Self = self(),
    HandlerId = {?MODULE, self()},
    ok = telemetry:attach_many(
        HandlerId,
        ?EVENTS,
        fun(Event, M, Meta, _) -> Self ! {telemetry, Event, M, Meta} end,
        []
    ),
    try
        Fun()
    after
        telemetry:detach(HandlerId)
    end.

await(Event, Inst) ->
    receive
        {telemetry, Event, _M, #{instance_id := Inst} = Meta} ->
            Meta
    after 10_000 ->
        error({telemetry_timeout, Event, Inst})
    end.
