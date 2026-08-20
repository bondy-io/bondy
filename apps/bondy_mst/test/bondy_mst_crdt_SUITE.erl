-module(bondy_mst_crdt_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(ISET(L), interval_sets:from_list(L)).
-define(TIMEOUT_XXL, timer:minutes(1)).

-compile(export_all).

all() ->
    [
        {group, set_with_local_store, []},
        {group, set_with_ets_store, []},
        {group, set_of_awsets_with_local_store, []},
        {group, set_of_awsets_with_ets_store, []}
        %% ,
        %% {group, set_with_leveled_store, []},
        %% {group, set_with_rocksdb_store, []},

        %% {group, set_of_awsets_with_leveled_store, []},
        %% {group, set_of_awsets_with_rocksdb_store, []}
    ].

set_test_cases() ->
    [
        set_online_sync,
        set_online_sync_complex,
        set_anti_entropy_fwd,
        set_bidirectional_sync
    ].

set_of_awsets_test_cases() ->
    [
        set_of_awsets_online_sync,
        set_of_awsets_online_sync_complex,
        set_of_awsets_anti_entropy_fwd
    ].

groups() ->
    [
        {set_with_local_store, [], set_test_cases()},
        {set_with_ets_store, [], set_test_cases()},
        %% {set_with_rocksdb_store, [], set_test_cases()},
        {set_with_leveled_store, [], set_test_cases()},
        {set_of_awsets_with_local_store, [], set_of_awsets_test_cases()},
        {set_of_awsets_with_ets_store, [], set_of_awsets_test_cases()},
        %% {set_of_awsets_with_rocksdb_store, [], set_of_awsets_test_cases()},
        {set_of_awsets_with_leveled_store, [], set_of_awsets_test_cases()}
    ].

init_per_group(set_with_local_store, Config) ->
    {ok, _} = application:ensure_all_started(bondy_mst),
    Opts = #{
        store => bondy_mst_map_store
    },
    [{grove_opts, Opts}] ++ Config;
init_per_group(set_with_ets_store, Config) ->
    {ok, _} = application:ensure_all_started(bondy_mst),
    Opts = #{
        store => bondy_mst_ets_store
    },
    [{grove_opts, Opts}] ++ Config;
init_per_group(set_with_leveled_store, Config) ->
    {ok, _} = application:ensure_all_started(bondy_mst),
    Opts = #{
        store => bondy_mst_leveled_store
    },
    [{grove_opts, Opts}] ++ Config;
init_per_group(set_with_rocksdb_store, Config) ->
    {ok, _} = application:ensure_all_started(bondy_mst),
    Opts = #{
        store => bondy_mst_rocksdb_store
    },
    [{grove_opts, Opts}] ++ Config;
init_per_group(set_of_awsets_with_local_store, Config) ->
    {ok, _} = application:ensure_all_started(bondy_mst),
    Opts = #{
        store => bondy_mst_map_store,
        merger => fun(_Key, A, B) -> state_awset:merge(A, B) end
    },
    [{grove_opts, Opts}] ++ Config;
init_per_group(set_of_awsets_with_ets_store, Config) ->
    {ok, _} = application:ensure_all_started(bondy_mst),
    Opts = #{
        store => bondy_mst_ets_store,
        merger => fun(_Key, A, B) -> state_awset:merge(A, B) end
    },
    [{grove_opts, Opts}] ++ Config;
init_per_group(set_of_awsets_with_leveled_store, Config) ->
    {ok, _} = application:ensure_all_started(bondy_mst),
    Opts = #{
        store => bondy_mst_leveled_store,
        merger => fun(_Key, A, B) -> state_awset:merge(A, B) end
    },
    [{grove_opts, Opts}] ++ Config;
init_per_group(set_of_awsets_with_rocksdb_store, Config) ->
    {ok, _} = application:ensure_all_started(bondy_mst),
    Opts = #{
        store => bondy_mst_rocksdb_store,
        merger => fun(_Key, A, B) -> state_awset:merge(A, B) end
    },
    [{grove_opts, Opts}] ++ Config.

end_per_group(_, _Config) ->
    ok.

%% Setup and teardown functions

%% Called once before any test cases are run
init_per_suite(Config) ->
    %% You can add any setup you need here
    Config.

%% Called once after all test cases have been run
end_per_suite(_Config) ->
    ok.

%% Called before each test case
init_per_testcase(TestCase, Config) ->
    GroveOpts0 = ?config(grove_opts, Config),
    GroveOpts = GroveOpts0#{store_opts => #{name => atom_to_binary(TestCase)}},
    lists:keyreplace(grove_opts, 1, Config, {grove_opts, GroveOpts}).

