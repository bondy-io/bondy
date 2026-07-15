%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_compaction_checkpoint_ets).
-behaviour(bondy_oplog_compaction_checkpoint).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
In-memory compaction checkpoint backed by a per-instance ETS table.

Suitable for tests and ephemeral instances where rebuild cost on
restart is acceptable. For durable single-node deployments, use
`bondy_oplog_compaction_checkpoint_file`. For other durability
characteristics, implement the
`bondy_oplog_compaction_checkpoint` behaviour directly.
""").

-record(state, {
    instance_id :: instance_id(),
    tab :: ets:tid()
}).

-export([init/2]).
-export([put_checkpoint/3]).
-export([get_checkpoint/1]).
-export([current_watermark/1]).
-export([close/1]).

%% =============================================================================
%% bondy_oplog_compaction_checkpoint CALLBACKS
%% =============================================================================

init(InstanceId, _Opts) when is_binary(InstanceId) ->
    Tab = ets:new(undefined, [
        set, public, {read_concurrency, true}
    ]),
    {ok, #state{instance_id = InstanceId, tab = Tab}}.

put_checkpoint(#state{tab = Tab}, Watermark, Checkpoint) ->
    %% Single-row policy: overwrite any prior checkpoint.
    true = ets:insert(Tab, {checkpoint, Watermark, Checkpoint}),
    ok.

get_checkpoint(#state{tab = Tab}) ->
    case ets:lookup(Tab, checkpoint) of
        [{checkpoint, W, S}] -> {ok, W, S};
        [] -> not_found
    end.

current_watermark(#state{tab = Tab}) ->
    case ets:lookup(Tab, checkpoint) of
        [{checkpoint, W, _}] -> W;
        [] -> undefined
    end.

close(#state{tab = Tab}) ->
    _ = catch ets:delete(Tab),
    ok.
