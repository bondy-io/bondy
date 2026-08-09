%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_status_SUITE).

-moduledoc """
Message status, and the idempotency it makes possible.

Two of these cases are the ones worth reading.

`every_node_agrees_on_the_owner` is the whole basis of cluster-wide
deduplication: three nodes, no communication, and for any key exactly one of
them says `local` while the other two point at it. If that ever stops holding,
two nodes will both accept the same key and the guarantee silently becomes a
node-local one.

`unreachable_owner_does_not_fall_back_to_local` pins the decision not to be
helpful. Sending locally when the owner cannot be reached would look like
resilience and would quietly break exactly what the caller asked for by
supplying a key.

The counting cases assert on how many messages the relay actually received, not
on the shape of a return value. A deduplication bug that returned
`duplicate => true` while still sending would satisfy the weaker assertion.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_mail/include/bondy_mail.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, ~"com.example.app").
-define(OTHER_REALM, ~"com.example.other").

all() ->
    [
        %% Ids
        id_embeds_this_node,
        keyed_id_is_stable,
        keyed_id_is_scoped_to_the_realm,
        unkeyed_ids_are_unique,
        malformed_id_has_no_node,
        unknown_node_does_not_mint_an_atom,
        %% Ownership
        unkeyed_request_is_always_local,
        every_node_agrees_on_the_owner,
        unreachable_owner_does_not_fall_back_to_local,
        %% Status
        sent_message_reports_sent,
        queued_message_reports_queued,
        failed_message_reports_nature_and_class,
        status_omits_recipients_and_content,
        status_is_unknown_for_another_realm,
        status_is_unknown_for_an_unheard_of_message,
        status_is_unknown_when_the_owner_is_unreachable,
        %% Idempotency
        same_key_sends_once,
        concurrent_duplicates_send_once,
        duplicate_reports_the_first_outcome,
        duplicate_of_a_failure_is_not_resent,
        different_keys_send_separately,
        same_key_in_another_realm_is_not_a_duplicate,
        refused_message_releases_its_claim,
        shed_message_gives_its_key_back,
        %% Sweep
        expired_status_is_forgotten
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(gproc),
    {ok, _} = application:ensure_all_started(bondy_regulator),
    {ok, Port} = mock_smtp_server:start(),
    [{port, Port} | Config].

end_per_suite(_Config) ->
    _ = application:stop(bondy_mail),
    ok = mock_smtp_server:stop(),
    ok.

init_per_testcase(expired_status_is_forgotten, Config) ->
    ok = mock_smtp_server:clear(),
    %% Short enough that a case can outlive an entry without sleeping for long.
    ok = restart(Config, #{status_ttl => 1000}),
    Config;
init_per_testcase(_Case, Config) ->
    ok = mock_smtp_server:clear(),
    ok = restart(Config, #{}),
    Config.

end_per_testcase(_Case, _Config) ->
    catch meck:unload(partisan),
    _ = application:stop(bondy_mail),
    ok.

%% =============================================================================
%% IDS
%% =============================================================================

-doc """
An id names the node holding the record, so any node can route a query from it.
""".
id_embeds_this_node(_) ->
    Id = bondy_mail_status:new_id(?REALM, undefined),
    ?assertEqual({ok, erlang:node()}, bondy_mail_status:node_of(Id)),

    %% `/` is the separator because it cannot occur in a node name, which is
    %% what makes the split unambiguous however the node is named.
    ?assertEqual(nomatch, binary:match(atom_to_binary(erlang:node()), ~"/")).

-doc """
The same key in the same realm always names the same message.

This is what lets a retry find the original rather than mint a second one, and
it is why no separate index from key to id is needed.
""".
keyed_id_is_stable(_) ->
    ?assertEqual(
        bondy_mail_status:new_id(?REALM, ~"order-42"),
        bondy_mail_status:new_id(?REALM, ~"order-42")
    ).

-doc """
Two realms using the same key do not collide.