%% Called after each test case
end_per_testcase(_TestCase, _Config) ->
    _ = [
        try
            gen_server:stop(Peer)
        catch
            _:_ -> ok
        end
     || Peer <- bondy_mst_test_crdt_server:peers()
    ],
    ok.

%% =============================================================================
%% TEST CASES: SET
%% =============================================================================

set_online_sync(Config) ->
    N1 = 10,
    N2 = 20,
    N3 = 30,

    %% We start 3 replicas
    GroveOpts = ?config(grove_opts, Config),
    {ok, Peers} = bondy_mst_test_crdt_server:start_all(GroveOpts),
    [Peer1, Peer2, Peer3] = Peers,

    %% We validate they are alive
    ?assert(
        lists:all(
            fun(Peer) ->
                erlang:is_process_alive(erlang:whereis(Peer)) andalso
                    pong == gen_server:call(Peer, ping)
            end,
            Peers
        )
    ),

    %% We add data to replica at Peer1
    _ = [
        gen_server:call(Peer1, {put, X}, ?TIMEOUT_XXL)
     || X <- suffled_seq(1, N1)
    ],
    timer:sleep(5000),

    %% Post condition: the 3 replicas have the same pages
    E1 = ?ISET([{1, N1}]),
    ?assertEqual(
        E1,
        ?ISET([K || {K, true} <- gen_server:call(Peer1, list, ?TIMEOUT_XXL)]),
        "Peer1 should have all the elements we put"
    ),
    ?assertEqual(
        E1,
        ?ISET([K || {K, true} <- gen_server:call(Peer2, list, ?TIMEOUT_XXL)]),
        "Peer2 should have all the elements via replication"
    ),
    ?assertEqual(
        E1,
        ?ISET([K || {K, true} <- gen_server:call(Peer3, list, ?TIMEOUT_XXL)]),
        "Peer3 should have all the elements via replication"
    ),

    %% We concurrently write into replicas at peers 2 and 3
    _ = spawn(fun() ->
        _ = [
            gen_server:call(Peer2, {put, X}, ?TIMEOUT_XXL)
         || X <- suffled_seq(N1 + 1, N2)
        ]
    end),

    _ = spawn(fun() ->
        _ = [
            gen_server:call(Peer3, {put, X}, ?TIMEOUT_XXL)
         || X <- suffled_seq(N2 + 1, N3)
        ]
    end),

    timer:sleep(5000),

    %% Post condition: the 3 replicas have the same pages
    E2 = ?ISET([{1, N3}]),
    ?assertEqual(
        E2,
        ?ISET([K || {K, true} <- gen_server:call(Peer1, list, ?TIMEOUT_XXL)]),
        "Peer1 should have all the elements via replication"
    ),
    ?assertEqual(
        E2,
        ?ISET([K || {K, true} <- gen_server:call(Peer2, list, ?TIMEOUT_XXL)]),
        "Peer2 should have all the elements via replication"
    ),
    ?assertEqual(
        E2,
        ?ISET([K || {K, true} <- gen_server:call(Peer3, list, ?TIMEOUT_XXL)]),
        "Peer3 should have all the elements via replication"
    ),

    %% We concurrently write into all replicas
    _ = spawn(fun() ->
        _ = [
            gen_server:call(Peer1, {put, X}, ?TIMEOUT_XXL)
         || X <- suffled_seq(N1 + 1, N2)
        ]
    end),
    _ = spawn(fun() ->
        _ = [
            gen_server:call(Peer2, {put, X}, ?TIMEOUT_XXL)
         || X <- suffled_seq(N2 + 1, N3)
        ]
    end),
    _ = spawn(fun() ->
        _ = [
            gen_server:call(Peer3, {put, X}, ?TIMEOUT_XXL)
         || X <- suffled_seq(1, N1)
        ]
    end),

    timer:sleep(5000),

    ?assertEqual(
        E2,
        ?ISET([K || {K, true} <- gen_server:call(Peer1, list, ?TIMEOUT_XXL)]),
        "Peer1 should have all the elements via replication"
    ),
    ?assertEqual(
        E2,
        ?ISET([K || {K, true} <- gen_server:call(Peer2, list, ?TIMEOUT_XXL)]),
        "Peer2 should have all the elements via replication"
    ),
    ?assertEqual(
        E2,
        ?ISET([K || {K, true} <- gen_server:call(Peer3, list, ?TIMEOUT_XXL)]),
        "Peer3 should have all the elements via replication"
    ),

    NewRoot = gen_server:call(Peer1, root, ?TIMEOUT_XXL),

    ?assertEqual(
        NewRoot,
        gen_server:call(Peer2, root, ?TIMEOUT_XXL)
    ),

    ?assertEqual(
        NewRoot,
        gen_server:call(Peer3, root, ?TIMEOUT_XXL)
    ),

    %%  GC
    %% Epoch = erlang:monotonic_time(),
    %% ok = gen_server:call(Peer1, {gc, Epoch}, ?TIMEOUT_XXL),
    %% ok = gen_server:call(Peer2, {gc, Epoch}, ?TIMEOUT_XXL),
    %% ok = gen_server:call(Peer3, {gc, Epoch}, ?TIMEOUT_XXL),

    ok = gen_server:call(Peer1, gc, ?TIMEOUT_XXL),
    ok = gen_server:call(Peer2, gc, ?TIMEOUT_XXL),
    ok = gen_server:call(Peer3, gc, ?TIMEOUT_XXL),

    %% Check pages after GC
    GetContent = fun(Page) ->
        {
            bondy_mst_page:level(Page),
            bondy_mst_page:low(Page),
            bondy_mst_page:list(Page)
        }
    end,

    Peer1Pages = gen_server:call(Peer1, list_pages, ?TIMEOUT_XXL),
    Peer2Pages = gen_server:call(Peer2, list_pages, ?TIMEOUT_XXL),
    Peer3Pages = gen_server:call(Peer3, list_pages, ?TIMEOUT_XXL),

    ?assertEqual(
        [],
        lists:filter(
            fun(Page) -> bondy_mst_page:freed_at(Page) =/= undefined end,
            Peer1Pages
        ),
        "All garbage should've been collected in Peer1"
    ),

    ?assertEqual(
        [],
        lists:filter(
            fun(Page) -> bondy_mst_page:freed_at(Page) =/= undefined end,
            Peer2Pages
        ),
        {"All garbage should've been collected in Peer2", Peer2Pages}
    ),

    ?assertEqual(
        [],
        lists:filter(
            fun(Page) -> bondy_mst_page:freed_at(Page) =/= undefined end,
            Peer3Pages
        ),
        {"All garbage should've been collected in Peer3", Peer3Pages}
    ),

    %% Check list of pages
    Fun = fun({_Hash, Page}, Acc) -> [Page | Acc] end,
    Opts = #{root => NewRoot},
    ?assertEqual(
        lists:sort(
            gen_server:call(Peer1, {fold_pages, Fun, [], Opts}, ?TIMEOUT_XXL)
        ),
        lists:sort(Peer1Pages),
        "We should have a single root, all pages members of it"
    ),

    ?assertEqual(
        lists:sort(
            gen_server:call(Peer2, {fold_pages, Fun, [], Opts}, ?TIMEOUT_XXL)
        ),
        lists:sort(Peer2Pages),
        "We should have a single root, all pages descendants of it"
    ),

    ?assertEqual(
        lists:sort(Peer3Pages),
        lists:sort(
            gen_server:call(Peer3, {fold_pages, Fun, [], Opts}, ?TIMEOUT_XXL)
        ),
        "We should have a single root, all pages members of it"
    ),

    Contents = [GetContent(P) || P <- Peer1Pages],
    ?assertEqual(
        Contents,
        [GetContent(P) || P <- Peer2Pages],
        #{peer1 => Peer1Pages, peer2 => Peer2Pages}
    ),
    ?assertEqual(
        Contents,
        [GetContent(P) || P <- Peer3Pages],
        #{peer1 => Peer1Pages, peer2 => Peer3Pages}
    ),

    ok.

