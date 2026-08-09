%% =============================================================================
%% D9 empirical verification — runs `bondy_oplog_core_proper_test`'s flagship
%% properties against the leveled-backed projection adapter, with the
%% ETS cache held constant. Three properties are exercised:
%%
%%   - prop_read_returns_latest_fold_leveled/0   (D1 — read consistency)
%%   - prop_range_monotonicity_leveled/0         (D4 — range scans)
%%   - prop_overlay_projection_merge_leveled/0   (D7 — projection + overlay)
%%
%% These exercise the read path, the range path, and the projection-write
%% + overlay-merge path respectively. Together they cover every adapter
%% callback the substrate uses on the hot path:
%%
%%   - `open/4`     (every property's setup)
%%   - `put_batch/2` (materialise → projection write)
%%   - `get/2`      (substrate's read pipeline)
%%   - `range/4`    (substrate's range pipeline)
%%   - `close/1`    (teardown)
%%
%% `delete/2` and `info/1` are exercised in the adapter-level eunit suite
%% (`bondy_db_projection_leveled_test`), not here.
%%
%% Each property creates a fresh namespace + a per-shard leveled Bookie
%% in a tempdir, runs the property, and tears the Bookie down. A property
%% running `?NUMTESTS` cases starts and stops `?NUMTESTS` Bookies — that
%% is intentional: every property case must be hermetic.
%%
%% Numtests is lower than the ETS suite (30 vs 50) because leveled IO is
%% slower; the goal is D9 *empirical* verification, not stress.
%% =============================================================================

-module(bondy_oplog_core_proper_leveled_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(CACHE_MOD, bondy_oplog_cache_ets).
-define(PROJ_MOD, bondy_db_projection_leveled).
-define(STRATEGY, lww_register).
-define(NUMTESTS, 30).
-define(BUCKET, <<>>).

-export([prop_read_returns_latest_fold_leveled/0]).
-export([prop_range_monotonicity_leveled/0]).
-export([prop_overlay_projection_merge_leveled/0]).

%% =============================================================================
%% Generators (shared shape with the ETS PropEr suite)
%% =============================================================================

key_gen() ->
    elements([<<"a">>, <<"b">>, <<"c">>, <<"d">>]).

events_gen() ->
    ?LET(
        N,
        integer(0, 6),
        ?LET(
            Ops,
            vector(N, op_kind_gen()),
            hlc_index(Ops)
        )
    ).

op_kind_gen() ->
    oneof([set, clear]).

hlc_index(Ops) ->
    hlc_index(Ops, 1, []).

hlc_index([], _Idx, Acc) ->
    lists:reverse(Acc);
hlc_index([set | Rest], Idx, Acc) ->
    hlc_index(Rest, Idx + 1, [{set, Idx, hlc_value(Idx)} | Acc]);
hlc_index([clear | Rest], Idx, Acc) ->
    hlc_index(Rest, Idx + 1, [{clear, Idx} | Acc]).

hlc_value(Idx) ->
    <<Idx:32/big>>.

range_bounds_gen() ->
    ?LET(
        {L, H},
        {
            elements([<<"a">>, <<"b">>, <<"c">>]),
            elements([<<"b">>, <<"c">>, <<"d">>, <<"z">>])
        },
        case L =< H of
            true -> {L, H};
            false -> {H, L}
        end
    ).

%% =============================================================================
%% Properties
%% =============================================================================

prop_read_returns_latest_fold_leveled() ->
    ?FORALL(
        {Key, Events},
        {key_gen(), events_gen()},
        with_shard(fun(NS) ->
            populate_overlay(NS, Key, Events),
            Got = bondy_oplog_core:read(NS, primary, Key),
            Expected = expected_read(Events),
            equal_read_result(Got, Expected)
        end)
    ).

prop_overlay_projection_merge_leveled() ->
    ?FORALL(
        {Key, Events, OverlayOp},
        {key_gen(), events_gen(), op_kind_gen()},
        ?IMPLIES(
            Events =/= [],
            with_shard(fun(NS) ->
                ProjValue = fold_events(initial(), Events),
                materialise(NS, Key, ProjValue),
                ProjHlc = hlc_of(ProjValue),
                OverlayHlc = ProjHlc + 1,
                OverlayEvent =
                    case OverlayOp of
                        set -> {set, OverlayHlc, hlc_value(OverlayHlc)};
                        clear -> {clear, OverlayHlc}
                    end,
                insert_overlay(NS, Key, OverlayEvent),
                Got = bondy_oplog_core:read(NS, primary, Key),
                Expected = expected_read(Events ++ [OverlayEvent]),
                equal_read_result(Got, Expected)
            end)
        )
    ).

prop_range_monotonicity_leveled() ->
    ?FORALL(
        {Keys, {Low, High}},
        {
            list(elements([<<"a">>, <<"b">>, <<"c">>, <<"d">>])),
            range_bounds_gen()
        },
        with_shard(fun(NS) ->
            UniqueKeys = lists:usort(Keys),
            lists:foreach(
                fun({K, Idx}) ->
                    materialise(NS, K, {set, hlc_value(Idx), Idx})
                end,
                lists:zip(UniqueKeys, lists:seq(1, length(UniqueKeys)))
            ),
            {ok, Rows} = bondy_oplog_core:range(
                NS,
                primary,
                {Low, High},
                #{}
            ),
            ResultKeys = [K || {K, _, _} <- Rows],
            Sorted = ResultKeys =:= lists:sort(ResultKeys),
            Expected = [K || K <- UniqueKeys, K >= Low, K < High],
            Sorted andalso ResultKeys =:= Expected
        end)
    ).

%% =============================================================================
%% Setup / teardown (leveled-aware)
%% =============================================================================

with_shard(Fn) ->
    {ok, _} = application:ensure_all_started(bondy_db),
    NS = mk_ns(),
    Handle = start_shard(NS, primary, 0, 1),
    try
        Fn(NS)
    after
        stop_shard(Handle)
    end.

start_shard(NS, Index, Shard, ShardCount) ->
    Dir = make_tempdir(),
    %% head_only=with_lookup is required by bondy_db_projection_leveled;
    %% use the proplist form to add it.
    {ok, Bookie} = leveled_bookie:book_start(
        [
            {root_path, Dir},
            {cache_size, 2000},
            {max_journalsize, 100_000_000},
            {sync_strategy, none},
            {head_only, with_lookup}
        ]
    ),
    {ok, CH} = ?CACHE_MOD:init(NS, Index, Shard, #{}),
    %% Bucket is a call-time parameter; the leveled projection adapter's
    %% handle only carries the Bookie pid.
    {ok, PH} = ?PROJ_MOD:open(
        NS,
        Index,
        Shard,
        #{bookie => Bookie}
    ),
    OV = bondy_oplog_db_overlay:new(),
    ok = bondy_oplog_core_registry:register(NS, Index, Shard, #{
        shard_count => ShardCount,
        cache_adapter => ?CACHE_MOD,
        cache_handle => CH,
        projection_adapter => ?PROJ_MOD,
        projection_handle => PH,
        overlay => OV,
        fold_module => ?STRATEGY
    }),
    #{
        ns => NS,
        index => Index,
        shard => Shard,
        cache_handle => CH,
        projection => PH,
        overlay => OV,
        bookie => Bookie,
        dir => Dir
    }.

stop_shard(#{
    ns := NS,
    index := Index,
    shard := Shard,
    cache_handle := CH,
    projection := PH,
    overlay := OV,
    bookie := Bookie,
    dir := Dir
}) ->
    ok = bondy_oplog_core_registry:unregister(NS, Index, Shard),
    ok = ?CACHE_MOD:invalidate_all(CH),
    ok = ?PROJ_MOD:close(PH),
    ok = bondy_oplog_db_overlay:delete(OV),
    ok = leveled_bookie:book_close(Bookie),
    rmrf(Dir).

mk_ns() ->
    list_to_atom(
        "mst_db_proper_lev_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

make_tempdir() ->
    Base = filename:join([
        "/tmp",
        "bondy_mst_proper_leveled",
        integer_to_list(erlang:unique_integer([positive, monotonic]))
    ]),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.

rmrf(Dir) ->
    case file:del_dir_r(Dir) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, _} -> ok
    end.

%% =============================================================================
%% Model helpers (same as ETS suite)
%% =============================================================================

populate_overlay(NS, Key, Events) ->
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, primary, 0),
    OV = bondy_oplog_core_registry:entry_overlay(Entry),
    lists:foreach(
        fun(E) ->
            Hlc = hlc_of_event(E),
            Event = mk_event(Hlc, E),
            ok = bondy_oplog_db_overlay:insert(OV, ?BUCKET, Key, Event)
        end,
        Events
    ).

insert_overlay(NS, Key, E) ->
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, primary, 0),
    OV = bondy_oplog_core_registry:entry_overlay(Entry),
    Hlc = hlc_of_event(E),
    Event = mk_event(Hlc, E),
    ok = bondy_oplog_db_overlay:insert(OV, ?BUCKET, Key, Event).

