%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_feature_flags).
-moduledoc """
Compact bit-mask representation of feature flags.

- One integer holds up to 64 (or more) boolean capabilities.
- O(1) look-ups, intersections and subset checks.

Increment `?VERSION` whenever you append to `cap_list/0`.
""".

-include("bondy_wamp.hrl").

-export([
    %% Current schema version
    version/0,
    %% Canonical ordered list of capabilities
    cap_list/0,

    %% Map ↔ Mask
    map_to_mask/1,
    mask_to_map/1,

    %% Single-flag helpers
    enabled/2,
    enable/2,
    disable/2,

    %% Two-party set operations
    common/2,
    combined/2,
    compatible/2
]).

%%--------------------------------------------------------------------
%% 1.  Canonical list  ➜  stable bit positions
%%--------------------------------------------------------------------
-define(VERSION, 1).

cap_list() ->
    %% Never reorder existing entries; only append at the tail.

    %% bit 0
    [
        <<"read">>,
        %% bit 1
        <<"write">>,
        %% bit 2
        <<"execute">>,
        %% bit 3
        <<"share">>,
        %% bit 4
        <<"admin">>
    ].

version() -> ?VERSION.

%% Pre-computed map {CapBinary ⇒ BitPosition} for O(1) lookup.
-define(CAP_POS_MAP, #{
    <<"read">> => 0,
    <<"write">> => 1,
    <<"execute">> => 2,
    <<"share">> => 3,
    <<"admin">> => 4
}).

pos(Cap) ->
    case maps:get(Cap, ?CAP_POS_MAP, undefined) of
        undefined -> error({unknown_capability, Cap});
        N -> N
    end.

%%--------------------------------------------------------------------
%% 2.  Map ➜ Integer mask
%%--------------------------------------------------------------------
-spec map_to_mask(map()) -> integer().
map_to_mask(Map) when is_map(Map) ->
    lists:foldl(
        fun(Cap, Acc) ->
            case maps:get(Cap, Map, false) of
                true -> Acc bor (1 bsl pos(Cap));
                false -> Acc
            end
        end,
        0,
        cap_list()
    ).

%%--------------------------------------------------------------------
%% 3.  Integer mask ➜ Map (for logs, APIs, tests)
%%--------------------------------------------------------------------
-spec mask_to_map(integer()) -> map().
mask_to_map(Mask) when is_integer(Mask) ->
    maps:from_list(
        [
            {Cap, (Mask band (1 bsl pos(Cap))) =/= 0}
         || Cap <- cap_list()
        ]
    ).

%%--------------------------------------------------------------------
%% 4.  Per-flag helpers (all guard-safe and inline-able)
%%--------------------------------------------------------------------
-spec enabled(integer(), binary()) -> boolean().
enabled(Mask, Cap) -> (Mask band (1 bsl pos(Cap))) =/= 0.

-spec enable(integer(), binary()) -> integer().
enable(Mask, Cap) -> Mask bor (1 bsl pos(Cap)).

-spec disable(integer(), binary()) -> integer().
disable(Mask, Cap) -> Mask band bnot (1 bsl pos(Cap)).

%%--------------------------------------------------------------------
%% 5.  Whole-set operations for handshakes / negotiation
%%--------------------------------------------------------------------
-spec common(integer(), integer()) -> integer().
common(MaskA, MaskB) -> MaskA band MaskB.

-spec combined(integer(), integer()) -> integer().
combined(MaskA, MaskB) -> MaskA bor MaskB.

%%  True when every bit set in RequiredMask is also set in PeerMask.
-spec compatible(integer(), integer()) -> boolean().
compatible(RequiredMask, PeerMask) ->
    (RequiredMask band PeerMask) =:= RequiredMask.

%% =============================================================================
%% PRIVATE
%% =============================================================================
