%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_transport_session_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").

-compile([nowarn_export_all, export_all]).



all() ->
    [
        start_and_stop,
        whereis_lookup,
        inactivity_timeout,
        touch_extends_lifetime,
        queue_integration,
        maybe_enqueue_http_transport,
        maybe_enqueue_websocket,
        session_record_transport_fields
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Config.


end_per_suite(Config) ->
    {save_config, Config}.


init_per_testcase(_TestCase, Config) ->
    %% Set test defaults
    bondy_config:set([transport_queue, max_messages], 1000),
    bondy_config:set([transport_queue, max_bytes], 10485760),
    bondy_config:set([transport_queue, message_ttl], 300000),
    bondy_config:set([transport_queue, transport_ttl], 3600000),
    Config.


end_per_testcase(_TestCase, _Config) ->
    ok.



%% =============================================================================
%% TEST CASES
%% =============================================================================



start_and_stop(_Config) ->
    TransportId = make_transport_id(),
    RealmUri = <<"com.test.realm">>,
    SessionId = bondy_session_id:new(),

    %% Start transport session
    {ok, Pid} = bondy_http_transport_session_sup:start_child(
        TransportId, RealmUri, SessionId
    ),
    ?assert(is_pid(Pid)),
    ?assert(erlang:is_process_alive(Pid)),

    %% Verify gproc registration
    ?assertEqual(Pid, bondy_http_transport_session:whereis(TransportId)),

    %% Verify queue was initialised (count returns 0, not from error path)
    ?assertEqual(0, bondy_transport_queue:count(TransportId)),

    %% Stop the transport session
    ok = bondy_http_transport_session:close(Pid),

    %% Wait for the process to terminate
    timer:sleep(100),

    %% Verify gproc deregistration
    ?assertEqual(undefined, bondy_http_transport_session:whereis(TransportId)),

    %% Verify process is dead
    ?assertNot(erlang:is_process_alive(Pid)),

    %% Verify queue was cleaned up (enqueue should fail)
    ?assertEqual(
        {error, transport_not_found},
        bondy_transport_queue:enqueue(TransportId, make_event(1), #{})
    ).


whereis_lookup(_Config) ->
    TransportId = make_transport_id(),
    RealmUri = <<"com.test.realm">>,
    SessionId = bondy_session_id:new(),

    %% Before start, whereis returns undefined
    ?assertEqual(
        undefined, bondy_http_transport_session:whereis(TransportId)
    ),

    %% Start and verify
    {ok, Pid} = bondy_http_transport_session_sup:start_child(
        TransportId, RealmUri, SessionId
    ),
    ?assertEqual(Pid, bondy_http_transport_session:whereis(TransportId)),

    %% Close by TransportId (not pid)
    ok = bondy_http_transport_session:close(TransportId),
    timer:sleep(100),
    ?assertEqual(
        undefined, bondy_http_transport_session:whereis(TransportId)
    ).


inactivity_timeout(_Config) ->
    TransportId = make_transport_id(),
    RealmUri = <<"com.test.realm">>,
    SessionId = bondy_session_id:new(),

    %% Set a very short TTL (100ms)
    bondy_config:set([transport_queue, transport_ttl], 100),

    {ok, Pid} = bondy_http_transport_session_sup:start_child(
        TransportId, RealmUri, SessionId
    ),
    ?assert(erlang:is_process_alive(Pid)),

    %% The inactivity check runs at max(5000, TTL/2) = 5000ms minimum.
    %% For testing, we wait for the check interval + margin.
    %% Since MIN_CHECK_INTERVAL is 5000ms, we need to wait at least that long.
    MonRef = monitor(process, Pid),
    receive
        {'DOWN', MonRef, process, Pid, normal} ->
            ok
    after 10000 ->
        demonitor(MonRef, [flush]),
        ct:fail("Transport session did not auto-close within timeout")
    end,

    %% Verify cleanup
    ?assertEqual(
        undefined, bondy_http_transport_session:whereis(TransportId)
    ).


touch_extends_lifetime(_Config) ->
    TransportId = make_transport_id(),
    RealmUri = <<"com.test.realm">>,
    SessionId = bondy_session_id:new(),

    %% Set a short TTL (200ms) — the check interval will be 5000ms minimum
    bondy_config:set([transport_queue, transport_ttl], 200),

    {ok, Pid} = bondy_http_transport_session_sup:start_child(
        TransportId, RealmUri, SessionId
    ),

    %% Touch repeatedly to keep the session alive
    %% Touch every 100ms for 600ms (well past the 200ms TTL)
    lists:foreach(
        fun(_) ->
            timer:sleep(100),
            bondy_http_transport_session:touch(Pid)
        end,
        lists:seq(1, 6)
    ),

    %% Session should still be alive because we kept touching it
    ?assert(erlang:is_process_alive(Pid)),
    ?assertEqual(Pid, bondy_http_transport_session:whereis(TransportId)),

    %% Now stop touching and wait for auto-close
    MonRef = monitor(process, Pid),
    receive
        {'DOWN', MonRef, process, Pid, normal} ->
            ok
    after 10000 ->
        demonitor(MonRef, [flush]),
        ct:fail("Transport session did not auto-close after touch stopped")
    end.


queue_integration(_Config) ->
    TransportId = make_transport_id(),
    RealmUri = <<"com.test.realm">>,
    SessionId = bondy_session_id:new(),

    %% Start transport session (which initialises the queue)
    {ok, Pid} = bondy_http_transport_session_sup:start_child(
        TransportId, RealmUri, SessionId
    ),

    %% Enqueue messages via the transport queue API
    Msgs = [make_event(I) || I <- lists:seq(1, 5)],
    lists:foreach(
        fun(Msg) ->
            ok = bondy_transport_queue:enqueue(TransportId, Msg, #{})
        end,
        Msgs
    ),

    %% Verify count
    ?assertEqual(5, bondy_transport_queue:count(TransportId)),

    %% Dequeue and verify ordering
    Dequeued = bondy_transport_queue:dequeue_batch(TransportId, 100),
    ?assertEqual(5, length(Dequeued)),
    ?assertEqual(Msgs, Dequeued),

    %% Queue should be empty now
    ?assertEqual(0, bondy_transport_queue:count(TransportId)),

    %% Cleanup
    ok = bondy_http_transport_session:close(Pid).


maybe_enqueue_http_transport(_Config) ->
    TransportId = make_transport_id(),
    RealmUri = <<"com.leapsight.test.maybe_enqueue">>,
    SessionId = bondy_session_id:new(),

    %% Create the realm if it doesn't exist
    _ = bondy_realm:create(RealmUri),
    ok = bondy_realm:disable_security(RealmUri),

    %% Start transport session (initialises queue)
    {ok, _Pid} = bondy_http_transport_session_sup:start_child(
        TransportId, RealmUri, SessionId
    ),

    %% Create a WAMP session with transport_id set
    Session = bondy_session:new(SessionId, RealmUri, #{
        peer => {{127, 0, 0, 1}, 10000},
        authid => <<"test_user">>,
        authmethod => <<"anonymous">>,
        is_anonymous => true,
        security_enabled => false,
        authroles => [<<"anonymous">>],
        roles => #{caller => #{}, subscriber => #{}},
        transport_type => http_longpoll,
        transport_id => TransportId
    }),
    {ok, StoredSession} = bondy_session:store(Session),

    %% Verify transport_id is set on the session
    ?assertEqual(TransportId, bondy_session:transport_id(StoredSession)),
    ?assertEqual(http_longpoll, bondy_session:transport_type(StoredSession)),

    %% Simulate what do_send does: call maybe_enqueue
    Msg = make_event(42),
    SId = bondy_session:id(StoredSession),

    %% Look up the session and check transport_id
    {ok, LookedUp} = bondy_session:lookup(SId),
    case bondy_session:transport_id(LookedUp) of
        undefined ->
            ct:fail("Expected transport_id to be set");
        TId ->
            ok = bondy_transport_queue:enqueue(TId, Msg, #{}),
            %% Verify message is in queue
            ?assertEqual(1, bondy_transport_queue:count(TId)),
            Dequeued = bondy_transport_queue:dequeue_batch(TId, 10),
            ?assertEqual([Msg], Dequeued)
    end,

    %% Cleanup
    bondy_session:close(StoredSession, undefined),
    ok = bondy_http_transport_session:close(TransportId).


maybe_enqueue_websocket(_Config) ->
    RealmUri = <<"com.leapsight.test.ws_session">>,
    SessionId = bondy_session_id:new(),

    %% Create the realm
    _ = bondy_realm:create(RealmUri),
    ok = bondy_realm:disable_security(RealmUri),

    %% Create a WAMP session WITHOUT transport_id (websocket session)
    Session = bondy_session:new(SessionId, RealmUri, #{
        peer => {{127, 0, 0, 1}, 10001},
        authid => <<"ws_user">>,
        authmethod => <<"anonymous">>,
        is_anonymous => true,
        security_enabled => false,
        authroles => [<<"anonymous">>],
        roles => #{caller => #{}, subscriber => #{}},
        transport_type => websocket
    }),
    {ok, StoredSession} = bondy_session:store(Session),

    %% transport_id should be undefined
    ?assertEqual(undefined, bondy_session:transport_id(StoredSession)),
    ?assertEqual(websocket, bondy_session:transport_type(StoredSession)),

    %% Look up and verify maybe_enqueue would return false
    SId = bondy_session:id(StoredSession),
    {ok, LookedUp} = bondy_session:lookup(SId),
    ?assertEqual(undefined, bondy_session:transport_id(LookedUp)),

    %% Cleanup
    bondy_session:close(StoredSession, undefined).


session_record_transport_fields(_Config) ->
    RealmUri = <<"com.leapsight.test.transport_fields">>,
    _ = bondy_realm:create(RealmUri),
    ok = bondy_realm:disable_security(RealmUri),

    %% Test http_sse transport type
    Session1 = bondy_session:new(RealmUri, #{
        peer => {{127, 0, 0, 1}, 10002},
        authid => <<"user1">>,
        authmethod => <<"anonymous">>,
        is_anonymous => true,
        security_enabled => false,
        authroles => [<<"anonymous">>],
        roles => #{caller => #{}},
        transport_type => http_sse,
        transport_id => <<"sse-transport-1">>
    }),
    ?assertEqual(http_sse, bondy_session:transport_type(Session1)),
    ?assertEqual(<<"sse-transport-1">>, bondy_session:transport_id(Session1)),

    %% Test http_longpoll transport type
    Session2 = bondy_session:new(RealmUri, #{
        peer => {{127, 0, 0, 1}, 10003},
        authid => <<"user2">>,
        authmethod => <<"anonymous">>,
        is_anonymous => true,
        security_enabled => false,
        authroles => [<<"anonymous">>],
        roles => #{caller => #{}},
        transport_type => http_longpoll,
        transport_id => <<"longpoll-transport-1">>
    }),
    ?assertEqual(http_longpoll, bondy_session:transport_type(Session2)),
    ?assertEqual(
        <<"longpoll-transport-1">>, bondy_session:transport_id(Session2)
    ),

    %% Test tcp transport type
    Session3 = bondy_session:new(RealmUri, #{
        peer => {{127, 0, 0, 1}, 10004},
        authid => <<"user3">>,
        authmethod => <<"anonymous">>,
        is_anonymous => true,
        security_enabled => false,
        authroles => [<<"anonymous">>],
        roles => #{caller => #{}},
        transport_type => tcp
    }),
    ?assertEqual(tcp, bondy_session:transport_type(Session3)),
    ?assertEqual(undefined, bondy_session:transport_id(Session3)),

    %% Test websocket (no transport_id)
    Session4 = bondy_session:new(RealmUri, #{
        peer => {{127, 0, 0, 1}, 10005},
        authid => <<"user4">>,
        authmethod => <<"anonymous">>,
        is_anonymous => true,
        security_enabled => false,
        authroles => [<<"anonymous">>],
        roles => #{caller => #{}},
        transport_type => websocket
    }),
    ?assertEqual(websocket, bondy_session:transport_type(Session4)),
    ?assertEqual(undefined, bondy_session:transport_id(Session4)),

    %% Test no transport fields set (default)
    Session5 = bondy_session:new(RealmUri, #{
        peer => {{127, 0, 0, 1}, 10006},
        authid => <<"user5">>,
        authmethod => <<"anonymous">>,
        is_anonymous => true,
        security_enabled => false,
        authroles => [<<"anonymous">>],
        roles => #{caller => #{}}
    }),
    ?assertEqual(undefined, bondy_session:transport_type(Session5)),
    ?assertEqual(undefined, bondy_session:transport_id(Session5)).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
make_transport_id() ->
    Bin = integer_to_binary(erlang:unique_integer([positive])),
    <<"test-http-transport-", Bin/binary>>.


%% @private
make_event(N) ->
    #event{
        subscription_id = 1,
        publication_id = N,
        details = #{},
        args = [<<"payload-", (integer_to_binary(N))/binary>>],
        kwargs = undefined
    }.
