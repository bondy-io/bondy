-module(bondy_oplog_peer_state_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    %% Tests use unique peer ids, so no peer state needs forgetting.
    ok.

peer_state_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun record_and_read/0,
        fun forget_peer/0,
        fun forget_instance/0,
        fun stale_peer_included_when_since_is_old/0,
        fun get_known_peers_unique/0,
        fun touch_peer_refreshes_last_seen/0,
        fun strict_read_ignores_recency/0,
        fun strict_read_names_unconfirmed_members/0,
        fun empty_report_refreshes_without_confirming/0,
        fun strict_read_solo_instance_is_stable/0,
        fun reclamation_members_clustering_disabled/0,
        fun reclamation_members_no_other_member/0,
        fun reclamation_members_unavailable/0
    ]}.

%% -----------------------------------------------------------------------------
%% Strict reading — for callers that reclaim irreversibly
%% -----------------------------------------------------------------------------
%%
%% A reading that drops peers unheard-from for a while is unsound for MST
%% compaction and projection-cell reclamation alike: a dropped member may hold
%% writes no other member has. `confirmed_peer_states/2` is the reading both
%% use.

strict_read_ignores_recency() ->
    P = mk_peer(),
    I = mk_inst(),
    H = vv(1),
    Stale = os:system_time(millisecond) - (10 * 60 * 1000),
    ok = bondy_oplog_peer_state:record_sync_complete(P, I, H, Stale),
    sync(),

    %% A cutoff after its last sync drops it...
    ?assertEqual(
        [], bondy_oplog_peer_state:get_instance_peer_states(I, Stale + 1)
    ),

    %% ...the strict read does not. A silent member must hold stability down,
    %% not vanish from the computation.
    ?assertMatch(
        {ok, [#{peer := P, frontier := H}]},
        bondy_oplog_peer_state:confirmed_peer_states(I, [P])
    ).

strict_read_names_unconfirmed_members() ->
    P1 = mk_peer(),
    P2 = mk_peer(),
    I = mk_inst(),
    ok = bondy_oplog_peer_state:record_sync_complete(P1, I, vv(2)),
    sync(),

    %% P2 is a member but has never confirmed, so there is no stability and the
    %% caller is told which member is missing.
    ?assertEqual(
        {unconfirmed, [P2]},
        bondy_oplog_peer_state:confirmed_peer_states(I, [P1, P2])
    ),

    ok = bondy_oplog_peer_state:record_sync_complete(P2, I, vv(3)),
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
%% `{ok, []}`, which licenses maximal reclamation, must come only from
%% clustering disabled. With clustering enabled, a membership listing no other
%% member (a member that has just restarted) and an unreadable one are errors.

reclamation_members_clustering_disabled() ->
    %% The eunit VM leaves `bondy_cluster` `enabled` unset, which is disabled.
    ?assertEqual({ok, []}, bondy_oplog_instance:reclamation_members()).

reclamation_members_no_other_member() ->
    bondy_oplog_test_helpers:with_members(
        fun() -> [partisan:node()] end,
        fun() ->
            ?assertEqual(
                {error, no_members},
                bondy_oplog_instance:reclamation_members()
            )
        end
    ).

reclamation_members_unavailable() ->
    bondy_oplog_test_helpers:with_members(
        fun() -> error(membership_unavailable) end,
        fun() ->
            ?assertEqual(
                {error, membership_unavailable},
                bondy_oplog_instance:reclamation_members()
            )
        end
    ).

record_and_read() ->
    P = mk_peer(),
    I = mk_inst(),
    H = vv(0),
    ok = bondy_oplog_peer_state:record_sync_complete(P, I, H),
    sync(),
    ?assertEqual({ok, H}, frontier_of(P, I)),
    ?assertMatch(
        [#{peer := P, frontier := H}],
        bondy_oplog_peer_state:get_instance_peer_states(I, 0)
    ).

forget_peer() ->
    P = mk_peer(),
    I1 = mk_inst(),
    I2 = mk_inst(),
    bondy_oplog_peer_state:record_sync_complete(P, I1, vv(1)),
    bondy_oplog_peer_state:record_sync_complete(P, I2, vv(2)),
    sync(),
    bondy_oplog_peer_state:forget_peer(P),
    sync(),
    ?assertEqual(not_found, frontier_of(P, I1)),
    ?assertEqual(not_found, frontier_of(P, I2)).

forget_instance() ->
    P1 = mk_peer(),
    P2 = mk_peer(),
    I = mk_inst(),
    bondy_oplog_peer_state:record_sync_complete(P1, I, vv(1)),
    bondy_oplog_peer_state:record_sync_complete(P2, I, vv(2)),
    sync(),
    bondy_oplog_peer_state:forget_instance(I),
    sync(),
    ?assertEqual(
        [],
        bondy_oplog_peer_state:get_known_peers(I, 0)
    ).

stale_peer_included_when_since_is_old() ->
    P = mk_peer(),
    I = mk_inst(),
    Old = os:system_time(millisecond) - 10 * 60 * 1000,
    bondy_oplog_peer_state:record_sync_complete(P, I, vv(4), Old),
    sync(),
    Cutoff = Old - 1,
    ?assertMatch(
        [P],
        bondy_oplog_peer_state:get_known_peers(I, Cutoff)
    ).

get_known_peers_unique() ->
    P = mk_peer(),
    I = mk_inst(),
    bondy_oplog_peer_state:record_sync_complete(P, I, vv(5)),
    bondy_oplog_peer_state:record_sync_complete(P, I, vv(6)),
    sync(),
    ?assertEqual(
        [P],
        bondy_oplog_peer_state:get_known_peers(I, 0)
    ),
    ?assertEqual({ok, vv(6)}, frontier_of(P, I)).

touch_peer_refreshes_last_seen() ->
    P = mk_peer(),
    I = mk_inst(),
    Old = os:system_time(millisecond) - 10 * 60 * 1000,
    bondy_oplog_peer_state:record_sync_complete(P, I, vv(7), Old),
    sync(),
    Cutoff = Old + 1,
    ?assertEqual([], bondy_oplog_peer_state:get_known_peers(I, Cutoff)),
    bondy_oplog_peer_state:touch_peer(P),
    sync(),
    ?assertEqual([P], bondy_oplog_peer_state:get_known_peers(I, Cutoff)).

%% A completed round whose peer reported no frontier, or an empty one, advances
%% the peer's recency, so the last-sync age stays truthful, but must NEVER
%% count as confirmation; and once a frontier IS recorded, later empty reports
%% refresh recency while preserving it.
empty_report_refreshes_without_confirming() ->
    P = mk_peer(),
    I = mk_inst(),
    T1 = os:system_time(millisecond) - 3000,

    %% No prior row: an empty report creates a recency-only entry.
    ok = bondy_oplog_peer_state:record_sync_complete(P, I, #{}, T1),
    sync(),
    ?assertMatch(
        [#{peer := P, frontier := undefined, last_sync := T1}],
        bondy_oplog_peer_state:get_instance_peer_states(I, 0)
    ),
    ?assertEqual(
        {unconfirmed, [P]},
        bondy_oplog_peer_state:confirmed_peer_states(I, [P])
    ),

    %% A non-empty frontier confirms.
    H = vv(9),
    T2 = T1 + 1000,
    ok = bondy_oplog_peer_state:record_sync_complete(P, I, H, T2),
    sync(),
    ?assertMatch(
        {ok, [#{peer := P, frontier := H, last_sync := T2}]},
        bondy_oplog_peer_state:confirmed_peer_states(I, [P])
    ),

    %% Later reports of none, or of an empty one, refresh recency and PRESERVE
    %% the recorded frontier.
    T3 = T2 + 1000,
    ok = bondy_oplog_peer_state:record_sync_complete(P, I, undefined, T3),
    T4 = T3 + 1000,
    ok = bondy_oplog_peer_state:record_sync_complete(P, I, #{}, T4),
    sync(),
    ?assertMatch(
        {ok, [#{peer := P, frontier := H, last_sync := T4}]},
        bondy_oplog_peer_state:confirmed_peer_states(I, [P])
    ).

%% Helpers

%% Force the gen_server's cast queue to drain by issuing a synchronous
%% round-trip. (`info/0` is intentionally lock-free and does not enter
%% the gen_server, so it cannot be used for this.)
sync() ->
    bondy_oplog_peer_state:sync().

vv(N) ->
    #{<<"origin">> => N}.

frontier_of(P, I) ->
    case
        [
            F
         || #{peer := Q, frontier := F} <-
                bondy_oplog_peer_state:get_instance_peer_states(I, 0),
            Q =:= P
        ]
    of
        [F] -> {ok, F};
        [] -> not_found
    end.

mk_peer() ->
    {peer, erlang:unique_integer([positive, monotonic])}.

mk_inst() ->
    list_to_binary(
        "ps_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).
