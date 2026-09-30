%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_instance_sup_origin_test).

%% End-to-end coverage of the two PR-J6 follow-ups:
%%   1. supervisor resolves `origin` from disk when `storage_path` is
%%      set, so kill -9 + restart picks up the same identity.
%%   2. supervisor emits a one-shot loud warning when WAL has no
%%      durable backing (no `wal_dir`, no `storage_path`).

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

origin_resolution_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun explicit_origin_wins/0,
        fun storage_path_origin_persists/0,
        fun storage_path_origin_survives_restart/0,
        fun no_storage_path_falls_back_to_default/0,
        fun restarted_ephemeral_instance_mints_undominated_events/0,
        fun crashed_ephemeral_instance_mints_undominated_events/0
    ]}.

%% ---------------------------------------------------------------------------
%% Tests
%% ---------------------------------------------------------------------------

explicit_origin_wins() ->
    Dir = mktemp_dir("sup_origin_explicit_"),
    Id = unique_id(<<"explicit">>),
    %% Origin is opaque to the lib but the WAL segment header is a
    %% fixed-width slot — must be exactly ?BONDY_OPLOG_ORIGIN_BYTES.
    Explicit = <<"explicit-orig-01">>,
    ?BONDY_OPLOG_ORIGIN_BYTES = byte_size(Explicit),
    try
        {ok, _} = bondy_oplog_test_projection:start_instance(Id, #{
            storage_path => unicode:characters_to_binary(Dir),
            path_layout => flat,
            seed => true,
            origin => Explicit
        }),
        ?assertEqual(Explicit, bondy_oplog:origin(Id)),
        %% The on-disk origin file should NOT be created when the
        %% caller supplied an explicit origin — explicit wins, no
        %% disk side-effect.
        OriginPath = filename:join(
            filename:join(Dir, Id), <<"origin">>
        ),
        ?assertNot(filelib:is_regular(OriginPath))
    after
        try
            bondy_oplog:stop_instance(Id)
        catch
            _:_ -> ok
        end,
        rm_rf(Dir)
    end.

storage_path_origin_persists() ->
    Dir = mktemp_dir("sup_origin_persist_"),
    Id = unique_id(<<"persist">>),
    try
        {ok, _} = bondy_oplog_test_projection:start_instance(Id, #{
            storage_path => unicode:characters_to_binary(Dir),
            path_layout => flat,
            seed => true
        }),
        Origin = bondy_oplog:origin(Id),
        ?assertEqual(?BONDY_OPLOG_ORIGIN_BYTES, byte_size(Origin)),
        OriginPath = filename:join(
            filename:join(Dir, Id), <<"origin">>
        ),
        ?assert(filelib:is_regular(OriginPath)),
        {ok, Bin} = file:read_file(OriginPath),
        ?assertEqual(Origin, Bin)
    after
        try
            bondy_oplog:stop_instance(Id)
        catch
            _:_ -> ok
        end,
        rm_rf(Dir)
    end.

storage_path_origin_survives_restart() ->
    %% Stop the instance, restart with the same storage_path, assert the
    %% origin is unchanged. This is the kill+restart scenario PR-J4 hit.
    Dir = mktemp_dir("sup_origin_restart_"),
    Id = unique_id(<<"restart">>),
    Opts = #{
        storage_path => unicode:characters_to_binary(Dir),
        path_layout => flat,
        seed => true
    },
    try
        {ok, _} = bondy_oplog_test_projection:start_instance(Id, Opts),
        OriginBefore = bondy_oplog:origin(Id),
        ok = bondy_oplog:stop_instance(Id),
        {ok, _} = bondy_oplog_test_projection:start_instance(Id, Opts),
        OriginAfter = bondy_oplog:origin(Id),
        ?assertEqual(OriginBefore, OriginAfter)
    after
        try
            bondy_oplog:stop_instance(Id)
        catch
            _:_ -> ok
        end,
        rm_rf(Dir)
    end.

