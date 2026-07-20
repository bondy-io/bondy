%% =============================================================================
%% Unit tests for the T2 topology (`bondy_db_topology_per_entity`).
%%
%% Verified in isolation against the topology behaviour — no `bondy_db`
%% facade. Tests focus on routing semantics, shard provisioning, and
%% teardown.
%% =============================================================================

-module(bondy_db_topology_per_entity_test).

-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_db_topology_per_entity).

%% =============================================================================
%% Test list
%% =============================================================================

topology_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun init_with_valid_opts/1,
        fun init_rejects_missing_sup/1,
        fun init_rejects_missing_dir/1,
        fun open_table_starts_one_bookie_per_shard/1,
        fun open_table_distinct_entities_get_distinct_bookies/1,
        fun route_returns_adapter_and_handle/1,
        fun route_distinct_shards_get_distinct_bookies/1,
        fun route_same_shard_returns_stable_handle/1,
        fun route_unknown_shard_returns_error/1,
        fun close_table_stops_bookies/1,
        fun shutdown_stops_supervisor_and_children/1,
        fun end_to_end_put_get_through_topology/1
    ]}.

%% =============================================================================
%% Setup / teardown
%% =============================================================================

setup() ->
    %% Trap exits so the supervisor's `shutdown` exit signal (delivered
    %% via the start_link/0 link in cleanup) does not also kill the
    %% per-test process.
    process_flag(trap_exit, true),
    Dir = make_tempdir(),
    {ok, Sup} = bondy_db_leveled_sup:start_link(),
    {Sup, Dir}.

cleanup({Sup, Dir}) ->
    case is_process_alive(Sup) of
        true -> bondy_db_leveled_sup:stop(Sup);
        false -> ok
    end,
    rmrf(Dir),
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