set_online_sync_complex(Config) ->
    GroveOpts = ?config(grove_opts, Config),
    {ok, Peers} = bondy_mst_test_crdt_server:start_all(GroveOpts),
    [Peer1, Peer2, Peer3] = Peers,

    L = [
        #{id => X, pid => self(), timestamp => erlang:monotonic_time()}
     || X <- lists:seq(1, 1000)
    ],

    _ = [
        gen_server:call(Peer1, {put, X}, ?TIMEOUT_XXL)
     || X <- list_shuffle(L)
    ],

    L1 = [K || {K, true} <- gen_server:call(Peer1, list, ?TIMEOUT_XXL)],
    L2 = [K || {K, true} <- gen_server:call(Peer2, list, ?TIMEOUT_XXL)],
    L3 = [K || {K, true} <- gen_server:call(Peer3, list, ?TIMEOUT_XXL)],

    ?assertEqual(L, L1),
    ?assertEqual(L1, L2),
    ?assertEqual(L2, L3),
    ok.

set_anti_entropy_fwd(Config) ->
    GroveOpts = ?config(grove_opts, Config),
    [Peer1 | RestPeers] = bondy_mst_test_crdt_server:peers(),

    %% We start Peer1 first
    {ok, [Peer1]} = bondy_mst_test_crdt_server:start(GroveOpts, [Peer1]),

    %% And put some values
    L = [
        #{id => X, pid => self(), timestamp => erlang:monotonic_time()}
     || X <- lists:seq(1, 1000)
    ],

    _ = [
        gen_server:call(Peer1, {put, X}, ?TIMEOUT_XXL)
     || X <- list_shuffle(L)
    ],

    L1 = [K || {K, true} <- gen_server:call(Peer1, list, ?TIMEOUT_XXL)],
    ?assertEqual(L, L1),

    %% We start the other peers
    {ok, [Peer2, Peer3]} = bondy_mst_test_crdt_server:start(
        GroveOpts, RestPeers
    ),

    %% Trigger sync Peer1 -> [Peer2, Peer3]
    ok = gen_server:call(Peer1, {trigger, Peer2}, ?TIMEOUT_XXL),
    ok = gen_server:call(Peer1, {trigger, Peer3}, ?TIMEOUT_XXL),

    timer:sleep(5000),

    %% Now Peer2 and Peer3 should have synced the data
    L2 = [K || {K, true} <- gen_server:call(Peer2, list, ?TIMEOUT_XXL)],
    L3 = [K || {K, true} <- gen_server:call(Peer3, list, ?TIMEOUT_XXL)],

    ?assertEqual(L1, L2),
    ?assertEqual(L2, L3),
    ok.

