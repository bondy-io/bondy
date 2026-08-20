%% =============================================================================
%% Stochastic churn test for `bondy_oplog_core_registry`.
%%
%% Runs random sequences of {register, unregister, kill_owner} operations
%% against a small pool of shard keys and owner processes. After every
%% step the registry's internal state must remain self-consistent:
%%
%%   - `mon_to_key` and `key_to_mon` are mutual inverses.
%%   - Every key in those maps has a matching ETS row.
%%   - No ETS row exists without a matching monitor entry.
%%
%% The test exercises the DOWN handler's interaction with explicit
%% unregister and with re-registration over the same shard key.
%% =============================================================================

-module(bondy_oplog_core_registry_churn_test).

-include_lib("eunit/include/eunit.hrl").

-define(STEPS, 200).
-define(NS_POOL, 4).
-define(OWNER_POOL, 3).

churn_test_() ->
    {timeout, 60, [
        {setup, fun setup/0, fun cleanup/1, [
            fun churn_invariants_hold/0
        ]}
    ]}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    %% Use a separate NS per pool slot to avoid colliding with other
    %% test modules running in the same suite.
    Suffix = integer_to_list(erlang:unique_integer([positive, monotonic])),
    Namespaces = [
        list_to_atom(
            "mst_db_churn_" ++ Suffix ++ "_" ++
                integer_to_list(N)
        )
     || N <- lists:seq(0, ?NS_POOL - 1)
    ],
    Namespaces.

cleanup(Namespaces) ->
    %% Clean any stragglers; the test loop should leave nothing, but
    %% be defensive in case a property regression leaks state.
    lists:foreach(
        fun(NS) ->
            try
                bondy_oplog_core_registry:unregister(NS, primary, 0)
            catch
                _:_ -> ok
            end
        end,
        Namespaces
    ),
    ok.

churn_invariants_hold() ->
    Namespaces = setup_namespaces(),
    Owners = [spawn_owner() || _ <- lists:seq(1, ?OWNER_POOL)],
    %% Seed the PRNG deterministically so failures are reproducible.
    _ = rand:seed(exsss, {1, 2, 3}),
    try
        run_steps(?STEPS, Namespaces, Owners)
    after
        [exit(P, kill) || P <- Owners],
        [
            try
                bondy_oplog_core_registry:unregister(NS, primary, 0)
            catch
                _:_ -> ok
            end
         || NS <- Namespaces
        ],
        %% Sync registry to absorb every pending DOWN before the next
        %% test starts.
        _ = sys:get_state(bondy_oplog_core_registry)
    end.

run_steps(0, _NSes, _Owners) ->
    ok;
run_steps(N, NSes, Owners) ->
    Action = pick_action(),
    NS = pick(NSes),
    Owner = pick(Owners),
    perform(Action, NS, Owner),
    %% Force the gen_server to drain any pending DOWN messages.
    _ = sys:get_state(bondy_oplog_core_registry),
    assert_invariants(),
    run_steps(N - 1, NSes, [revive_if_dead(O) || O <- Owners]).

pick_action() ->
    %% Weighted: register more often than unregister/kill so the table
    %% grows enough to exercise both DOWN and explicit removal paths.
    case rand:uniform(10) of
        N when N =< 5 -> register;
        N when N =< 8 -> unregister;
        _ -> kill_owner
    end.

pick(List) ->
    lists:nth(rand:uniform(length(List)), List).

perform(register, NS, Owner) when is_pid(Owner) ->
    case erlang:is_process_alive(Owner) of
        true ->
            Owner ! {register, NS, primary, 0, self()},
            receive
                {registered, NS} -> ok
            after 1_000 -> ok
            end;
        false ->
            ok
    end;
perform(unregister, NS, _Owner) ->
    ok = bondy_oplog_core_registry:unregister(NS, primary, 0);
perform(kill_owner, _NS, Owner) when is_pid(Owner) ->
    case erlang:is_process_alive(Owner) of
        true -> exit(Owner, kill);
        false -> ok
    end.

revive_if_dead(Pid) ->
    case erlang:is_process_alive(Pid) of
        true -> Pid;
        false -> spawn_owner()
    end.

spawn_owner() ->
    spawn(fun owner_loop/0).

owner_loop() ->
    receive
        {register, NS, Index, Shard, Reply} ->
            CHandle = make_ref(),
            PHandle = make_ref(),
            OV = bondy_oplog_db_overlay:new(),
            try
                ok = bondy_oplog_core_registry:register(NS, Index, Shard, #{
                    shard_count => 1,
                    cache_adapter => bondy_oplog_cache_counting,
                    cache_handle => CHandle,
                    projection_adapter => fake_projection,
                    projection_handle => PHandle,
                    overlay => OV,
                    fold_module => lww_register,
                    owner => self()
                }),
                Reply ! {registered, NS}
            catch
                _:_ ->
                    Reply ! {registered, NS}
            end,
            owner_loop();
        stop ->
            ok
    end.

setup_namespaces() ->
    Suffix = integer_to_list(erlang:unique_integer([positive, monotonic])),
    [
        list_to_atom(
            "mst_db_churn_step_" ++ Suffix ++ "_" ++
                integer_to_list(N)
        )
     || N <- lists:seq(0, ?NS_POOL - 1)
    ].

assert_invariants() ->
    %% Atomic snapshot: ETS rows and the two maps come from the same
    %% gen_server callback instant. An outside observer combining
    %% `sys:get_state/1` with `lookup/3` would race against DOWN
    %% handlers and unregister calls — the snapshot would say "Key is
    %% tracked" while the live ETS had already cleared the row.
    #{
        entries := Entries,
        mon_to_key := MonToKey,
        key_to_mon := KeyToMon
    } = bondy_oplog_core_registry:snapshot_for_invariants(),
    %% Map sizes must match.
    ?assertEqual(map_size(MonToKey), map_size(KeyToMon)),
    %% mon_to_key and key_to_mon are inverses.
    maps:foreach(
        fun(Mon, Key) ->
            ?assertEqual(Mon, maps:get(Key, KeyToMon))
        end,
        MonToKey
    ),
    maps:foreach(
        fun(Key, Mon) ->
            ?assertEqual(Key, maps:get(Mon, MonToKey))
        end,
        KeyToMon
    ),
    %% Every tracked key has a matching ETS row (atomic snapshot).
    EntryKeys = sets:from_list(
        [bondy_oplog_core_registry:entry_key(E) || E <- Entries]
    ),
    maps:foreach(
        fun(Key, _Mon) ->
            ?assert(sets:is_element(Key, EntryKeys))
        end,
        KeyToMon
    ),
    %% Every ETS row has a matching monitor entry.
    lists:foreach(
        fun(E) ->
            Key = bondy_oplog_core_registry:entry_key(E),
            ?assert(maps:is_key(Key, KeyToMon))
        end,
        Entries
    ).