Idempotency keys are chosen by callers, and `order-42` is not an imaginative
choice. Without the realm in the digest, one tenant's key would suppress
another tenant's mail.
""".
keyed_id_is_scoped_to_the_realm(_) ->
    ?assertNotEqual(
        bondy_mail_status:new_id(?REALM, ~"order-42"),
        bondy_mail_status:new_id(?OTHER_REALM, ~"order-42")
    ).

unkeyed_ids_are_unique(_) ->
    Ids = [
        bondy_mail_status:new_id(?REALM, undefined)
     || _ <- lists:seq(1, 500)
    ],
    ?assertEqual(500, length(lists:usort(Ids))).

malformed_id_has_no_node(_) ->
    [
        ?assertEqual(error, bondy_mail_status:node_of(Id))
     || Id <- [~"", ~"no-separator", ~"/token", ~"node@host/", not_a_binary]
    ].

-doc """
A caller-supplied id cannot create an atom.

`binary_to_atom` on caller input would let anyone fill the atom table by
guessing ids, which is a node-wide denial of service rather than a mail
problem. An id naming a node this one has never heard of is simply unknown.
""".
unknown_node_does_not_mint_an_atom(_) ->
    Node = ~"definitely-not-a-node-bondy-has-heard-of@10.255.255.255",
    Id = <<Node/binary, "/00112233445566778899aabbccddeeff">>,

    ?assertEqual(error, bondy_mail_status:node_of(Id)),
    ?assertMatch(
        {ok, #{status := unknown}}, bondy_mail:status(?REALM, Id)
    ),
    %% And asking did not create it.
    ?assertError(badarg, binary_to_existing_atom(Node, utf8)).

%% =============================================================================
%% OWNERSHIP
%% =============================================================================

-doc """
A request with no idempotency key is kept by the node that accepted it.

There is nothing to deduplicate, so there is no reason to pay a hop.
""".
unkeyed_request_is_always_local(_) ->
    ok = mock_cluster('a@127.0.0.1', ['b@127.0.0.1', 'c@127.0.0.1']),
    ?assertEqual(local, bondy_mail_status:owner(?REALM, undefined)).

-doc """
Three nodes, no communication, one owner per key.

Each node is asked who owns each key. Exactly one must answer `local` and the
other two must name that same node. If this fails, deduplication silently
degrades to node-local -- two nodes accept the same key and two emails go out --
which is the failure this whole mechanism exists to prevent.
""".
every_node_agrees_on_the_owner(_) ->
    Nodes = ['a@127.0.0.1', 'b@127.0.0.1', 'c@127.0.0.1'],
    Keys = [integer_to_binary(N) || N <- lists:seq(1, 200)],

    Owners = [
        begin
            Answers = [
                begin
                    ok = mock_cluster(Self, Nodes -- [Self]),
                    {Self, bondy_mail_status:owner(?REALM, Key)}
                end
             || Self <- Nodes
            ],
            Locals = [N || {N, local} <- Answers],
            Named = lists:usort([N || {_, {remote, N}} <- Answers]),

            %% Exactly one node claims it, and everyone else points at that one.
            ?assertMatch([_], Locals),
            ?assertEqual(Locals, Named),
            hd(Locals)
        end
     || Key <- Keys
    ],

    %% And ownership is actually spread, rather than every key landing on one
    %% node -- which would agree perfectly and be useless.
    ?assert(length(lists:usort(Owners)) > 1).

-doc """
An owner that cannot be reached is a transient error, never a local send.

