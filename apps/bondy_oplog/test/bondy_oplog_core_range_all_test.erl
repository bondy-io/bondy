%% =============================================================================
%% Tests for `bondy_oplog_core:range_all/4,5` (`MST_DB_DESIGN.md` §18 item 2).
%%
%% Pins cross-shard scatter-merge: enumerating every shard registered
%% under `(NS, Index)`, running the single-shard `range/5` per shard with
%% `shard => N`, and merging the per-shard results into a single
%% globally-sorted list. Verifies limit truncation after merge,
%% include_overlay + fence propagation, bucket isolation,
%% and the `range_all/4` backward-compat alias.
%% =============================================================================

-module(bondy_oplog_core_range_all_test).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    ok.

range_all_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun empty_namespace_returns_empty_list/0,
        fun single_shard_matches_single_shard_range/0,
        fun multi_shard_merges_globally_sorted/0,
        fun multi_shard_respects_limit/0,
        fun multi_shard_propagates_include_overlay_false/0,
        fun multi_shard_propagates_fence/0,
        fun bucket_isolation_within_shard/0,
        fun range_all_4_defaults_to_empty_bucket/0,
        fun other_index_not_scanned/0
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

empty_namespace_returns_empty_list() ->
    NS = mk_ns(),
    ?assertEqual(
        {ok, []},
        bondy_oplog_core:range_all(
            NS,
            primary,
            <<>>,
            {<<"a">>, <<"z">>},
            #{}
        )
    ).

