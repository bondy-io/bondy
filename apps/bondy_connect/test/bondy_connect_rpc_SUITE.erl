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
        load_rejection_under_burst,
        progressive_end_to_end,
        progressive_input_end_to_end,
        progressive_input_ordering,
        progressive_input_caller_unsupported,
        progressive_feature_disabled,
        progressive_sync_call_rejected,
        progressive_caller_death_interrupts_callee,
        progressive_timeout_resets_between_results,
        progressive_inactivity_timeout,
        progressive_deadline_caps_stream
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    {ok, _} = application:ensure_all_started(bondy_connect),
    ok = add_anon_realm(?REALM),
    Config.

end_per_suite(_) ->
    ok.

%% The dealer feature ships default-off (mixed-cluster safety); progressive
%% tests enable it per-testcase and every testcase restores the default.
init_per_testcase(progressive_feature_disabled, Config) ->
    ok = set_progressive_feature(false),
    Config;
init_per_testcase(Case, Config) ->
    case lists:prefix("progressive", atom_to_list(Case)) of
        true ->
            ok = set_progressive_feature(true),
            ok = set_progressive_calls_feature(true);
        false ->
            ok
    end,
    Config.

end_per_testcase(_, _Config) ->
    ok = set_progressive_feature(false),
    ok = set_progressive_calls_feature(false).

%% =============================================================================
%% TESTS
%% =============================================================================