Falling back would look like resilience and would break the guarantee the
caller asked for by supplying a key: the owner may well have accepted the same
key already. Refusing lets the caller retry once membership has settled.
""".
unreachable_owner_does_not_fall_back_to_local(_) ->
    %% Chosen so the key's owner is one of the peers rather than this node.
    Peers = ['b@127.0.0.1', 'c@127.0.0.1'],
    Key = find_remote_key('a@127.0.0.1', Peers),

    ok = mock_cluster('a@127.0.0.1', Peers),
    Result = bondy_mail:send(?REALM, (base())#{~"id" => Key}),

    ?assertMatch({error, {transient, owner_unavailable, _}}, Result),
    ?assertEqual([], mock_smtp_server:messages()).

%% =============================================================================
%% STATUS
%% =============================================================================

sent_message_reports_sent(_) ->
    {ok, #{id := Id}} = send(base()),

    ?assertMatch(
        {ok, #{status := sent, relay := ~"default", attempts := 1}},
        bondy_mail:status(?REALM, Id)
    ).

queued_message_reports_queued(_) ->
    ok = mock_smtp_server:latency(400),
    {ok, #{id := Id}} = bondy_mail:send_async(?REALM, base()),

    ?assertMatch({ok, #{status := queued}}, bondy_mail:status(?REALM, Id)),

    ok = await_messages(1),
    ?assertMatch({ok, #{status := sent}}, bondy_mail:status(?REALM, Id)).

-doc """
A failure records what kind it was, which is what an operator needs.

`permanent` versus `transient` is the single fact that decides whether someone
should be woken up or whether waiting is the right answer.
""".
failed_message_reports_nature_and_class(_) ->
    ok = mock_smtp_server:fail_data("550 mailbox unavailable"),
    Key = ~"failing",
    Id = bondy_mail_status:new_id(?REALM, Key),

    ?assertMatch(
        {error, {permanent, _, _}}, send((base())#{~"id" => Key})
    ),
    ?assertMatch(
        {ok, #{status := failed, nature := permanent, error_class := _}},
        bondy_mail:status(?REALM, Id)
    ).

-doc """
A status record holds nothing about the message's content.

Status is queryable by any session in the realm, so anything recorded here is
effectively published to that realm. Recipients and subject lines are not.
""".
status_omits_recipients_and_content(_) ->
    Req = (base())#{
        ~"to" => [~"private@example.com"],
        ~"subject" => ~"Confidential",
        ~"text" => ~"secret body"
    },
    {ok, #{id := Id}} = send(Req),
    {ok, Info} = bondy_mail:status(?REALM, Id),

    ?assertEqual(
        [attempts, created_at, id, relay, status, updated_at],
        lists:sort(maps:keys(Info))
    ),
    Flat = iolist_to_binary(io_lib:format("~p", [Info])),
    [
        ?assertEqual(nomatch, binary:match(Flat, Needle))
     || Needle <- [~"private@example.com", ~"Confidential", ~"secret body"]
    ].

-doc """
A realm cannot see another realm's messages, and cannot tell that they exist.

Answering `unknown` rather than `forbidden` is the point: a distinguishable
refusal would turn guessable ids into an existence oracle across tenants.
""".
status_is_unknown_for_another_realm(_) ->
    {ok, #{id := Id}} = send(base()),

    ?assertMatch({ok, #{status := sent}}, bondy_mail:status(?REALM, Id)),
    ?assertMatch(
        {ok, #{status := unknown}}, bondy_mail:status(?OTHER_REALM, Id)
    ).

status_is_unknown_for_an_unheard_of_message(_) ->
    Id = bondy_mail_status:new_id(?REALM, ~"never-sent"),
    ?assertMatch({ok, #{status := unknown}}, bondy_mail:status(?REALM, Id)).

-doc """
A message on a node that is gone has genuinely unknown status.

The queue is in memory, so a node that stopped took its unsent messages with
it, and nothing left in the cluster knows what it had managed to deliver first.
`unknown` is the truthful answer; anything more definite would be a guess.
""".
status_is_unknown_when_the_owner_is_unreachable(_) ->
    Ghost = 'ghost@127.0.0.1',
    Id = <<
        (atom_to_binary(Ghost))/binary, "/00112233445566778899aabbccddeeff"
    >>,

    %% The node is one this cluster has heard of -- so the id parses -- but it
    %% cannot be reached.
    ?assertEqual({ok, Ghost}, bondy_mail_status:node_of(Id)),
    ?assertMatch({ok, #{status := unknown}}, bondy_mail:status(?REALM, Id)).

%% =============================================================================
%% IDEMPOTENCY
%% =============================================================================

-doc """
The same key twice is one email.

