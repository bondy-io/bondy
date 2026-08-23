%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_transport_sse_SUITE).

-moduledoc """
**WAMP over Server-Sent Events**, driving the SDK's
`m:bondy_connect_transport_sse` against the live Bondy `api_gateway_http`
listener (port 18080, which `bondy_ct` starts with the `wamp_sse` service).

Establishing a session and carrying WAMP over it are not tested here: every
WAMP use case runs on `sse` in `bondy_connect_conformance_SUITE`.

What is left differs from long-poll in what can go wrong, so these cases are not
the long-poll ones renamed:

- the stream is **always open**, so server push needs no arrangement — but the
  server writes `: keepalive` comments into it on its own timer, and a comment
  decoded as a WAMP message would corrupt the session. `sse_survives_keepalives`
  idles across several of them.
- a chunk boundary has nothing to do with an event boundary, so a message split
  across two TCP reads must be reassembled. `sse_fragmented_event_reassembled`
  drives the transport's own `handle_data/2` with a deliberately split payload,
  which is the only way to make that split happen on purpose.
- the receive half is a `GET` that must be REJECTED before the session is
  reported established, or a client ends up with a session that can never
  receive anything (`sse_bad_path_fails`).
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.bondy_connect.sse">>).
-define(HOST, "127.0.0.1").
-define(PORT, 18080).
-define(TRANSPORT, bondy_connect_transport_sse).

all() ->
    [
        sse_push_needs_no_client_request,
        sse_survives_keepalives,
        sse_fragmented_event_reassembled,
        sse_outbound_too_large_rejected,
        sse_bad_path_fails
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

%% `/open' plus the `GET /receive' stream is enough to reach `established'.
sse_push_needs_no_client_request(_) ->
    Topic = <<"com.example.res.sse.push">>,
    Self = self(),
    Sub = connect(),
    Pub = connect(),

    {ok, _} = bondy_connect_client:subscribe(Sub, Topic, event_handler(Self)),
    ok = drain_events(),

    timer:sleep(3000),

    ok = bondy_connect_client:publish(Pub, Topic, [<<"pushed">>]),

    receive
        {event, Args} -> ?assertEqual([<<"pushed">>], Args)
    after 15000 -> ct:fail(no_pushed_event)
    end,

    ok = bondy_connect_client:disconnect(Sub),
    ok = bondy_connect_client:disconnect(Pub).

%% The server writes `: keepalive' comments into the stream on its own timer
%% (`listeners.$name.sse.ping.interval', 20s by default). A comment is not a
%% WAMP message: decoding one would fail the session, and surfacing one as an
%% inbound would confuse the protocol layer. Idles across at least two.
sse_survives_keepalives(_) ->
    Conn = connect(),
    Proc = <<"com.example.res.sse.quiet">>,
    {ok, _} = bondy_connect_client:register(Conn, Proc, echo_handler()),

    timer:sleep(45000),

    ?assertEqual(established, bondy_connect_client:status(Conn)),
    {ok, R} = bondy_connect_client:call(Conn, Proc, [<<"still here">>]),
    ?assertEqual([<<"still here">>], maps:get(args, R)),
    ok = bondy_connect_client:disconnect(Conn).

%% A chunk boundary is not an event boundary. Driven through the transport's own
%% `handle_data/2' rather than over the network, because a split at a chosen
%% byte is not something a test can ask TCP for.
%%
%% Three feeds, and the assertion is on ALL of them: nothing before the event is
%% terminated by its blank line, then exactly one message, and the trailing
%% partial event held back rather than decoded as a malformed half.
sse_fragmented_event_reassembled(_) ->
    {ok, St0} = ?TRANSPORT:connect({?HOST, ?PORT}, transport_opts()),
    {ok, _, St1} = ?TRANSPORT:handshake({raw, binary, json}, St0),

    Encoded = bondy_wamp_encoding:encode(
        #event{
            subscription_id = 1,
            publication_id = 2,
            details = #{},
            args = [<<"split">>],
            kwargs = undefined
        },
        json
    ),
    Event =
        <<"event: wamp\ndata: ", (iolist_to_binary(Encoded))/binary, "\n\n">>,
    Half = byte_size(Event) div 2,
    <<First:Half/binary, Second/binary>> = Event,

    {ok, None, St2} = ?TRANSPORT:handle_data(First, St1),
    ?assertEqual([], None),

    {ok, [Decoded], St3} = ?TRANSPORT:handle_data(Second, St2),
    ?assertEqual([<<"split">>], element(#event.args, Decoded)),

    %% A comment and an unterminated event: neither yields a message.
    {ok, Nothing, _St4} = ?TRANSPORT:handle_data(
        <<": keepalive\n\nevent: wamp\ndata: [1,">>, St3
    ),
    ?assertEqual([], Nothing),

    ok = ?TRANSPORT:close(St3).

sse_outbound_too_large_rejected(_) ->
    {ok, Conn} = bondy_connect_client:connect(
        spec(#{
            max_message_length => 2048
        })
    ),
    ?assertEqual(established, bondy_connect_client:status(Conn)),
    Big = binary:copy(<<"x">>, 8192),
    Result = bondy_connect_client:publish(
        Conn, <<"com.example.res.sse.big">>, [Big]
    ),
    ?assertMatch({error, {message_too_large, _, 2048}}, Result),
    ?assertEqual(established, bondy_connect_client:status(Conn)),
    ok = bondy_connect_client:disconnect(Conn).

%% The stream `GET' is awaited during the handshake precisely so this fails
%% here. A transport that established first and discovered the rejected stream
%% later would hand back a session that can never receive anything.
sse_bad_path_fails(_) ->
    Result = bondy_connect_client:connect(
        spec(#{
            sse_path => <<"/nope/sse">>
        })
    ),
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
            transport => sse,
            endpoint => {?HOST, ?PORT},
            realm => ?REALM,
            auth => #{method => ?WAMP_ANON_AUTH},
            serializers => [json]
        },
        Extra
    ).

%% @private The option map the CONNECTION would build, for the cases that drive
%% the transport directly.
transport_opts() ->
    #{
        connect_timeout => 5000,
        max_message_length => 16#1000000,
        scheme => sse,
        serializers => [json],
        sse_path => <<"/wamp/sse">>,
        network_timeout => 15000,
        tls => #{}
    }.

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

%% @private
drain_events() ->
    receive
        {event, _} -> drain_events()
    after 250 -> ok
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
