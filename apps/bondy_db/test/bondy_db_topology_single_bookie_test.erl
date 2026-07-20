%% =============================================================================
%% Unit tests for the single_bookie topology
%% (`bondy_db_topology_single_bookie`).
%%
%% Verified in isolation against the topology behaviour — no `bondy_db`
%% facade. Focuses on Bookie sharing, bucket composition, and the no-op
%% close_table contract.
%% =============================================================================

-module(bondy_db_topology_single_bookie_test).

-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_db_topology_single_bookie).

%% =============================================================================
%% Test list
%% =============================================================================

topology_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun init_with_valid_opts_starts_bookie/1,
        fun init_rejects_missing_sup/1,
        fun init_rejects_missing_dir/1,
        fun open_table_does_not_start_new_bookie/1,
        fun open_two_tables_share_one_bookie/1,
        fun route_returns_adapter_and_bookie_handle/1,
        fun bucket_for_composes_realm_and_entity/1,
        fun bucket_for_distinct_entities_distinct_buckets/1,
        fun close_table_is_a_noop/1,
        fun shutdown_stops_bookie_and_supervisor/1,
        fun end_to_end_put_get_through_topology/1,
        fun bucket_isolation_across_realms_via_key/1
    ]}.

%% =============================================================================
%% Setup / teardown
%% =============================================================================

setup() ->
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

init_with_valid_opts_starts_bookie({Sup, Dir}) ->
    fun() ->
        {ok, State} = ?MOD:init(my_db, #{sup => Sup, dir => Dir}),
        #{bookie := Bookie, sup := Sup, db_name := my_db} = State,
        ?assert(is_pid(Bookie)),
        ?assert(is_process_alive(Bookie))
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

open_table_does_not_start_new_bookie({Sup, Dir}) ->
    fun() ->
        {ok, S0} = ?MOD:init(my_db, #{sup => Sup, dir => Dir}),
        BookieBefore = maps:get(bookie, S0),
        {ok, T, _S1} = ?MOD:open_table(users, 8, #{}, S0),
        ?assertEqual(BookieBefore, maps:get(bookie, T))
    end.

open_two_tables_share_one_bookie({Sup, Dir}) ->
    fun() ->
        {ok, S0} = ?MOD:init(my_db, #{sup => Sup, dir => Dir}),
        {ok, T1, _} = ?MOD:open_table(users, 8, #{}, S0),
        {ok, T2, _} = ?MOD:open_table(tokens, 8, #{}, S0),
        ?assertEqual(maps:get(bookie, T1), maps:get(bookie, T2))
    end.

route_returns_adapter_and_bookie_handle({Sup, Dir}) ->
    fun() ->
        {ok, S0} = ?MOD:init(my_db, #{sup => Sup, dir => Dir}),
        {ok, T, _} = ?MOD:open_table(users, 8, #{}, S0),
        {ok, Adapter, Handle} = ?MOD:route(0, T),
        ?assertEqual(bondy_db_projection_leveled, Adapter),
        %% Bucket is supplied per-call via `bucket_for/3`; the handle
        %% just carries the shared Bookie.
        ?assertMatch(#{bookie := _}, Handle),
        ?assertNot(maps:is_key(bucket, Handle))
    end.

bucket_for_composes_realm_and_entity({Sup, Dir}) ->
    fun() ->
        {ok, S0} = ?MOD:init(my_db, #{sup => Sup, dir => Dir}),
        {ok, T, _} = ?MOD:open_table(users, 8, #{}, S0),
        %% Single Bookie holds every entity for every realm — the bucket
        %% must encode both. The contract here pins the composition format.
        ?assertEqual(
            <<"realm-1/users">>,
            ?MOD:bucket_for(users, <<"realm-1">>, T)
        )
    end.

bucket_for_distinct_entities_distinct_buckets({Sup, Dir}) ->
    fun() ->
        {ok, S0} = ?MOD:init(my_db, #{sup => Sup, dir => Dir}),
        {ok, Users, _} = ?MOD:open_table(users, 8, #{}, S0),
        {ok, Tokens, _} = ?MOD:open_table(tokens, 8, #{}, S0),
        UB = ?MOD:bucket_for(users, <<"realm-1">>, Users),
        TB = ?MOD:bucket_for(tokens, <<"realm-1">>, Tokens),
        ?assertNotEqual(UB, TB)
    end.

close_table_is_a_noop({Sup, Dir}) ->
    fun() ->
        {ok, S0} = ?MOD:init(my_db, #{sup => Sup, dir => Dir}),
        Bookie = maps:get(bookie, S0),
        {ok, T, _} = ?MOD:open_table(users, 8, #{}, S0),
        {ok, _} = ?MOD:close_table(T, S0),
        %% The shared Bookie must survive close_table.
        ?assert(is_process_alive(Bookie))
    end.

shutdown_stops_bookie_and_supervisor({Sup, Dir}) ->
    fun() ->
        {ok, S0} = ?MOD:init(my_db, #{sup => Sup, dir => Dir}),
        Bookie = maps:get(bookie, S0),
        ok = ?MOD:shutdown(S0),
        wait_until_dead([Sup, Bookie], 5_000)
    end.

end_to_end_put_get_through_topology({Sup, Dir}) ->
    fun() ->
        {ok, S0} = ?MOD:init(my_db, #{sup => Sup, dir => Dir}),
        {ok, T, _} = ?MOD:open_table(users, 8, #{}, S0),
        {ok, Adapter, Handle} = ?MOD:route(0, T),
        Bucket = ?MOD:bucket_for(users, <<"realm-1">>, T),
        F = mk_frame(<<"frame">>),
        ok = Adapter:put_batch(Handle, [{Bucket, <<"alice">>, F}]),
        ?assertEqual(
            {ok, F},
            Adapter:get(Handle, Bucket, <<"alice">>)
        )
    end.

bucket_isolation_across_realms_via_key({Sup, Dir}) ->
    fun() ->
        {ok, S0} = ?MOD:init(my_db, #{sup => Sup, dir => Dir}),
        {ok, T, _} = ?MOD:open_table(users, 8, #{}, S0),
        {ok, Adapter, Handle} = ?MOD:route(0, T),
        %% Realms are isolated at the Bucket level — `bucket_for/3`
        %% composes (Realm, EntityType) so distinct realms land in
        %% distinct buckets even with the same cell key.
        B1 = ?MOD:bucket_for(users, <<"realm-1">>, T),
        B2 = ?MOD:bucket_for(users, <<"realm-2">>, T),
        ?assertNotEqual(B1, B2),
        F1 = mk_frame(<<"v1">>),
        F2 = mk_frame(<<"v2">>),
        ok = Adapter:put_batch(Handle, [
            {B1, <<"alice">>, F1},
            {B2, <<"alice">>, F2}
        ]),
        ?assertEqual({ok, F1}, Adapter:get(Handle, B1, <<"alice">>)),
        ?assertEqual({ok, F2}, Adapter:get(Handle, B2, <<"alice">>))
    end.

mk_frame(Bytes) when is_binary(Bytes) ->
    bondy_oplog_cell_frame:encode(0, Bytes, Bytes, false).

%% =============================================================================
%% Helpers
%% =============================================================================

make_tempdir() ->
    Base = filename:join([
        "/tmp",
        "bondy_db_single_bookie_test",
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