init_with_valid_opts({Sup, Dir}) ->
    fun() ->
        ?assertMatch(
            {ok, #{db_name := my_db, sup := Sup, dir := _}},
            ?MOD:init(my_db, #{sup => Sup, dir => Dir})
        )
    end.

init_rejects_missing_sup({_Sup, Dir}) ->
    fun() ->
        ?assertMatch(
            {error, {missing_required_opt, sup}},
            ?MOD:init(my_db, #{dir => Dir})
        )
    end.

init_rejects_missing_dir({Sup, _Dir}) ->
    fun() ->
        ?assertMatch(
            {error, {missing_required_opt, dir}},
            ?MOD:init(my_db, #{sup => Sup})
        )
    end.

open_table_starts_one_bookie_per_shard({Sup, Dir}) ->
    fun() ->
        {ok, S0} = ?MOD:init(my_db, #{sup => Sup, dir => Dir}),
        {ok, T, _S1} = ?MOD:open_table(users, 4, #{}, S0),
        #{shards := Shards, shard_count := 4} = T,
        ?assertEqual(4, map_size(Shards)),
        ?assert(
            lists:all(
                fun(P) -> is_pid(P) andalso is_process_alive(P) end,
                maps:values(Shards)
            )
        ),
        %% Each shard's pid is distinct — there should be no aliasing.
        Pids = maps:values(Shards),
        ?assertEqual(length(Pids), sets:size(sets:from_list(Pids)))
    end.

open_table_distinct_entities_get_distinct_bookies({Sup, Dir}) ->
    fun() ->
        {ok, S0} = ?MOD:init(my_db, #{sup => Sup, dir => Dir}),
        {ok, Users, _S1} = ?MOD:open_table(users, 2, #{}, S0),
        {ok, Tokens, _S2} = ?MOD:open_table(tokens, 2, #{}, S0),
        UPids = maps:values(maps:get(shards, Users)),
        TPids = maps:values(maps:get(shards, Tokens)),
        Common = sets:intersection(
            sets:from_list(UPids), sets:from_list(TPids)
        ),
        ?assertEqual(0, sets:size(Common))
    end.

route_returns_adapter_and_handle({Sup, Dir}) ->
    fun() ->
        {ok, S0} = ?MOD:init(my_db, #{sup => Sup, dir => Dir}),
        {ok, T, _} = ?MOD:open_table(users, 4, #{}, S0),
        {ok, Adapter, Handle} = ?MOD:route(0, T),
        ?assertEqual(bondy_db_projection_leveled, Adapter),
        %% Bucket is per-call (supplied via `bucket_for/3`), so the
        %% handle just carries the Bookie pid.
        ?assertMatch(#{bookie := _}, Handle),
        ?assertNot(maps:is_key(bucket, Handle))
    end.

route_distinct_shards_get_distinct_bookies({Sup, Dir}) ->
    fun() ->
        {ok, S0} = ?MOD:init(my_db, #{sup => Sup, dir => Dir}),
        {ok, T, _} = ?MOD:open_table(users, 4, #{}, S0),
        {ok, _, #{bookie := B0}} = ?MOD:route(0, T),
        {ok, _, #{bookie := B1}} = ?MOD:route(1, T),
        ?assertNotEqual(B0, B1)
    end.

route_same_shard_returns_stable_handle({Sup, Dir}) ->
    fun() ->
        {ok, S0} = ?MOD:init(my_db, #{sup => Sup, dir => Dir}),
        {ok, T, _} = ?MOD:open_table(users, 4, #{}, S0),
        {ok, A0, H0} = ?MOD:route(0, T),
        {ok, A1, H1} = ?MOD:route(0, T),
        ?assertEqual(A0, A1),
        ?assertEqual(H0, H1)
    end.

route_unknown_shard_returns_error({Sup, Dir}) ->
    fun() ->
        {ok, S0} = ?MOD:init(my_db, #{sup => Sup, dir => Dir}),
        {ok, T, _} = ?MOD:open_table(users, 4, #{}, S0),
        ?assertMatch(
            {error, {unknown_shard, 99}},
            ?MOD:route(99, T)
        )
    end.

close_table_stops_bookies({Sup, Dir}) ->
    fun() ->
        {ok, S0} = ?MOD:init(my_db, #{sup => Sup, dir => Dir}),
        {ok, T, _} = ?MOD:open_table(users, 2, #{}, S0),
        Pids = maps:values(maps:get(shards, T)),
        ?assert(lists:all(fun is_process_alive/1, Pids)),
        {ok, _} = ?MOD:close_table(T, S0),
        %% Allow leveled's `terminate/2` to run.
        wait_until_dead(Pids, 5_000)
    end.

shutdown_stops_supervisor_and_children({Sup, Dir}) ->
    fun() ->
        {ok, S0} = ?MOD:init(my_db, #{sup => Sup, dir => Dir}),
        {ok, T, _} = ?MOD:open_table(users, 2, #{}, S0),
        Pids = maps:values(maps:get(shards, T)),
        ok = ?MOD:shutdown(S0),
        %% Both the supervisor and every child must be dead.
        ?assertNot(is_process_alive(Sup)),
        wait_until_dead(Pids, 5_000)
    end.

end_to_end_put_get_through_topology({Sup, Dir}) ->
    fun() ->
        {ok, S0} = ?MOD:init(my_db, #{sup => Sup, dir => Dir}),
        {ok, T, _} = ?MOD:open_table(users, 4, #{}, S0),
        {ok, Adapter, Handle} = ?MOD:route(0, T),
        %% Per-entity: `bucket_for/3` returns the realm verbatim; the
        %% facade folds the realm into the bucket and uses a bare cell
        %% key. Drive the adapter with two distinct buckets (one per
        %% realm) at the same key to exercise that path.
        F1 = mk_frame(<<"f1">>),
        F2 = mk_frame(<<"f2">>),
        ok = Adapter:put_batch(Handle, [
            {<<"realm-1">>, <<"alice">>, F1},
            {<<"realm-2">>, <<"alice">>, F2}
        ]),
        ?assertEqual(
            {ok, F1},
            Adapter:get(Handle, <<"realm-1">>, <<"alice">>)
        ),
        ?assertEqual(
            {ok, F2},
            Adapter:get(Handle, <<"realm-2">>, <<"alice">>)
        )
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

make_tempdir() ->
    Base = filename:join([
        "/tmp",
        "bondy_db_per_entity_test",
        integer_to_list(erlang:unique_integer([positive, monotonic]))
    ]),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.

mk_frame(Bytes) when is_binary(Bytes) ->
    %% Wrap raw bytes in the minimal V2 cell-frame shape so the leveled
    %% tag extractor accepts the object.
    bondy_oplog_cell_frame:encode(0, Bytes, Bytes, false).

rmrf(Dir) ->
    case file:del_dir_r(Dir) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, _} -> ok
    end.

wait_until_dead([], _Deadline) ->
    ok;
wait_until_dead([Pid | Rest], Deadline) when Deadline > 0 ->
    case is_process_alive(Pid) of
        false ->
            wait_until_dead(Rest, Deadline);
        true ->
            timer:sleep(50),
            wait_until_dead([Pid | Rest], Deadline - 50)
    end;
wait_until_dead([Pid | _], _) ->
    error({still_alive, Pid}).