set_bidirectional_sync(Config) ->
    GroveOpts = ?config(grove_opts, Config),
    [Peer1, Peer2, Peer3] = bondy_mst_test_crdt_server:peers(),

    %% We start Peer2 first
    {ok, [Peer2]} = bondy_mst_test_crdt_server:start(GroveOpts, [Peer2]),

    %% And put some values
    L = lists:seq(1, 1000),
    _ = [
        gen_server:call(Peer2, {put, X}, ?TIMEOUT_XXL)
     || X <- list_shuffle(L)
    ],
    L2 = [K || {K, true} <- gen_server:call(Peer2, list, ?TIMEOUT_XXL)],
    ?assertEqual(L, L2),

    %% We start Peer1 and trigger sync Peer1 -> Peer2
    {ok, [Peer1]} = bondy_mst_test_crdt_server:start(GroveOpts, [Peer1]),
    ok = gen_server:call(Peer1, {trigger, Peer2}, ?TIMEOUT_XXL),
    timer:sleep(5000),
    %% Now Peer1 should have synced the data
    L1 = [K || {K, true} <- gen_server:call(Peer1, list, ?TIMEOUT_XXL)],
    ?assertEqual(L, L1),

    %% We start Peer3 and trigger sync Peer2 -> Peer3
    {ok, [Peer3]} = bondy_mst_test_crdt_server:start(GroveOpts, [Peer3]),
    ok = gen_server:call(Peer2, {trigger, Peer3}, ?TIMEOUT_XXL),
    timer:sleep(5000),
    %% Now Peer3 should have synced the data
    L3 = [K || {K, true} <- gen_server:call(Peer3, list, ?TIMEOUT_XXL)],
    ?assertEqual(L, L3),

    ok.

%% =============================================================================
%% TEST CASES: SET
%% =============================================================================

set_of_awsets_online_sync(Config) ->
    GroveOpts = ?config(grove_opts, Config),
    {ok, Peers} = bondy_mst_test_crdt_server:start_all(GroveOpts),

    [Peer1, Peer2, Peer3] = Peers,

    V0 = state_awset:new(),
    {ok, V1} = state_type:mutate({add, foo}, Peer1, V0),

    ?assert(
        lists:all(
            fun(Peer) ->
                erlang:is_process_alive(erlang:whereis(Peer)) andalso
                    pong == gen_server:call(Peer, ping)
            end,
            Peers
        )
    ),

    E1 = lists:usort([{X, V1} || X <- suffled_seq(1, 1000)]),
    _ = [gen_server:call(Peer1, {put, X, V}, ?TIMEOUT_XXL) || {X, V} <- E1],

    ?assertEqual(
        E1,
        lists:usort(gen_server:call(Peer1, list, ?TIMEOUT_XXL)),
        "Peer1 should have all the elements we put"
    ),
    ?assertEqual(
        E1,
        lists:usort(gen_server:call(Peer2, list, ?TIMEOUT_XXL)),
        "Peer2 should have all the elements via replication"
    ),
    ?assertEqual(
        E1,
        lists:usort(gen_server:call(Peer3, list, ?TIMEOUT_XXL)),
        "Peer3 should have all the elements via replication"
    ),
    ok.

