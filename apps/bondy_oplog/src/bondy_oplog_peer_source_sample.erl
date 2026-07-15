%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_peer_source_sample).
-behaviour(bondy_oplog_peer_source).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Random-sampling peer source for open-network deployments.

`Opts` keys:

- `pool`   :: list of candidate peers.
- `count`  :: how many to pick per call (default 3).

Returns a uniformly-random subset (without replacement). When the pool
is smaller than `count`, returns the whole pool.
""").

-export([peers_for/2]).

-spec peers_for(instance_id(), map()) -> [peer_id()].

peers_for(_InstanceId, #{pool := Pool} = Opts) when is_list(Pool) ->
    Count = maps:get(count, Opts, 3),
    sample(Pool, Count);
peers_for(_InstanceId, _Opts) ->
    [].

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Reservoir-style sampling. For our typical pool sizes (tens to a few
%% hundreds), this is fine; for very large pools a streaming reservoir
%% sampler would amortise better, but we don't have that pressure yet.
sample(Pool, N) when N >= length(Pool) ->
    Pool;
sample(Pool, N) when N >= 0 ->
    Tagged = [{rand:uniform(), P} || P <- Pool],
    Sorted = lists:sort(Tagged),
    [P || {_, P} <- lists:sublist(Sorted, N)].
