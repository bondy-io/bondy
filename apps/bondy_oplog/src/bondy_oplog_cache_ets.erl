%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_cache_ets).

-include("bondy_doc.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Reference `bondy_oplog_cache_adapter` implementation backed by a single
`public set` ETS table per `(NS, Index, Shard)` triple.

This adapter is bundled with the substrate primarily as a **contract
validator**: the PropEr suite for `bondy_oplog_core` runs against this
implementation and any consumer-supplied adapter, and both must produce
identical results.

It is also suitable for production use when a simple unbounded-by-default
in-RAM cache is acceptable. Two opts gate memory growth:

- `max_entries` (default `infinity`) — evict the first row on overflow.
  Eviction order is unspecified (ETS `first/1`); good adapters use LRU /
  LFU / TTL instead.
- `read_concurrency` (default `true`) — passed to `ets:new/2`.
- `write_concurrency` (default `true`) — passed to `ets:new/2`. Set
  `false` only when single-writer semantics are guaranteed; concurrent
  `write_through/4` callers and the applier touch the cache, so the
  default is required to avoid cache-line contention starving readers.

For LRU/LFU/TTL/ARC semantics, supply a richer adapter.

## Handle shape

The adapter's handle is the ETS tid. All callbacks are wait-free except
`invalidate_all/1` (which calls `ets:delete_all_objects/1`).
""").

-behaviour(bondy_oplog_cache_adapter).

-export([
    init/4,
    close/1,
    get/3,
    put/4,
    delete/3,
    invalidate_all/1,
    info/1
]).

%% =============================================================================
%% API
%% =============================================================================

-spec init(
    Namespace :: atom(),
    Index :: atom(),
    Shard :: non_neg_integer(),
    Opts :: map()
) -> {ok, ets:tid()}.

init(_NS, _Index, _Shard, Opts) ->
    ReadConc = maps:get(read_concurrency, Opts, true),
    WriteConc = maps:get(write_concurrency, Opts, true),
    Tab = ets:new(?MODULE, [
        set,
        public,
        {read_concurrency, ReadConc},
        {write_concurrency, WriteConc},
        {decentralized_counters, true}
    ]),
    ok = maybe_set_max_entries(Tab, Opts),
    {ok, Tab}.

-spec close(ets:tid()) -> ok.

close(Tab) ->
    true = ets:delete(Tab),
    ok.

-spec get(ets:tid(), Bucket :: term(), Key :: term()) ->
    {ok, {Value :: term(), Hlc :: bondy_oplog_hlc:hlc()}} | not_found.

get(Tab, Bucket, Key) ->
    case ets:lookup(Tab, {Bucket, Key}) of
        [] -> not_found;
        [{_, Value, Hlc}] -> {ok, {Value, Hlc}}
    end.

-spec put(
    ets:tid(),
    Bucket :: term(),
    Key :: term(),
    {Value :: term(), Hlc :: bondy_oplog_hlc:hlc()}
) -> ok.

put(Tab, Bucket, Key, {Value, Hlc}) ->
    true = ets:insert(Tab, {{Bucket, Key}, Value, Hlc}),
    ok = maybe_evict(Tab),
    ok.

-spec delete(ets:tid(), Bucket :: term(), Key :: term()) -> ok.

delete(Tab, Bucket, Key) ->
    true = ets:delete(Tab, {Bucket, Key}),
    ok.

-spec invalidate_all(ets:tid()) -> ok.

invalidate_all(Tab) ->
    true = ets:delete_all_objects(Tab),
    ok.

-spec info(ets:tid()) -> #{atom() => term()}.

info(Tab) ->
    #{
        size => ets:info(Tab, size),
        memory => ets:info(Tab, memory),
        max_entries => persistent_max_entries(Tab)
    }.

%% =============================================================================
%% PRIVATE
%% =============================================================================

maybe_set_max_entries(Tab, #{max_entries := N}) when
    is_integer(N), N > 0
->
    %% Stash the bound in the table itself under a reserved key so the
    %% adapter is self-contained (no persistent_term, no parallel ETS).
    true = ets:insert(Tab, {'$max_entries', N}),
    ok;
maybe_set_max_entries(_Tab, _Opts) ->
    ok.

persistent_max_entries(Tab) ->
    case ets:lookup(Tab, '$max_entries') of
        [{_, N}] -> N;
        [] -> infinity
    end.

maybe_evict(Tab) ->
    case persistent_max_entries(Tab) of
        infinity ->
            ok;
        N ->
            %% Subtract one to account for the reserved '$max_entries' row.
            evict_until(Tab, N)
    end.

evict_until(Tab, N) ->
    case ets:info(Tab, size) of
        Size when Size =< N + 1 ->
            ok;
        _ ->
            %% Walk from the lowest key, skipping the reserved
            %% `'$max_entries'` row, and drop one row per pass.
            case ets:first(Tab) of
                '$end_of_table' ->
                    ok;
                '$max_entries' ->
                    case ets:next(Tab, '$max_entries') of
                        '$end_of_table' ->
                            ok;
                        Next ->
                            true = ets:delete(Tab, Next),
                            evict_until(Tab, N)
                    end;
                Key ->
                    true = ets:delete(Tab, Key),
                    evict_until(Tab, N)
            end
    end.
