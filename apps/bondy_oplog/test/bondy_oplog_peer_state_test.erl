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
        fun touch_peer_refreshes_last_seen/0,
        fun strict_read_ignores_recency/0,
        fun strict_read_names_unconfirmed_members/0,
        fun rootless_round_refreshes_without_confirming/0,
        fun strict_read_solo_instance_is_stable/0,
        fun reclamation_members_solo/0,
        fun reclamation_members_error_is_not_solo/0
    ]}.

%% -----------------------------------------------------------------------------
%% Strict reading — for callers that reclaim irreversibly
%% -----------------------------------------------------------------------------
%%
%% `get_instance_peer_states/1` drops peers unheard-from within
%% `peer_timeout_ms`. That is correct for MST compaction, where a dropped peer
%% resyncs via bootstrap, and unsound for projection-cell reclamation, where it
%% silently resurrects deleted data. `confirmed_peer_states/2` is the reading
%% reclamation must use.

strict_read_ignores_recency() ->
    P = mk_peer(),
    I = mk_inst(),
    H = <<1:256>>,
    %% Record with a last_seen far enough in the past that the recency read
    %% excludes it.
    Stale = os:system_time(millisecond) - (10 * 60 * 1000),
    ok = bondy_oplog_peer_state:record_sync_complete(P, I, H, Stale),
    sync(),

    %% Recency read drops it...
    ?assertEqual([], bondy_oplog_peer_state:get_instance_peer_states(I)),

    %% ...the strict read does not. A silent member must hold stability down,
    %% not vanish from the computation.
    ?assertMatch(
        {ok, [#{peer := P, root_hash := H}]},
        bondy_oplog_peer_state:confirmed_peer_states(I, [P])
    ).

strict_read_names_unconfirmed_members() ->
    P1 = mk_peer(),
    P2 = mk_peer(),
    I = mk_inst(),
    ok = bondy_oplog_peer_state:record_sync_complete(P1, I, <<2:256>>),
    sync(),

    %% P2 is a member but has never confirmed, so there is no stability and the
    %% caller is told which member is missing.
    ?assertEqual(
        {unconfirmed, [P2]},
        bondy_oplog_peer_state:confirmed_peer_states(I, [P1, P2])
    ),

    %% With P2 confirmed, both are returned in member order.
    ok = bondy_oplog_peer_state:record_sync_complete(P2, I, <<3:256>>),
    sync(),
    {ok, States} = bondy_oplog_peer_state:confirmed_peer_states(I, [P1, P2]),
    ?assertEqual([P1, P2], [maps:get(peer, S) || S <- States]).

strict_read_solo_instance_is_stable() ->
    I = mk_inst(),
    %% No members ⇒ nothing can contradict us ⇒ trivially stable.
    ?assertEqual({ok, []}, bondy_oplog_peer_state:confirmed_peer_states(I, [])).

%% -----------------------------------------------------------------------------
%% Reclamation membership — the ONLY member source reclamation may use
%% -----------------------------------------------------------------------------
%%
%% `error` ≠ `[]` is the load-bearing contract: `[]` means genuinely solo
%% (maximal reclamation is licensed), `error` means the membership service is
%% unavailable and MUST propagate as "no stability, reclaim nothing".
%% Conflating them would let a node that merely cannot see its membership
%% service reclaim as though nothing could contradict it.

reclamation_members_solo() ->
    %% Single-node eunit VM: the known membership is exactly this node, so
    %% reclamation members = [] — the solo case, distinct from `error`.
    ?assertEqual({ok, []}, bondy_oplog_instance:reclamation_members()).

reclamation_members_error_is_not_solo() ->
    ok = meck:new(partisan_peer_service, [passthrough]),
    try
        %% A dead/hung peer service exits the call rather than returning a
        %% tuple — that must surface as `error`, never as solo.
        ok = meck:expect(partisan_peer_service, members, fun() ->
            exit({noproc, {gen_server, call, [partisan_peer_service]}})
        end),
        ?assertEqual(error, bondy_oplog_instance:reclamation_members()),

        %% A malformed reply is equally `error`.
        ok = meck:expect(partisan_peer_service, members, fun() ->
            {ok, not_a_list}
        end),
        ?assertEqual(error, bondy_oplog_instance:reclamation_members())
    after
        meck:unload(partisan_peer_service)
    end.

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
%% A completed round against an empty peer tree (RootHash = `undefined` —
%% e.g. a fully-compacted quiescent shard) advances the peer's recency, so
%% the last-sync age stays truthful, but must NEVER count as confirmation;
%% and once a root IS confirmed, later rootless rounds refresh recency
%% while preserving it.
rootless_round_refreshes_without_confirming() ->
    P = mk_peer(),
    I = mk_inst(),
    T1 = os:system_time(millisecond) - 3000,

    %% No prior row: a rootless completion creates a recency-only entry.
    ok = bondy_oplog_peer_state:record_sync_complete(P, I, undefined, T1),
    sync(),
    ?assertMatch(
        [#{peer := P, root_hash := undefined, last_sync := T1}],
        bondy_oplog_peer_state:get_instance_peer_states(I, 0)
    ),
    ?assertEqual(
        {unconfirmed, [P]},
        bondy_oplog_peer_state:confirmed_peer_states(I, [P])
    ),

    %% A binary root confirms.
    H = <<9:256>>,
    T2 = T1 + 1000,
    ok = bondy_oplog_peer_state:record_sync_complete(P, I, H, T2),
    sync(),
    ?assertMatch(
        {ok, [#{peer := P, root_hash := H, last_sync := T2}]},
        bondy_oplog_peer_state:confirmed_peer_states(I, [P])
    ),

    %% A later rootless completion refreshes recency and PRESERVES the
    %% confirmed root — the stability frontier must not regress just
    %% because the peer compacted.
    T3 = T2 + 1000,
    ok = bondy_oplog_peer_state:record_sync_complete(P, I, undefined, T3),
    sync(),
    ?assertMatch(
        {ok, [#{peer := P, root_hash := H, last_sync := T3}]},
        bondy_oplog_peer_state:confirmed_peer_states(I, [P])
    ).

sync() ->
    bondy_oplog_peer_state:sync().

mk_peer() ->
    {peer, erlang:unique_integer([positive, monotonic])}.

mk_inst() ->
    list_to_binary(
        "ps_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).
