%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_cancel_SUITE).

-moduledoc """
M3 integration tests for **call cancellation** against a live Bondy router over
raw TCP. A `bondy_connect` caller issues an asynchronous CALL to a slow callee
and then cancels it with each WAMP mode:

- `skip` — the caller is errored immediately; the callee is **not** interrupted.
- `killnowait` — the caller is errored immediately; an INTERRUPT is sent to the
  callee (and its servicing worker is killed).
- `kill` — an INTERRUPT is sent to the callee and the caller is errored only
  once the callee answers the INTERRUPT.

The `kill` test is also the proof of the **callee INTERRUPT** path: the caller
receives the `canceled` error long before the slow handler would have completed,
which is only possible if the callee killed its worker and answered the
INTERRUPT. It further asserts the callee connection survives and keeps serving.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.bondy_connect.m3.cancel">>).
-define(HOST, "127.0.0.1").
-define(PORT, 18082).

%% Long enough that, without a working interrupt/cancel, the caller would only
%% hear back when the handler finishes — so a fast `canceled` reply proves it.
-define(SLOW_MS, 5000).
-define(RECV_MS, 3000).

all() ->
    [
        cancel_skip,
        cancel_killnowait,
        cancel_kill_interrupts_callee,
        cancel_specific_among_many,
        cancel_unknown_token
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

%% skip: caller errored immediately, no INTERRUPT to the callee.
cancel_skip(_) ->
    Callee = connect(),
    {ok, _} = bondy_connect:register(
        Callee, <<"com.example.cancel.skip">>, slow()
    ),

    Caller = connect(),
    {ok, Token} = bondy_connect:call_async(
        Caller, <<"com.example.cancel.skip">>, []
    ),
    ok = bondy_connect:cancel(Caller, Token, skip),
    assert_canceled(Token),

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

%% killnowait: caller errored immediately, INTERRUPT sent to the callee.
cancel_killnowait(_) ->
    Callee = connect(),
    {ok, _} = bondy_connect:register(
        Callee, <<"com.example.cancel.kn">>, slow()
    ),

    Caller = connect(),
    {ok, Token} = bondy_connect:call_async(
        Caller, <<"com.example.cancel.kn">>, []
    ),
    ok = bondy_connect:cancel(Caller, Token, killnowait),
    assert_canceled(Token),

    ?assertEqual(established, bondy_connect:status(Callee)),

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

%% kill: the callee is interrupted; the caller hears `canceled` well before the
%% slow handler would finish, and the callee survives to serve a fresh call.
cancel_kill_interrupts_callee(_) ->
    Callee = connect(),
    {ok, _} = bondy_connect:register(
        Callee, <<"com.example.cancel.kill">>, slow()
    ),
    Ok = fun(Args, _, _) -> {reply, Args} end,
    {ok, _} = bondy_connect:register(Callee, <<"com.example.cancel.ok">>, Ok),

    Caller = connect(),
    {ok, Token} = bondy_connect:call_async(
        Caller, <<"com.example.cancel.kill">>, []
    ),
    ok = bondy_connect:cancel(Caller, Token, kill),
    assert_canceled(Token),

    %% The crashing/killed worker must not take the callee connection down.
    ?assertEqual(established, bondy_connect:status(Callee)),
    {ok, R} = bondy_connect:call(
        Caller, <<"com.example.cancel.ok">>, [<<"alive">>]
    ),
    ?assertEqual([<<"alive">>], maps:get(args, R)),

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

%% Cancelling one token among several in-flight async calls must cancel exactly
%% that call and leave the others in flight — proving the token->ReqId secondary
%% index (review C1) resolves each token to its own request, not just "some"
%% pending call.
cancel_specific_among_many(_) ->
    Callee = connect(),
    {ok, _} = bondy_connect:register(
        Callee, <<"com.example.cancel.many">>, slow()
    ),

    Caller = connect(),
    [T1, T2, T3] = [
        begin
            {ok, T} = bondy_connect:call_async(
                Caller, <<"com.example.cancel.many">>, []
            ),
            T
        end
     || _ <- lists:seq(1, 3)
    ],

    %% Cancel only the middle one.
    ok = bondy_connect:cancel(Caller, T2, killnowait),
    assert_canceled(T2),

    %% The other two are untouched: still in flight, so no reply within a window
    %% the slow handler runs well past (only T1/T3 are matched here).
    receive
        {bondy_connect, T1, _} -> ct:fail(t1_unexpectedly_replied);
        {bondy_connect, T3, _} -> ct:fail(t3_unexpectedly_replied)
    after 500 ->
        ok
    end,

    ?assertEqual(established, bondy_connect:status(Callee)),

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

%% Cancelling an unknown token is a clean error, not a crash.
cancel_unknown_token(_) ->
    Caller = connect(),
    ?assertEqual(
        {error, unknown_call},
        bondy_connect:cancel(Caller, make_ref(), kill)
    ),
    ok = bondy_connect:disconnect(Caller).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private A handler that sleeps well past the receive window.
slow() ->
    fun(_, _, _) ->
        timer:sleep(?SLOW_MS),
        {reply, [<<"too_late">>]}
    end.

%% @private Assert the async caller received a terminating `canceled` error.
assert_canceled(Token) ->
    receive
        {bondy_connect, Token, Reply} ->
            ?assertMatch({error, #{uri := ?WAMP_CANCELLED}}, Reply)
    after ?RECV_MS ->
        ct:fail(no_cancel_reply)
    end.

%% @private
connect() ->
    {ok, Conn} = bondy_connect:connect(#{
        transport => tcp,
        endpoint => {?HOST, ?PORT},
        realm => ?REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json]
    }),
    Conn.

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
                    <<"wamp.call">>,
                    <<"wamp.cancel">>
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
