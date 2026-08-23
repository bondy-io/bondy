%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_conformance_SUITE).

-moduledoc """
The canonical WAMP suite: one case list, run on every transport.

A WAMP use case is a property of the session, not of the pipe under it, so each
case here is written once and CT runs it once per transport — one group per
entry in `bondy_connect_ct:transports/0`. A case names no transport and reaches
the wire only through `bondy_connect_ct:connect/1`.

The point is the report. Reading it down a column tells you which transports
carry a use case; reading across a row tells you what a transport carries. A
use case that a transport cannot support is not omitted from its group — it is
skipped with the reason, so the matrix has no silent holes.

Cases that are about a transport rather than about WAMP — a bad upgrade path,
an oversize frame, SSE event fragmentation, a long-poll cycle expiring — belong
in that transport's own suite and are deliberately not here.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-compile([nowarn_export_all, export_all]).

%% The HTTP transports carry an event no faster than a poll cycle, so the
%% receive timeouts below are sized for the slowest transport rather than per
%% group: a case that passes only because it ran on a socket is not evidence
%% about long-poll.
-define(RECV_TIMEOUT, 15000).

%% A handler that outlives any reply the cases wait for, so a reply arriving
%% at all is evidence of a cancel rather than of the call completing.
-define(SLOW_MS, 30000).

%% The idle window `keepalive_survives_idle' waits out.
%%
%% Sized against the horizon of a connection that pings and never counts a
%% pong, NOT against the ping interval: `bondy_connect_keepalive' retries an
%% unanswered ping `max_attempts' times at `timeout' apiece before declaring
%% the link dead, so with that case's config (idle 200, timeout 500, 2
%% attempts) such a connection is down by ~1200ms. Waiting 2.5x that is what
%% makes the case fail if the pong is never sent, never received, or received
%% and not counted as activity.
%%
%% 500ms is not a tight deadline for the pong itself: a probe run with
%% `timeout' set to 1ms still passed on all five transports, so on loopback the
%% pong is back inside a millisecond.
%%
%% What this does NOT establish: that the pings are why the session survived.
%% The router's own idle timeout on these listeners is far longer than this
%% window, so nothing would have closed the session inside it anyway. The case
%% is a guard against the CLIENT tearing down a healthy link, not evidence that
%% the router needed convincing to keep it.
-define(IDLE_MS, 3000).

suite() ->
    [{timetrap, {minutes, 5}}].

all() ->
    [{group, T} || T <- bondy_connect_ct:transports()].

groups() ->
    [{T, [], cases()} || T <- bondy_connect_ct:transports()].

-doc "The WAMP use cases, in the order a session would exercise them.".
cases() ->
    [
        anonymous_establishes,
        wampcra_establishes,
        cryptosign_establishes,
        ticket_establishes,
        wrong_password_aborts,
        json_payload_round_trip,
        msgpack_payload_round_trip,
        cbor_payload_round_trip,
        call_round_trip,
        pubsub_round_trip,
        unregister_stops_routing,
        disconnect_stops_routing,
        router_closed_session_is_observed,
        handler_error_propagates,
        handler_crash_isolation,
        per_call_timeout,
        cancel_skip,
        cancel_killnowait,
        cancel_kill_interrupts_callee,
        progressive_results,
        progressive_input,
        progressive_input_ordering,
        progressive_results_need_opt_in,
        keepalive_survives_idle,
        reconnect_replays_registration
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    {ok, _} = application:ensure_all_started(bondy_connect_sdk),
    [
        {cacertfile, bondy_connect_ct:cacertfile()},
        {keypair, bondy_wamp_cryptosign:generate_key()},
        {dealer_features, [
            {F, dealer_feature(F)}
         || F <- [progressive_call_results, progressive_calls]
        ]}
        | Config
    ].

end_per_suite(_) ->
    ok.

init_per_group(Transport, Config) ->
    ok = bondy_connect_ct:add_realm(Transport),
    ok = bondy_connect_ct:add_auth_realms(Transport, Config),
    [{transport, Transport} | Config].

end_per_group(_, _) ->
    ok.

%% Both progressive dealer features are ON at boot -- measured, not assumed:
%% `bondy_config:setup_wamp/0' seats them from `?DEALER_FEATURES', which builds
%% on `?COMMON_RPC_FEATURES' where both are `true', and no `bondy.conf' key
%% exists to say otherwise. Several comments in the tree still describe them as
%% shipping default-off.
%%
%% They are set here anyway, because the value is global to the node and
%% `bondy_connect_rpc_SUITE:end_per_testcase/2' leaves both `false'; sharing a
%% CT node with that suite would otherwise decide these cases. What is restored
%% afterwards is whatever `init_per_suite' observed, NOT a literal -- writing
%% `false' back is how a suite leaves the next one's outcome depending on
%% running order.
init_per_testcase(Case, Config) ->
    ok = bondy_connect_ct:drain_events(),
    case
        bondy_connect_ct:unsupported(?config(transport, Config), needs(Case))
    of
        {true, Reason} ->
            {skip, Reason};
        false ->
            case lists:prefix("progressive", atom_to_list(Case)) of
                true ->
                    ok = set_dealer_feature(progressive_call_results, true),
                    ok = set_dealer_feature(progressive_calls, true);
                false ->
                    ok
            end,
            Config
    end.

end_per_testcase(_Case, Config) ->
    lists:foreach(
        fun({Feature, Value}) -> ok = set_dealer_feature(Feature, Value) end,
        ?config(dealer_features, Config)
    ).

%% =============================================================================
%% TESTS
%% =============================================================================

-doc """
A client offering only `anonymous` establishes a session.

