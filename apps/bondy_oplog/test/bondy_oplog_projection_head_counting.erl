%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Test-only projection adapter that wraps `bondy_oplog_projection_ets`
%% and counts `get/3` and `head/3` calls. Used by
%% `bondy_oplog_install_head_fastpath_test` to assert that the install
%% path uses the HEAD fast-path in `replace` mode and full GET in
%% `merge` mode.
%%
%% `head/3` is satisfied by `get/3 + extract_head/1` against the
%% inner ETS adapter — the counters distinguish *which* callback the
%% caller invoked, not whether the substrate has a native HEAD.
%% =============================================================================
-module(bondy_oplog_projection_head_counting).

-behaviour(bondy_oplog_projection_adapter).

-export([
    open/4,
    close/1,
    get/3,
    put_batch/2,
    range/5,
    delete/3,
    info/1,
    head/3
]).

-export([
    reset/0,
    get_count/0,
    head_count/0
]).

-define(TAB, ?MODULE).

%% =============================================================================
%% Counters
%% =============================================================================

ensure_table() ->
    case ets:info(?TAB) of
        undefined ->
            ets:new(?TAB, [named_table, public, set]),
            ets:insert(?TAB, [{get, 0}, {head, 0}]);
        _ ->
            ok
    end.

reset() ->
    ensure_table(),
    ets:insert(?TAB, [{get, 0}, {head, 0}]),
    ok.

get_count() ->
    ensure_table(),
    ets:lookup_element(?TAB, get, 2).

head_count() ->
    ensure_table(),
    ets:lookup_element(?TAB, head, 2).

%% =============================================================================
%% Adapter callbacks
%% =============================================================================

open(NS, Index, Shard, Opts) ->
    ensure_table(),
    bondy_oplog_projection_ets:open(NS, Index, Shard, Opts).

close(H) ->
    bondy_oplog_projection_ets:close(H).

get(H, Bucket, Key) ->
    ensure_table(),
    _ = ets:update_counter(?TAB, get, 1),
    bondy_oplog_projection_ets:get(H, Bucket, Key).

put_batch(H, Entries) ->
    bondy_oplog_projection_ets:put_batch(H, Entries).

range(H, Bucket, Low, High, Opts) ->
    bondy_oplog_projection_ets:range(H, Bucket, Low, High, Opts).

delete(H, Bucket, Key) ->
    bondy_oplog_projection_ets:delete(H, Bucket, Key).

info(H) ->
    bondy_oplog_projection_ets:info(H).

head(H, Bucket, Key) ->
    ensure_table(),
    _ = ets:update_counter(?TAB, head, 1),
    case bondy_oplog_projection_ets:get(H, Bucket, Key) of
        not_found ->
            not_found;
        {ok, Frame} ->
            {ok, bondy_oplog_cell_frame:extract_head(Frame)}
    end.