register_and_call(_) ->
    Callee = connect(),
    Echo = fun(Args, KWArgs, _Details) ->
        {ok, #{args => Args, kwargs => KWArgs}}
    end,
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
    Echo = fun(Args, _KWArgs, _Details) -> {ok, #{args => Args}} end,
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
    Echo = fun(Args, _, _) -> {ok, #{args => Args}} end,
    {ok, RegId} = bondy_connect:register(
        Callee, <<"com.example.transient">>, Echo
    ),
    ok = bondy_connect:unregister(Callee, RegId),

    Caller = connect(),
    Result = bondy_connect:call(Caller, <<"com.example.transient">>, []),
    ?assertMatch(
        {error, #{kind := wamp, uri := <<"wamp.error.no_such_procedure">>}},
        Result
    ),

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

handler_error_propagates(_) ->
    Callee = connect(),
    Failing = fun(_, _, _) ->
        {error, #{uri => <<"com.example.business_error">>}}
    end,
    {ok, _} = bondy_connect:register(Callee, <<"com.example.err">>, Failing),

    Caller = connect(),
    Result = bondy_connect:call(Caller, <<"com.example.err">>, []),
    ?assertMatch(
        {error, #{kind := wamp, uri := <<"com.example.business_error">>}},
        Result
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
        {error, #{kind := wamp, uri := ?BONDY_CONNECT_INTERNAL_ERROR}},
        Result
    ),

    %% The crashing handler must NOT take the connection down — it can still
    %% serve a freshly-registered procedure.
    ?assertEqual(established, bondy_connect:status(Callee)),
    Ok = fun(Args, _, _) -> {ok, #{args => Args}} end,
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
        {ok, #{args => []}}
    end,
    {ok, _} = bondy_connect:register(Callee, <<"com.example.slow">>, Slow),

    Caller = connect(),
    Result = bondy_connect:call(
        Caller, <<"com.example.slow">>, [], #{}, #{timeout => 300}
    ),
    ?assertEqual({error, #{kind => client, reason => timeout}}, Result),

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
        {ok, #{args => [<<"done">>]}}
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
        [
            R
         || {error, #{kind := wamp, uri := <<"wamp.error.unavailable">>}} = R <-
                Replies
        ],
    ?assertEqual(1, length(Oks)),
    ?assertEqual(2, length(Unavail)),

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

progressive_end_to_end(_) ->
    %% A callee streams two progressive results via the progress fun the
    %% handler receives in its details, then returns the final result. The
    %% async caller observes them in yield order, each flagged in the
    %% RESULT details, and exactly one terminal reply.
    Callee = connect(),
    Handler = fun(_, _, Details) ->
        Progress = maps:get(progress, Details),
        ok = Progress([1], #{}),
        ok = Progress([2], #{}),
        {ok, #{args => [3]}}
    end,
    {ok, _} = bondy_connect:register(
        Callee, <<"com.example.progressive">>, Handler
    ),

    Caller = connect(),
    {ok, Token} = bondy_connect:call_async(
        Caller, <<"com.example.progressive">>, [], #{}, #{
            receive_progress => true
        }
    ),

    P1 = next_reply(Token),
    ?assertMatch({progress, #{args := [1]}}, P1),
    {progress, #{details := D1}} = P1,
    ?assertEqual(true, maps:get(progress, D1)),

    P2 = next_reply(Token),
    ?assertMatch({progress, #{args := [2]}}, P2),

    Final = next_reply(Token),
    ?assertMatch({ok, #{args := [3]}}, Final),
    {ok, #{details := DF}} = Final,
    ?assertNot(maps:get(progress, DF, false)),

    %% Terminal means terminal — nothing further arrives for this token.
    receive
        {bondy_connect, Token, Extra} -> ct:fail({extra_reply, Extra})
    after 300 -> ok
    end,

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

progressive_input_end_to_end(_) ->
    %% The mirror of progressive_end_to_end for the INPUT direction. The caller
    %% opens a progressive call with call_stream (the first argument chunk),
    %% streams two more chunks with send_input, then closes the stream with
    %% finish_input. The callee handler receives the first chunk as its args and
    %% PULLS the rest through the input fun until the final chunk, summing every
    %% chunk and replying with the total.
    Callee = connect(),
    Handler = fun([First], _KWArgs, Details) ->
        Input = maps:get(input, Details),
        {ok, #{args => [collect_input(Input, First)]}}
    end,
    {ok, _} = bondy_connect:register(
        Callee, <<"com.example.progressive.input">>, Handler
    ),

    Caller = connect(),
    {ok, Token} = bondy_connect:call_stream(
        Caller, <<"com.example.progressive.input">>, [1], #{}, #{}
    ),
    ok = bondy_connect:send_input(Caller, Token, [2], #{}),
    ok = bondy_connect:finish_input(Caller, Token, [3], #{}),

    ?assertMatch({ok, #{args := [6]}}, next_reply(Token)),

    %% Terminal means terminal — nothing further arrives for this token.
    receive
        {bondy_connect, Token, Extra} -> ct:fail({extra_reply, Extra})
    after 300 -> ok
    end,

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

progressive_input_ordering(_) ->
    %% Order-sensitive counterpart of progressive_input_end_to_end. The caller
    %% streams the sequence 1..20 as separate chunks; the callee collects each
    %% chunk (in arrival order) into a list and replies with it. A reordering
    %% anywhere on the caller->dealer->callee path would make the collected list
    %% differ from 1..20, so the assertion is a direct check of inter-chunk
    %% ordering (which addition in the sum test would mask).
    N = 20,
    Callee = connect(),
    Handler = fun([First], _KWArgs, Details) ->
        Input = maps:get(input, Details),
        {ok, #{args => [collect_input_list(Input, [First])]}}
    end,
    {ok, _} = bondy_connect:register(
        Callee, <<"com.example.progressive.ordering">>, Handler
    ),

    Caller = connect(),
    {ok, Token} = bondy_connect:call_stream(
        Caller, <<"com.example.progressive.ordering">>, [1], #{}, #{}
    ),
    _ = [
        ok = bondy_connect:send_input(Caller, Token, [I], #{})
     || I <- lists:seq(2, N - 1)
    ],
    ok = bondy_connect:finish_input(Caller, Token, [N], #{}),

    {ok, #{args := [Collected]}} = next_reply(Token),
    ?assertEqual(lists:seq(1, N), Collected),

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

progressive_input_caller_unsupported(_) ->
    %% A caller that does not announce progressive_calls (strict opt-in: the
    %% negotiated caller role lacks it) must be rejected when it opens a
    %% progressive input stream. The CALL fails with option_not_allowed and the
    %% callee handler never runs — no silent degrade for a started stream.
    TestPid = self(),
    Callee = connect(),
    Handler = fun(_, _, _) ->
        TestPid ! handler_ran,
        {ok, #{args => [<<"unexpected">>]}}
    end,
    {ok, _} = bondy_connect:register(
        Callee, <<"com.example.progressive.input.caller_off">>, Handler
    ),

    {ok, Caller} = bondy_connect:connect(
        spec(#{
            roles => #{
                caller => #{
                    features => #{
                        call_canceling => true,
                        progressive_call_results => true
                    }
                }
            }
        })
    ),
    {ok, Token} = bondy_connect:call_stream(
        Caller, <<"com.example.progressive.input.caller_off">>, [1], #{}, #{}
    ),

    ?assertMatch(
        {error, #{kind := wamp, uri := <<"wamp.error.option_not_allowed">>}},
        next_reply(Token)
    ),

    receive
        handler_ran -> ct:fail(handler_should_not_run)
    after 300 -> ok
    end,

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

progressive_feature_disabled(_) ->
    %% With the dealer feature off, receive_progress is stripped at the
    %% router: the handler sees neither receive_progress nor a progress fun
    %% in its details and the caller gets a single final result.
    TestPid = self(),
    Callee = connect(),
    Handler = fun(_, _, Details) ->
        TestPid !
            {details_flags, maps:is_key(receive_progress, Details),
                maps:is_key(progress, Details)},
        {ok, #{args => [<<"done">>]}}
    end,
    {ok, _} = bondy_connect:register(
        Callee, <<"com.example.progressive.off">>, Handler
    ),

    Caller = connect(),
    {ok, Token} = bondy_connect:call_async(
        Caller, <<"com.example.progressive.off">>, [], #{}, #{
            receive_progress => true
        }
    ),

    ?assertMatch({ok, #{args := [<<"done">>]}}, next_reply(Token)),

    receive
        {details_flags, HasReceiveProgress, HasProgressFun} ->
            ?assertNot(HasReceiveProgress),
            ?assertNot(HasProgressFun)
    after 1000 -> ct:fail(no_details_flags)
    end,

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

progressive_sync_call_rejected(_) ->
    Caller = connect(),
    ?assertEqual(
        {error, #{kind => client, reason => {invalid_option, receive_progress}}},
        bondy_connect:call(Caller, <<"com.example.whatever">>, [], #{}, #{
            receive_progress => true
        })
    ),
    ok = bondy_connect:disconnect(Caller).

progressive_caller_death_interrupts_callee(_) ->
    %% When the caller session dies mid-stream the router INTERRUPTs the
    %% callee (promise flush on the caller side), which kills the handler
    %% worker — the stream must not keep running for a dead caller.
    TestPid = self(),
    Callee = connect(),
    Handler = fun(_, _, Details) ->
        Progress = maps:get(progress, Details),
        TestPid ! {worker, self()},
        Loop = fun Loop() ->
            _ = Progress([<<"tick">>], #{}),
            timer:sleep(50),
            Loop()
        end,
        Loop()
    end,
    {ok, _} = bondy_connect:register(
        Callee, <<"com.example.progressive.abandon">>, Handler
    ),

    Caller = connect(),
    {ok, Token} = bondy_connect:call_async(
        Caller, <<"com.example.progressive.abandon">>, [], #{}, #{
            receive_progress => true
        }
    ),

    ?assertMatch({progress, _}, next_reply(Token)),

    WorkerPid =
        receive
            {worker, W} -> W
        after 1000 -> ct:fail(no_worker)
        end,
    MRef = monitor(process, WorkerPid),

    ok = bondy_connect:disconnect(Caller),

    receive
        {'DOWN', MRef, process, WorkerPid, _} -> ok
    after 5000 ->
        ct:fail(worker_not_interrupted)
    end,

    ok = bondy_connect:disconnect(Callee).

progressive_timeout_resets_between_results(_) ->
    %% Per the WAMP spec, for a progressive call the timeout is the limit
    %% between the call and the first result and between results
    %% thereafter: a stream whose TOTAL duration exceeds the timeout must
    %% still succeed as long as the gaps stay under it.
    Callee = connect(),
    Handler = fun(_, _, Details) ->
        Progress = maps:get(progress, Details),
        _ = [
            begin
                _ = Progress([N], #{}),
                timer:sleep(200)
            end
         || N <- lists:seq(1, 6)
        ],
        {ok, #{args => [<<"final">>]}}
    end,
    {ok, _} = bondy_connect:register(
        Callee, <<"com.example.progressive.reset">>, Handler
    ),

    Caller = connect(),
    %% 6 x 200ms of streaming ≈ 1.2s total against a 500ms timeout.
    {ok, Token} = bondy_connect:call_async(
        Caller, <<"com.example.progressive.reset">>, [], #{}, #{
            receive_progress => true,
            timeout => 500
        }
    ),

    {NProgress, Terminal} = drain_replies(Token, 0, 10000),
    ?assertEqual(6, NProgress),
    ?assertMatch({ok, #{args := [<<"final">>]}}, Terminal),

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

progressive_inactivity_timeout(_) ->
    %% A stream that goes quiet for longer than the timeout ends with the
    %% timeout error as the terminal reply.
    Callee = connect(),
    Handler = fun(_, _, Details) ->
        Progress = maps:get(progress, Details),
        _ = Progress([1], #{}),
        _ = Progress([2], #{}),
        timer:sleep(60000),
        {ok, #{args => [<<"never">>]}}
    end,
    {ok, _} = bondy_connect:register(
        Callee, <<"com.example.progressive.stall">>, Handler
    ),

    Caller = connect(),
    {ok, Token} = bondy_connect:call_async(
        Caller, <<"com.example.progressive.stall">>, [], #{}, #{
            receive_progress => true,
            timeout => 500
        }
    ),

    {NProgress, Terminal} = drain_replies(Token, 0, 10000),
    ?assertEqual(2, NProgress),
    ?assertEqual({error, #{kind => client, reason => timeout}}, Terminal),

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

progressive_deadline_caps_stream(_) ->
    %% The _deadline extension bounds the WHOLE call: a healthy stream
    %% that keeps resetting its inactivity timeout is still cut off at the
    %% deadline.
    Callee = connect(),
    Handler = fun(_, _, Details) ->
        Progress = maps:get(progress, Details),
        Loop = fun Loop() ->
            _ = Progress([<<"tick">>], #{}),
            timer:sleep(100),
            Loop()
        end,
        Loop()
    end,
    {ok, _} = bondy_connect:register(
        Callee, <<"com.example.progressive.deadline">>, Handler
    ),

    Caller = connect(),
    T0 = erlang:monotonic_time(millisecond),
    {ok, Token} = bondy_connect:call_async(
        Caller, <<"com.example.progressive.deadline">>, [], #{}, #{
            receive_progress => true,
            timeout => 500,
            '_deadline' => 1000
        }
    ),

    {NProgress, Terminal} = drain_replies(Token, 0, 10000),
    Elapsed = erlang:monotonic_time(millisecond) - T0,

    ?assert(NProgress >= 3),
    ?assertEqual({error, #{kind => client, reason => timeout}}, Terminal),
    %% Terminated by the deadline, not by stream completion or the
    %% inactivity timeout (which never fires — chunks come every 100ms).
    ?assert(Elapsed >= 1000 andalso Elapsed < 5000),

    ok = bondy_connect:disconnect(Caller),
    ok = bondy_connect:disconnect(Callee).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
next_reply(Token) ->
    receive
        {bondy_connect, Token, Reply} -> Reply
    after 5000 ->
        ct:fail(no_reply)
    end.

%% @private Collect progress replies until the terminal one arrives.
drain_replies(Token, N, Timeout) ->
    receive
        {bondy_connect, Token, {progress, _}} ->
            drain_replies(Token, N + 1, Timeout);
        {bondy_connect, Token, Terminal} ->
            {N, Terminal}
    after Timeout ->
        ct:fail(no_terminal_reply)
    end.

%% @private
set_progressive_feature(Bool) when is_boolean(Bool) ->
    bondy_config:set(
        [wamp, dealer, features, progressive_call_results], Bool
    ).

set_progressive_calls_feature(Bool) when is_boolean(Bool) ->
    bondy_config:set(
        [wamp, dealer, features, progressive_calls], Bool
    ).

%% Pull every input chunk through the handler's `input` fun, accumulating the
%% single integer each chunk carries, until the final chunk closes the stream.
collect_input(Input, Acc) ->
    case Input() of
        {more, [N], _} -> collect_input(Input, Acc + N);
        {last, [N], _} -> Acc + N
    end.

%% Order-preserving variant: accumulate each chunk's single integer in arrival
%% order, returning the list once the final chunk closes the stream.
collect_input_list(Input, Acc) ->
    case Input() of
        {more, [N], _} -> collect_input_list(Input, [N | Acc]);
        {last, [N], _} -> lists:reverse([N | Acc])
    end.

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
