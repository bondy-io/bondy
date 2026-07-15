%% Stage-3 peer-state tests.

-module(bondy_oplog_peer_state_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    %% Clear all state by forgetting every peer touched in this run.
    %% Tests use unique peer ids so this is best-effort.
    ok.

peer_state_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun record_and_read/0,
        fun forget_peer/0,
        fun forget_instance/0,
        fun stale_peer_excluded/0,
        fun stale_peer_included_when_since_is_old/0,
        fun get_known_peers_unique/0,
        fun touch_peer_refreshes_last_seen/0
    ]}.

record_and_read() ->
    P = mk_peer(),
    I = mk_inst(),
    H = <<0:256>>,
    ok = bondy_oplog_peer_state:record_sync_complete(P, I, H),
    %% record_sync_complete is a cast — give it a beat to land.
    sync(),
    ?assertEqual(
        {ok, H},
        bondy_oplog_peer_state:get_peer_root_hash(P, I)
    ),
    ?assertMatch(
        [#{peer := P, root_hash := H}],
        bondy_oplog_peer_state:get_instance_peer_states(I)
    ).

forget_peer() ->
    P = mk_peer(),
    I1 = mk_inst(),
    I2 = mk_inst(),
    bondy_oplog_peer_state:record_sync_complete(P, I1, <<1>>),
    bondy_oplog_peer_state:record_sync_complete(P, I2, <<2>>),
    sync(),
    bondy_oplog_peer_state:forget_peer(P),
    sync(),
    ?assertEqual(
        not_found,
        bondy_oplog_peer_state:get_peer_root_hash(P, I1)
    ),
    ?assertEqual(
        not_found,
        bondy_oplog_peer_state:get_peer_root_hash(P, I2)
    ).

forget_instance() ->
    P1 = mk_peer(),
    P2 = mk_peer(),
    I = mk_inst(),
    bondy_oplog_peer_state:record_sync_complete(P1, I, <<1>>),
    bondy_oplog_peer_state:record_sync_complete(P2, I, <<2>>),
    sync(),
    bondy_oplog_peer_state:forget_instance(I),
    sync(),
    ?assertEqual(
        [],
        bondy_oplog_peer_state:get_known_peers(I)
    ).

stale_peer_excluded() ->
    P = mk_peer(),
    I = mk_inst(),
    %% Record at a timestamp 10 minutes in the past.
    Old = os:system_time(millisecond) - 10 * 60 * 1000,
    bondy_oplog_peer_state:record_sync_complete(P, I, <<3>>, Old),
    sync(),
    %% Default peer_timeout_ms is 30s, so 10min-old is excluded.
    ?assertEqual(
        [],
        bondy_oplog_peer_state:get_known_peers(I)
    ),
    ?assertEqual(
        [],
        bondy_oplog_peer_state:get_instance_peer_states(I)
    ).

stale_peer_included_when_since_is_old() ->
    P = mk_peer(),
    I = mk_inst(),
    Old = os:system_time(millisecond) - 10 * 60 * 1000,
    bondy_oplog_peer_state:record_sync_complete(P, I, <<4>>, Old),
    sync(),
    %% Override the cutoff via the explicit /2 form.
    Cutoff = Old - 1,
    ?assertMatch(
        [P],
        bondy_oplog_peer_state:get_known_peers(I, Cutoff)
    ).

get_known_peers_unique() ->
    P = mk_peer(),
    I = mk_inst(),
    bondy_oplog_peer_state:record_sync_complete(P, I, <<5>>),
    bondy_oplog_peer_state:record_sync_complete(P, I, <<6>>),
    sync(),
    ?assertEqual(
        [P],
        bondy_oplog_peer_state:get_known_peers(I)
    ),
    ?assertEqual(
        {ok, <<6>>},
        bondy_oplog_peer_state:get_peer_root_hash(P, I)
    ).

touch_peer_refreshes_last_seen() ->
    P = mk_peer(),
    I = mk_inst(),
    Old = os:system_time(millisecond) - 10 * 60 * 1000,
    bondy_oplog_peer_state:record_sync_complete(P, I, <<7>>, Old),
    sync(),
    %% Stale before touch.
    ?assertEqual([], bondy_oplog_peer_state:get_known_peers(I)),
    bondy_oplog_peer_state:touch_peer(P),
    sync(),
    %% Fresh after touch.
    ?assertEqual([P], bondy_oplog_peer_state:get_known_peers(I)).

%% Helpers

%% Force the gen_server's cast queue to drain by issuing a synchronous
%% round-trip. (`info/0` is intentionally lock-free and does not enter
%% the gen_server, so it cannot be used for this.)
sync() ->
    bondy_oplog_peer_state:sync().

mk_peer() ->
    {peer, erlang:unique_integer([positive, monotonic])}.

mk_inst() ->
    list_to_binary(
        "ps_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).