Asserted by counting what the relay received, not by the shape of the return
value: a bug that reported a duplicate and sent anyway would pass the weaker
check.
""".
same_key_sends_once(_) ->
    Req = (base())#{~"id" => ~"order-42"},

    {ok, First} = send(Req),
    {ok, Second} = send(Req),

    ?assertEqual(1, length(mock_smtp_server:messages())),
    ?assertEqual(maps:get(id, First), maps:get(id, Second)),
    ?assertNot(maps:is_key(duplicate, First)),
    ?assertMatch(#{duplicate := true}, Second).

-doc """
Simultaneous requests carrying one key produce one email.

A check-then-insert would pass `same_key_sends_once` and fail here: the window
between reading and writing is exactly where a client's parallel retries land.
The claim is a single atomic insert for that reason, and this races it to say
so.
""".
concurrent_duplicates_send_once(_) ->
    Req = (base())#{~"id" => ~"order-46"},
    Self = self(),

    %% Started, then released together. Spawning and sending in one step would
    %% let the first caller finish before the last was created, and the case
    %% would pass without ever having raced anything.
    Pids = [
        spawn_link(fun() ->
            Self ! {ready, self()},
            receive
                go -> Self ! {result, N, send(Req)}
            end
        end)
     || N <- lists:seq(1, 25)
    ],
    [
        receive
            {ready, Pid} -> ok
        after 5000 -> ct:fail(worker_never_started)
        end
     || Pid <- Pids
    ],
    _ = [Pid ! go || Pid <- Pids],

    Results = [
        receive
            {result, _, R} -> R
        after 30000 -> ct:fail(send_never_returned)
        end
     || _ <- Pids
    ],

    ?assertEqual(1, length(mock_smtp_server:messages())),

    %% Exactly one caller was the one that sent it.
    Sent = [R || {ok, #{status := sent}} = R <- Results],
    ?assertMatch([_], Sent),

    %% Every other caller was told so, and told the same message id.
    Ids = lists:usort([Id || {ok, #{id := Id}} <- Results]),
    ?assertMatch([_], Ids),
    ?assertEqual(24, length([R || {ok, #{duplicate := true}} = R <- Results])).

duplicate_reports_the_first_outcome(_) ->
    Req = (base())#{~"id" => ~"order-43"},
    {ok, _} = send(Req),

    ?assertMatch(
        {ok, #{duplicate := true, status := sent, attempts := 1}}, send(Req)
    ).

-doc """
A failed message is not resent under the same key.

Bondy cannot distinguish a relay that never saw the message from one that
accepted it and dropped the connection, so treating a failure as licence to
send again would be exactly how a caller gets two emails from one key. The
reported outcome tells them to use a new key if they want another attempt.
""".
duplicate_of_a_failure_is_not_resent(_) ->
    ok = mock_smtp_server:fail_data("550 mailbox unavailable"),
    Req = (base())#{~"id" => ~"order-44"},

    ?assertMatch({error, {permanent, _, _}}, send(Req)),
    Attempts = rcpt_count(),

    ?assertMatch(
        {ok, #{duplicate := true, status := failed, nature := permanent}},
        send(Req)
    ),
    %% The relay was not asked a second time.
    ?assertEqual(Attempts, rcpt_count()).

different_keys_send_separately(_) ->
    {ok, _} = send((base())#{~"id" => ~"one"}),
    {ok, _} = send((base())#{~"id" => ~"two"}),

    ?assertEqual(2, length(mock_smtp_server:messages())).

-doc """
One tenant's key does not suppress another's mail.
""".
same_key_in_another_realm_is_not_a_duplicate(_) ->
    Req = (base())#{~"id" => ~"order-45"},

    {ok, _} = bondy_mail:send(?REALM, Req),
    {ok, Second} = bondy_mail:send(?OTHER_REALM, Req),

    ?assertNot(maps:is_key(duplicate, Second)),
    ?assertEqual(2, length(mock_smtp_server:messages())).

-doc """
A message refused before it reached a worker gives its claim back.

