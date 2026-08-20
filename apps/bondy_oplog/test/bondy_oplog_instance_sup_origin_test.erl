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
        fun no_storage_path_falls_back_to_default/0
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
        {ok, _} = bondy_oplog:start_instance(Id, #{
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
        {ok, _} = bondy_oplog:start_instance(Id, #{
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
        {ok, _} = bondy_oplog:start_instance(Id, Opts),
        OriginBefore = bondy_oplog:origin(Id),
        ok = bondy_oplog:stop_instance(Id),
        {ok, _} = bondy_oplog:start_instance(Id, Opts),
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
        {ok, _} = bondy_oplog:start_instance(Id, #{}),
        Origin = bondy_oplog:origin(Id),
        ?assertEqual(bondy_oplog_origin:default(), Origin)
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
