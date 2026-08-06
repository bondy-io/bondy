%% Lifecycle and supervision tests for the library.

-module(bondy_oplog_lifecycle_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    [
        bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    ok.

lifecycle_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun start_stop/0,
        fun stop_unknown/0,
        fun stop_survives_missing_registry_row/0,
        fun crash_isolated_between_instances/0,
        fun discover_flat/0,
        fun discover_sharded/0,
        fun path_layouts_round_trip/0
    ]}.

%% Regression: an instance whose registry row is gone while its subtree
%% still runs (a consumer teardown that failed mid-close) must remain
%% STOPPABLE. `list_instances/0` enumerates supervisor children while
%% `stop_instance/1` used to resolve only via the registry row — the
%% asymmetry made such an instance visible to every scheduler yet
%% unkillable, so it polluted every later test module's clean slate for
%% the VM's lifetime (the `my_db/0` zombie).
stop_survives_missing_registry_row() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    ?assert(lists:member(Id, bondy_oplog:list_instances())),

    %% Mint the zombie: drop the row, keep the subtree.
    ok = bondy_oplog_registry:unregister(Id),
    ?assertEqual(undefined, bondy_oplog_registry:sup_pid(Id)),
    ?assert(lists:member(Id, bondy_oplog:list_instances())),

    %% The fallback resolves through the same enumeration
    %% `list_instances/0` uses, so what is visible is killable.
    ?assertEqual(ok, bondy_oplog:stop_instance(Id)),
    ?assertNot(lists:member(Id, bondy_oplog:list_instances())),
    ?assertEqual({error, not_found}, bondy_oplog:stop_instance(Id)).

start_stop() ->
    Id = mk_id(),
    {ok, SupPid} = bondy_oplog:start_instance(Id),
    ?assert(is_pid(SupPid)),
    K = bondy_oplog:append(Id, hi),
    ?assertMatch({ok, _}, bondy_oplog:get(Id, K)),
    ok = bondy_oplog:stop_instance(Id),
    ?assertEqual(
        {error, not_found},
        bondy_oplog:stop_instance(Id)
    ).

stop_unknown() ->
    ?assertEqual(
        {error, not_found},
        bondy_oplog:stop_instance(<<"never_started">>)
    ).

crash_isolated_between_instances() ->
    A = mk_id(),
    B = mk_id(),
    {ok, _} = bondy_oplog:start_instance(A),
    {ok, _} = bondy_oplog:start_instance(B),
    PidA = bondy_oplog_instance:whereis(A),
    ?assert(is_pid(PidA)),
    exit(PidA, kill),
    ok = wait_until(
        fun() ->
            P = bondy_oplog_instance:whereis(A),
            is_pid(P) andalso P =/= PidA
        end,
        2000
    ),
    ?assert(is_pid(bondy_oplog_instance:whereis(B))),
    ok = bondy_oplog:stop_instance(A),
    ok = bondy_oplog:stop_instance(B).

discover_flat() ->
    Tmp = mk_tmp_dir(),
    %% Create three "instance" directories under the flat layout.
    Ids = [<<"alpha">>, <<"beta">>, <<"gamma">>],
    [ok = file:make_dir(filename:join(Tmp, Id)) || Id <- Ids],
    Found = bondy_oplog:discover_instances(
        Tmp, flat
    ),
    ?assertEqual(lists:sort(Ids), lists:sort(Found)),
    ok = del_tree(Tmp).

discover_sharded() ->
    Tmp = mk_tmp_dir(),
    Ids = [<<"foo">>, <<"bar">>, <<"baz">>],
    [
        begin
            P = bondy_oplog_path:storage_path(Id, Tmp, sharded),
            %% `ensure_dir/1` ensures the *parent* exists; passing a
            %% sentinel filename inside `P` makes `P` itself the parent
            %% to be created.
            ok = filelib:ensure_dir(filename:join(P, "marker"))
        end
     || Id <- Ids
    ],
    Found = bondy_oplog:discover_instances(
        Tmp, sharded
    ),
    ?assertEqual(lists:sort(Ids), lists:sort(Found)),
    ok = del_tree(Tmp).

path_layouts_round_trip() ->
    Id = <<"hello">>,
    Base = <<"/tmp/bondy_mst_data">>,
    Flat = bondy_oplog_path:storage_path(Id, Base, flat),
    Sharded = bondy_oplog_path:storage_path(Id, Base, sharded),
    ?assertEqual(
        <<"/tmp/bondy_mst_data/hello">>,
        unicode:characters_to_binary(Flat)
    ),
    %% sha256("hello") = 2cf24dba...
    ?assertEqual(
        <<"/tmp/bondy_mst_data/2c/2cf2/hello">>,
        unicode:characters_to_binary(Sharded)
    ).

%% Helpers

mk_id() ->
    list_to_binary(
        "lc_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

mk_tmp_dir() ->
    Suffix =
        integer_to_list(os:system_time(microsecond)) ++ "_" ++
            integer_to_list(erlang:phash2(make_ref())),
    Dir = filename:join(
        <<"/tmp">>,
        list_to_binary("bondy_mst_lc_" ++ Suffix)
    ),
    %% `ensure_path/1` is idempotent — collisions across VM restarts
    %% don't matter and leftover dirs from prior runs are reused.
    ok = filelib:ensure_path(Dir),
    Dir.

del_tree(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            [
                begin
                    P = filename:join(Dir, N),
                    case filelib:is_dir(P) of
                        true -> del_tree(P);
                        false -> file:delete(P)
                    end
                end
             || N <- Names
            ];
        _ ->
            ok
    end,
    file:del_dir(Dir).

wait_until(_F, T) when T =< 0 -> error(timeout);
wait_until(F, T) ->
    case F() of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_until(F, T - 20)
    end.