Keeping the claim would mean refusing to retry something that was never
attempted -- an idempotency key suppressing an email that was never sent, which
is worse than the duplicate it exists to prevent.
""".
refused_message_releases_its_claim(_) ->
    %% `slow` holds each message and bounds its queue at one, so filling it is
    %% what makes the keyed request below get as far as a claim and no further.
    ok = mock_smtp_server:latency(3000),
    Key = ~"refused",
    Id = bondy_mail_status:new_id(?REALM, Key),

    Slow = (base())#{~"relay" => ~"slow"},
    _ = [bondy_mail:send_async(?REALM, Slow) || _ <- lists:seq(1, 20)],

    ?assertMatch(
        {error, {transient, queue_full, _}},
        bondy_mail:send_async(?REALM, Slow#{~"id" => Key})
    ),
    ?assertMatch({ok, #{status := unknown}}, bondy_mail:status(?REALM, Id)),

    %% And the key is free: the same one now sends rather than reporting a
    %% duplicate of a message that never existed.
    ok = mock_smtp_server:latency(0),
    {ok, Result} = send((base())#{~"id" => Key}),
    ?assertNot(maps:is_key(duplicate, Result)),
    ?assertMatch(#{status := sent}, Result).

-doc """
A message shed from the queue reports what happened AND gives its key back.

Both halves, because each without the other is a defect.

Recording it as a failure would leave the claim consumed, so every later request
carrying that key is answered with the recorded failure and nothing is ever sent
-- for a message no relay was ever shown, which is exactly the case an
idempotency key is supposed to make retryable. Simply deleting the record frees
the key but leaves an asynchronous caller holding an id that answers `unknown`,
indistinguishable from one that never existed.

So the record stays, saying `shed`, and `claim/1` takes it over.
""".
shed_message_gives_its_key_back(_) ->
    %% One worker, held for longer than the queue's TTL, so the second message
    %% is shed at the head of the queue without a connection ever being opened
    %% for it.
    ok = mock_smtp_server:latency(1000),
    Key = ~"shed-1",
    Req = (base())#{~"relay" => ~"shedding"},

    {ok, _} = bondy_mail:send_async(?REALM, Req),
    {ok, #{id := Id}} = bondy_mail:send_async(?REALM, Req#{~"id" => Key}),

    ok = await_status(Id, shed),
    {ok, Info} = bondy_mail:status(?REALM, Id),
    ?assertEqual(transient, maps:get(nature, Info)),
    ?assertEqual(expired, maps:get(error_class, Info)),

    ok = mock_smtp_server:latency(0),
    {ok, Result} = bondy_mail:send(?REALM, Req#{~"id" => Key}),
    ?assertNot(maps:is_key(duplicate, Result)),
    ?assertMatch(#{id := Id, status := sent}, Result),

    %% And having been sent, the key holds again: shedding does not make a key
    %% permanently reusable, it makes one reusable while nothing has been sent.
    {ok, Again} = bondy_mail:send(?REALM, Req#{~"id" => Key}),
    ?assertMatch(#{duplicate := true, status := sent}, Again).

%% =============================================================================
%% SWEEP
%% =============================================================================

-doc """
Status is forgotten once its time is up, and so is the key that named it.

