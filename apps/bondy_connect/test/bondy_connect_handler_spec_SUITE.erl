%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_handler_spec_SUITE).

-moduledoc "Pure unit tests for `bondy_connect_handler_spec`.".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).

all() ->
    [
        validate_shapes,
        invoke_fun,
        invoke_mf,
        invoke_mfa
    ].

%% A module:function/3 and /4 handler used by invoke_mf/invoke_mfa.
echo(Args, KWArgs, Details) ->
    {Args, KWArgs, Details}.

echo(Args, KWArgs, Details, Extra) ->
    {Args, KWArgs, Details, Extra}.

validate_shapes(_) ->
    ?assertEqual(
        ok, bondy_connect_handler_spec:validate(fun(_, _, _) -> ok end)
    ),
    ?assertEqual(ok, bondy_connect_handler_spec:validate({m, f})),
    ?assertEqual(ok, bondy_connect_handler_spec:validate({m, f, extra})),
    ?assertMatch(
        {error, {invalid_handler, _}},
        bondy_connect_handler_spec:validate(fun(_) -> ok end)
    ),
    ?assertMatch(
        {error, {invalid_handler, _}},
        bondy_connect_handler_spec:validate(not_a_handler)
    ).

invoke_fun(_) ->
    H = fun(A, K, D) -> {reply, [A, K, D]} end,
    ?assertEqual(
        {reply, [[1], #{x => 2}, #{}]},
        bondy_connect_handler_spec:invoke(H, [1], #{x => 2}, #{})
    ).

invoke_mf(_) ->
    ?assertEqual(
        {[1], #{}, #{d => 1}},
        bondy_connect_handler_spec:invoke({?MODULE, echo}, [1], #{}, #{d => 1})
    ).

invoke_mfa(_) ->
    ?assertEqual(
        {[1], #{}, #{}, extra_arg},
        bondy_connect_handler_spec:invoke(
            {?MODULE, echo, extra_arg}, [1], #{}, #{}
        )
    ).