set_of_awsets_online_sync_complex(_Config) ->
    ok.

set_of_awsets_anti_entropy_fwd(Config) ->
    meck:new(bondy_mst_test_crdt_server, [passthrough]),

    GroveOpts = ?config(grove_opts, Config),
    [Peer1, Peer2, _Peer3] = bondy_mst_test_crdt_server:peers(),
    {ok, [Peer1]} = bondy_mst_test_crdt_server:start(GroveOpts, [Peer1]),
    {ok, [Peer2]} = bondy_mst_test_crdt_server:start(GroveOpts, [Peer2]),

    V0 = state_awset:new(),
    {ok, V1} = state_type:mutate({add, foo}, Peer1, V0),
    {ok, V2} = state_type:mutate({add, bar}, Peer2, V0),
    V3 = state_awset:merge(V1, V2),

    N = 1000,

    L1 = [{X, V1} || X <- lists:seq(1, N)],
    L2 = [{X, V2} || X <- lists:seq(1, N)],
    L3 = [{X, V3} || X <- lists:seq(1, N)],

    %% We override broadcast, this way Peer2 will not receive
    %% the broadcast of the changes, i.e. we simulate they are not connected
    meck:expect(bondy_mst_test_crdt_server, broadcast, fun(_) ->
        ct:pal("Broadcasting disabled"),
        ok
    end),

    _ = [
        gen_server:call(Peer1, {put, K, V}, ?TIMEOUT_XXL)
     || {K, V} <- list_shuffle(L1)
    ],

    ?assertEqual(L1, gen_server:call(Peer1, list, ?TIMEOUT_XXL)),
    ?assertEqual([], gen_server:call(Peer2, list, ?TIMEOUT_XXL)),

    _ = [
        gen_server:call(Peer2, {put, K, V}, ?TIMEOUT_XXL)
     || {K, V} <- list_shuffle(L2)
    ],

    ?assertEqual(L1, gen_server:call(Peer1, list, ?TIMEOUT_XXL)),
    ?assertEqual(L2, gen_server:call(Peer2, list, ?TIMEOUT_XXL)),

    %% Restore module, any put or merge will broadcast to all peers
    meck:unload(bondy_mst_test_crdt_server),

    %% Trigger sync Peer1 -> Peer2
    ok = gen_server:call(Peer1, {trigger, Peer2}),

    timer:sleep(5000),

    %% Now Peer1 and Peer2 should have synced the data
    ?assertEqual(
        L3,
        gen_server:call(Peer1, list, ?TIMEOUT_XXL),
        "Merged values"
    ),
    ?assertEqual(
        L3,
        gen_server:call(Peer2, list, ?TIMEOUT_XXL),
        "Merged values"
    ),

    %% Trigger sync Peer2 -> Peer1
    ok = gen_server:call(Peer2, {trigger, Peer1}),
    timer:sleep(5000),
    %% Idempotency
    ?assertEqual(
        L3,
        gen_server:call(Peer1, list, ?TIMEOUT_XXL),
        "Merged values"
    ),
    ?assertEqual(
        L3,
        gen_server:call(Peer2, list, ?TIMEOUT_XXL),
        "Merged values"
    ),

    ok.

%% =============================================================================
%% PRIVATE VALIDATIONS
%% =============================================================================

%% no_dangling_garbage(T) ->

%% =============================================================================
%% PRIVATE UTILS
%% =============================================================================

%% @private
suffled_seq(N, M) ->
    list_shuffle(lists:seq(N, M)).

%% @private
randomize(1, List) ->
    randomize(List);
randomize(T, List) ->
    lists:foldl(
        fun(_E, Acc) -> randomize(Acc) end,
        randomize(List),
        lists:seq(1, (T - 1))
    ).

%% @private
randomize(List) ->
    D = lists:map(fun(A) -> {rand:uniform(), A} end, List),
    {_, D1} = lists:unzip(lists:keysort(1, D)),
    D1.

%% -----------------------------------------------------------------------------
%% @doc
%% From https://erlangcentral.org/wiki/index.php/RandomShuffle
%% @end
%% -----------------------------------------------------------------------------
list_shuffle([]) ->
    [];
list_shuffle(List) ->
    %% Determine the log n portion then randomize the list.
    randomize(round(math:log(length(List)) + 0.5), List).
