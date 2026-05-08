%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_transport_queue_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").

-compile([nowarn_export_all, export_all]).



all() ->
    [
        init_and_delete_transport,
        enqueue_dequeue_ordering,
        max_messages_bound,
        max_bytes_bound,
        ttl_expiry_dequeue,
        ttl_expiry_sweep,
        concurrent_enqueue,
        dequeue_empty,
        multiple_transports_isolation,
        init_is_idempotent,
        partition_tables_are_anonymous,
        partitions_survive_manager_crash
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Config.


end_per_suite(Config) ->
    {save_config, Config}.


init_per_testcase(_TestCase, Config) ->
    %% Set small bounds for testing
    bondy_config:set([transport_queue, max_messages], 10),
    bondy_config:set([transport_queue, max_bytes], 10485760),
    bondy_config:set([transport_queue, message_ttl], 300000),
    Config.


end_per_testcase(_TestCase, _Config) ->
    ok.



%% =============================================================================
%% TEST CASES
%% =============================================================================



init_and_delete_transport(_Config) ->
    TransportId = make_transport_id(),
    RealmUri = <<"com.test.realm">>,
    SessionId = rand:uniform(1 bsl 53),

    %% Init creates meta
    ok = bondy_transport_queue:init_transport(
        TransportId, RealmUri, SessionId
    ),

    %% Verify meta exists via count returning 0 (not from error path)
    ?assertEqual(0, bondy_transport_queue:count(TransportId)),

    %% Double init returns error
    ?assertEqual(
        {error, already_exists},
        bondy_transport_queue:init_transport(
            TransportId, RealmUri, SessionId
        )
    ),

    %% Enqueue a message
    Msg = make_event(1),
    ok = bondy_transport_queue:enqueue(TransportId, Msg, #{}),
    ?assertEqual(1, bondy_transport_queue:count(TransportId)),

    %% Delete removes all entries + meta
    ok = bondy_transport_queue:delete_transport(TransportId),
    ?assertEqual(0, bondy_transport_queue:count(TransportId)),

    %% Enqueue after delete fails (no meta)
    ?assertEqual(
        {error, transport_not_found},
        bondy_transport_queue:enqueue(TransportId, Msg, #{})
    ).


enqueue_dequeue_ordering(_Config) ->
    TransportId = make_transport_id(),
    ok = bondy_transport_queue:init_transport(
        TransportId, <<"com.test.realm">>, rand:uniform(1 bsl 53)
    ),

    %% Enqueue 5 messages with distinct payloads
    Msgs = [make_event(I) || I <- lists:seq(1, 5)],
    lists:foreach(
        fun(Msg) ->
            ok = bondy_transport_queue:enqueue(TransportId, Msg, #{})
        end,
        Msgs
    ),

    ?assertEqual(5, bondy_transport_queue:count(TransportId)),

    %% Dequeue all — should come back in insertion order
    Dequeued = bondy_transport_queue:dequeue_batch(TransportId, 100),
    ?assertEqual(5, length(Dequeued)),
    ?assertEqual(Msgs, Dequeued),

    %% Queue should be empty now
    ?assertEqual(0, bondy_transport_queue:count(TransportId)),

    %% Cleanup
    ok = bondy_transport_queue:delete_transport(TransportId).


max_messages_bound(_Config) ->
    TransportId = make_transport_id(),
    ok = bondy_transport_queue:init_transport(
        TransportId, <<"com.test.realm">>, rand:uniform(1 bsl 53)
    ),

    %% max_messages is 10 (set in init_per_testcase)
    %% Enqueue 15 messages
    _Msgs = [
        begin
            Msg = make_event(I),
            ok = bondy_transport_queue:enqueue(TransportId, Msg, #{}),
            Msg
        end
        || I <- lists:seq(1, 15)
    ],

    %% Count should be <= max_messages + EVICTION_BATCH_SIZE tolerance
    %% but in practice should be around 10 since eviction fires on each
    %% enqueue that exceeds the bound
    Count = bondy_transport_queue:count(TransportId),
    ?assert(
        Count =< 10,
        lists:flatten(
            io_lib:format(
                "Expected count =< 10, got ~p", [Count]
            )
        )
    ),

    %% Dequeue and verify we get the newest messages (oldest were evicted)
    Dequeued = bondy_transport_queue:dequeue_batch(TransportId, 100),
    ?assert(length(Dequeued) =< 10),

    %% The dequeued messages should be from the later enqueues
    %% (publication_id 6..15 range, since 1..5 may have been evicted)
    lists:foreach(
        fun(#event{publication_id = PubId}) ->
            ?assert(
                PubId > 5,
                lists:flatten(
                    io_lib:format(
                        "Expected publication_id > 5, got ~p", [PubId]
                    )
                )
            )
        end,
        Dequeued
    ),

    %% Cleanup
    ok = bondy_transport_queue:delete_transport(TransportId).


max_bytes_bound(_Config) ->
    TransportId = make_transport_id(),
    ok = bondy_transport_queue:init_transport(
        TransportId, <<"com.test.realm">>, rand:uniform(1 bsl 53)
    ),

    %% Set a small byte limit
    %% First, compute the size of one message
    SampleMsg = make_event(1),
    MsgSize = erlang:external_size(SampleMsg),

    %% Set max_bytes to hold approximately 3 messages
    MaxBytes = MsgSize * 3 + 1,
    bondy_config:set([transport_queue, max_bytes], MaxBytes),
    %% Set max_messages high so it doesn't interfere
    bondy_config:set([transport_queue, max_messages], 1000),

    %% Enqueue 6 messages
    lists:foreach(
        fun(I) ->
            ok = bondy_transport_queue:enqueue(
                TransportId, make_event(I), #{}
            )
        end,
        lists:seq(1, 6)
    ),

    %% Byte size should be bounded
    ByteSize = bondy_transport_queue:byte_size(TransportId),
    ?assert(
        ByteSize =< MaxBytes,
        lists:flatten(
            io_lib:format(
                "Expected byte_size =< ~p, got ~p", [MaxBytes, ByteSize]
            )
        )
    ),

    %% Cleanup
    ok = bondy_transport_queue:delete_transport(TransportId).


ttl_expiry_dequeue(_Config) ->
    TransportId = make_transport_id(),
    ok = bondy_transport_queue:init_transport(
        TransportId, <<"com.test.realm">>, rand:uniform(1 bsl 53)
    ),

    %% Set a very short TTL (1ms)
    bondy_config:set([transport_queue, message_ttl], 1),

    %% Enqueue a message
    ok = bondy_transport_queue:enqueue(TransportId, make_event(1), #{}),
    ?assertEqual(1, bondy_transport_queue:count(TransportId)),

    %% Wait for the message to expire
    timer:sleep(10),

    %% Dequeue should skip expired messages and return empty
    Dequeued = bondy_transport_queue:dequeue_batch(TransportId, 100),
    ?assertEqual([], Dequeued),

    %% The count still shows 1 because dequeue_batch skips but doesn't
    %% remove expired entries (that's the sweep's job)
    %% The atomics counter may still show 1

    %% Cleanup
    ok = bondy_transport_queue:delete_transport(TransportId).


ttl_expiry_sweep(_Config) ->
    TransportId = make_transport_id(),
    ok = bondy_transport_queue:init_transport(
        TransportId, <<"com.test.realm">>, rand:uniform(1 bsl 53)
    ),

    %% Set a very short TTL (1ms)
    bondy_config:set([transport_queue, message_ttl], 1),

    %% Enqueue messages
    lists:foreach(
        fun(I) ->
            ok = bondy_transport_queue:enqueue(
                TransportId, make_event(I), #{}
            )
        end,
        lists:seq(1, 5)
    ),

    ?assertEqual(5, bondy_transport_queue:count(TransportId)),

    %% Wait for messages to expire
    timer:sleep(10),

    %% Run the eviction sweep
    ok = bondy_transport_queue:evict_expired_all(),

    %% All messages should have been removed
    ?assertEqual(0, bondy_transport_queue:count(TransportId)),
    ?assertEqual(0, bondy_transport_queue:byte_size(TransportId)),

    %% Cleanup
    ok = bondy_transport_queue:delete_transport(TransportId).


concurrent_enqueue(_Config) ->
    TransportId = make_transport_id(),
    ok = bondy_transport_queue:init_transport(
        TransportId, <<"com.test.realm">>, rand:uniform(1 bsl 53)
    ),

    %% Raise the limit so eviction doesn't interfere
    bondy_config:set([transport_queue, max_messages], 10000),

    %% Spawn N processes that each enqueue M messages
    N = 10,
    M = 50,
    Parent = self(),
    Pids = [
        spawn_link(fun() ->
            lists:foreach(
                fun(I) ->
                    Msg = make_event(ProcIdx * 1000 + I),
                    ok = bondy_transport_queue:enqueue(
                        TransportId, Msg, #{}
                    )
                end,
                lists:seq(1, M)
            ),
            Parent ! {done, self()}
        end)
        || ProcIdx <- lists:seq(1, N)
    ],

    %% Wait for all processes to finish
    lists:foreach(
        fun(Pid) ->
            receive {done, Pid} -> ok end
        end,
        Pids
    ),

    %% Verify total count matches N * M
    ExpectedCount = N * M,
    ?assertEqual(
        ExpectedCount,
        bondy_transport_queue:count(TransportId)
    ),

    %% Dequeue all and verify we get exactly N * M messages
    Dequeued = bondy_transport_queue:dequeue_batch(
        TransportId, ExpectedCount + 100
    ),
    ?assertEqual(ExpectedCount, length(Dequeued)),

    %% Counter should be 0 after dequeue
    ?assertEqual(0, bondy_transport_queue:count(TransportId)),

    %% Cleanup
    ok = bondy_transport_queue:delete_transport(TransportId).


dequeue_empty(_Config) ->
    %% Dequeue from nonexistent transport returns []
    FakeId = make_transport_id(),
    ?assertEqual([], bondy_transport_queue:dequeue_batch(FakeId, 10)),

    %% Dequeue from empty but initialised transport returns []
    TransportId = make_transport_id(),
    ok = bondy_transport_queue:init_transport(
        TransportId, <<"com.test.realm">>, rand:uniform(1 bsl 53)
    ),
    ?assertEqual([], bondy_transport_queue:dequeue_batch(TransportId, 10)),

    %% Cleanup
    ok = bondy_transport_queue:delete_transport(TransportId).


multiple_transports_isolation(_Config) ->
    TransportA = make_transport_id(),
    TransportB = make_transport_id(),

    ok = bondy_transport_queue:init_transport(
        TransportA, <<"com.test.realm">>, rand:uniform(1 bsl 53)
    ),
    ok = bondy_transport_queue:init_transport(
        TransportB, <<"com.test.realm">>, rand:uniform(1 bsl 53)
    ),

    %% Enqueue different messages to each transport
    MsgsA = [make_event(I) || I <- lists:seq(1, 3)],
    MsgsB = [make_event(I) || I <- lists:seq(101, 105)],

    lists:foreach(
        fun(Msg) ->
            ok = bondy_transport_queue:enqueue(TransportA, Msg, #{})
        end,
        MsgsA
    ),
    lists:foreach(
        fun(Msg) ->
            ok = bondy_transport_queue:enqueue(TransportB, Msg, #{})
        end,
        MsgsB
    ),

    %% Counts are independent
    ?assertEqual(3, bondy_transport_queue:count(TransportA)),
    ?assertEqual(5, bondy_transport_queue:count(TransportB)),

    %% Dequeue from A only gets A's messages
    DequeuedA = bondy_transport_queue:dequeue_batch(TransportA, 100),
    ?assertEqual(3, length(DequeuedA)),
    ?assertEqual(MsgsA, DequeuedA),

    %% B is unaffected
    ?assertEqual(5, bondy_transport_queue:count(TransportB)),

    %% Dequeue from B only gets B's messages
    DequeuedB = bondy_transport_queue:dequeue_batch(TransportB, 100),
    ?assertEqual(5, length(DequeuedB)),
    ?assertEqual(MsgsB, DequeuedB),

    %% Delete A doesn't affect B (even if they share a partition)
    ok = bondy_transport_queue:delete_transport(TransportA),
    ok = bondy_transport_queue:init_transport(
        TransportA, <<"com.test.realm">>, rand:uniform(1 bsl 53)
    ),
    ok = bondy_transport_queue:enqueue(TransportA, make_event(999), #{}),
    ok = bondy_transport_queue:delete_transport(TransportA),
    ?assertEqual(0, bondy_transport_queue:count(TransportB)),

    %% Cleanup
    ok = bondy_transport_queue:delete_transport(TransportB).


init_is_idempotent(_Config) ->
    %% Partition tables and the meta table must survive a re-invocation of
    %% init/0 (simulating bondy_transport_queue_manager being restarted by
    %% its supervisor without the table manager dying).
    RingBefore = persistent_term:get({bondy_transport_queue, ring}),
    MetaBefore = ets:info(bondy_transport_queue_meta, size),

    %% Put some state in so we can verify it survives
    TransportId = make_transport_id(),
    ok = bondy_transport_queue:init_transport(
        TransportId, <<"com.test.realm">>, rand:uniform(1 bsl 53)
    ),
    ok = bondy_transport_queue:enqueue(TransportId, make_event(1), #{}),
    ?assertEqual(1, bondy_transport_queue:count(TransportId)),

    %% Re-run init/0
    ok = bondy_transport_queue:init(),

    %% Ring is the same map (same TIDs for every bucket)
    RingAfter = persistent_term:get({bondy_transport_queue, ring}),
    ?assertEqual(RingBefore, RingAfter),

    %% Meta table still exists
    ?assertNotEqual(undefined, ets:info(bondy_transport_queue_meta, size)),

    %% Queued message survived
    ?assertEqual(1, bondy_transport_queue:count(TransportId)),
    [Msg] = bondy_transport_queue:dequeue_batch(TransportId, 10),
    ?assertEqual(make_event(1), Msg),

    %% Meta size didn't regress (may have grown by 1 from this test)
    MetaAfter = ets:info(bondy_transport_queue_meta, size),
    ?assert(MetaAfter >= MetaBefore),

    ok = bondy_transport_queue:delete_transport(TransportId).


partition_tables_are_anonymous(_Config) ->
    %% Each partition table must be an anonymous ets:tid(), not a named
    %% atom. This is the property that guarantees no atoms are allocated
    %% per bucket at boot.
    Tabs = bondy_transport_queue:tables(),
    ?assert(length(Tabs) > 0),

    lists:foreach(
        fun(Tab) ->
            ?assertEqual(false, ets:info(Tab, named_table)),
            %% TIDs are opaque (reference or integer depending on OTP
            %% release). Explicitly reject the atom case.
            ?assertNot(is_atom(Tab))
        end,
        Tabs
    ).


partitions_survive_manager_crash(_Config) ->
    %% The real property this suite is here to guard: when the transport
    %% queue manager gen_server crashes, the partition tables owned by
    %% bondy_table_manager must stay alive and queued messages must still
    %% be dequeue-able after a new manager replaces the crashed one.
    TransportId = make_transport_id(),
    ok = bondy_transport_queue:init_transport(
        TransportId, <<"com.test.realm">>, rand:uniform(1 bsl 53)
    ),

    %% Enqueue a message the crashed manager would have been responsible for
    Msg = make_event(42),
    ok = bondy_transport_queue:enqueue(TransportId, Msg, #{}),
    ?assertEqual(1, bondy_transport_queue:count(TransportId)),

    RingBefore = persistent_term:get({bondy_transport_queue, ring}),

    %% Simulate a manager crash. The supervisor will restart it, which
    %% calls bondy_transport_queue:init/0 again (now idempotent). We
    %% reproduce that sequence manually here.
    ManagerPid = whereis(bondy_transport_queue_manager),
    ?assert(is_pid(ManagerPid)),

    MRef = erlang:monitor(process, ManagerPid),
    exit(ManagerPid, kill),
    receive
        {'DOWN', MRef, process, ManagerPid, _} -> ok
    after 2000 ->
        error(manager_did_not_die)
    end,

    %% Wait for the supervisor to bring a new manager up
    NewPid = wait_for_manager(10, 100),
    ?assert(is_pid(NewPid)),
    ?assertNotEqual(ManagerPid, NewPid),

    %% Ring is unchanged — same TIDs
    RingAfter = persistent_term:get({bondy_transport_queue, ring}),
    ?assertEqual(RingBefore, RingAfter),

    %% The queued message is still there and still dequeue-able
    ?assertEqual(1, bondy_transport_queue:count(TransportId)),
    [Dequeued] = bondy_transport_queue:dequeue_batch(TransportId, 10),
    ?assertEqual(Msg, Dequeued),

    ok = bondy_transport_queue:delete_transport(TransportId).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
make_transport_id() ->
    Bin = integer_to_binary(erlang:unique_integer([positive])),
    <<"test-transport-", Bin/binary>>.


%% @private
make_event(N) ->
    #event{
        subscription_id = 1,
        publication_id = N,
        details = #{},
        args = [<<"payload-", (integer_to_binary(N))/binary>>],
        kwargs = undefined
    }.


%% @private
wait_for_manager(0, _Every) ->
    undefined;

wait_for_manager(Attempts, Every) ->
    case whereis(bondy_transport_queue_manager) of
        undefined ->
            timer:sleep(Every),
            wait_for_manager(Attempts - 1, Every);
        Pid ->
            Pid
    end.
