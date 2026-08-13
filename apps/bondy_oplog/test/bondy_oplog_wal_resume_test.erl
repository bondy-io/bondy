%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Reproduction for the WAL-drain resume coupling.
%%
%% The applier positions its WAL reader from `resume_position/2`, which is
%% derived from the MST's last key (`bondy_oplog_instance:mst_last/1`) — i.e. the
%% log consumer asks a DOWNSTREAM projection where to resume reading its own log.
%% The WAL already persists the authoritative cursor for this (`consumer.offset`)
%% but it is used only to seed the commit accumulator, never for positioning.
%%
%% These tests pin two facts, independent of WHY `mst_last` might be stale:
%%
%%   1. After a full drain, the durable consumer offset sits AT the WAL head:
%%      opening a reader there yields end_of_log immediately (0 frames). The
%%      consumer offset is the correct, O(1) resume cursor.
%%
%%   2. When the MST root does not reflect the applied data — `mst_last`
%%      undefined/stale, which the instance's own `terminate/2` comment
%%      documents can happen ("resume falls back to `beginning` ... and the WAL
%%      would never truncate") — `resume_position/2` regresses to `beginning`
%%      and the SAME fully-drained WAL is re-read end-to-end on every drain.
%%      That re-read, re-armed continuously, is the livelock.
%%
%% A third test exercises the faithful path (durable async-seal instance,
%% append + drain + stop + restart) and asserts the architectural invariant that
%% must hold: `mst_last` still reflects the data and resume does not regress.
%%
%% Harness mirrors `bondy_oplog_instance_async_seal_test`.
%% =============================================================================

-module(bondy_oplog_wal_resume_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).
-define(N, 500).
-define(SEAL_EVERY, 50).

%% =============================================================================
%% TESTS
%% =============================================================================

%% PROOF 1 — the consumer offset is an O(1) resume cursor.
offset_is_o1_resume_cursor_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Dir) ->
        {timeout, 60, fun() -> run_offset_o1(Dir) end}
    end}.

%% PROOF 2 — MST-derived resume re-reads the whole WAL when the root is stale.
mst_resume_rereads_whole_wal_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Dir) ->
        {timeout, 60, fun() -> run_mst_reread(Dir) end}
    end}.

%% FAITHFUL — durable async instance must keep `mst_last` across a restart.
durable_async_mst_last_survives_restart_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Dir) ->
        {timeout, 60, fun() -> run_restart(Dir) end}
    end}.

%% =============================================================================
%% TEST BODIES
%% =============================================================================

run_offset_o1(Dir) ->
    {InstId, NS, _Origin, C, P} = boot(Dir),
    append_batch(InstId, 1, ?N),
    ok = bondy_oplog_instance:await_apply(InstId),
    ?assertEqual(?N, bondy_oplog:size(InstId)),

    WalP = bondy_oplog_registry:wal_pid(InstId),
    {Seg, Off} = consumer_offset_pos(WalP),
    FromOffset = frames_to_eol(WalP, {offset, Seg, Off}),
    ?debugFmt(
        "consumer offset = {seg=~p, off=~p}; frames-from-offset to eol = ~p",
        [Seg, Off, FromOffset]
    ),
    %% The offset is AT the head: a re-armed drain from here does no work.
    ?assertEqual(
        0,
        FromOffset,
        "consumer offset is not at the WAL head after a full drain"
    ),
    teardown(InstId, NS, C, P).

run_mst_reread(Dir) ->
    {InstId, NS, _Origin, C, P} = boot(Dir),
    append_batch(InstId, 1, ?N),
    ok = bondy_oplog_instance:await_apply(InstId),

    WalP = bondy_oplog_registry:wal_pid(InstId),

    %% (a) From the durable consumer offset: O(1) — already at the head.
    {Seg, Off} = consumer_offset_pos(WalP),
    FromOffset = frames_to_eol(WalP, {offset, Seg, Off}),

    %% (b) From an MST-derived resume whose root is stale/undefined. This is
    %% exactly `resume_position(undefined, undefined)` — the value the applier
    %% computes when `mst_last/1` returns `undefined`.
    StaleResume = bondy_oplog_applier:resume_position(undefined, undefined),
    ?assertEqual(beginning, StaleResume),
    FromStaleMst = frames_to_eol(WalP, StaleResume),

    TotalFrames = frames_to_eol(WalP, beginning),
    ?debugFmt(
        "frames-from-offset = ~p | frames-from-stale-mst = ~p | "
        "total frames in WAL = ~p",
        [FromOffset, FromStaleMst, TotalFrames]
    ),

    %% The coupling: offset-resume does nothing; mst-resume re-reads everything.
    ?assertEqual(0, FromOffset),
    ?assert(TotalFrames > 0),
    ?assertEqual(
        TotalFrames,
        FromStaleMst,
        "stale-MST resume must re-read the entire WAL (the livelock)"
    ),
    teardown(InstId, NS, C, P).

