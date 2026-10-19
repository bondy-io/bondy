%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_router_utils_test).
-moduledoc """
`bondy_router_utils:maybe_encode/2`, the encoder behind the Kafka bridge's
`encoding` option.
""".

-include_lib("eunit/include/eunit.hrl").

maybe_encode_erl_produces_external_term_format_test() ->
    Term = #{~"k" => [1, 2.5, ~"v"]},
    ?assertEqual(
        Term, binary_to_term(bondy_router_utils:maybe_encode(erl, Term), [safe])
    ),
    ?assertEqual(
        Term,
        binary_to_term(bondy_router_utils:maybe_encode(~"erl", Term), [safe])
    ).

%% A binary that is valid JSON is taken as already encoded and sent as it is;
%% any other binary is encoded as a JSON string.
maybe_encode_json_keeps_an_encoded_binary_test() ->
    [
        ?assertEqual(Bin, bondy_router_utils:maybe_encode(json, Bin))
     || Bin <- [~"123", ~"\"a\"", ~"{\"a\":1}", ~"[1,2]", ~"true"]
    ],
    ?assertEqual(~"\"hello\"", bondy_router_utils:maybe_encode(json, ~"hello")).
