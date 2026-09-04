%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% A `bondy_oplog_compaction_checkpoint` backend for tests: the file backend,
%% plus a record of what the instance's WAL reported as its snapshot
%% watermark at the moment each checkpoint was written. That is the
%% observable for the durability ORDER compaction must keep — checkpoint
%% durable first, WAL watermark advanced second — which has no consequence
%% a black-box test can reach (the WAL's head segment always retains the
%% latest own append, so the counter seed survives either order) and is
%% therefore pinned by observation.
%% =============================================================================
-module(bondy_oplog_test_observing_checkpoint).

-behaviour(bondy_oplog_compaction_checkpoint).

-export([init/2]).
-export([put_checkpoint/3]).
-export([get_checkpoint/1]).
-export([current_watermark/1]).
-export([close/1]).
-export([observations/1]).

-record(state, {
    instance_id :: binary(),
    inner :: term(),
    tab :: ets:tid()
}).

init(InstanceId, Opts) ->
    {ok, Inner} = bondy_oplog_compaction_checkpoint_file:init(InstanceId, Opts),
    Tab = maps:get(observations, Opts),
    {ok, #state{instance_id = InstanceId, inner = Inner, tab = Tab}}.

%% Records `{Watermark, WalSnapshotWatermark}` BEFORE delegating, so the
%% observation is what the WAL believed when the checkpoint write began.
put_checkpoint(#state{} = S, Watermark, Checkpoint) ->
    Seen =
        case bondy_oplog_registry:wal_pid(S#state.instance_id) of
            undefined ->
                no_wal;
            Pid ->
                maps:get(snapshot_watermark, bondy_oplog_wal:info(Pid))
        end,
    true = ets:insert(S#state.tab, {
        erlang:unique_integer([monotonic]), Watermark, Seen
    }),
    bondy_oplog_compaction_checkpoint_file:put_checkpoint(
        S#state.inner, Watermark, Checkpoint
    ).

get_checkpoint(#state{inner = Inner}) ->
    bondy_oplog_compaction_checkpoint_file:get_checkpoint(Inner).

current_watermark(#state{inner = Inner}) ->
    bondy_oplog_compaction_checkpoint_file:current_watermark(Inner).

close(#state{inner = Inner}) ->
    bondy_oplog_compaction_checkpoint_file:close(Inner).

%% `[{Watermark, WalSnapshotWatermarkAtWrite}]`, oldest first (`Tab` is an
%% `ordered_set` keyed on a monotonic integer).
observations(Tab) ->
    ets:select(Tab, [{{'_', '$1', '$2'}, [], [{{'$1', '$2'}}]}]).