The realm has `security_enabled`, so this is a negotiated method rather than
security being off.
""".
anonymous_establishes(Config) ->
    Conn = bondy_connect_ct:connect(Config),
    ?assertEqual(established, bondy_connect_client:status(Conn)),
    ok = bondy_connect_client:disconnect(Conn).

-doc """
WAMP-CRA: the router CHALLENGEs, the client signs the challenge with a key
derived from its password, and the router WELCOMEs.

Reaching `established` is the whole assertion because the realm offers no other
method — see `wrong_password_aborts` for the evidence that it discriminates.
""".
wampcra_establishes(Config) ->
    {ok, Conn} = bondy_connect_client:connect(
        auth_spec(Config, cra, #{
            method => ?WAMP_CRA_AUTH,
            authid => bondy_connect_ct:user(),
            password => bondy_connect_ct:password()
        })
    ),
    ?assertEqual(established, bondy_connect_client:status(Conn)),
    ok = bondy_connect_client:disconnect(Conn).

-doc """
Cryptosign: the client signs the router's challenge with the secret half of the
only key the user is authorized to use.
""".
cryptosign_establishes(Config) ->
    #{secret := Secret} = ?config(keypair, Config),
    {ok, Conn} = bondy_connect_client:connect(
        auth_spec(Config, cryptosign, #{
            method => ?WAMP_CRYPTOSIGN_AUTH,
            authid => bondy_connect_ct:user(),
            privkey => bondy_wamp_cryptosign:encode_hex(Secret)
        })
    ),
    ?assertEqual(established, bondy_connect_client:status(Conn)),
    ok = bondy_connect_client:disconnect(Conn).

-doc """
Ticket: a ticket issued by an already-authenticated session authenticates a
fresh connection.

The ticket is a real one from `bondy_ticket:issue/2`, not a fixture, so this
also covers the router verifying it.
""".
ticket_establishes(Config) ->
    Ticket = bondy_connect_ct:issue_ticket(?config(transport, Config)),
    {ok, Conn} = bondy_connect_client:connect(
        auth_spec(Config, ticket, #{
            method => ?WAMP_TICKET_AUTH,
            authid => bondy_connect_ct:user(),
            ticket => Ticket
        })
    ),
    ?assertEqual(established, bondy_connect_client:status(Conn)),
    ok = bondy_connect_client:disconnect(Conn).

-doc """
A wrong password is refused, and the refusal reaches the client.

This is what makes the three cases above evidence rather than a claim that
`connect/1` returns `{ok, _}`: the same realm, the same user, the same method,
one byte of credential different, and the outcome inverts.