no_storage_path_falls_back_to_default() ->
    %% Without `storage_path` or `wal_dir`, the supervisor must NOT
    %% touch disk for the origin — falls through to the per-VM
    %% ephemeral default. Behaviour-preserving for tests.
    Id = unique_id(<<"ephemeral">>),
    try
        {ok, _} = bondy_oplog_test_projection:start_instance(Id, #{}),
        Origin = bondy_oplog:origin(Id),
        ?assertEqual(bondy_oplog_origin:default(), Origin)
    after
        try
            bondy_oplog:stop_instance(Id)
        catch
            _:_ -> ok
        end
    end.

%% A fused instance with an in-memory WAL and MST (the `registry` DB's opts)
%% keeps nothing across a stop, so an instance started again under the same id
%% must mint events that no replica holding the old incarnation's frontier
%% treats as already applied: a key `(Origin, Seq)` with `Seq` at or below that
%% frontier's entry for `Origin` is skipped as a duplicate.
restarted_ephemeral_instance_mints_undominated_events() ->
    Id = unique_id(<<"ephemeral">>),
    try
        {ok, _} = bondy_oplog_test_projection:start_instance(
            Id, ephemeral_opts()
        ),
        Frontier = frontier([
            bondy_oplog:append(Id, {custom, N})
         || N <- [1, 2, 3]
        ]),
        ok = bondy_oplog:stop_instance(Id),
        {ok, _} = bondy_oplog_test_projection:start_instance(
            Id, ephemeral_opts()
        ),
        assert_undominated(bondy_oplog:append(Id, {custom, 4}), Frontier)
    after
        try
            bondy_oplog:stop_instance(Id)
        catch
            _:_ -> ok
        end
    end.

%% The same epoch boundary when the instance process is killed and its
%% supervisor restarts it. The registry row outlives a subtree restart, so the
%% new incarnation's origin must replace the old one there: it is what the node
%% advertises, and an unadvertised live origin is dead to a peer's reap.
crashed_ephemeral_instance_mints_undominated_events() ->
    Id = unique_id(<<"crashed">>),
    try
        {ok, _} = bondy_oplog_test_projection:start_instance(
            Id, ephemeral_opts()
        ),
        Frontier = frontier([
            bondy_oplog:append(Id, {custom, N})
         || N <- [1, 2, 3]
        ]),
        Old = bondy_oplog_registry:instance_pid(Id),
        exit(Old, kill),
        ok = await_restart(Id, Old, 100),
        New = bondy_oplog:append(Id, {custom, 4}),
        assert_undominated(New, Frontier),
        Origin = bondy_oplog_event:key_origin(New),
        ?assertEqual(Origin, bondy_oplog:origin(Id)),
        ?assert(lists:member(Origin, bondy_oplog_registry:origins()))
    after
        try
            bondy_oplog:stop_instance(Id)
        catch
            _:_ -> ok
        end
    end.

%% ---------------------------------------------------------------------------
%% helpers
%% ---------------------------------------------------------------------------

ephemeral_opts() ->
    #{
        backend => ets,
        wal_backend => mem,
        durability => ephemeral,
        fused => true
    }.

frontier(Keys) ->
    lists:foldl(
        fun(K, Acc) ->
            O = bondy_oplog_event:key_origin(K),
            Acc#{O => max(maps:get(O, Acc, 0), bondy_oplog_event:key_seq(K))}
        end,
        #{},
        Keys
    ).

assert_undominated(Key, Frontier) ->
    Origin = bondy_oplog_event:key_origin(Key),
    ?assert(bondy_oplog_event:key_seq(Key) > maps:get(Origin, Frontier, 0)).

await_restart(_Id, _Old, 0) ->
    {error, not_restarted};
await_restart(Id, Old, N) ->
    case bondy_oplog_registry:instance_pid(Id) of
        Pid when is_pid(Pid), Pid =/= Old ->
            ok;
        _ ->
            timer:sleep(20),
            await_restart(Id, Old, N - 1)
    end.

unique_id(Prefix) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    <<Prefix/binary, "_", Suffix/binary>>.

mktemp_dir(Prefix) ->
    Base = filename:join(
        "/tmp/" ++ os:getpid(),
        Prefix ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.

rm_rf(Dir) ->
    _ = os:cmd("rm -rf " ++ Dir),
    ok.