single_shard_matches_single_shard_range() ->
    %% With one shard the scatter is a no-op — same result as
    %% `range/5` against that shard.
    NS = mk_ns(),
    {Setup, #{projection := PH}} = setup_shard(NS, primary, 0, 1, lww_register),
    materialise(PH, <<"a">>, {set, <<"va">>, 10}, 10),
    materialise(PH, <<"b">>, {set, <<"vb">>, 20}, 20),
    {ok, R} = bondy_oplog_core:range_all(
        NS,
        primary,
        <<>>,
        {<<"a">>, <<"z">>},
        #{}
    ),
    ?assertEqual(
        [
            {<<"a">>, <<"va">>, 10},
            {<<"b">>, <<"vb">>, 20}
        ],
        R
    ),
    teardown_shard(Setup).

multi_shard_merges_globally_sorted() ->
    %% Three shards, interleaved keys. Result must be ascending across
    %% all shards.
    NS = mk_ns(),
    Setups = setup_n_shards(NS, primary, 3, 3, lww_register),
    %% Place keys directly into each shard's projection. The hash
    %% routing is `range/5`'s concern; `range_all` scatters to every
    %% registered shard, so where each key physically lives is
    %% immaterial to this test.
    place(Setups, 0, <<"a">>, 10),
    place(Setups, 1, <<"b">>, 20),
    place(Setups, 2, <<"c">>, 30),
    place(Setups, 0, <<"d">>, 40),
    place(Setups, 1, <<"e">>, 50),
    {ok, R} = bondy_oplog_core:range_all(
        NS,
        primary,
        <<>>,
        {<<"a">>, <<"z">>},
        #{}
    ),
    Keys = [K || {K, _, _} <- R],
    ?assertEqual([<<"a">>, <<"b">>, <<"c">>, <<"d">>, <<"e">>], Keys),
    teardown_shards(Setups).

multi_shard_respects_limit() ->
    NS = mk_ns(),
    Setups = setup_n_shards(NS, primary, 4, 4, lww_register),
    place(Setups, 0, <<"a">>, 10),
    place(Setups, 1, <<"b">>, 20),
    place(Setups, 2, <<"c">>, 30),
    place(Setups, 3, <<"d">>, 40),
    {ok, R} = bondy_oplog_core:range_all(
        NS,
        primary,
        <<>>,
        {<<"a">>, <<"z">>},
        #{limit => 2}
    ),
    Keys = [K || {K, _, _} <- R],
    ?assertEqual([<<"a">>, <<"b">>], Keys),
    teardown_shards(Setups).

multi_shard_propagates_include_overlay_false() ->
    %% Overlay-only cells must be dropped from every shard when the
    %% caller asks for projection-only data.
    NS = mk_ns(),
    Setups = setup_n_shards(NS, primary, 2, 2, lww_register),
    %% Shard 0: projection cell.
    place(Setups, 0, <<"a">>, 10),
    %% Shard 1: overlay-only cell.
    overlay_place(Setups, 1, <<"b">>, 20),
    %% With include_overlay=true both surface.
    {ok, With} = bondy_oplog_core:range_all(
        NS,
        primary,
        <<>>,
        {<<"a">>, <<"z">>},
        #{include_overlay => true}
    ),
    ?assertEqual([<<"a">>, <<"b">>], [K || {K, _, _} <- With]),
    %% With include_overlay=false the overlay cell is excluded.
    {ok, Without} = bondy_oplog_core:range_all(
        NS,
        primary,
        <<>>,
        {<<"a">>, <<"z">>},
        #{include_overlay => false}
    ),
    ?assertEqual([<<"a">>], [K || {K, _, _} <- Without]),
    teardown_shards(Setups).

multi_shard_propagates_fence() ->
    %% Per-shard `fence` must clip overlay events to `=< Fence` for
    %% every shard.
    NS = mk_ns(),
    Setups = setup_n_shards(NS, primary, 2, 2, lww_register),
    overlay_place(Setups, 0, <<"a">>, 5),
    overlay_place(Setups, 1, <<"b">>, 15),
    %% Fence = 10 excludes the HLC=15 event in shard 1.
    {ok, R} = bondy_oplog_core:range_all(
        NS,
        primary,
        <<>>,
        {<<"a">>, <<"z">>},
        #{fence => 10}
    ),
    ?assertEqual([<<"a">>], [K || {K, _, _} <- R]),
    teardown_shards(Setups).

bucket_isolation_within_shard() ->
    %% A shard hosts more than one bucket. `range_all` must only return
    %% rows in the requested bucket.
    NS = mk_ns(),
    {Setup, #{projection := PH}} = setup_shard(NS, primary, 0, 1, lww_register),
    materialise_bucket(PH, <<"b1">>, <<"k">>, {set, <<"v1">>, 10}, 10),
    materialise_bucket(PH, <<"b2">>, <<"k">>, {set, <<"v2">>, 20}, 20),
    {ok, R1} = bondy_oplog_core:range_all(
        NS,
        primary,
        <<"b1">>,
        {<<"a">>, <<"z">>},
        #{}
    ),
    ?assertEqual([{<<"k">>, <<"v1">>, 10}], R1),
    {ok, R2} = bondy_oplog_core:range_all(
        NS,
        primary,
        <<"b2">>,
        {<<"a">>, <<"z">>},
        #{}
    ),
    ?assertEqual([{<<"k">>, <<"v2">>, 20}], R2),
    teardown_shard(Setup).

range_all_4_defaults_to_empty_bucket() ->
    %% The `/4` alias hits the default `<<>>` bucket.
    NS = mk_ns(),
    {Setup, #{projection := PH}} = setup_shard(NS, primary, 0, 1, lww_register),
    materialise(PH, <<"a">>, {set, <<"v">>, 10}, 10),
    ?assertEqual(
        bondy_oplog_core:range_all(
            NS,
            primary,
            <<>>,
            {<<"a">>, <<"z">>},
            #{}
        ),
        bondy_oplog_core:range_all(
            NS,
            primary,
            {<<"a">>, <<"z">>},
            #{}
        )
    ),
    teardown_shard(Setup).

other_index_not_scanned() ->
    %% Shards under a different Index must not surface in the result —
    %% the `(NS, Index)` filter is what bounds the scatter.
    NS = mk_ns(),
    {S1, #{projection := PH1}} = setup_shard(NS, primary, 0, 1, lww_register),
    {S2, #{projection := PH2}} = setup_shard(NS, by_name, 0, 1, lww_register),
    materialise(PH1, <<"a">>, {set, <<"primary">>, 10}, 10),
    materialise(PH2, <<"a">>, {set, <<"secondary">>, 20}, 20),
    {ok, R} = bondy_oplog_core:range_all(
        NS,
        primary,
        <<>>,
        {<<"a">>, <<"z">>},
        #{}
    ),
    ?assertEqual([{<<"a">>, <<"primary">>, 10}], R),
    teardown_shard(S1),
    teardown_shard(S2).

%% =============================================================================
%% Helpers
%% =============================================================================

mk_ns() ->
    list_to_atom(
        "mst_db_range_all_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

mk_event(Hlc, Origin, Seq, Op) ->
    K = bondy_oplog_event:key(Hlc, Origin, Seq),
    bondy_oplog_event:new(K, Op, undefined).

materialise(PH, Key, State, Hlc) ->
    materialise_bucket(PH, <<>>, Key, State, Hlc).

materialise_bucket(PH, Bucket, Key, State, Hlc) ->
    Frame = bondy_oplog_test_helpers:frame(lww_register, State, Hlc),
    ok = bondy_oplog_projection_ets:put_batch(PH, [{Bucket, Key, Frame}]).

overlay_insert(OV, Key, Hlc, Op) ->
    Event = mk_event(Hlc, <<"origin">>, Hlc, Op),
    ok = bondy_oplog_db_overlay:insert(OV, <<>>, Key, Event).

setup_shard(NS, Index, Shard, ShardCount, Strategy) ->
    {ok, CH} = bondy_oplog_cache_ets:init(NS, Index, Shard, #{}),
    {ok, PH} = bondy_oplog_projection_ets:open(NS, Index, Shard, #{}),
    OV = bondy_oplog_db_overlay:new(),
    ok = bondy_oplog_core_registry:register(NS, Index, Shard, #{
        shard_count => ShardCount,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => CH,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => PH,
        overlay => OV,
        fold_module => Strategy
    }),
    Setup = #{
        ns => NS,
        index => Index,
        shard => Shard,
        cache_handle => CH,
        projection => PH,
        overlay => OV
    },
    {Setup, Setup}.

teardown_shard(#{
    ns := NS,
    index := Index,
    shard := Shard,
    cache_handle := CH,
    projection := PH,
    overlay := OV
}) ->
    ok = bondy_oplog_core_registry:unregister(NS, Index, Shard),
    ok = bondy_oplog_cache_ets:close(CH),
    ok = bondy_oplog_projection_ets:close(PH),
    ok = bondy_oplog_db_overlay:delete(OV).

setup_n_shards(NS, Index, ShardCount, _NShards, Strategy) ->
    [
        begin
            {S, _} = setup_shard(NS, Index, Sh, ShardCount, Strategy),
            S
        end
     || Sh <- lists:seq(0, ShardCount - 1)
    ].

teardown_shards(Setups) ->
    [teardown_shard(S) || S <- Setups],
    ok.

place(Setups, ShardIdx, Key, Hlc) ->
    #{projection := PH} = lists:nth(ShardIdx + 1, Setups),
    materialise(PH, Key, {set, <<"v">>, Hlc}, Hlc).

overlay_place(Setups, ShardIdx, Key, Hlc) ->
    #{overlay := OV} = lists:nth(ShardIdx + 1, Setups),
    overlay_insert(OV, Key, Hlc, {set, Hlc, <<"v">>}).
