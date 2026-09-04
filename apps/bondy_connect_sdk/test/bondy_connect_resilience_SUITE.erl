%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_resilience_SUITE).

-moduledoc """
M4 (Phase 6 — resilience) tests.

- **Config** (pure): `reconnect`/`ping`/`network_timeout` defaults, user-merge
  and validation.
- **Keepalive** (live): an idle connection configured with a short ping interval
  survives well past its idle timeout — proving the router answers our pings and
  no false reconnect happens.
- **Reconnect + replay** (live): abruptly killing a connection's *server-side*
  ranch handler drops the socket without a GOODBYE; the client reconnects and
  replays its declared registration so the procedure is callable again.
- **Revocation** (live): a router-driven `registration_revocation` drops only
  the *established* registration (the callee survives, stops serving it) while
  keeping the *declared* entry, so a later reconnect replays it — a revocation
  is session-scoped and must not survive the reconnect.
- **Fail-fast** (live): an in-flight async call is terminated with
  `{error, #{kind := client, reason := disconnected}}` when the link drops;
  and the initial connect to a dead endpoint fails fast by default (no
  blocking on retries).
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.bondy_connect.m4.resilience">>).
-define(HOST, "127.0.0.1").
-define(PORT, 18082).
-define(DEAD_PORT, 18099).

all() ->
    [
        %% pure config
        config_defaults,
        config_merge_user_over_defaults,
        config_rejects_bad_option,
        config_handler_options,

        %% live
        ping_keepalive_survives_idle,
        ping_failure_triggers_reconnect,
        reconnect_replays_registration,
        malformed_frame_triggers_reconnect,
        revocation_keeps_declared_replays_on_reconnect,
        register_duplicate_uri_errors,
        unregister_unknown_ref_errors,
        in_flight_call_fails_on_drop,
        initial_connect_fails_fast,
        transient_abort_retries_until_admitted,
        transient_abort_retry_backs_off,
        permanent_abort_still_fails_fast,
        connect_error_reports_the_router_reason,
        initial_connect_retries_when_enabled,
        reconnect_budget_exhaustion_gives_up
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    {ok, _} = application:ensure_all_started(bondy_connect_sdk),
    ok = add_anon_realm(?REALM),
    Config.

end_per_suite(_) ->
    ok.

%% =============================================================================
%% CONFIG (pure)
%% =============================================================================

config_defaults(_) ->
    {ok, C} = bondy_connect_config:validate(#{realm => ?REALM}),
    R = maps:get(reconnect, C),
    ?assertEqual(true, maps:get(enabled, R)),
    ?assertEqual(false, maps:get(retry_initial_connect, R)),
    ?assertEqual(10, maps:get(max_retries, R)),
    ?assertEqual(3000, maps:get(interval, R)),
    ?assertEqual(true, maps:get(backoff_enabled, R)),
    P = maps:get(ping, C),
    ?assertEqual(true, maps:get(enabled, P)),
    ?assertEqual(30000, maps:get(idle_timeout, P)),
    ?assertEqual(10000, maps:get(timeout, P)),
    ?assertEqual(3, maps:get(max_attempts, P)),
    ?assertEqual(60000, maps:get(network_timeout, C)).

config_merge_user_over_defaults(_) ->
    {ok, C} = bondy_connect_config:validate(#{
        realm => ?REALM,
        reconnect => #{enabled => false, max_retries => 3}
    }),
    R = maps:get(reconnect, C),
    %% user values win, untouched defaults survive
    ?assertEqual(false, maps:get(enabled, R)),
    ?assertEqual(3, maps:get(max_retries, R)),
    ?assertEqual(3000, maps:get(interval, R)).

config_rejects_bad_option(_) ->
    ?assertMatch(
        {error, {unknown_option, reconnect, bogus}},
        bondy_connect_config:validate(#{
            realm => ?REALM, reconnect => #{bogus => 1}
        })
    ),
    ?assertMatch(
        {error, {invalid_option, ping, enabled, yes}},
        bondy_connect_config:validate(#{
            realm => ?REALM, ping => #{enabled => yes}
        })
    ),
    ?assertMatch(
        {error, {invalid_option, reconnect, max_retries, -1}},
        bondy_connect_config:validate(#{
            realm => ?REALM, reconnect => #{max_retries => -1}
        })
    ),
    ?assertMatch(
        {error, {invalid_network_timeout, -1}},
        bondy_connect_config:validate(#{realm => ?REALM, network_timeout => -1})
    ).

%% The optional `handler' load-regulation config (Decision 5) is plumbed through
%% validation so `max_concurrency'/`rate' are reachable by the connection's
%% `bondy_connect_load:new/1' (an absent `handler' means unlimited, no rate).
config_handler_options(_) ->
    {ok, C0} = bondy_connect_config:validate(#{realm => ?REALM}),
    ?assertEqual(#{}, maps:get(handler, C0)),

    {ok, C1} = bondy_connect_config:validate(#{
        realm => ?REALM, handler => #{max_concurrency => 4}
    }),
    ?assertEqual(#{max_concurrency => 4}, maps:get(handler, C1)),

    ?assertMatch(
        {error, {invalid_option, handler, max_concurrency, -1}},
        bondy_connect_config:validate(#{
            realm => ?REALM, handler => #{max_concurrency => -1}
        })
    ),
    ?assertMatch(
        {error, {unknown_option, handler, bogus}},
        bondy_connect_config:validate(#{
            realm => ?REALM, handler => #{bogus => 1}
        })
    ).

%% =============================================================================
%% LIVE
%% =============================================================================

%% A connection with a short ping idle interval must stay established across an
%% idle period far longer than that interval: the router answers each ping and
%% the client never falsely reconnects.
ping_keepalive_survives_idle(_) ->
    {Conn, _Server} = connect_and_server(#{
        ping => #{
            enabled => true,
            idle_timeout => 300,
            timeout => 1000,
            max_attempts => 3
        }
    }),
    ?assertEqual(established, bondy_connect_client:status(Conn)),
    %% Idle ~7x the ping interval — several ping/pong cycles must occur.
    timer:sleep(2000),
    ?assertEqual(established, bondy_connect_client:status(Conn)),
    %% And it still works.
    {ok, _} = bondy_connect_client:register(
        Conn, <<"com.example.res.ka">>, ok_handler()
    ),
    {ok, R} = bondy_connect_client:call(Conn, <<"com.example.res.ka">>, [
        <<"hi">>
    ]),
    ?assertEqual([<<"hi">>], maps:get(args, R)),
    ok = bondy_connect_client:disconnect(Conn).

%% The flip side of the above: a client whose pings go *unanswered*
%% must give up after `max_attempts` and reconnect. We point the client at a
%% **mock** raw-socket server that completes the WAMP handshake + an anonymous
%% WELCOME — so the client genuinely reaches `established` — but then stays SILENT
%% on pings, never sending a pong. The link is otherwise healthy, so the only
%% possible cause of the reconnect is the ping timeout. We observe the reconnect
%% as a socket swap on the *same* connection process (its Erlang port changes),
%% the same definitive signal the malformed-frame test uses.
%%
%% With the give-up path dead — the keepalive unable to trigger a reconnect on
%% a silent link — this test hangs at `established` until the wait_until
%% ceiling fires.
ping_failure_triggers_reconnect(_) ->
    Server = start_silent_server(),
    Port = silent_server_port(Server),
    try
        {ok, Conn} = bondy_connect_client:connect(#{
            transport => tcp,
            endpoint => {?HOST, Port},
            realm => ?REALM,
            auth => #{method => ?WAMP_ANON_AUTH},
            serializers => [json],
            ping => #{
                enabled => true,
                idle_timeout => 200,
                timeout => 200,
                max_attempts => 2
            }
        }),
        ?assertEqual(established, bondy_connect_client:status(Conn)),
        Port0 = socket_port(Conn),
        ?assert(is_port(Port0)),

        %% Unanswered pings exhaust the budget -> give up -> reconnect on a fresh
        %% socket (same connection pid). ~600ms to the first reconnect; poll up
        %% to 5s.
        ok = wait_until(
            fun() ->
                bondy_connect_client:status(Conn) =:= established andalso
                    is_port(socket_port(Conn)) andalso
                    socket_port(Conn) =/= Port0
            end,
            50,
            100
        ),
        ?assert(is_process_alive(conn_pid(Conn))),
        ok = bondy_connect_client:disconnect(Conn)
    after
        stop_silent_server(Server)
    end.

%% Killing the callee's server-side handler drops its socket without a GOODBYE;
%% the client reconnects and replays its declared registration, so the procedure
%% is callable again on the fresh session.
reconnect_replays_registration(_) ->
    Proc = <<"com.example.res.echo">>,
    {Callee, CalleeServer} = connect_and_server(#{}),
    {ok, _} = bondy_connect_client:register(Callee, Proc, echo_handler()),

    Caller = connect(#{}),
    {ok, R0} = bondy_connect_client:call(Caller, Proc, [<<"a">>]),
    ?assertEqual([<<"a">>], maps:get(args, R0)),

    %% Abrupt server-side drop.
    true = is_process_alive(CalleeServer),
    _ = exit(CalleeServer, kill),

    %% The callee reconnects...
    ok = wait_until(
        fun() -> bondy_connect_client:status(Callee) =:= established end,
        100,
        100
    ),

    %% ...and the replayed registration makes the procedure callable again.
    ok = wait_until(
        fun() ->
            case bondy_connect_client:call(Caller, Proc, [<<"b">>]) of
                {ok, #{args := [<<"b">>]}} -> true;
                _ -> false
            end
        end,
        100,
        100
    ),

    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

%% A malformed frame arriving on an established connection must trigger
%% on_transport_failure -> reconnect (the codec returns {protocol_error,_}),
%% NOT crash the gen_statem. We inject a valid raw-socket frame header whose
%% payload is undecodable WAMP straight into the connection's socket mailbox
%% (identical in shape to what the kernel delivers in {active, once} mode). The
%% same connection process must reconnect on a fresh socket and replay its
%% declared registration.
malformed_frame_triggers_reconnect(_) ->
    Proc = <<"com.example.res.malformed">>,
    Callee = connect(#{}),
    {ok, _} = bondy_connect_client:register(Callee, Proc, echo_handler()),

    Caller = connect(#{}),
    {ok, R0} = bondy_connect_client:call(Caller, Proc, [<<"a">>]),
    ?assertEqual([<<"a">>], maps:get(args, R0)),

    Port0 = socket_port(Callee),
    ?assert(is_port(Port0)),

    %% Frame: <<Reserved:5=0, Type:3=0 (message), Len:24, Payload>> with a
    %% payload that is not decodable WAMP -> codec {protocol_error,_}.
    Payload = <<"not-a-json">>,
    Frame = <<0:5, 0:3, (byte_size(Payload)):24, Payload/binary>>,
    conn_pid(Callee) ! {tcp, Port0, Frame},

    %% The reconnect opens a *new* socket (different port) on the *same*
    %% connection process — a definitive signal a genuine reconnect occurred
    %% (and that the statem did not crash/restart).
    ok = wait_until(
        fun() ->
            bondy_connect_client:status(Callee) =:= established andalso
                is_port(socket_port(Callee)) andalso
                socket_port(Callee) =/= Port0
        end,
        100,
        100
    ),
    ?assert(is_process_alive(conn_pid(Callee))),

    %% ...and the replayed registration makes the procedure callable again.
    ok = wait_until(
        fun() ->
            case bondy_connect_client:call(Caller, Proc, [<<"b">>]) of
                {ok, #{args := [<<"b">>]}} -> true;
                _ -> false
            end
        end,
        100,
        100
    ),

    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

%% A router-driven registration_revocation (an unsolicited UNREGISTERED with
%% request_id 0) drops only the *established* registration: the callee stops
%% serving it but its connection survives. The *declared* entry is kept, and
%% because a revocation is scoped to the current session (Bondy has no durable
%% sessions) a later reconnect replays the declared registration and the
%% procedure is callable again — the revocation must NOT survive the reconnect
%%.
revocation_keeps_declared_replays_on_reconnect(_) ->
    Proc = <<"com.example.res.revoked">>,
    {Callee, CalleeServer} = connect_and_server(#{}),
    {ok, RegId} = bondy_connect_client:register(Callee, Proc, echo_handler()),

    Caller = connect(#{}),
    {ok, R0} = bondy_connect_client:call(Caller, Proc, [<<"a">>]),
    ?assertEqual([<<"a">>], maps:get(args, R0)),

    %% Inject a synthetic router revocation straight into the callee's socket
    %% mailbox: an unsolicited UNREGISTERED (request_id 0) naming RegId, framed
    %% with the same codec the router uses so it round-trips to the record the
    %% connection routes on.
    Port = socket_port(Callee),
    ?assert(is_port(Port)),
    Revocation = bondy_wamp_message:unregistered(0, #{registration => RegId}),
    Codec = bondy_connect_codec:new(json, 1048576, 1048576),
    {ok, Frame} = bondy_connect_codec:encode(Revocation, Codec),
    conn_pid(Callee) ! {tcp, Port, Frame},

    %% The established registration is gone: the router still routes the
    %% INVOCATION here, but the callee no longer knows RegId and answers
    %% no_such_registration — and its connection stays up (graceful handling,
    %% no crash/reconnect).
    ok = wait_until(
        fun() ->
            case bondy_connect_client:call(Caller, Proc, [<<"b">>]) of
                {error, #{kind := wamp, uri := ?WAMP_NO_SUCH_REGISTRATION}} ->
                    true;
                _ ->
                    false
            end
        end,
        100,
        100
    ),
    ?assertEqual(established, bondy_connect_client:status(Callee)),

    %% Force a reconnect (an abrupt server-side drop, which also clears the
    %% router-side registration). The kept declared entry replays, so the
    %% procedure is callable again — proving the revocation did not survive the
    %% reconnect.
    true = is_process_alive(CalleeServer),
    _ = exit(CalleeServer, kill),
    ok = wait_until(
        fun() -> bondy_connect_client:status(Callee) =:= established end,
        200,
        100
    ),
    ok = wait_until(
        fun() ->
            case bondy_connect_client:call(Caller, Proc, [<<"c">>]) of
                {ok, #{args := [<<"c">>]}} -> true;
                _ -> false
            end
        end,
        200,
        100
    ),

    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

%% register/subscribe/unregister/unsubscribe share error_payload/1 with call*
%% (T2, decision 1): a router-refused REGISTER is a `kind := wamp` call_error(),
%% not a bare atom.
register_duplicate_uri_errors(_) ->
    Proc = <<"com.example.res.duplicate">>,
    Callee1 = connect(#{}),
    {ok, _} = bondy_connect_client:register(Callee1, Proc, echo_handler()),

    Callee2 = connect(#{}),
    Result = bondy_connect_client:register(Callee2, Proc, echo_handler()),
    ?assertMatch(
        {error, #{kind := wamp, uri := ?WAMP_PROCEDURE_ALREADY_EXISTS}},
        Result
    ),

    ok = bondy_connect_client:disconnect(Callee1),
    ok = bondy_connect_client:disconnect(Callee2).

%% An unresolvable URI is rejected locally (no router round-trip) as a
%% `kind := client` call_error() — the sibling of register's `kind := wamp`
%% case above.
unregister_unknown_ref_errors(_) ->
    Callee = connect(#{}),
    ?assertEqual(
        {error, #{kind => client, reason => no_such_registration}},
        bondy_connect_client:unregister(
            Callee, <<"com.example.res.never_registered">>
        )
    ),
    ok = bondy_connect_client:disconnect(Callee).

%% An in-flight async call is terminated with {error, disconnected} (fail-fast)
%% when the caller's link drops.
in_flight_call_fails_on_drop(_) ->
    Proc = <<"com.example.res.slow">>,
    Self = self(),
    Callee = connect(#{}),
    %% A slow handler that first signals the test that it is running, so we drop
    %% the link only once the CALL is provably in flight on the callee — and the
    %% long sleep guarantees the real reply can never win the race against the
    %% disconnect (no fixed pre-kill sleep, no false "in flight").
    Handler = fun(_, _, _) ->
        Self ! invocation_started,
        timer:sleep(3000),
        {ok, #{args => [<<"too_late">>]}}
    end,
    {ok, _} = bondy_connect_client:register(Callee, Proc, Handler),

    {Caller, CallerServer} = connect_and_server(#{}),
    {ok, Token} = bondy_connect_client:call_async(Caller, Proc, []),
    receive
        invocation_started -> ok
    after 5000 ->
        ct:fail(invocation_not_started)
    end,

    _ = exit(CallerServer, kill),

    receive
        {bondy_connect_client, Token, Reply} ->
            ?assertEqual(
                {error, #{kind => client, reason => disconnected}}, Reply
            )
    after 5000 ->
        ct:fail(no_disconnected_reply)
    end,

    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

%% By default the initial connect is fail-fast: a dead endpoint returns an error
%% promptly rather than blocking on the reconnect budget.
initial_connect_fails_fast(_) ->
    {Elapsed, Result} = timer:tc(fun() ->
        bondy_connect_client:connect(#{
            transport => tcp,
            endpoint => {?HOST, ?DEAD_PORT},
            realm => ?REALM,
            auth => #{method => ?WAMP_ANON_AUTH},
            serializers => [json]
        })
    end),
    ?assertMatch({error, _}, Result),
    %% Well under the 30s await_ready ceiling — proves it did not retry-loop.
    ?assert(Elapsed < 5000000).

%% A router ABORT whose `nature` is `transient` must NOT be fatal: the HELLO
%% load-admission gate sheds new sessions under load with
%% `wamp.error.unavailable`, expecting well-behaved clients to back off and come
%% back. This is the FIRST connect, where `retry_initial_connect` defaults to
%% `false` — the exception is deliberate (a transient abort is the opposite of a
%% misconfiguration, which is what fail-fast exists for).
%%
%% Before the fix the abort short-circuited out of `process_records/3` straight
%% into a gen_statem stop, never reaching `is_retriable/1` at all, so EVERY
%% abort killed the connection for good.
%%
%% The gate is closed deterministically rather than by generating real load:
%% suspend the sampler so it cannot re-evaluate (it re-samples every 100ms and
%% would immediately undo us), then flip the shared status cell it publishes.
transient_abort_retries_until_admitted(_) ->
    ok = force_hello_gate(closed),
    Parent = self(),

    %% `connect/1` blocks, so drive it from a helper and watch what it does.
    Pid = spawn_link(fun() ->
        Parent !
            {result, self(),
                bondy_connect_client:connect(#{
                    transport => tcp,
                    endpoint => {?HOST, ?PORT},
                    realm => ?REALM,
                    auth => #{method => ?WAMP_ANON_AUTH},
                    serializers => [json],
                    reconnect => #{backoff_min => 200, backoff_max => 500}
                })}
    end),

    %% It must still be trying: a fail-fast would have answered by now.
    receive
        {result, Pid, Early} ->
            ok = force_hello_gate(open),
            ct:fail({gave_up_on_transient_abort, Early})
    after 1500 ->
        ok
    end,

    %% Open the gate; the in-flight backoff loop must now get in.
    ok = force_hello_gate(open),
    receive
        {result, Pid, {ok, Conn}} ->
            ?assertEqual(established, bondy_connect_client:status(Conn)),
            ok = bondy_connect_client:disconnect(Conn);
        {result, Pid, Other} ->
            ct:fail({did_not_recover, Other})
    after 30000 ->
        ct:fail(no_reply_after_gate_opened)
    end.

%% Retrying is only half the contract — retrying WITHOUT backoff is worse than
%% not retrying at all, because an un-backed-off reconnect loop is itself what
%% keeps the router's run queues deep.
%%
%% This is not covered by the case above (a hot loop passes it just as happily).
%% The trap is specific: on a refused handshake the TCP connect SUCCEEDS every
%% time, so `on_connect_failure/2` — the only caller of `backoff_retry/2` —
%% never runs, and a plain `{next_state, connecting, _}` would reset the budget
%% and re-dial on a 0ms timer.
%%
%% Count actual HELLO arrivals at the router over a fixed window: with the
%% `bondy_retry` ladder engaged (min 300ms, jittered) a few attempts fit; a
%% full-speed loop produces orders of magnitude more.
transient_abort_retry_backs_off(_) ->
    ok = force_hello_gate(closed),
    Before = hello_refusals(),
    Parent = self(),

    Pid = spawn(fun() ->
        Parent !
            {result, self(),
                bondy_connect_client:connect(#{
                    transport => tcp,
                    endpoint => {?HOST, ?PORT},
                    realm => ?REALM,
                    auth => #{method => ?WAMP_ANON_AUTH},
                    serializers => [json],
                    reconnect => #{
                        backoff_min => 300, backoff_max => 5000, deadline => 0
                    }
                })}
    end),

    timer:sleep(3000),
    Attempts = hello_refusals() - Before,
    _ = exit(Pid, kill),
    ok = force_hello_gate(open),

    %% It must have retried at all...
    ?assert(Attempts >= 1),
    %% ...and must NOT have hammered. 3s of 300ms-and-growing jittered backoff
    %% is well under 20; a 0ms-timer loop is in the hundreds or thousands.
    ?assert(
        Attempts =< 20,
        lists:flatten(
            io_lib:format("no backoff: ~p HELLO refusals in 3s", [Attempts])
        )
    ).

%% @private Count of HELLOs the load gate has refused on this node.
hello_refusals() ->
    lists:sum([
        V
     || {_, V} <- prometheus_counter:values(default, bondy_wamp_dropped_total)
    ]).

%% The other half of the contract: a `permanent` abort must still fail fast.
%% An unknown realm is refused with `wamp.error.no_such_realm`, nature
%% `permanent` — retrying that forever would be strictly worse than surfacing it.
permanent_abort_still_fails_fast(_) ->
    {Elapsed, Result} = timer:tc(fun() ->
        bondy_connect_client:connect(#{
            transport => tcp,
            endpoint => {?HOST, ?PORT},
            realm => <<"com.example.no.such.realm.at.all">>,
            auth => #{method => ?WAMP_ANON_AUTH},
            serializers => [json]
        })
    end),
    ?assertMatch({error, _}, Result),
    ?assert(Elapsed < 5000000).

%% `connect/1` must say WHY it failed. Replying every waiter a flat
%% `{error, disconnected}` from `terminate/3` would make a wrong realm, a bad
%% credential and a router refusal indistinguishable — to the caller and to
%% anyone debugging one.
connect_error_reports_the_router_reason(_) ->
    Result = bondy_connect_client:connect(#{
        transport => tcp,
        endpoint => {?HOST, ?PORT},
        realm => <<"com.example.no.such.realm.at.all">>,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json]
    }),
    ?assertMatch(
        {error, {abort, <<"wamp.error.no_such_realm">>, _}}, Result
    ).

%% @private Force the router's HELLO admission gate open or closed.
force_hello_gate(State) ->
    Ref = persistent_term:get({bondy_regulator_load, status}),
    case State of
        closed ->
            ok = sys:suspend(bondy_regulator_load),
            atomics:put(Ref, 1, 1);
        open ->
            atomics:put(Ref, 1, 0),
            ok = sys:resume(bondy_regulator_load)
    end,
    ok.

%% With retry_initial_connect => true the initial connect retries the configured
%% budget and then returns an error (still bounded, no infinite block).
initial_connect_retries_when_enabled(_) ->
    Result = bondy_connect_client:connect(#{
        transport => tcp,
        endpoint => {?HOST, ?DEAD_PORT},
        realm => ?REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json],
        reconnect => #{
            enabled => true,
            retry_initial_connect => true,
            max_retries => 2,
            interval => 200,
            deadline => 0,
            backoff_enabled => false
        }
    }),
    ?assertMatch({error, _}, Result).

%% After a connection has *established once*, an abrupt server disappearance
%% drives the reconnect/backoff loop; once the retry budget is exhausted the
%% connection gives up and terminates with `{shutdown, {reconnect_failed, _}}`
%% (distinct from the *initial*-connect budget path above — this one only
%% becomes reachable via `established_once = true`). A mock raw-socket server
%% completes the handshake + WELCOME, then on cue closes both the live socket
%% (the client sees the drop) and the listen socket (so every reconnect attempt
%% is refused fast). Ping is disabled so the only reconnect driver is the drop.
reconnect_budget_exhaustion_gives_up(_) ->
    Server = start_drop_server(),
    Port = drop_server_port(Server),
    %% connect/1 blocks until established, so on return established_once is set.
    {ok, Conn} = bondy_connect_client:connect(#{
        transport => tcp,
        endpoint => {?HOST, Port},
        realm => ?REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json],
        ping => #{enabled => false},
        reconnect => #{
            enabled => true,
            retry_initial_connect => false,
            max_retries => 2,
            interval => 100,
            deadline => 0,
            backoff_enabled => false
        }
    }),
    ?assertEqual(established, bondy_connect_client:status(Conn)),
    Pid = conn_pid(Conn),
    Ref = erlang:monitor(process, Pid),
    %% Make the server vanish: the live socket close triggers the reconnect, the
    %% listen socket close makes each retry fail fast with econnrefused.
    ok = drop_server_drop(Server),
    try
        receive
            {'DOWN', Ref, process, Pid, Reason} ->
                ?assertMatch({shutdown, {reconnect_failed, _}}, Reason)
        after 5000 ->
            ct:fail(connection_did_not_give_up)
        end
    after
        stop_drop_server(Server)
    end,
    %% The process is gone for good — no restart.
    ?assertEqual(down, bondy_connect_client:status(Conn)).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
ok_handler() ->
    fun(Args, _, _) -> {ok, #{args => Args}} end.

echo_handler() ->
    fun(Args, _, _) -> {ok, #{args => Args}} end.

%% @private Establish a connection (with extra config merged in).
connect(Extra) ->
    Base = #{
        transport => tcp,
        endpoint => {?HOST, ?PORT},
        realm => ?REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json]
    },
    {ok, Conn} = bondy_connect_client:connect(maps:merge(Base, Extra)),
    Conn.

%% @private Establish a connection and return its *server-side* ranch handler pid
%% (identified as the new TCP connection that appears during connect).
connect_and_server(Extra) ->
    Before = bondy_listener_manager:connections(wamp_tcp),
    Conn = connect(Extra),
    Server = new_server_conn(Before, 100),
    {Conn, Server}.

%% @private
new_server_conn(_Before, 0) ->
    error(no_new_server_conn);
new_server_conn(Before, N) ->
    case bondy_listener_manager:connections(wamp_tcp) -- Before of
        [Pid | _] ->
            Pid;
        [] ->
            timer:sleep(50),
            new_server_conn(Before, N - 1)
    end.

%% @private Start a mock raw-socket WAMP server that completes the handshake +
%% an anonymous WELCOME (so a connecting client reaches `established`) but then
%% stays SILENT on pings — it never sends a pong. Accepts reconnects forever.
%% Returns an opaque handle for `silent_server_port/1` and `stop_silent_server/1`.
start_silent_server() ->
    {ok, LSock} = gen_tcp:listen(0, [
        binary,
        {ip, {127, 0, 0, 1}},
        {active, false},
        {reuseaddr, true},
        {packet, 0}
    ]),
    {ok, Port} = inet:port(LSock),
    Acceptor = spawn(fun() ->
        receive
            go -> silent_accept_loop(LSock)
        end
    end),
    ok = gen_tcp:controlling_process(LSock, Acceptor),
    Acceptor ! go,
    {silent_server, Port, Acceptor}.

%% @private
silent_server_port({silent_server, Port, _Acceptor}) ->
    Port.

%% @private
stop_silent_server({silent_server, _Port, Acceptor}) ->
    %% The acceptor owns the listen socket, so killing it closes the socket; the
    %% per-connection handlers exit on their own when the client closes.
    _ = exit(Acceptor, kill),
    ok.

%% @private Accept reconnects until the listen socket is closed; serve each on
%% its own process.
silent_accept_loop(LSock) ->
    case gen_tcp:accept(LSock, 1000) of
        {ok, Sock} ->
            Handler = spawn(fun() ->
                receive
                    go -> serve_silent(Sock)
                end
            end),
            ok = gen_tcp:controlling_process(Sock, Handler),
            Handler ! go,
            silent_accept_loop(LSock);
        {error, timeout} ->
            silent_accept_loop(LSock);
        {error, _Closed} ->
            ok
    end.

%% @private Complete the raw handshake + an anonymous WELCOME, then read-and-
%% discard all inbound frames (pings included) until the client closes the
%% socket — deliberately never sending a pong.
serve_silent(Sock) ->
    ok = serve_welcome(Sock),
    %% Stay silent: drain & drop everything (incl. pings) until the client gives
    %% up and closes the socket.
    silent_drain(Sock).

%% @private Drive a connecting client to `established`: echo the 4-octet raw
%% handshake (the non-zero serializer nibble reads as success), read-and-discard
%% the HELLO frame, then send an anonymous WELCOME. Shared by the silent and the
%% drop mock servers.
serve_welcome(Sock) ->
    %% 1. Raw handshake: echo the client's 4-octet request.
    {ok, <<16#7F, _:8, 0:16>> = Req} = gen_tcp:recv(Sock, 4, 5000),
    ok = gen_tcp:send(Sock, Req),
    %% 2. Read the HELLO frame (4-octet header + Len-octet payload); ignored.
    {ok, <<_:8, Len:24>>} = gen_tcp:recv(Sock, 4, 5000),
    {ok, _Hello} = gen_tcp:recv(Sock, Len, 5000),
    %% 3. Send an anonymous WELCOME so the client establishes the session.
    Welcome = bondy_wamp_message:welcome(erlang:unique_integer([positive]), #{
        realm => ?REALM,
        roles => #{dealer => #{}, broker => #{}},
        authid => <<"anonymous">>,
        authrole => <<"anonymous">>,
        authmethod => <<"anonymous">>
    }),
    Codec = bondy_connect_codec:new(json, 1048576, 1048576),
    {ok, Frame} = bondy_connect_codec:encode(Welcome, Codec),
    ok = gen_tcp:send(Sock, Frame),
    ok.

%% @private
silent_drain(Sock) ->
    case gen_tcp:recv(Sock, 0, infinity) of
        {ok, _Data} -> silent_drain(Sock);
        {error, _} -> ok
    end.

%% @private Start a mock raw-socket WAMP server that establishes *one* session
%% (handshake + WELCOME), then — on `drop_server_drop/1` — closes both the live
%% socket and the listen socket, so the client reconnects into a refused port.
%% Returns an opaque handle for `drop_server_port/1`, `drop_server_drop/1` and
%% `stop_drop_server/1`.
start_drop_server() ->
    {ok, LSock} = gen_tcp:listen(0, [
        binary,
        {ip, {127, 0, 0, 1}},
        {active, false},
        {reuseaddr, true},
        {packet, 0}
    ]),
    {ok, Port} = inet:port(LSock),
    Acceptor = spawn(fun() ->
        receive
            go -> drop_accept(LSock)
        end
    end),
    ok = gen_tcp:controlling_process(LSock, Acceptor),
    Acceptor ! go,
    {drop_server, Port, Acceptor}.

%% @private
drop_server_port({drop_server, Port, _Acceptor}) ->
    Port.

%% @private Tell the server to vanish: drop the live socket and stop listening.
drop_server_drop({drop_server, _Port, Acceptor}) ->
    Acceptor ! drop,
    ok.

%% @private
stop_drop_server({drop_server, _Port, Acceptor}) ->
    _ = exit(Acceptor, kill),
    ok.

%% @private Accept exactly one connection, establish it, then wait for the
%% `drop' cue (or a generous timeout) before closing both sockets.
drop_accept(LSock) ->
    {ok, Sock} = gen_tcp:accept(LSock, 5000),
    ok = serve_welcome(Sock),
    receive
        drop -> ok
    after 10000 -> ok
    end,
    _ = gen_tcp:close(Sock),
    _ = gen_tcp:close(LSock),
    ok.

%% @private The TCP socket port owned by a connection process (`undefined` if
%% there is not exactly one — e.g. mid-reconnect between close and re-connect).
%% Lets a test inject a synthetic `{tcp, Port, _}` and observe the post-reconnect
%% socket swap without depending on the connection's private record layout.
socket_port(Conn) ->
    Pid = conn_pid(Conn),
    Ports = [
        P
     || P <- erlang:ports(),
        erlang:port_info(P, connected) =:= {connected, Pid},
        erlang:port_info(P, name) =:= {name, "tcp_inet"}
    ],
    case Ports of
        [P] -> P;
        _ -> undefined
    end.

%% @private The underlying connection process pid behind an opaque conn() handle.
%% White-box tests need the raw pid to inject socket messages / probe liveness.
conn_pid({bondy_connect_client, Pid}) when is_pid(Pid) -> Pid;
conn_pid(Pid) when is_pid(Pid) -> Pid.

%% @private Poll `Fun` until it returns `true` (or fail after Tries x SleepMs).
wait_until(_Fun, 0, _Sleep) ->
    ct:fail(condition_not_met);
wait_until(Fun, Tries, Sleep) ->
    case Fun() of
        true ->
            ok;
        _ ->
            timer:sleep(Sleep),
            wait_until(Fun, Tries - 1, Sleep)
    end.

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
                    <<"wamp.subscribe">>,
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