It is also the only case here that puts an ABORT on the wire. On a polled
transport that reply is produced during the HELLO exchange and delivered on a
later cycle, so a client seeing it at all is evidence the queue carries
handshake replies and not only routed messages.
""".
wrong_password_aborts(Config) ->
    Spec = auth_spec(Config, cra, #{
        method => ?WAMP_CRA_AUTH,
        authid => bondy_connect_ct:user(),
        password => <<"not-the-password">>
    }),
    ?assertMatch(
        {error, {abort, ?WAMP_AUTHENTICATION_FAILED, _}},
        bondy_connect_client:connect(Spec)
    ).

-doc """
A rich payload survives a call and its result under `json`.

Run on every transport, including `local`, where nothing is encoded at all —
which makes it the control the two encoded cases are compared against.
""".
json_payload_round_trip(Config) ->
    payload_round_trip(Config, json).

-doc "The same payload under `msgpack`, on the transports that negotiate it.".
msgpack_payload_round_trip(Config) ->
    payload_round_trip(Config, msgpack).

-doc "The same payload under `cbor`, on the transports that negotiate it.".
cbor_payload_round_trip(Config) ->
    payload_round_trip(Config, cbor).

-doc """
A callee registers, a caller calls it, and the result comes back.

One connection acts as both, so a failure is the transport rather than routing
between two of them.
""".
call_round_trip(Config) ->
    Uri = <<"com.example.conformance.echo">>,
    Conn = bondy_connect_ct:connect(Config),
    ?assertEqual(established, bondy_connect_client:status(Conn)),

    {ok, _} = bondy_connect_client:register(
        Conn, Uri, bondy_connect_ct:echo_handler()
    ),
    {ok, Result} = bondy_connect_client:call(Conn, Uri, [<<"hi">>]),
    ?assertEqual([<<"hi">>], maps:get(args, Result)),

    ok = bondy_connect_client:disconnect(Conn).

-doc """
A subscriber receives an event published by a second connection.

Two connections, so the event crosses the broker and is delivered on the
subscriber's own transport rather than being echoed back on the publisher's.
""".
pubsub_round_trip(Config) ->
    Topic = <<"com.example.conformance.topic">>,
    Self = self(),
    Sub = bondy_connect_ct:connect(Config),
    Pub = bondy_connect_ct:connect(Config),

    {ok, _} = bondy_connect_client:subscribe(
        Sub, Topic, bondy_connect_ct:event_handler(Self)
    ),
    ok = bondy_connect_client:publish(Pub, Topic, [<<"ping">>]),

    receive
        {event, Args} ->
            ?assertEqual([<<"ping">>], Args)
    after ?RECV_TIMEOUT ->
        ct:fail({no_event, ?config(transport, Config)})
    end,

    ok = bondy_connect_client:disconnect(Sub),
    ok = bondy_connect_client:disconnect(Pub).

-doc """
An unregistered procedure is no longer routed.

