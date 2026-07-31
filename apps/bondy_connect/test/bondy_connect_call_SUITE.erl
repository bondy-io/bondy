%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_call_SUITE).

-moduledoc """
M1 walking-skeleton integration tests: an anonymous `bondy_connect` client
connecting to a live Bondy router over raw TCP, issuing a CALL, and
disconnecting — exercising the whole stack (facade → manager → connection
gen_statem → protocol → transport/codec/framing).

The call target is `bondy.session.self`, a built-in procedure that returns the
caller's own session.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bondy_connect.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.bondy_connect.m1">>).
-define(HOST, "127.0.0.1").
-define(PORT, 18082).

all() ->
    [
        connect_call_disconnect,
        named_connection,
        multiple_calls,
        call_unknown_procedure_errors,
        connect_unknown_realm_fails,
        call_after_disconnect_fails
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    {ok, _} = application:ensure_all_started(bondy_connect),
    ok = add_anon_realm(?REALM),
    Config.

end_per_suite(_) ->
    ok.

%% @private
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

%% @private
spec() ->
    #{
        transport => tcp,
        endpoint => {?HOST, ?PORT},
        realm => ?REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json]
    }.

%% =============================================================================
%% TESTS
%% =============================================================================

connect_call_disconnect(_) ->
    {ok, Conn} = bondy_connect:connect(spec()),
    ?assertEqual(established, bondy_connect:status(Conn)),

    %% The CALL round-trips and a well-formed RESULT is correlated back to the
    %% caller. (bondy.session.self returns empty args for an anonymous session.)
    {ok, Result} = bondy_connect:call(Conn, <<"bondy.session.self">>, []),
    ct:pal("bondy.session.self -> ~p", [Result]),
    ?assertMatch(#{args := _, kwargs := _}, Result),

    ok = bondy_connect:disconnect(Conn),
    ?assertEqual(down, bondy_connect:status(Conn)).

named_connection(_) ->
    {ok, Conn} = bondy_connect:connect(m1_named, spec()),
    %% A named connection can be referenced from its name via named/1 (yielding
    %% an opaque handle), not just from the handle connect/2 returned.
    Named = bondy_connect:named(m1_named),
    ?assertEqual(established, bondy_connect:status(Named)),
    {ok, _} = bondy_connect:call(Named, <<"bondy.session.self">>, []),
    ok = bondy_connect:disconnect(Conn),
    %% Name is freed and can be reused.
    {ok, Conn2} = bondy_connect:connect(m1_named, spec()),
    ok = bondy_connect:disconnect(Conn2).

multiple_calls(_) ->
    {ok, Conn} = bondy_connect:connect(spec()),
    {ok, R1} = bondy_connect:call(Conn, <<"bondy.session.self">>, []),
    {ok, R2} = bondy_connect:call(Conn, <<"bondy.session.self">>, []),
    ?assertMatch(#{args := _, kwargs := _}, R1),
    ?assertMatch(#{args := _, kwargs := _}, R2),
    ok = bondy_connect:disconnect(Conn).

%% Calling an unregistered procedure must come back as a correlated WAMP ERROR
%% (proves the dealer is really routing and that ERROR correlation works).
call_unknown_procedure_errors(_) ->
    {ok, Conn} = bondy_connect:connect(spec()),
    Result = bondy_connect:call(Conn, <<"com.example.no.such.proc.m1">>, []),
    ct:pal("unknown procedure -> ~p", [Result]),
    ?assertMatch({error, #{kind := wamp, uri := _}}, Result),
    ok = bondy_connect:disconnect(Conn).

connect_unknown_realm_fails(_) ->
    Spec = (spec())#{realm => <<"com.example.no.such.realm.m1">>},
    ?assertMatch({error, _}, bondy_connect:connect(Spec)).

call_after_disconnect_fails(_) ->
    {ok, Conn} = bondy_connect:connect(spec()),
    ok = bondy_connect:disconnect(Conn),
    ?assertMatch(
        {error, _}, bondy_connect:call(Conn, <<"bondy.session.self">>, [])
    ).
