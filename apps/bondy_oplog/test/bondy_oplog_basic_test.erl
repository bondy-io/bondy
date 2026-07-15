%% Smoke tests for the foundation primitives that survive the
%% course-correction reshape: origin, HLC, event keys.
%%
%% Event-log tests have been deleted with the event_log module per
%% `_design/_implementation_plan.md` §1.2. Realm-MST tests live in
%% `bondy_replication_realm_mst_test`.

-module(bondy_oplog_basic_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

%% =============================================================================
%% Origin
%% =============================================================================

origin_default_stable_test() ->
    A = bondy_oplog_origin:default(),
    ?assert(is_binary(A)),
    ?assertEqual(?BONDY_OPLOG_ORIGIN_BYTES, byte_size(A)),
    ?assertEqual(A, bondy_oplog_origin:default()).

origin_new_random_test() ->
    ?assertNotEqual(bondy_oplog_origin:new(), bondy_oplog_origin:new()).

origin_validate_test() ->
    ?assertEqual(ok, bondy_oplog_origin:validate(<<1, 2, 3>>)),
    ?assertMatch({error, _}, bondy_oplog_origin:validate(<<>>)),
    ?assertMatch({error, _}, bondy_oplog_origin:validate("string")),
    ?assertMatch({error, _}, bondy_oplog_origin:validate(undefined)).

%% =============================================================================
%% HLC
%% =============================================================================

hlc_monotonic_test() ->
    H = bondy_oplog_hlc:new(),
    Vs = [bondy_oplog_hlc:now(H) || _ <- lists:seq(1, 1000)],
    ?assertEqual(Vs, lists:sort(Vs)),
    ?assertEqual(length(Vs), length(lists:usort(Vs))).

hlc_update_test() ->
    H = bondy_oplog_hlc:new(),
    Peer = bondy_oplog_hlc:encode(erlang:system_time(millisecond) + 60_000, 7),
    Updated = bondy_oplog_hlc:update(H, Peer),
    ?assert(Updated > Peer),
    Next = bondy_oplog_hlc:now(H),
    ?assert(Next > Peer).

hlc_logical_overflow_test() ->
    Seed = bondy_oplog_hlc:encode(erlang:system_time(millisecond) + 60_000, 0),
    H = bondy_oplog_hlc:new(Seed),
    N = ?BONDY_OPLOG_HLC_LOGICAL_MAX + 100,
    Last = lists:foldl(
        fun(_, Prev) ->
            V = bondy_oplog_hlc:now(H),
            ?assert(V > Prev),
            V
        end,
        0,
        lists:seq(1, N)
    ),
    {LastPhys, _} = bondy_oplog_hlc:decode(Last),
    {SeedPhys, _} = bondy_oplog_hlc:decode(Seed),
    ?assert(LastPhys > SeedPhys).

hlc_concurrent_test() ->
    H = bondy_oplog_hlc:new(),
    Parent = self(),
    NWorkers = 8,
    NPerWorker = 500,
    Pids = [
        spawn_link(fun() ->
            Vs = [bondy_oplog_hlc:now(H) || _ <- lists:seq(1, NPerWorker)],
            Parent ! {self(), Vs}
        end)
     || _ <- lists:seq(1, NWorkers)
    ],
    All = lists:flatten([
        receive
            {P, Vs} -> Vs
        end
     || P <- Pids
    ]),
    ?assertEqual(length(All), length(lists:usort(All))).

hlc_encode_decode_test() ->
    Cases = [
        {0, 0},
        {1, 1},
        {1700000000000, 12345},
        {16#FFFFFFFFFFFF, ?BONDY_OPLOG_HLC_LOGICAL_MAX}
    ],
    [
        ?assertEqual(
            {Phys, Log},
            bondy_oplog_hlc:decode(bondy_oplog_hlc:encode(Phys, Log))
        )
     || {Phys, Log} <- Cases
    ].

%% =============================================================================
%% Event key
%% =============================================================================

event_key_total_order_test() ->
    O1 = <<1>>,
    O2 = <<2>>,
    K1 = bondy_oplog_event:key(10, O1, 1),
    K2 = bondy_oplog_event:key(10, O1, 2),
    K3 = bondy_oplog_event:key(10, O2, 1),
    K4 = bondy_oplog_event:key(11, O1, 1),
    ?assertEqual([K1, K2, K3, K4], lists:sort([K4, K3, K2, K1])).

event_key_min_max_test() ->
    Min = bondy_oplog_event:min_key(),
    Max = bondy_oplog_event:max_key_for_hlc(100),
    K = bondy_oplog_event:key(50, <<"abc">>, 5),
    ?assert(Min < K),
    ?assert(K < Max).