The idempotency window is the TTL. Nothing here is durable, and a record that
outlived its window would be a slow memory leak with a bounded table's name.
""".
expired_status_is_forgotten(_) ->
    Key = ~"expiring",
    {ok, #{id := Id}} = send((base())#{~"id" => Key}),
    ?assertMatch({ok, #{status := sent}}, bondy_mail:status(?REALM, Id)),

    ok = await_unknown(Id),

    %% And the key deduplicates nothing any more.
    {ok, Result} = send((base())#{~"id" => Key}),
    ?assertNot(maps:is_key(duplicate, Result)),
    ?assertEqual(2, length(mock_smtp_server:messages())).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
send(Map) ->
    bondy_mail:send(?REALM, Map).

%% @private
base() ->
    #{
        ~"relay" => ~"default",
        ~"to" => [~"user@example.com"],
        ~"subject" => ~"Hello",
        ~"text" => ~"Body"
    }.

%% @private
%% The only mock in this suite. A multi-node cluster is what ownership is about,
%% and standing up real nodes to compute a hash would test Partisan rather than
%% the selection.
mock_cluster(Self, Peers) ->
    catch meck:unload(partisan),
    meck:new(partisan, [passthrough, no_link]),
    meck:expect(partisan, node, fun() -> Self end),
    meck:expect(partisan, nodes, fun() -> Peers end),
    ok.

%% @private
%% A key whose owner is not `Self`, so the routing path is actually taken.
find_remote_key(Self, Peers) ->
    Nodes = [Self | Peers],
    Keys = [integer_to_binary(N) || N <- lists:seq(1, 100)],
    Remote = [
        Key
     || Key <- Keys, lrw:top({?REALM, Key}, Nodes, 1) =/= [Self]
    ],
    hd(Remote).

%% @private
await_status(Id, Status) ->
    await_status(Id, Status, 100).

%% @private
await_status(Id, Status, 0) ->
    ct:fail({expected_status, Id, Status});
await_status(Id, Status, Retries) ->
    case bondy_mail:status(?REALM, Id) of
        {ok, #{status := Status}} ->
            ok;
        _ ->
            timer:sleep(50),
            await_status(Id, Status, Retries - 1)
    end.

%% @private
await_unknown(Id) ->
    await_unknown(Id, 60).

%% @private
await_unknown(Id, 0) ->
    ct:fail({status_never_expired, Id});
await_unknown(Id, Retries) ->
    case bondy_mail:status(?REALM, Id) of
        {ok, #{status := unknown}} ->
            ok;
        _ ->
            timer:sleep(100),
            await_unknown(Id, Retries - 1)
    end.

%% @private
await_messages(N) ->
    await_messages(N, 60).

%% @private
await_messages(N, 0) ->
    ct:fail({expected_messages, N, got, length(mock_smtp_server:messages())});
await_messages(N, Retries) ->
    case length(mock_smtp_server:messages()) >= N of
        true ->
            ok;
        false ->
            timer:sleep(100),
            await_messages(N, Retries - 1)
    end.

%% @private
rcpt_count() ->
    MS = [{{{rcpt_to, '$1'}, '_'}, [], ['$1']}],
    length(ets:select(mock_smtp_server, MS)).

%% @private
restart(Config, Env) ->
    _ = application:stop(bondy_mail),
    ok = application:set_env(
        bondy_mail, relays, relays(?config(port, Config))
    ),
    ok = application:set_env(bondy_mail, default_relay, undefined),
    ok = application:set_env(
        bondy_mail, status_ttl, maps:get(status_ttl, Env, undefined)
    ),
    {ok, _} = application:ensure_all_started(bondy_mail),
    ok.

%% @private
relays(Port) ->
    Common = #{
        host => ~"127.0.0.1",
        port => Port,
        transport => plain,
        auth => never,
        from => ~"no-reply@example.com",
        realms => any,
        retry_max_attempts => 0,
        retry_backoff_min => 10,
        retry_backoff_max => 50
    },
    [
        Common#{name => ~"default"},
        Common#{
            name => ~"slow",
            pool_size => 1,
            queue_max_size => 1,
            timeout => 20000
        },
        %% One worker and a TTL short enough that anything queued behind a
        %% message in flight is shed rather than delivered.
        Common#{
            name => ~"shedding",
            pool_size => 1,
            queue_ttl => 200
        }
    ].
