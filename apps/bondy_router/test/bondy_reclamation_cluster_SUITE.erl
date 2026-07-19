%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_reclamation_cluster_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).

%% BONDY_DB_RECLAMATION_PLAN.md Step 9 — the capstone validation, over a
%% 2-node Partisan cluster with live AAE (production paths only: writes and
%% deletes through `bondy_db`, stability through the confirm_root swap the
%% background sync performs, reclamation through
%% `bondy_oplog_instance:reclaim_stable_cells/1`):
%%
%%   - `reclaim_after_convergence_no_resurrection`: write on BOTH nodes,
%%     converge, delete on both sides, converge the deletions, reclaim on
%%     both nodes, then keep syncing and assert the deleted cells never
%%     come back while surviving cells are untouched — on either node.
%%   - `down_member_blocks_reclamation_until_retired`: with one member
%%     permanently down, a fresh tombstone is NOT reclaimable (the strict
%%     all-member oracle refuses); after the member is retired by a
%%     deliberate membership act (`partisan_peer_service:leave/1` — the
%%     replicated authority), the same tombstone IS reclaimed. This is the
%%     plan's "frontier advances past a retired member" assertion, and its
%%     converse: an un-retired silent member holds the frontier down.
%%
%% Scheduler-driven GC (compaction) is frozen suite-wide, as in
%% `bondy_frontier_cluster_SUITE`: reclamation must not race MST truncation
%% in the test window, and recorded peer roots must stay readable for the
%% frontier computation.

-define(NODE_NAMES, [creap1, creap2]).
-define(USERS_TABLE, security_users).
-define(BANDS, 4).
-define(CONVERGE_MS, 120000).

all() ->
    [
        reclaim_after_convergence_no_resurrection,
        down_member_blocks_reclamation_until_retired
    ].

suite() ->
    [{timetrap, {minutes, 10}}].

init_per_suite(Config) ->
    Nodes = bondy_ct:start_cluster(?NODE_NAMES, Config),
    _ = [push_module(Node, ?MODULE) || {_, Node, _} <- Nodes],
    _ = [bondy_ct:freeze_gc(Node) || {_, Node, _} <- Nodes],
    [{cluster, Nodes} | Config].

end_per_suite(Config) ->
    ok = bondy_ct:stop_cluster(?config(cluster, Config)),
    Config.

%% =============================================================================
%% TESTS
%% =============================================================================

