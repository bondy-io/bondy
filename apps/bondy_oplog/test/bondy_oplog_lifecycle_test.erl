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
        fun path_layouts_round_trip/0,
        fun start_refuses_an_id_that_cannot_name_a_directory/0,
        fun start_admits_a_hyphenated_id_without_storage_path/0
    ]}.

%% An instance id becomes a directory under every base the instance writes
%% to. `bondy_oplog_path:storage_path/3` checks it, but two of those bases
%% never go through `storage_path/3`: an explicit `wal_dir`, and the
%% `/tmp/bondy_oplog_wal/<os pid>` default an instance without
%% `storage_path` gets — which is what every case here uses. The check
%% therefore has to sit at admission, and a refused id must leave nothing
%% behind: no registry row, no supervisor child.
start_refuses_an_id_that_cannot_name_a_directory() ->
    WalDir = unicode:characters_to_binary(
        filename:join("/tmp", "bondy_oplog_lifecycle_" ++ os:getpid())
    ),
    Cases = [
        {<<"a/b">>, separator, #{}},
        {<<"a/b">>, separator, #{wal_dir => WalDir}},
        {<<"../../pwned">>, separator, #{}},
        {<<"..">>, relative, #{}},
        {<<>>, empty, #{}},
        {<<"a", 0, "b">>, nul_byte, #{}},
        {<<"inst-", 233>>, not_utf8, #{}}
    ],
    lists:foreach(
        fun({Id, Reason, Opts}) ->
            ?assertError(
                {invalid_instance_id, Id, Reason},
                bondy_oplog:start_instance(Id, Opts)
            ),
            ?assertEqual(undefined, bondy_oplog_registry:sup_pid(Id)),
            ?assertNot(lists:member(Id, bondy_oplog:list_instances()))
        end,
        Cases
    ).

%% The complement: a `bondy_db`-shaped id (`<Db>-<Shard>`) with no
%% `storage_path` starts, its WAL lands under the `/tmp` default as ONE
%% component named by the id, and it stops cleanly.
start_admits_a_hyphenated_id_without_storage_path() ->
    Id =
        <<"lc_db-",
            (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    {ok, SupPid} = bondy_oplog:start_instance(Id),
    ?assert(is_pid(SupPid)),
    WalDir = unicode:characters_to_binary(
        filename:join(["/tmp", "bondy_oplog_wal", os:getpid(), Id])
    ),
    ?assert(filelib:is_dir(WalDir)),
    ok = bondy_oplog:stop_instance(Id),
    ?assertEqual({error, not_found}, bondy_oplog:stop_instance(Id)).

%% An instance whose registry row is gone while its subtree still runs (a
%% consumer teardown that failed mid-close) must remain STOPPABLE.
%%
%% The registry is the source of truth for enumeration: `list_instances/0`
%% reads it, so a row-less instance is invisible to it and to every
%% scheduler that drives work from it — which is what keeps a zombie from
%% receiving gc/sync dispatches for the VM's lifetime. Being invisible must
%% not mean being unkillable, so `stop_instance/1` falls back to resolving
%% the subtree by instance id directly
%% (`bondy_oplog_instance_dyn_sup:find_child_by_instance_id/1`).
stop_survives_missing_registry_row() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    ?assert(lists:member(Id, bondy_oplog:list_instances())),

    %% Mint the zombie: drop the row, keep the subtree.
    ok = bondy_oplog_registry:unregister(Id),
    ?assertEqual(undefined, bondy_oplog_registry:sup_pid(Id)),
    ?assertNot(lists:member(Id, bondy_oplog:list_instances())),

    %% Invisible, but still killable through the supervisor fallback.
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

wait_until(_F, T) when T =< 0 -> error(timeout);
wait_until(F, T) ->
    case F() of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_until(F, T - 20)
    end.
