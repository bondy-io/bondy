%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Byte-identity regression for `bondy_oplog_crdt_aw_map:encode_state/1`.
%%
%% aw_map's dot/version-vector machinery was extracted into the shared
%% `bondy_oplog_crdt_aw_core` (so aw_set / ew_flag reuse it). The encoded
%% state is the durable on-disk / on-wire form of an aw_map cell, so it
%% MUST remain byte-identical across that refactor (and any future one) —
%% durable cells and in-flight sync pages must decode unchanged. This pins
%% a known state's encoding to a captured golden vector.

-module(bondy_oplog_crdt_aw_map_golden_test).

-include_lib("eunit/include/eunit.hrl").

-define(MOD, bondy_oplog_crdt_aw_map).

%% Captured from the pre-extraction implementation (single-line, to avoid
%% transcription error).
-define(GOLDEN_HEX,
    <<"018368036C0000000268026D000000026B316C00000001680268026D000000016161016D00000001786A68026D000000026B326C00000001680268026D000000016161026D000000017A6A6A6C0000000268026D0000000161610268026D000000016261026A6104">>
).

encode_state_is_byte_identical_test() ->
    Log = [
        ev(1, <<"a">>, 1, {put, <<"k1">>, <<"x">>}, []),
        ev(2, <<"b">>, 1, {put, <<"k1">>, <<"y">>}, []),
        ev(3, <<"a">>, 2, {put, <<"k2">>, <<"z">>}, [{<<"a">>, 1}]),
        ev(4, <<"b">>, 2, {rmv, <<"k1">>}, [{<<"b">>, 1}])
    ],
    State = ?MOD:interpret_cog(Log, ?MOD:init()),
    Bytes = ?MOD:encode_state(State),
    ?assertEqual(binary:decode_hex(?GOLDEN_HEX), Bytes),
    %% And it still round-trips.
    ?assertEqual(State, ?MOD:decode_state(Bytes)).

ev(Hlc, Origin, Seq, Op, Ctx) ->
    Key = bondy_oplog_event:key(Hlc, Origin, Seq),
    bondy_oplog_event:new(Key, Op, Ctx).