materialise(NS, Key, {set, _, _} = State) ->
    do_materialise(NS, Key, State);
materialise(NS, Key, {cleared, _} = State) ->
    do_materialise(NS, Key, State);
materialise(_NS, _Key, undefined) ->
    ok.

do_materialise(NS, Key, State) ->
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, primary, 0),
    PH = bondy_oplog_core_registry:entry_projection_handle(Entry),
    Frame = bondy_oplog_test_helpers:frame(?STRATEGY, State, hlc_of(State)),
    ok = ?PROJ_MOD:put_batch(PH, [{?BUCKET, Key, Frame}]).

mk_event(Hlc, Op) ->
    Key = bondy_oplog_event:key(Hlc, <<"o">>, Hlc),
    bondy_oplog_event:new(Key, Op, undefined).

initial() ->
    bondy_oplog_crdt_lww_register:init().

fold_events(State, Events) ->
    lists:foldl(
        fun(E, Acc) ->
            bondy_oplog_crdt_lww_register:apply_op(Acc, E, undefined)
        end,
        State,
        Events
    ).

hlc_of({set, _Val, H}) -> H;
hlc_of({cleared, H}) -> H;
hlc_of(undefined) -> 0.

hlc_of_event({set, H, _}) -> H;
hlc_of_event({clear, H}) -> H.

expected_read(Events) ->
    Sorted = lists:sort(
        fun(A, B) -> hlc_of_event(A) =< hlc_of_event(B) end,
        Events
    ),
    State = fold_events(initial(), Sorted),
    case bondy_oplog_crdt_lww_register:to_value(State) of
        undefined -> undefined;
        Value -> {Value, hlc_of(State)}
    end.

equal_read_result(Got, Expected) ->
    case {Got, Expected} of
        {undefined, undefined} -> true;
        {{V1, H1}, {V2, H2}} -> V1 =:= V2 andalso H1 =:= H2;
        _ -> false
    end.

%% =============================================================================
%% EUnit wrapper
%% =============================================================================

properties_leveled_test_() ->
    {timeout, 600, fun() ->
        Opts = [{to_file, user}, {numtests, ?NUMTESTS}],
        Props = [
            prop_read_returns_latest_fold_leveled(),
            prop_range_monotonicity_leveled(),
            prop_overlay_projection_merge_leveled()
        ],
        lists:foreach(
            fun(Prop) -> ?assert(proper:quickcheck(Prop, Opts)) end,
            Props
        )
    end}.
