%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_query).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Query path.

Two flavours:

- **Hot query** (`query/2`) — loads the latest snapshot, replays the
  live MST events on top of it through `interpret_cog/2`, and runs
  the CRDT's `query/2` against the resulting state. Reflects the most
  recent local view, including events not yet stable.

- **Stable query** (`query_stable/2`) — runs the CRDT's `query/2`
  against the latest snapshot directly, with no replay. Cheaper and
  guaranteed identical across replicas that have compacted to the
  same watermark.

Both paths are lock-free reads: a single ETS lookup pulls the
published `{mst, watermark, snapshot, crdt_module}` from
`bondy_oplog_registry`, and all subsequent work (the
`bondy_mst:fold/4` over live events, the CRDT replay, the projection)
happens in the calling process. The instance gen_server is not
involved.
""").

-export([query/2]).
-export([query_stable/2]).

?DOC("""
Hot query: snapshot + live events, projected through the CRDT's
`query/2`.
""").
-spec query(instance_id(), Query :: term()) -> term().

query(InstanceId, Query) when is_binary(InstanceId) ->
    case bondy_oplog_registry:lookup(InstanceId) of
        not_found ->
            error({noproc, InstanceId});
        {ok, #{crdt_module := undefined}} ->
            error({no_crdt_module, InstanceId});
        {ok, Entry} ->
            CrdtMod = maps:get(crdt_module, Entry),
            BaseState = base_state(Entry, CrdtMod),
            LiveEvents = live_events(Entry),
            FinalState =
                case LiveEvents of
                    [] -> BaseState;
                    _ -> CrdtMod:interpret_cog(LiveEvents, BaseState)
                end,
            CrdtMod:query(Query, FinalState)
    end.

?DOC("""
Stable query: snapshot only, no live-event replay.
""").
-spec query_stable(instance_id(), Query :: term()) -> term().

query_stable(InstanceId, Query) when is_binary(InstanceId) ->
    case bondy_oplog_registry:lookup(InstanceId) of
        not_found ->
            error({noproc, InstanceId});
        {ok, #{crdt_module := undefined}} ->
            error({no_crdt_module, InstanceId});
        {ok, Entry} ->
            CrdtMod = maps:get(crdt_module, Entry),
            CrdtMod:query(Query, base_state(Entry, CrdtMod))
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
base_state(#{snapshot := undefined}, CrdtMod) ->
    CrdtMod:init();
base_state(#{snapshot := {_W, S}}, _CrdtMod) ->
    S.

%% @private
%% Returns events with key > watermark in key order.
live_events(#{mst := MST, watermark := WM}) ->
    From =
        case WM of
            undefined -> bondy_oplog_event:min_key();
            W -> next_after(W)
        end,
    To = bondy_oplog_event:max_key_for_hlc(16#FFFFFFFFFFFFFFFF),
    lists:reverse(
        bondy_mst:fold(
            MST,
            fun
                ({K, V}, Acc) when K >= From, K =< To ->
                    [bondy_oplog_event_from_value(K, V) | Acc];
                (_, Acc) ->
                    Acc
            end,
            []
        )
    ).

%% @private
bondy_oplog_event_from_value(Key, {Op, Meta, PrevHash, Signature}) ->
    bondy_oplog_event:new(Key, Op, Meta, PrevHash, Signature).

%% @private
%% Returns the smallest key strictly greater than `K`. Since fold_range
%% is inclusive on both ends, we use the watermark+1 trick: bump the
%% Seq field which is a non_neg_integer, never overflows in practice.
next_after(K) ->
    Hlc = bondy_oplog_event:key_hlc(K),
    Origin = bondy_oplog_event:key_origin(K),
    Seq = bondy_oplog_event:key_seq(K),
    bondy_oplog_event:key(Hlc, Origin, Seq + 1).
