%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_transport_longpoll_SUITE).

-moduledoc """
**WAMP over HTTP long-poll** integration tests, driving the SDK's
`m:bondy_connect_transport_longpoll` against the live Bondy `api_gateway_http`
listener (port 18080, which `bondy_ct` starts with the `wamp_longpoll` service).

Establishing a session and carrying WAMP over it are not tested here: every
WAMP use case runs on `longpoll` in `bondy_connect_conformance_SUITE`, server
push included.

What is left is what only a polled transport can get wrong:

- **push while the client is not polling** — the message must survive in
  `bondy_http_transport_queue` and arrive on the next poll, which is the whole
  reason that queue exists;
- a quiet link outlives the server's `poll_timeout`, so a `204` is not mistaken
  for a failure;
- oversized outbound and a bad path both fail cleanly rather than hanging.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.bondy_connect.longpoll">>).
-define(HOST, "127.0.0.1").
-define(PORT, 18080).
-define(TRANSPORT, bondy_connect_transport_longpoll).

all() ->
    [
        longpoll_push_while_idle_is_queued,
        longpoll_survives_server_poll_timeout,
        longpoll_outbound_too_large_rejected,
        longpoll_bad_path_fails
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    {ok, _} = application:ensure_all_started(bondy_connect_sdk),
    ok = add_anon_realm(?REALM),
    Config.

end_per_suite(_) ->
    ok.

%% =============================================================================
%% TESTS
%% =============================================================================

%% The `/open' handshake plus the poll loop is enough to reach `established'.
%% Asserted on its own because every other case depends on it, and a failure
%% here means the handshake rather than the feature under test.
longpoll_push_while_idle_is_queued(_) ->
    Topic = <<"com.example.res.longpoll.idle">>,
    Self = self(),
    Sub = connect(),
    Pub = connect(),

    {ok, _} = bondy_connect_client:subscribe(Sub, Topic, event_handler(Self)),

    %% Drain anything already in flight so the assertion is about THIS event.
    ok = quiesce(),

    %% Two connections in this case, so two pollers; the subscriber's is the
    %% one whose events we are asserting on. Suspend BOTH — the publisher's
    %% poll loop is irrelevant to the assertion and suspending it costs
    %% nothing, which avoids having to tell two identical processes apart.
    Pollers = pollers(2),
    ok = lists:foreach(fun suspend_poller/1, Pollers),

    ok = bondy_connect_client:publish(Pub, Topic, [<<"queued">>]),

    %% Nothing can arrive while the poller is suspended: no `/receive' is in
    %% flight, so the server has nowhere to put the event but the queue.
    receive
        {event, Early} ->
            ct:fail({event_arrived_with_poller_suspended, Early})
    after 2000 ->
        ok
    end,

    ok = lists:foreach(fun resume_poller/1, Pollers),

    receive
        {event, Args} ->
            ?assertEqual([<<"queued">>], Args)
    after 15000 ->
        ct:fail(queued_event_never_delivered)
    end,

    ok = bondy_connect_client:disconnect(Sub),
    ok = bondy_connect_client:disconnect(Pub).

%% A quiet link must outlive the server's own `poll_timeout' (30s by default):
%% the server answers `204' and the poller must treat that as "nothing yet"
%% rather than as a failure. Written against the transport's most likely bug —
%% a client timeout shorter than the server's would tear the session down here.
longpoll_survives_server_poll_timeout(_) ->
    Conn = connect(),
    Proc = <<"com.example.res.longpoll.quiet">>,
    {ok, _} = bondy_connect_client:register(Conn, Proc, echo_handler()),

    %% Idle across at least one full server-side poll cycle.
    timer:sleep(35000),

    ?assertEqual(established, bondy_connect_client:status(Conn)),
    {ok, R} = bondy_connect_client:call(Conn, Proc, [<<"still here">>]),
    ?assertEqual([<<"still here">>], maps:get(args, R)),
    ok = bondy_connect_client:disconnect(Conn).

%% The outbound bound is the transport's, not the server's: a message over
%% `max_message_length' is refused before it reaches the wire.
longpoll_outbound_too_large_rejected(_) ->
    %% 2048, not 512: the HELLO this SDK sends is ~727 bytes with the four
    %% client roles, so a 512-byte bound fails the HANDSHAKE and the case would
    %% be asserting on the wrong message entirely (MEASURED — the connect
    %% itself returned `{message_too_large, 727, 512}').
    {ok, Conn} = bondy_connect_client:connect(
        spec(#{
            max_message_length => 2048
        })
    ),
    ?assertEqual(established, bondy_connect_client:status(Conn)),
    Big = binary:copy(<<"x">>, 8192),
    Result = bondy_connect_client:publish(
        Conn, <<"com.example.res.longpoll.big">>, [Big]
    ),
    %% The bound is enforced before the bytes reach the wire, and the failure is
    %% returned to the CALLER rather than taking the connection down — asserted
    %% below, because a transport that killed the session on an oversized
    %% publish would still satisfy `{error, _}'.
    %%
    %% Asserted on the reason, not on `{error, _}' alone: a connection failing
    %% for any other cause would otherwise pass this case.
    ?assertMatch({error, {message_too_large, _, 2048}}, Result),
    ?assertEqual(established, bondy_connect_client:status(Conn)),
    ok = bondy_connect_client:disconnect(Conn).

%% A base path with no long-poll handler fails, and fails FAST — the failure
%% mode worth guarding is a hang, since every long-poll request is one the
%% client is prepared to wait a long time for.
longpoll_bad_path_fails(_) ->
    Result = bondy_connect_client:connect(
        spec(#{
            longpoll_path => <<"/nope/longpoll">>
        })
    ),
    %% Asserted as "never establishes" rather than as `{error, _}' from
    %% `connect/1'. `connect/1' answered `{ok, _}' here — the SDK keeps the
    %% connection process and retries under its own reconnect policy — so a
    %% case matching on the return value would have passed while the session
    %% was in fact dead, which is the opposite of what it is for.
    case Result of
        {error, _} ->
            ok;
        {ok, Conn} ->
            ?assertNotEqual(established, bondy_connect_client:status(Conn)),
            timer:sleep(2000),
            ?assertNotEqual(established, bondy_connect_client:status(Conn)),
            _ = bondy_connect_client:disconnect(Conn),
            ok
    end.

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
spec(Extra) ->
    maps:merge(
        #{
            transport => longpoll,
            endpoint => {?HOST, ?PORT},
            realm => ?REALM,
            auth => #{method => ?WAMP_ANON_AUTH},
            serializers => [json]
        },
        Extra
    ).

%% @private
connect() ->
    {ok, Conn} = bondy_connect_client:connect(spec(#{})),
    Conn.

%% @private
echo_handler() ->
    fun(Args, _, _) -> {ok, #{args => Args}} end.

%% @private
event_handler(Pid) ->
    fun(Args, _, _) ->
        Pid ! {event, Args},
        ok
    end.

%% @private Let anything already in flight land, then clear the mailbox.
quiesce() ->
    timer:sleep(500),
    drain_events().

%% @private
drain_events() ->
    receive
        {event, _} -> drain_events()
    after 0 -> ok
    end.

%% @private
%% The poller is the transport's only inbound path, and suspending it is how a
%% case creates a "client is not polling" window that does not depend on timing.
%%
%% Identified by `initial_call', not `current_function': a poller spends nearly
%% all of its life blocked inside gun waiting for `/receive', so its CURRENT
%% frame is gun's and matching on it found zero processes (MEASURED —
%% `{expected_pollers, 2, found, 0}'). `initial_call' is the spawn entry point
%% and does not move.
%%
%% Read from the scheduler rather than out of the transport's record: `conn()'
%% is opaque and its internals are not this suite's business. The helper fails
%% loudly when the count is not what the caller expected, so a case can never
%% silently suspend the wrong connection's poller — or none at all.
pollers(Expected) ->
    Pids = [
        P
     || P <- erlang:processes(),
        erlang:process_info(P, initial_call) ==
            {initial_call, {?TRANSPORT, poll_loop, 4}}
    ],
    Expected == length(Pids) orelse
        ct:fail({expected_pollers, Expected, found, length(Pids)}),
    Pids.

%% @private
suspend_poller(Poller) ->
    true = erlang:suspend_process(Poller),
    ok.

%% @private
resume_poller(Poller) ->
    true = erlang:resume_process(Poller),
    ok.

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