reclaim_after_convergence_no_resurrection(Config) ->
    [N1, N2] = nodes_of(Config),
    %% Writes on BOTH sides: N1 owns the `a` bands, N2 the `b` bands.
    APairs = seed_pairs(<<"nra">>),
    BPairs = seed_pairs(<<"nrb">>),
    seed_and_converge(N1, N2, APairs),
    seed_and_converge(N2, N1, BPairs),

    %% Delete every seeded cell on its writer, and land a NUDGE write on the
    %% same band afterwards: the tombstone must sit strictly BELOW the
    %% stability point, and a boundary tombstone (the instance's last event)
    %% is deliberately unreclaimable (strict `<`).
    [delete_with_nudge(N1, B, K) || {B, K} <- APairs],
    [delete_with_nudge(N2, B, K) || {B, K} <- BPairs],
    [wait_gone(N2, B, K) || {B, K} <- APairs],
    [wait_gone(N1, B, K) || {B, K} <- BPairs],
    [wait_converge(N2, B, nudge_key(K), nudge_val(B)) || {B, K} <- APairs],
    [wait_converge(N1, B, nudge_key(K), nudge_val(B)) || {B, K} <- BPairs],

    %% Reclaim on both nodes. Stability needs confirm_root rounds from the
    %% live sync, so poll with scheduler nudges until tombstones are
    %% physically discarded on each side.
    DeletedCount = length(APairs) + length(BPairs),
    {ok, D1} = reclaim_until_discarded(N1, DeletedCount),
    {ok, D2} = reclaim_until_discarded(N2, DeletedCount),
    ct:pal("reclaimed: ~p cells on ~p, ~p cells on ~p", [D1, N1, D2, N2]),

    %% NO RESURRECTION: keep syncing, then every deleted cell is still gone
    %% on BOTH nodes and every nudge cell still reads back intact.
    sync_rounds(N1, N2, 5),
    [?assertEqual({error, not_found}, read(N1, B, K)) || {B, K} <- APairs],
    [?assertEqual({error, not_found}, read(N2, B, K)) || {B, K} <- APairs],
    [?assertEqual({error, not_found}, read(N1, B, K)) || {B, K} <- BPairs],
    [?assertEqual({error, not_found}, read(N2, B, K)) || {B, K} <- BPairs],
    [
        ?assertMatch({ok, {_, _}}, read(N, B, nudge_key(K)))
     || N <- [N1, N2], {B, K} <- APairs ++ BPairs
    ],

    %% The system is still live end-to-end: a NEW write to a reclaimed key
    %% converges like any other.
    {B1, K1} = hd(APairs),
    ok = erpc:call(N1, ?MODULE, do_apply, [
        ?USERS_TABLE, B1, K1, val(B1, K1)
    ]),
    ok = wait_converge(N2, B1, K1, val(B1, K1)),
    ok.

down_member_blocks_reclamation_until_retired(Config) ->
    [N1, N2] = nodes_of(Config),
    {_, N2, Peer2} = lists:keyfind(N2, 2, ?config(cluster, Config)),

    %% A cell that converged while both members were alive.
    Pairs = seed_pairs(<<"ret">>),
    seed_and_converge(N1, N2, Pairs),

    %% N2 goes down for good (crash, not a membership act).
    ok = peer:stop(Peer2),

    %% Fresh tombstones minted AFTER the death.
    [delete_with_nudge(N1, B, K) || {B, K} <- Pairs],

    %% The oracle refuses to advance past the down member: its confirmed
    %% roots are frozen at pre-death state, so the NEW tombstones (minted
    %% after) sit above every stability point and are RETAINED — however
    %% many attempts run. (Older, pre-death-confirmed garbage may
    %% legitimately reclaim; retention of the new tombstones is what the
    %% strict oracle guarantees, and it is proven below by the
    %% post-retirement discard count.)
    _ = [reclaim_once(N1) || _ <- lists:seq(1, 3)],

    %% RETIREMENT — a deliberate, replicated membership act.
    ok = erpc:call(N1, ?MODULE, do_retire, [N2]),

    %% The frontier advances past the retired member: all `length(Pairs)`
    %% new tombstones are reclaimed NOW — proof they were all retained
    %% through the down phase.
    {ok, D} = reclaim_until_discarded(N1, length(Pairs)),
    ct:pal("post-retirement reclaimed ~p cells", [D]),
    [?assertEqual({error, not_found}, read(N1, B, K)) || {B, K} <- Pairs],
    [
        ?assertMatch({ok, {_, _}}, read(N1, B, nudge_key(K)))
     || {B, K} <- Pairs
    ],
    ok.

%% =============================================================================
%% CONTROLLER HELPERS
%% =============================================================================

%% @private
nodes_of(Config) ->
    [Node || {_, Node, _} <- ?config(cluster, Config)].

%% @private
seed_pairs(Tag) ->
    [{band_for(Tag, B), <<"k">>} || B <- lists:seq(1, ?BANDS)].

%% @private
band_for(Tag, B) ->
    <<"com.bondy.creap.", Tag/binary, ".", (integer_to_binary(B))/binary>>.

%% @private
val(Band, Key) ->
    #{band_uri => Band, key => Key, marker => <<"creap">>}.

%% @private
nudge_key(Key) ->
    <<Key/binary, "_after">>.

%% @private
nudge_val(Band) ->
    #{band_uri => Band, marker => <<"nudge">>}.

%% @private
seed_and_converge(Writer, Other, Pairs) ->
    lists:foreach(
        fun({B, K}) ->
            ok = erpc:call(Writer, ?MODULE, do_apply, [
                ?USERS_TABLE, B, K, val(B, K)
            ])
        end,
        Pairs
    ),
    lists:foreach(
        fun({B, K}) -> ok = wait_converge(Other, B, K, val(B, K)) end,
        Pairs
    ).

%% @private
delete_with_nudge(Node, Band, Key) ->
    ok = erpc:call(Node, ?MODULE, do_delete, [?USERS_TABLE, Band, Key]),
    ok = erpc:call(Node, ?MODULE, do_apply, [
        ?USERS_TABLE, Band, nudge_key(Key), nudge_val(Band)
    ]),
    ok.

%% @private
read(Node, Band, Key) ->
    erpc:call(Node, ?MODULE, do_read, [?USERS_TABLE, Band, Key]).

%% @private
wait_converge(Node, Band, Key, Expected) ->
    wait_until(
        fun() ->
            case read(Node, Band, Key) of
                {ok, {Expected, _Hlc}} -> true;
                _ -> false
            end
        end,
        {converge_timeout, Node, Band, Key}
    ).

%% @private
wait_gone(Node, Band, Key) ->
    wait_until(
        fun() -> read(Node, Band, Key) =:= {error, not_found} end,
        {delete_converge_timeout, Node, Band, Key}
    ).

%% @private
%% Sum of cells discarded by one reclamation attempt across every instance
%% on `Node`. Per-instance errors ({unconfirmed, _} etc.) count as zero —
%% they are the oracle refusing, which is the behaviour under test.
reclaim_once(Node) ->
    _ = catch erpc:call(Node, bondy_oplog_sync_scheduler, trigger, []),
    Results = erpc:call(Node, ?MODULE, do_reclaim_all, []),
    lists:sum([
        maps:get(discarded, Stats)
     || {_I, {ok, Stats}} <- Results
    ]).

%% @private
%% Stability advances only as live-sync confirm_root rounds complete, so
%% poll, accumulating the (one-shot) discards until `Min` cells are gone.
%%
%% Each attempt also lands a round of CHURN — fresh writes with unique keys.
%% `security_users` shards by (realm, aggregate) hash, and a tombstone that
%% remains the NEWEST event on its shard is deliberately retained by the
%% strict `<` bound (BONDY_DB_RECLAMATION_PROOF.md §5: the frontier cannot
%% cover a same-HLC/higher-origin dot). Ongoing traffic — the production
%% condition — is what advances each shard past its tombstones; the churn
%% models it deterministically-in-the-limit across attempts.
reclaim_until_discarded(Node, Min) ->
    reclaim_until_discarded(Node, Min, now_ms() + ?CONVERGE_MS, 0, 0).

%% @private
reclaim_until_discarded(Node, Min, Deadline, Round, Acc0) ->
    churn_round(Node, Round),
    Acc = Acc0 + reclaim_once(Node),
    case Acc >= Min of
        true ->
            {ok, Acc};
        false ->
            now_ms() =< Deadline orelse
                error({reclaim_timeout, Node, Acc, Min}),
            timer:sleep(300),
            reclaim_until_discarded(Node, Min, Deadline, Round + 1, Acc)
    end.

%% @private
%% Fresh unique-keyed writes across every band: over attempts the
%% (realm, key) hash coverage advances every shard's newest event past the
%% tombstones minted earlier.
churn_round(Node, Round) ->
    lists:foreach(
        fun(B) ->
            Band = band_for(<<"churn">>, B),
            Key =
                <<"c_", (integer_to_binary(Round))/binary, "_",
                    (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
            _ =
                catch erpc:call(Node, ?MODULE, do_apply, [
                    ?USERS_TABLE, Band, Key, nudge_val(Band)
                ])
        end,
        lists:seq(1, ?BANDS)
    ).

%% @private
sync_rounds(N1, N2, Rounds) ->
    lists:foreach(
        fun(_) ->
            _ = catch erpc:call(N1, bondy_oplog_sync_scheduler, trigger, []),
            _ = catch erpc:call(N2, bondy_oplog_sync_scheduler, trigger, []),
            timer:sleep(300)
        end,
        lists:seq(1, Rounds)
    ).

%% @private
wait_until(Fun, ErrorTag) ->
    wait_until(Fun, ErrorTag, now_ms() + ?CONVERGE_MS).

%% @private
wait_until(Fun, ErrorTag, Deadline) ->
    case Fun() of
        true ->
            ok;
        false ->
            now_ms() =< Deadline orelse error(ErrorTag),
            timer:sleep(200),
            wait_until(Fun, ErrorTag, Deadline)
    end.

%% @private
now_ms() ->
    erlang:monotonic_time(millisecond).

%% @private
push_module(Node, Mod) ->
    {Mod, Bin, File} = code:get_object_code(Mod),
    {module, Mod} = erpc:call(Node, code, load_binary, [Mod, File, Bin]),
    ok.

%% =============================================================================
%% PEER-SIDE HELPERS (run on the cluster nodes via erpc)
%% =============================================================================

%% @private
do_apply(Table, Band, Key, Val) ->
    bondy_db:apply(table_handle(Table), Band, Key, {set, Val}).

%% @private
do_delete(Table, Band, Key) ->
    bondy_db:delete(table_handle(Table), Band, Key).

%% @private
do_read(Table, Band, Key) ->
    bondy_db:read(table_handle(Table), Band, Key).

%% @private
do_reclaim_all() ->
    [
        {I, catch bondy_oplog_instance:reclaim_stable_cells(I)}
     || I <- bondy_oplog:list_instances()
    ].

%% @private
%% Retirement: the deliberate, REPLICATED membership act — remove the (dead)
%% node from the Partisan membership. This is the plan's §4.8 authority.
do_retire(Node) ->
    Specs =
        case partisan_peer_service:members_for_orchestration() of
            {ok, L} when is_list(L) -> L;
            L when is_list(L) -> L
        end,
    case [S || #{name := N} = S <- Specs, N =:= Node] of
        [Spec | _] -> partisan_peer_service:leave(Spec);
        [] -> error({not_a_member, Node})
    end.

%% @private
table_handle(Table) ->
    case bondy_namespace_catalog:table(Table) of
        undefined -> error({table_not_provisioned, Table});
        Tab -> Tab
    end.