run_restart(Dir) ->
    {InstId, NS, Origin, C, P} = boot(Dir),
    append_batch(InstId, 1, ?N),
    ok = bondy_oplog_instance:await_apply(InstId),

    %% Pre-stop: the MST reflects the data and the offset is at the head.
    ML0 = bondy_oplog_instance:mst_last(InstId),
    ?assertNotEqual(undefined, ML0),
    WalP0 = bondy_oplog_registry:wal_pid(InstId),
    {S0, O0} = consumer_offset_pos(WalP0),
    ?assertEqual(0, frames_to_eol(WalP0, {offset, S0, O0})),

    %% Clean stop + restart (durable close must preserve the tree).
    ok = bondy_oplog:stop_instance(InstId),
    {ok, _} = open_async_instance(InstId, NS, Dir, Origin, ?SEAL_EVERY),
    ok = bondy_oplog:await_drain(InstId),
    ?assertEqual(?N, bondy_oplog:size(InstId)),

    %% Post-restart: the architectural invariant that MUST hold.
    ML1 = bondy_oplog_instance:mst_last(InstId),
    WalP1 = bondy_oplog_registry:wal_pid(InstId),
    {S1, O1} = consumer_offset_pos(WalP1),
    FromOffset1 = frames_to_eol(WalP1, {offset, S1, O1}),
    ResumeNow = bondy_oplog_applier:resume_position(ML1, undefined),
    FromResume1 = frames_to_eol(WalP1, ResumeNow),
    ?debugFmt(
        "post-restart: mst_last=~p resume=~p | frames-from-offset=~p "
        "frames-from-resume=~p",
        [ML1, ResumeNow, FromOffset1, FromResume1]
    ),

    %% A clean stop+restart preserves the durable root (close-not-destroy), so
    %% `mst_last` is NOT undefined here — clean restart is not the livelock
    %% trigger. The live `mst_last = undefined` comes from a root left stale
    %% under load, which PROOF 2 reproduces in isolation.
    ?assertNotEqual(
        undefined,
        ML1,
        "durable MST root did not survive a clean restart"
    ),
    %% The fix cursor is ALWAYS O(1): resuming from the consumer offset does no
    %% work, regardless of the MST.
    ?assertEqual(
        0,
        FromOffset1,
        "consumer offset is not at the WAL head after restart"
    ),
    %% Even with a HEALTHY root, MST-derived resume re-reads the boundary frame
    %% (the seek lands on the first frame `>= last-applied HLC`, inclusive). It
    %% is 1 here; it becomes `total frames` the instant the root goes stale.
    ?assert(
        FromResume1 >= 1,
        "MST-derived resume re-reads at least the boundary frame"
    ),
    teardown(InstId, NS, C, P).

%% =============================================================================
%% RESUME-CURSOR HELPERS
%% =============================================================================

consumer_offset_pos(WalP) ->
    View = bondy_oplog_wal:reader_view(WalP),
    Dir = maps:get(dir, View),
    {ok, CO} = bondy_oplog_wal_state:read_consumer_offset(Dir),
    {
        bondy_oplog_wal_state:committed_segment(CO),
        bondy_oplog_wal_state:committed_frame_offset(CO)
    }.

frames_to_eol(WalP, Start) ->
    case bondy_oplog_wal_reader:open(WalP, Start, [{follow, false}]) of
        {ok, It} ->
            N = count_frames(It, 0),
            _ = bondy_oplog_wal_reader:close(It),
            N;
        {error, R} ->
            error({open_failed, Start, R})
    end.

count_frames(It, Acc) ->
    case bondy_oplog_wal_reader:next(It) of
        {ok, _Batch, _Hlcs, _NextPos, NewIt} ->
            count_frames(NewIt, Acc + 1);
        end_of_log ->
            Acc;
        {error, R} ->
            error({reader_error, R})
    end.

%% =============================================================================
%% HARNESS (mirrored from bondy_oplog_instance_async_seal_test)
%% =============================================================================

boot(Dir) ->
    InstId = mk_id(),
    NS = ns_of(InstId),
    Origin = bondy_oplog_origin:new(),
    {C, P} = register_shard(NS),
    {ok, _} = open_async_instance(InstId, NS, Dir, Origin, ?SEAL_EVERY),
    {InstId, NS, Origin, C, P}.

teardown(InstId, NS, C, P) ->
    ok = bondy_oplog:stop_instance(InstId),
    close_shard(C, P),
    ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
    ok.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    Dir = filename:join(
        "/tmp/" ++ os:getpid(),
        "walresume_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

cleanup(Dir) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    _ = (catch del_tree(Dir)),
    ok.

mk_id() ->
    list_to_binary(
        "walresume_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

ns_of(Id) when is_binary(Id) ->
    binary_to_atom(<<"ns_", Id/binary>>, utf8).

register_shard(NS) ->
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
    ok = bondy_oplog_core_registry:register(NS, primary, 0, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        fold_module => lww_register,
        overlay => disabled
    }),
    {Cache, Proj}.

close_shard(Cache, Proj) ->
    ok = bondy_oplog_projection_ets:close(Proj),
    ok = bondy_oplog_cache_ets:close(Cache).

open_async_instance(InstanceId, NS, Dir, Origin, SealEvery) ->
    bondy_oplog:start_instance(InstanceId, #{
        origin => Origin,
        fold_module => lww_register,
        backend => bondy_mst_pack_store,
        storage_path => unicode:characters_to_binary(Dir),
        backend_options => #{
            auto_seal_records => SealEvery,
            seal_mode => async
        },
        seed => true,
        applier => #{cell_apply_target => {NS, primary, 0}}
    }).

append_batch(InstanceId, I, Batch) ->
    lists:foreach(
        fun(J) ->
            Key = key(I, J),
            Hlc = I * 1000 + J,
            _ = bondy_oplog:append(
                InstanceId, {cell_apply, ?B, Key, {set, Hlc, Key}}
            ),
            _ = bondy_oplog:projection(InstanceId)
        end,
        lists:seq(1, Batch)
    ).

key(I, J) ->
    <<"k_", (integer_to_binary(I))/binary, "_", (integer_to_binary(J))/binary>>.

del_tree(Dir) ->
    case filelib:is_dir(Dir) of
        true ->
            {ok, Names} = file:list_dir(Dir),
            [del_tree(filename:join(Dir, N)) || N <- Names],
            file:del_dir(Dir);
        false ->
            file:delete(Dir)
    end.
