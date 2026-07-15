%% Integration tests for the bootstrap-lifecycle gate (PR-1 /
%% catalogue expansion plan §2).
%%
%% Exercises the applier gate against a persistent instance: events
%% appended while `pre_bootstrap` must NOT be installed into the MST
%% by the applier; once `mark_live/1` flips the lifecycle, the
%% backlogged events drain.

-module(bondy_oplog_bootstrap_lifecycle_e2e_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup(_) ->
    _ = [
        bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    ok.

lifecycle_gate_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 30, fun applier_gated_in_pre_bootstrap/0},
        {timeout, 30, fun mark_live_drains_backlog/0},
        {timeout, 30, fun ephemeral_default_live_drains_normally/0},
        {timeout, 30, fun ephemeral_seed_false_gates/0},
        {timeout, 30, fun seed_true_starts_live/0}
    ]}.

%% A persistent instance opened without `seed: true` starts in
%% `pre_bootstrap`. Events appended to it land in the WAL+overlay,
%% but `await_apply` (which signals when the applier has drained the
%% overlay onto the MST) times out — the applier is gated.
applier_gated_in_pre_bootstrap() ->
    Tmp = mk_tmp_dir(),
    Id = mk_id(),
    try
        Opts = persistent_opts(Tmp),
        {ok, _} = bondy_oplog:start_instance(Id, Opts),
        ?assertEqual(pre_bootstrap, lifecycle_state(Id)),

        [bondy_oplog:append(Id, {inc, 1}) || _ <- lists:seq(1, 5)],

        %% `await_apply` blocks until the overlay drains. While gated
        %% the applier issues no `install_local_batch` casts so the
        %% overlay stays non-empty and the wait times out.
        ?assertEqual(
            {error, timeout},
            bondy_oplog:await_apply(Id, 200),
            "applier MUST NOT drain while pre_bootstrap"
        ),

        %% The MST itself must still be empty (no live events
        %% promoted). Use the instance API to bypass the auto-await in
        %% bondy_oplog:root_hash/1.
        ?assertEqual(undefined, bondy_oplog_instance:root_hash(Id))
    after
        _ = bondy_oplog:stop_instance(Id),
        rm_rf(Tmp)
    end.

%% Same scenario, then `mark_live/1` flips the lifecycle and the
%% applier drains the backlog.
mark_live_drains_backlog() ->
    Tmp = mk_tmp_dir(),
    Id = mk_id(),
    try
        Opts = persistent_opts(Tmp),
        {ok, _} = bondy_oplog:start_instance(Id, Opts),
        ?assertEqual(pre_bootstrap, lifecycle_state(Id)),

        N = 7,
        [bondy_oplog:append(Id, {inc, 1}) || _ <- lists:seq(1, N)],

        %% Gated.
        ?assertEqual(
            {error, timeout}, bondy_oplog:await_apply(Id, 200)
        ),

        ok = bondy_oplog_instance:mark_live(Id),
        ok = bondy_oplog:await_apply(Id),

        ?assertEqual(live, lifecycle_state(Id)),
        ?assertEqual(N, bondy_oplog:size(Id)),
        %% MST is now non-empty.
        ?assertNotEqual(undefined, bondy_oplog_instance:root_hash(Id))
    after
        _ = bondy_oplog:stop_instance(Id),
        rm_rf(Tmp)
    end.

%% An ephemeral instance (no `storage_path`) defaults to `live` and
%% the applier drains normally — proves the gate is a no-op for
%% in-memory tests that haven't been migrated to `seed: true`.
ephemeral_default_live_drains_normally() ->
    Id = mk_id(),
    try
        {ok, _} = bondy_oplog:start_instance(Id, ephemeral_opts()),
        ?assertEqual(live, lifecycle_state(Id)),
        [bondy_oplog:append(Id, {inc, 1}) || _ <- lists:seq(1, 4)],
        ok = bondy_oplog:await_apply(Id),
        ?assertEqual(4, bondy_oplog:size(Id))
    after
        _ = bondy_oplog:stop_instance(Id)
    end.

%% Forcing `seed: false` on an ephemeral instance still gates the
%% applier — the policy follows the explicit opt, not the persistence
%% mode.
ephemeral_seed_false_gates() ->
    Id = mk_id(),
    try
        Opts = (ephemeral_opts())#{seed => false},
        {ok, _} = bondy_oplog:start_instance(Id, Opts),
        ?assertEqual(pre_bootstrap, lifecycle_state(Id)),
        [bondy_oplog:append(Id, {inc, 1}) || _ <- lists:seq(1, 3)],
        ?assertEqual(
            {error, timeout}, bondy_oplog:await_apply(Id, 200)
        ),

        ok = bondy_oplog_instance:mark_live(Id),
        ok = bondy_oplog:await_apply(Id),
        ?assertEqual(3, bondy_oplog:size(Id))
    after
        _ = bondy_oplog:stop_instance(Id)
    end.

%% A persistent instance opened with `seed: true` starts directly in
%% `live`. The applier drains and the flag file is created so the
%% next restart (not exercised here) would see `live` again.
seed_true_starts_live() ->
    Tmp = mk_tmp_dir(),
    Id = mk_id(),
    try
        Opts = (persistent_opts(Tmp))#{seed => true},
        {ok, _} = bondy_oplog:start_instance(Id, Opts),
        ?assertEqual(live, lifecycle_state(Id)),
        [bondy_oplog:append(Id, {inc, 1}) || _ <- lists:seq(1, 2)],
        ok = bondy_oplog:await_apply(Id),
        ?assertEqual(2, bondy_oplog:size(Id)),
        %% Flag file materialised.
        FlagPath = filename:join([
            bondy_oplog_path:storage_path(Id, Tmp, sharded),
            "lifecycle.live"
        ]),
        ?assert(filelib:is_regular(FlagPath))
    after
        _ = bondy_oplog:stop_instance(Id),
        rm_rf(Tmp)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

mk_id() ->
    list_to_binary(
        "blc_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

ephemeral_opts() ->
    #{
        crdt_module => bondy_oplog_test_counter,
        origin => bondy_oplog_origin:new()
    }.

persistent_opts(BaseDir) ->
    #{
        crdt_module => bondy_oplog_test_counter,
        origin => bondy_oplog_origin:new(),
        storage_path => BaseDir
    }.

lifecycle_state(Id) ->
    bondy_oplog_instance:lifecycle_state(Id).

mk_tmp_dir() ->
    Base = filename:join(
        ["/tmp", "bondy_mst_lifecycle_e2e", os:getpid()]
    ),
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    Dir = filename:join(Base, Suffix),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    unicode:characters_to_binary(Dir).

rm_rf(Dir0) ->
    Dir = unicode:characters_to_list(Dir0),
    case filelib:is_dir(Dir) of
        true ->
            {ok, Entries} = file:list_dir(Dir),
            lists:foreach(
                fun(E) ->
                    P = filename:join(Dir, E),
                    case filelib:is_dir(P) of
                        true -> rm_rf(P);
                        false -> file:delete(P)
                    end
                end,
                Entries
            ),
            file:del_dir(Dir);
        false ->
            ok
    end.
