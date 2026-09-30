%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% `bondy_oplog_projection_ets` with a `sync/1` the test sets through
%% `set_sync/1`; `ok` until it does.
-module(bondy_oplog_projection_sync_probe).
-behaviour(bondy_oplog_projection_adapter).

-export([set_sync/1]).
-export([open/4]).
-export([close/1]).
-export([get/3]).
-export([put_batch/2]).
-export([range/5]).
-export([delete/3]).
-export([clear/2]).
-export([info/1]).
-export([sync/1]).

-define(ETS, bondy_oplog_projection_ets).
-define(SYNC, {?MODULE, sync}).

set_sync(Fun) when is_function(Fun, 1) ->
    persistent_term:put(?SYNC, Fun).

open(NS, Index, Shard, Opts) -> ?ETS:open(NS, Index, Shard, Opts).

close(H) -> ?ETS:close(H).

get(H, Bucket, Key) -> ?ETS:get(H, Bucket, Key).

put_batch(H, Entries) -> ?ETS:put_batch(H, Entries).

range(H, Bucket, Low, High, Opts) -> ?ETS:range(H, Bucket, Low, High, Opts).

delete(H, Bucket, Key) -> ?ETS:delete(H, Bucket, Key).

clear(H, Scope) -> ?ETS:clear(H, Scope).

info(H) -> ?ETS:info(H).

sync(H) -> (persistent_term:get(?SYNC, fun(_) -> ok end))(H).