Register then unregister, and a caller on a second connection gets
`wamp.error.no_such_procedure` — so the case fails both if UNREGISTER never
reached the dealer and if the call never reached it either.
""".
unregister_stops_routing(Config) ->
    Uri = <<"com.example.conformance.transient">>,
    Callee = bondy_connect_ct:connect(Config),
    {ok, RegId} = bondy_connect_client:register(
        Callee, Uri, bondy_connect_ct:echo_handler()
    ),
    ok = bondy_connect_client:unregister(Callee, RegId),

    Caller = bondy_connect_ct:connect(Config),
    ?assertMatch(
        {error, #{kind := wamp, uri := <<"wamp.error.no_such_procedure">>}},
        bondy_connect_client:call(Caller, Uri, [])
    ),

    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
A disconnected callee's registration stops routing.

The same shape as `unregister_stops_routing`, but the callee never says
anything — it just goes away, which is what a crashed client does. The dealer
has to notice on its own, and until it does, a call to that URI is routed to a
process that no longer exists and the caller waits out its timeout with no
error to explain it.

This case exists because a shared procedure URI between two earlier cases hit
exactly that on one transport: the second caller's CALL was answered by
nothing, not by `no_such_procedure`.
""".
disconnect_stops_routing(Config) ->
    Uri = <<"com.example.conformance.departed">>,
    Callee = bondy_connect_ct:connect(Config),
    {ok, _} = bondy_connect_client:register(
        Callee, Uri, bondy_connect_ct:echo_handler()
    ),
    ok = bondy_connect_client:disconnect(Callee),

    Caller = bondy_connect_ct:connect(Config),
    ?assertMatch(
        {error, #{kind := wamp, uri := <<"wamp.error.no_such_procedure">>}},
        bondy_connect_client:call(Caller, Uri, [])
    ),

    ok = bondy_connect_client:disconnect(Caller).

-doc """
A session the router closes is observed by the client: it goes `down`, and the
next request says so instead of hanging.

The router's `GOODBYE` is how an administrative close, a disabled realm and a
credential revocation all reach a client, so what a client does with one is a
property of every transport rather than of any single one.

No reconnect follows, on any transport. A `GOODBYE` is a graceful close and
`bondy_connect_connection:is_retriable/1` does not cover it, which is why
`reconnect_replays_registration` stages its drop with a kill instead — the two
cases exercise opposite halves of the same lifecycle and neither substitutes
for the other.

This is the only case that reaches the in-VM transport's session-loss path.
`reconnect_replays_registration` cannot: its drop kills the session's owner,
which in-VM is the client itself.
""".
router_closed_session_is_observed(Config) ->
    Uri = <<"com.example.conformance.closed">>,
    Conn = bondy_connect_ct:connect(Config),
    {ok, _} = bondy_connect_client:register(
        Conn, Uri, bondy_connect_ct:echo_handler()
    ),
    {ok, Before} = bondy_connect_client:call(Conn, Uri, [<<"a">>]),
    ?assertEqual([<<"a">>], maps:get(args, Before)),

    Closed = bondy_connect_ct:close_sessions(
        ?config(transport, Config), ?WAMP_CLOSE_NORMAL
    ),
    ?assert(Closed >= 1),

    ok = wait_until(fun() ->
        bondy_connect_client:status(Conn) =:= down
    end),
    ?assertEqual(
        {error, #{kind => client, reason => not_connected}},
        bondy_connect_client:call(Conn, Uri, [<<"b">>])
    ).

-doc """
A callee's application error reaches the caller with its own URI intact.

The URI is a custom one, so a transport that lost it and substituted a generic
error would fail rather than pass on a near-enough match.
""".
handler_error_propagates(Config) ->
    Uri = <<"com.example.conformance.err">>,
    Callee = bondy_connect_ct:connect(Config),
    Failing = fun(_, _, _) ->
        {error, #{uri => <<"com.example.business_error">>}}
    end,
    {ok, _} = bondy_connect_client:register(Callee, Uri, Failing),

    Caller = bondy_connect_ct:connect(Config),
    ?assertMatch(
        {error, #{kind := wamp, uri := <<"com.example.business_error">>}},
        bondy_connect_client:call(Caller, Uri, [])
    ),

    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
A crashing handler errors that one call and leaves the connection usable.

The second call is the point: it proves the callee's transport survived the
crash, not merely that the caller heard about it.
""".
handler_crash_isolation(Config) ->
    Boom = <<"com.example.conformance.crash">>,
    Alive = <<"com.example.conformance.still_ok">>,
    Callee = bondy_connect_ct:connect(Config),
    {ok, _} = bondy_connect_client:register(
        Callee, Boom, fun(_, _, _) -> error(boom) end
    ),

    Caller = bondy_connect_ct:connect(Config),
    ?assertMatch(
        {error, #{kind := wamp, uri := ?BONDY_CONNECT_INTERNAL_ERROR}},
        bondy_connect_client:call(Caller, Boom, [])
    ),

    ?assertEqual(established, bondy_connect_client:status(Callee)),
    {ok, _} = bondy_connect_client:register(
        Callee, Alive, bondy_connect_ct:echo_handler()
    ),
    {ok, R} = bondy_connect_client:call(Caller, Alive, [<<"alive">>]),
    ?assertEqual([<<"alive">>], maps:get(args, R)),

    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
A per-call timeout fires client-side while the callee is still working.

The handler outlasts the timeout by two orders of magnitude, so the deadline
cannot be met by the call simply completing first on a fast transport.
""".
per_call_timeout(Config) ->
    Uri = <<"com.example.conformance.slow">>,
    Callee = bondy_connect_ct:connect(Config),
    {ok, _} = bondy_connect_client:register(Callee, Uri, slow()),

    Caller = bondy_connect_ct:connect(Config),
    ?assertEqual(
        {error, #{kind => client, reason => timeout}},
        bondy_connect_client:call(Caller, Uri, [], #{}, #{timeout => 300})
    ),

    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
CANCEL with `skip`: the caller is released without interrupting the callee.
""".
cancel_skip(Config) ->
    cancel_releases_caller(Config, skip, <<"com.example.conformance.c.skip">>).

-doc """
CANCEL with `killnowait`: the caller is released and the callee is interrupted
without the router waiting for it to acknowledge.
""".
cancel_killnowait(Config) ->
    cancel_releases_caller(
        Config, killnowait, <<"com.example.conformance.c.kn">>
    ).

-doc """
CANCEL with `kill`: the callee is interrupted and survives to serve a fresh
call, which is what separates interrupting a worker from dropping the session.
""".
cancel_kill_interrupts_callee(Config) ->
    Uri = <<"com.example.conformance.c.kill">>,
    Alive = <<"com.example.conformance.c.ok">>,
    Callee = bondy_connect_ct:connect(Config),
    {ok, _} = bondy_connect_client:register(Callee, Uri, slow()),
    {ok, _} = bondy_connect_client:register(
        Callee, Alive, bondy_connect_ct:echo_handler()
    ),

    Caller = bondy_connect_ct:connect(Config),
    {ok, Token} = bondy_connect_client:call_async(Caller, Uri, []),
    ok = bondy_connect_client:cancel(Caller, Token, kill),
    ok = assert_cancelled(Token),

    ?assertEqual(established, bondy_connect_client:status(Callee)),
    {ok, R} = bondy_connect_client:call(Caller, Alive, [<<"alive">>]),
    ?assertEqual([<<"alive">>], maps:get(args, R)),

    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
A callee streams two progressive results before its final one.

Asserts the order they were yielded in, that only the interim ones carry
`progress`, and that the terminal reply is terminal.
""".
progressive_results(Config) ->
    Uri = <<"com.example.conformance.progressive">>,
    Callee = bondy_connect_ct:connect(Config),
    Handler = fun(_, _, Details) ->
        Progress = maps:get(progress, Details),
        ok = Progress([1], #{}),
        ok = Progress([2], #{}),
        {ok, #{args => [3]}}
    end,
    {ok, _} = bondy_connect_client:register(Callee, Uri, Handler),

    Caller = bondy_connect_ct:connect(Config),
    {ok, Token} = bondy_connect_client:call_async(
        Caller, Uri, [], #{}, #{receive_progress => true}
    ),

    P1 = next_reply(Token),
    ?assertMatch({progress, #{args := [1]}}, P1),
    {progress, #{details := D1}} = P1,
    ?assertEqual(true, maps:get(progress, D1)),

    ?assertMatch({progress, #{args := [2]}}, next_reply(Token)),

    Final = next_reply(Token),
    ?assertMatch({ok, #{args := [3]}}, Final),
    {ok, #{details := DF}} = Final,
    ?assertNot(maps:get(progress, DF, false)),

    ok = assert_terminal(Token),

    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
The caller streams three argument chunks and the callee pulls them.

The callee sums the chunks, so a lost chunk changes the total.
""".
progressive_input(Config) ->
    Uri = <<"com.example.conformance.progressive.input">>,
    Callee = bondy_connect_ct:connect(Config),
    Handler = fun([First], _, Details) ->
        Input = maps:get(input, Details),
        {ok, #{args => [collect_sum(Input, First)]}}
    end,
    {ok, _} = bondy_connect_client:register(Callee, Uri, Handler),

    Caller = bondy_connect_ct:connect(Config),
    {ok, Token} = bondy_connect_client:call_stream(Caller, Uri, [1], #{}, #{}),
    ok = bondy_connect_client:send_input(Caller, Token, [2], #{}),
    ok = bondy_connect_client:finish_input(Caller, Token, [3], #{}),

    ?assertMatch({ok, #{args := [6]}}, next_reply(Token)),
    ok = assert_terminal(Token),

    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
Twenty input chunks arrive at the callee in the order the caller sent them.

The callee collects them into a list rather than summing, so a reordering shows
up -- addition would hide it. This is the strongest ordering claim in the
suite, and the one most likely to separate a streaming transport from a
request/response one.
""".
progressive_input_ordering(Config) ->
    N = 20,
    Uri = <<"com.example.conformance.progressive.ordering">>,
    Callee = bondy_connect_ct:connect(Config),
    Handler = fun([First], _, Details) ->
        Input = maps:get(input, Details),
        {ok, #{args => [collect_list(Input, [First])]}}
    end,
    {ok, _} = bondy_connect_client:register(Callee, Uri, Handler),

    Caller = bondy_connect_ct:connect(Config),
    {ok, Token} = bondy_connect_client:call_stream(Caller, Uri, [1], #{}, #{}),
    _ = [
        ok = bondy_connect_client:send_input(Caller, Token, [I], #{})
     || I <- lists:seq(2, N - 1)
    ],
    ok = bondy_connect_client:finish_input(Caller, Token, [N], #{}),

    {ok, #{args := [Collected]}} = next_reply(Token),
    ?assertEqual(lists:seq(1, N), Collected),

    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
A caller that does not announce `progressive_call_results` does not negotiate
it, even with the dealer feature on and `receive_progress` requested.

This is the negotiation that makes the feature safe to have on by default: the
router offers it, and only a client that asked in HELLO is given it.

What the callee observes is the evidence. The `progress` fun is injected into
the handler's details PER INVOCATION, and only when the caller negotiated the
feature -- so its absence is the router's answer, reported back through the
result rather than asserted inside the handler, where a failure would surface
as an opaque internal error. The caller still receives its final result: the
degrade is silent, not an error.
""".
progressive_results_need_opt_in(Config) ->
    Uri = <<"com.example.conformance.progressive.optin">>,
    Callee = bondy_connect_ct:connect(Config),
    Handler = fun(_, _, Details) ->
        {ok, #{args => [maps:is_key(progress, Details)]}}
    end,
    {ok, _} = bondy_connect_client:register(Callee, Uri, Handler),

    Caller = bondy_connect_ct:connect(Config, #{roles => caller_no_progress()}),
    {ok, Token} = bondy_connect_client:call_async(
        Caller, Uri, [], #{}, #{receive_progress => true}
    ),

    ?assertMatch({ok, #{args := [false]}}, next_reply(Token)),
    ok = assert_terminal(Token),

    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

%% =============================================================================
%% PRIVATE
%% =============================================================================

-doc """
A client whose link is dropped reconnects and its registration works again.

The drop is abrupt — the router-side session owner is killed, so there is no
GOODBYE and nothing on the wire — which is the case a reconnecting client
exists for.

One connection is both callee and caller, so the assertion needs no second
session: the CALL can only be answered if the registration was replayed onto
the new session, since the old one died with its owner.

The kill count is asserted, because a drop helper that found nothing would
leave this case green over a link that was never broken.

Both waits are polled rather than slept: a reconnect has a backoff, and the
replay lands some time after the session reports `established`.
""".
reconnect_replays_registration(Config) ->
    Uri = <<"com.example.conformance.replayed">>,
    Conn = bondy_connect_ct:connect(Config),
    {ok, _} = bondy_connect_client:register(
        Conn, Uri, bondy_connect_ct:echo_handler()
    ),
    {ok, Before} = bondy_connect_client:call(Conn, Uri, [<<"a">>]),
    ?assertEqual([<<"a">>], maps:get(args, Before)),

    Killed = bondy_connect_ct:drop_sessions(?config(transport, Config)),
    ?assert(Killed >= 1),

    ok = wait_until(fun() ->
        bondy_connect_client:status(Conn) =:= established
    end),
    ok = wait_until(fun() ->
        case bondy_connect_client:call(Conn, Uri, [<<"b">>]) of
            {ok, #{args := [<<"b">>]}} -> true;
            _ -> false
        end
    end),

    ok = bondy_connect_client:disconnect(Conn).

-doc """
An idle session is kept alive by ping/pong, and still works afterwards.

`?IDLE_MS` is sized against the give-up horizon of a connection whose pings go
unanswered, not against the ping interval — see the macro. A case that merely
slept "a few ping intervals" would pass with zero pongs, because an unanswered
ping is retried `max_attempts` times at `timeout` apiece before the link is
declared dead.

Both halves are checked: that the session is still established, and that it can
still carry a call, since a connection can report `established` while its
transport has quietly stopped moving bytes.

Only run where the pong comes from the router. The transports that answer their
own ping are skipped rather than shown green — see
`bondy_connect_ct:unsupported/2`.
""".
keepalive_survives_idle(Config) ->
    Uri = <<"com.example.conformance.keepalive">>,
    Conn = bondy_connect_ct:connect(Config, #{
        ping => #{
            enabled => true,
            idle_timeout => 200,
            timeout => 500,
            max_attempts => 2
        }
    }),
    {ok, _} = bondy_connect_client:register(
        Conn, Uri, bondy_connect_ct:echo_handler()
    ),

    timer:sleep(?IDLE_MS),

    ?assertEqual(established, bondy_connect_client:status(Conn)),
    {ok, Result} = bondy_connect_client:call(Conn, Uri, [<<"still here">>]),
    ?assertEqual([<<"still here">>], maps:get(args, Result)),

    ok = bondy_connect_client:disconnect(Conn).

%% @private The payload every serializer case round-trips.
%%
%% Deliberately restricted to the types WAMP itself defines, because that is
%% the portability claim being tested: what a client may put in a CALL and
%% expect back unchanged whatever the peers negotiated. Types only some codecs
%% carry — a non-UTF-8 binary, a non-string map key, an integer beyond a
%% double's exact range — are not WAMP types and are not here; they belong to a
%% case about one codec, not to one that asserts three agree.
%%
%% It travels twice per case: caller -> callee in the CALL, and back in the
%% RESULT. A codec that were asymmetric would show as an inequality on the
%% return leg only.
payload() ->
    Args = [
        <<"ascii">>,
        <<"unicode: äöü 日本語 🎉"/utf8>>,
        <<>>,
        0,
        -1,
        42,
        3.5,
        -0.125,
        true,
        false,
        [],
        [1, [2, [3]]]
    ],
    KWArgs = #{
        <<"nested">> => #{
            <<"a">> => [1, 2, 3],
            <<"b">> => #{<<"c">> => <<"d">>}
        },
        <<"empty_map">> => #{},
        <<"empty_list">> => []
    },
    {Args, KWArgs}.

%% @private
payload_round_trip(Config, Serializer) ->
    Name = atom_to_binary(Serializer, utf8),
    Uri = <<"com.example.conformance.payload.", Name/binary>>,
    {Args, KWArgs} = payload(),

    Conn = bondy_connect_ct:connect(Config, #{serializers => [Serializer]}),
    Handler = fun(A, K, _) -> {ok, #{args => A, kwargs => K}} end,
    {ok, _} = bondy_connect_client:register(Conn, Uri, Handler),

    {ok, Result} = bondy_connect_client:call(Conn, Uri, Args, KWArgs),
    ?assertEqual(Args, maps:get(args, Result)),
    ?assertEqual(KWArgs, maps:get(kwargs, Result)),

    ok = bondy_connect_client:disconnect(Conn).

%% @private What a case needs beyond an established session, so
%% `bondy_connect_ct:unsupported/2' can say whether the group's transport has
%% it. Every case absent from this list needs nothing beyond a session, which
%% is why the catch-all answers `none' rather than raising: a new case is
%% assumed portable until a transport is shown not to carry it.
needs(wampcra_establishes) -> credential_auth;
needs(cryptosign_establishes) -> credential_auth;
needs(ticket_establishes) -> credential_auth;
needs(wrong_password_aborts) -> credential_auth;
needs(msgpack_payload_round_trip) -> {serializer, msgpack};
needs(cbor_payload_round_trip) -> {serializer, cbor};
needs(keepalive_survives_idle) -> router_pong;
needs(reconnect_replays_registration) -> transport_drop;
needs(_) -> none.

%% @private Poll `Fun' until it answers `true', up to ?RECV_TIMEOUT.
%%
%% Polled, not slept: the two things this suite waits on after a drop — a
%% reconnect and the replay that follows it — have no event a test can observe,
%% and a fixed sleep would either be flaky or be sized for the slowest machine
%% anyone ever runs this on.
wait_until(Fun) ->
    wait_until(Fun, ?RECV_TIMEOUT div 100).

%% @private
wait_until(_Fun, 0) ->
    {error, timeout};
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        _ ->
            timer:sleep(100),
            wait_until(Fun, N - 1)
    end.

%% @private The spec for a case authenticating with `Method' on the group's
%% transport. Built rather than connected, because the negative case needs the
%% `{error, _}` that `bondy_connect_ct:connect/2' asserts away.
auth_spec(Config, Method, Auth) ->
    Transport = ?config(transport, Config),
    bondy_connect_ct:spec(Transport, Config, #{
        realm => bondy_connect_ct:auth_realm(Transport, Method),
        auth => Auth
    }).

%% @private A caller role announcing everything the SDK normally does EXCEPT
%% `progressive_call_results'. `call_canceling' has to stay: the router rejects
%% a HELLO asking for progressive results without it
%% (`bondy_wamp_details:validate/1'), so dropping both would fail the handshake
%% rather than test the negotiation. The spec's `roles' replaces the SDK
%% default wholesale, so this is the complete announcement.
caller_no_progress() ->
    #{
        caller => #{
            features => #{
                call_timeout => true,
                call_canceling => true,
                caller_identification => true,
                call_retries => true,
                progressive_calls => true
            }
        }
    }.

%% @private
set_dealer_feature(Feature, Bool) when is_boolean(Bool) ->
    bondy_config:set([wamp, dealer, features, Feature], Bool).

%% @private
dealer_feature(Feature) ->
    bondy_config:get([wamp, dealer, features, Feature], false).

%% @private The next reply for a token, sized for the slowest transport.
next_reply(Token) ->
    receive
        {bondy_connect_client, Token, Reply} -> Reply
    after ?RECV_TIMEOUT ->
        ct:fail(no_reply)
    end.

%% @private Nothing further arrives for a token that already got its terminal
%% reply. A bounded negative check: it would not catch a duplicate latent for
%% longer than the window, which is sized to keep 8 groups affordable.
assert_terminal(Token) ->
    receive
        {bondy_connect_client, Token, Extra} -> ct:fail({extra_reply, Extra})
    after 1000 -> ok
    end.

%% @private Pull every input chunk, summing them.
collect_sum(Input, Acc) ->
    case Input() of
        {more, [N], _} -> collect_sum(Input, Acc + N);
        {last, [N], _} -> Acc + N
    end.

%% @private Pull every input chunk, keeping arrival order.
collect_list(Input, Acc) ->
    case Input() of
        {more, [N], _} -> collect_list(Input, [N | Acc]);
        {last, [N], _} -> lists:reverse([N | Acc])
    end.

%% @private A handler that never returns in time to be mistaken for a reply.
slow() ->
    fun(_, _, _) ->
        timer:sleep(?SLOW_MS),
        {ok, #{args => [<<"too_late">>]}}
    end.

%% @private Call a slow procedure asynchronously, cancel it with `Mode', and
%% require the caller to be released with `wamp.error.canceled'.
cancel_releases_caller(Config, Mode, Uri) ->
    Callee = bondy_connect_ct:connect(Config),
    {ok, _} = bondy_connect_client:register(Callee, Uri, slow()),

    Caller = bondy_connect_ct:connect(Config),
    {ok, Token} = bondy_connect_client:call_async(Caller, Uri, []),
    ok = bondy_connect_client:cancel(Caller, Token, Mode),
    ok = assert_cancelled(Token),

    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

%% @private The only reply a cancelled call can produce. `slow/0' outlasts the
%% timeout, so a transport that dropped the CANCEL times out here rather than
%% delivering the handler's result.
assert_cancelled(Token) ->
    receive
        {bondy_connect_client, Token, Reply} ->
            ?assertMatch(
                {error, #{kind := wamp, uri := ?WAMP_CANCELLED}}, Reply
            ),
            ok
    after ?RECV_TIMEOUT ->
        ct:fail(no_cancel_reply)
    end.
