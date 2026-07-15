%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_rpc_SUITE).

-moduledoc """
M2 integration tests for the **caller** and **callee** roles against a live
Bondy router over raw TCP: a `bondy_connect` callee registers a procedure whose
handler runs in an isolated worker, and a separate caller invokes it. Covers
synchronous + async calls, error propagation, handler-crash isolation,
per-call timeouts, and unregistration.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bondy_connect.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.bondy_connect.m2.rpc">>).
-define(HOST, "127.0.0.1").
-define(PORT, 18082).

all() ->
    [
        register_and_call,
        call_async_token_reply,
        unregister_stops_routing,
        handler_error_propagates,
        handler_crash_isolation,
        per_call_timeout,
        load_rejection_under_burst
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    {ok, _} = application:ensure_all_started(bondy_connect),
    ok = add_anon_realm(?REALM),
    Config.

end_per_suite(_) ->
    ok.

%% =============================================================================
%% TESTS
%% =============================================================================

register_and_call(_) ->
    Callee = connect(),
    Echo = fun(Args, KWArgs, _Details) -> {reply, Args, KWArgs} end,
    {ok, RegId} = bondy_connect:register(Callee, <<"com.example.echo">>, Echo),
    ?assert(is_integer(RegId)),

    Caller = connect(),
    {ok, Result} = bondy_connect:call(
        Caller, <<"com.example.echo">>, [<<"hello">>, 42]
    ),
    ?assertEqual([<<"hello">>, 42], maps:get(args, Result)),

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

call_async_token_reply(_) ->
    Callee = connect(),
    Echo = fun(Args, _KWArgs, _Details) -> {reply, Args} end,
    {ok, _} = bondy_connect:register(Callee, <<"com.example.async">>, Echo),

    Caller = connect(),
    {ok, Token} = bondy_connect:call_async(Caller, <<"com.example.async">>, [
        <<"x">>
    ]),
    ?assert(is_reference(Token)),
    receive
        {bondy_connect, Token, Reply} ->
            ?assertMatch({ok, #{args := [<<"x">>]}}, Reply)
    after 5000 ->
        ct:fail(no_async_reply)
    end,

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

unregister_stops_routing(_) ->
    Callee = connect(),
    Echo = fun(Args, _, _) -> {reply, Args} end,
    {ok, RegId} = bondy_connect:register(
        Callee, <<"com.example.transient">>, Echo
    ),
    ok = bondy_connect:unregister(Callee, RegId),

    Caller = connect(),
    Result = bondy_connect:call(Caller, <<"com.example.transient">>, []),
    ?assertMatch({error, #{uri := <<"wamp.error.no_such_procedure">>}}, Result),

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

handler_error_propagates(_) ->
    Callee = connect(),
    Failing = fun(_, _, _) -> {error, <<"com.example.business_error">>} end,
    {ok, _} = bondy_connect:register(Callee, <<"com.example.err">>, Failing),

    Caller = connect(),
    Result = bondy_connect:call(Caller, <<"com.example.err">>, []),
    ?assertMatch(
        {error, #{uri := <<"com.example.business_error">>}}, Result
    ),

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

handler_crash_isolation(_) ->
    Callee = connect(),
    Boom = fun(_, _, _) -> error(boom) end,
    {ok, _} = bondy_connect:register(Callee, <<"com.example.crash">>, Boom),

    Caller = connect(),
    Result = bondy_connect:call(Caller, <<"com.example.crash">>, []),
    ?assertMatch(
        {error, #{uri := ?BONDY_CONNECT_INTERNAL_ERROR}}, Result
    ),

    %% The crashing handler must NOT take the connection down — it can still
    %% serve a freshly-registered procedure.
    ?assertEqual(established, bondy_connect:status(Callee)),
    Ok = fun(Args, _, _) -> {reply, Args} end,
    {ok, _} = bondy_connect:register(Callee, <<"com.example.still_ok">>, Ok),
    {ok, R2} = bondy_connect:call(Caller, <<"com.example.still_ok">>, [
        <<"alive">>
    ]),
    ?assertEqual([<<"alive">>], maps:get(args, R2)),

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

per_call_timeout(_) ->
    Callee = connect(),
    Slow = fun(_, _, _) ->
        timer:sleep(2000),
        {reply, []}
    end,
    {ok, _} = bondy_connect:register(Callee, <<"com.example.slow">>, Slow),

    Caller = connect(),
    Result = bondy_connect:call(
        Caller, <<"com.example.slow">>, [], #{}, #{timeout => 300}
    ),
    ?assertEqual({error, timeout}, Result),

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

%% A callee capped at a single in-flight invocation rejects concurrent
%% invocations at admission with ERROR(wamp.error.unavailable) — the
%% `bondy_connect_load' backpressure arm (Decision 5), relayed by the router to
%% each caller. This drives the `{error, overloaded}' path end-to-end (the unit
%% suite only exercises the pure counter) and proves the `handler' load config is
%% reachable through the public connect spec.
load_rejection_under_burst(_) ->
    Proc = <<"com.example.capped">>,
    {ok, Callee} = bondy_connect:connect(
        spec(#{handler => #{max_concurrency => 1}})
    ),
    %% Holds the only slot long enough for the burst to pile up behind it (well
    %% under the 30s default call timeout, so the admitted call still succeeds).
    Slow = fun(_, _, _) ->
        timer:sleep(1500),
        {reply, [<<"done">>]}
    end,
    {ok, _} = bondy_connect:register(Callee, Proc, Slow),

    Caller = connect(),
    %% Burst of three concurrent calls: one takes the slot, the other two are
    %% rejected immediately while it is in flight.
    Tokens = [
        begin
            {ok, T} = bondy_connect:call_async(Caller, Proc, []),
            T
        end
     || _ <- lists:seq(1, 3)
    ],
    %% Selective receive per (bound) token collects every reply regardless of
    %% arrival order — the admitted reply lands ~1.5s after the two rejections.
    Replies = [
        receive
            {bondy_connect, Tk, R} -> R
        after 5000 -> ct:fail(no_reply)
        end
     || Tk <- Tokens
    ],
    Oks = [R || {ok, _} = R <- Replies],
    Unavail =
        [R || {error, #{uri := <<"wamp.error.unavailable">>}} = R <- Replies],
    ?assertEqual(1, length(Oks)),
    ?assertEqual(2, length(Unavail)),

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
connect() ->
    {ok, Conn} = bondy_connect:connect(spec()),
    Conn.

%% @private
spec() ->
    spec(#{}).

%% @private
spec(Extra) when is_map(Extra) ->
    Base = #{
        transport => tcp,
        endpoint => {?HOST, ?PORT},
        realm => ?REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json]
    },
    maps:merge(Base, Extra).

%% @private
add_anon_realm(RealmUri) ->
    Cfg = #{
        uri => RealmUri,
        authmethods => [?WAMP_ANON_AUTH],
        security_enabled => true,
        grants => [
            #{
                permissions => [
                    <<"wamp.register">>,
                    <<"wamp.unregister">>,
                    <<"wamp.subscribe">>,
                    <<"wamp.unsubscribe">>,
                    <<"wamp.call">>,
                    <<"wamp.cancel">>,
                    <<"wamp.publish">>
                ],
                uri => <<"">>,
                match => <<"prefix">>,
                roles => [<<"anonymous">>]
            }
        ],
        sources => [
            #{
                usernames => [<<"anonymous">>],
                authmethod => ?WAMP_ANON_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    },
    _ = bondy_realm:create(Cfg),
    ok.
