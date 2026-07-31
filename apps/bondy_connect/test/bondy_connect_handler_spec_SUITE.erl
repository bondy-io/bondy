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
        invoke_mfa,
        normalize_return_ok,
        normalize_return_ok_empty_map,
        normalize_return_ok_args,
        normalize_return_ok_kwargs_only,
        normalize_return_error_uri_only,
        normalize_return_error_uri_kwargs,
        normalize_return_invalid_noreply,
        normalize_return_invalid_missing_uri,
        normalize_return_invalid_legacy_reply
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
    H = fun(A, K, D) -> {ok, #{args => [A, K, D]}} end,
    ?assertEqual(
        {ok, #{args => [[1], #{x => 2}, #{}]}},
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

%% -----------------------------------------------------------------------------
%% normalize_return/1 -- the callee return-shape interpreter.
%% -----------------------------------------------------------------------------

normalize_return_ok(_) ->
    ?assertEqual(
        {yield, [], undefined}, bondy_connect_handler_spec:normalize_return(ok)
    ).

normalize_return_ok_empty_map(_) ->
    ?assertEqual(
        {yield, [], undefined},
        bondy_connect_handler_spec:normalize_return({ok, #{}})
    ).

normalize_return_ok_args(_) ->
    ?assertEqual(
        {yield, [1, 2], undefined},
        bondy_connect_handler_spec:normalize_return({ok, #{args => [1, 2]}})
    ).

normalize_return_ok_kwargs_only(_) ->
    %% args omitted -> defaults to [].
    ?assertEqual(
        {yield, [], #{a => 1}},
        bondy_connect_handler_spec:normalize_return(
            {ok, #{kwargs => #{a => 1}}}
        )
    ).

normalize_return_error_uri_only(_) ->
    Uri = <<"com.app.error.nope">>,
    ?assertEqual(
        {error, Uri, undefined, undefined},
        bondy_connect_handler_spec:normalize_return({error, #{uri => Uri}})
    ).

normalize_return_error_uri_kwargs(_) ->
    Uri = <<"com.app.error.nope">>,
    ?assertEqual(
        {error, Uri, undefined, #{why => x}},
        bondy_connect_handler_spec:normalize_return(
            {error, #{uri => Uri, kwargs => #{why => x}}}
        )
    ).

normalize_return_invalid_noreply(_) ->
    %% `noreply` was a synonym for `ok` pre-1.0; it is no longer accepted.
    ?assertEqual(
        invalid, bondy_connect_handler_spec:normalize_return(noreply)
    ).

normalize_return_invalid_missing_uri(_) ->
    %% An error map without a `uri` key is malformed, not a valid Result.
    ?assertEqual(
        invalid, bondy_connect_handler_spec:normalize_return({error, #{}})
    ).

normalize_return_invalid_legacy_reply(_) ->
    %% The pre-1.0 `{reply, Args}` form is no longer part of the contract.
    ?assertEqual(
        invalid, bondy_connect_handler_spec:normalize_return({reply, [1]})
    ).
