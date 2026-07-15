%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_transport_SUITE).

-moduledoc """
Integration tests for the raw-socket TCP transport against a live Bondy router
(the `wamp_tcp` listener). Exercises the full PR-1 + PR-2 stack end-to-end:
`bondy_connect_protocol` builds the HELLO record, `bondy_connect_transport_tcp`
encodes/frames/sends it and reads/deframes/decodes the reply, and the protocol
layer turns the WELCOME record into an established session — no gen_statem yet
(that is Phase 3).
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.bondy_connect.pr2">>).
-define(HOST, "127.0.0.1").
-define(PORT, 18082).

all() ->
    [
        handshake_succeeds,
        serializer_negotiated,
        hello_welcome_round_trip
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    ok = add_anon_realm(?REALM),
    Config.

end_per_suite(_) ->
    ok.

%% @private An anonymous-only realm reachable from any IP.
add_anon_realm(RealmUri) ->
    Cfg = #{
        uri => RealmUri,
        authmethods => [?WAMP_ANON_AUTH],
        security_enabled => true,
        grants => [
            #{
                permissions => [<<"wamp.call">>],
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

%% @private Connect + raw handshake, returning the transport state.
connected(Enc) ->
    {ok, T0} = bondy_connect_transport_tcp:connect({?HOST, ?PORT}, #{}),
    {ok, Negotiated, T1} =
        bondy_connect_transport_tcp:handshake({raw, binary, Enc}, T0),
    {Negotiated, T1}.

%% @private Recv until at least one WAMP message record arrives (skip control
%% frames), or fail loudly.
recv_message(T, Timeout) ->
    case bondy_connect_transport_tcp:recv(Timeout, T) of
        {ok, Msgs, T1} ->
            case [M || M <- Msgs, bondy_wamp_message:is_message(M)] of
                [Msg | _] -> {Msg, T1};
                [] -> recv_message(T1, Timeout)
            end;
        {error, Reason} ->
            ct:fail({recv_failed, Reason})
    end.

%% =============================================================================
%% TESTS
%% =============================================================================

handshake_succeeds(_) ->
    {Negotiated, T} = connected(json),
    ?assertEqual({raw, binary, json}, Negotiated),
    ok = bondy_connect_transport_tcp:close(T).

serializer_negotiated(_) ->
    %% The router accepts and echoes our requested serializer.
    {Negotiated, T} = connected(msgpack),
    ?assertEqual({raw, binary, msgpack}, Negotiated),
    ok = bondy_connect_transport_tcp:close(T).

hello_welcome_round_trip(_) ->
    {ok, Cfg} = bondy_connect_config:validate(#{
        realm => ?REALM, auth => #{method => ?WAMP_ANON_AUTH}
    }),
    {ok, P0} = bondy_connect_protocol:init(Cfg),
    {ok, Hello, P1} = bondy_connect_protocol:start(P0),

    {_Negotiated, T1} = connected(json),
    ok = bondy_connect_transport_tcp:send(Hello, T1),

    {Reply, T2} = recv_message(T1, 5000),
    ?assertMatch(#welcome{}, Reply),

    {established, Session, P2} =
        bondy_connect_protocol:handle_message(Reply, P1),
    ?assertEqual(established, bondy_connect_protocol:state_name(P2)),
    ?assertEqual(?REALM, bondy_connect_session:realm_uri(Session)),
    ?assert(is_integer(bondy_connect_session:id(Session))),
    ?assert(bondy_connect_session:id(Session) > 0),
    ct:pal("Established session: ~p", [Session]),

    ok = bondy_connect_transport_tcp:close(T2).
