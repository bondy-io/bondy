%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_erl_test).

-include_lib("eunit/include/eunit.hrl").

-define(MESSAGE(Value), [48, 1, #{}, ~"com.example.proc", [Value]]).

improper_lists() ->
    [[1 | 2], [~"a", 1 | ~"b"], [{a, 1} | b], [[1, [2 | 3]]]].

encode_rejects_an_improper_list_test() ->
    [
        ?assertError(badarg, bondy_wamp_erl:encode(?MESSAGE(L)))
     || L <- improper_lists()
    ].

decode_rejects_an_improper_list_test() ->
    [
        ?assertError(badarg, bondy_wamp_erl:decode(?MESSAGE(L)))
     || L <- improper_lists()
    ].

decode_rejects_a_tuple_inside_a_message_test() ->
    ?assertError(badarg, bondy_wamp_erl:decode(?MESSAGE({1, 2}))).

decode_keeps_a_proper_list_test() ->
    ?assertEqual(
        ?MESSAGE([1, [~"a"]]), bondy_wamp_erl:decode(?MESSAGE([1, [~"a"]]))
    ).

encode_keeps_a_list_of_pairs_a_list_test() ->
    [
        ?assertEqual(?MESSAGE(Encoded), bondy_wamp_erl:encode(?MESSAGE(L)))
     || {L, Encoded} <- [
            {[{1, 2}, {1, 3}], [[1, 2], [1, 3]]},
            {[{a, 1}, 2], [[~"a", 1], 2]}
        ]
    ].
