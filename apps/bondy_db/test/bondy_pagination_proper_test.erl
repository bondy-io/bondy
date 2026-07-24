%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% PropEr properties for the shared pagination cursor codec: the wire format
%% round-trips for any fingerprint/payload, a foreign fingerprint is rejected
%% as `stale`, and the `result/2` invariant (`next` undefined iff not
%% `has_more`) holds.

-module(bondy_pagination_proper_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(DEFAULT_NUMTESTS, 300).

-export([prop_codec_roundtrip/0]).
-export([prop_foreign_fingerprint_is_stale/0]).
-export([prop_result_invariant/0]).

%% =============================================================================
%% GENERATORS
%% =============================================================================

%% A `[safe]`-decodable payload: no funs/pids/refs, only data and atoms that
%% already exist (proper mints them in this VM, so they do).
payload() ->
    ?SIZED(
        Size,
        payload(Size)
    ).

payload(0) ->
    oneof([integer(), binary(), boolean(), atom(), <<>>]);
payload(Size) ->
    Smaller = payload(Size div 3),
    oneof([
        integer(),
        binary(),
        atom(),
        list(Smaller),
        {Smaller, Smaller},
        map(binary(), Smaller)
    ]).

fingerprint() ->
    ?LET(B, non_empty(binary()), B).

%% =============================================================================
%% PROPERTIES
%% =============================================================================

prop_codec_roundtrip() ->
    ?FORALL(
        {FP, Payload},
        {fingerprint(), payload()},
        begin
            C = bondy_pagination:new_cursor(FP, Payload),
            Bin = bondy_pagination:encode_cursor(C),
            {ok, C} =:= bondy_pagination:decode_cursor(FP, Bin)
        end
    ).

prop_foreign_fingerprint_is_stale() ->
    ?FORALL(
        {FP1, FP2, Payload},
        {fingerprint(), fingerprint(), payload()},
        ?IMPLIES(
            FP1 =/= FP2,
            begin
                C = bondy_pagination:new_cursor(FP1, Payload),
                Bin = bondy_pagination:encode_cursor(C),
                {error, stale} =:= bondy_pagination:decode_cursor(FP2, Bin)
            end
        )
    ).

prop_result_invariant() ->
    ?FORALL(
        {Values, MaybeNext},
        {list(integer()), oneof([undefined, {cursor}])},
        begin
            Next =
                case MaybeNext of
                    undefined -> undefined;
                    {cursor} -> bondy_pagination:new_cursor(<<"fp">>, pos)
                end,
            #{next := N, has_more := More} =
                bondy_pagination:result(Values, Next),
            (N =:= undefined) =:= (not More)
        end
    ).

%% =============================================================================
%% EUnit wrapper
%% =============================================================================

properties_test_() ->
    {timeout, 120, fun() ->
        Opts = [{to_file, user}, {numtests, ?DEFAULT_NUMTESTS}],
        Props = [
            prop_codec_roundtrip(),
            prop_foreign_fingerprint_is_stale(),
            prop_result_invariant()
        ],
        lists:foreach(
            fun(Prop) -> ?assert(proper:quickcheck(Prop, Opts)) end,
            Props
        )
    end}.
