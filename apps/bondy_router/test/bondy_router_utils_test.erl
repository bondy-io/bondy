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
