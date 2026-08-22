%% =============================================================================
%% Tests for `bondy_oplog_core:subscribe/2` + the reference dispatcher
%% (`MST_DB_DESIGN.md` §12, wired in D8).
%%
%% Pins: monitor-based cleanup, NS isolation, pattern matching
%% (`all`, `{prefix, _}`, `{match, F}`, exact), best-effort delivery,
%% and the public `publish/4` facade.
%% =============================================================================

-module(bondy_oplog_core_subscribe_test).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    ok.

subscribe_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun subscribe_returns_a_reference/0,
        fun all_pattern_receives_every_event/0,
        fun exact_pattern_receives_only_matching_key/0,
        fun prefix_binary_pattern_matches_by_prefix/0,
        fun prefix_list_pattern_matches_by_prefix/0,
        fun prefix_pattern_with_type_mismatch_does_not_match/0,
        fun match_fun_pattern_filters_events/0,
        fun match_fun_throwing_is_treated_as_false/0,
        fun unsubscribe_stops_delivery/0,
        fun subscriber_down_cleans_up_subscription/0,
        fun ns_isolation_other_ns_events_not_delivered/0,
        fun multiple_subscribers_all_receive_matching/0,
        fun unsubscribe_unknown_ref_is_idempotent/0,
        fun bootstrap_reaches_an_all_subscriber/0,
        fun bootstrap_ignores_the_key_pattern/0,
        fun bootstrap_respects_ns_isolation/0,
        fun bootstrap_reaches_every_subscriber_of_the_ns/0
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

%% A catalogue-snapshot install replaced a table's projection wholesale.
%% Unlike `publish/4` and `publish_merge/5` this event carries NO key, so it
%% cannot be pattern-matched — see `bootstrap_ignores_the_key_pattern/0`.
bootstrap_reaches_an_all_subscriber() ->
    NS = some_ns(),
    {ok, Ref} = bondy_oplog_core:subscribe(NS, all),
    ok = bondy_oplog_core:publish_bootstrap(NS, <<"some_bucket">>),
    ?assertEqual(
        [{bondy_oplog_core_bootstrap_event, NS, <<"some_bucket">>}],
        drain_bootstrap()
    ),
    ok = bondy_oplog_core:unsubscribe(Ref).

%% THE LOAD-BEARING PROPERTY. A `{prefix, _}`/`{exact, _}` subscriber cares
%% about a slice of the keyspace, and a wholesale replace changes that slice
%% too — but there is no key to test the pattern against. Filtering this
%% event by pattern would silently skip exactly the subscribers that most
%% need to rebuild, so delivery MUST ignore the pattern. Asserted here
%% rather than argued in a comment.
bootstrap_ignores_the_key_pattern() ->
    NS = some_ns(),
    {ok, R1} = bondy_oplog_core:subscribe(NS, {prefix, <<"zzz">>}),
    {ok, R2} = bondy_oplog_core:subscribe(NS, {exact, <<"nothing">>}),
    {ok, R3} = bondy_oplog_core:subscribe(NS, {match, fun(_) -> false end}),
    ok = bondy_oplog_core:publish_bootstrap(NS, <<"b">>),
    ?assertEqual(
        [
            {bondy_oplog_core_bootstrap_event, NS, <<"b">>},
            {bondy_oplog_core_bootstrap_event, NS, <<"b">>},
            {bondy_oplog_core_bootstrap_event, NS, <<"b">>}
        ],
        drain_bootstrap(),
        "a wholesale replace has no key, so no pattern may filter it out"
    ),
    ok = bondy_oplog_core:unsubscribe(R1),
    ok = bondy_oplog_core:unsubscribe(R2),
    ok = bondy_oplog_core:unsubscribe(R3).

%% Ignoring the PATTERN must not mean ignoring the NAMESPACE.
bootstrap_respects_ns_isolation() ->
    NS = some_ns(),
    Other = some_ns(),
    {ok, Ref} = bondy_oplog_core:subscribe(NS, all),
    ok = bondy_oplog_core:publish_bootstrap(Other, <<"b">>),
    ?assertEqual([], drain_bootstrap()),
    ok = bondy_oplog_core:unsubscribe(Ref).

bootstrap_reaches_every_subscriber_of_the_ns() ->
    NS = some_ns(),
    Parent = self(),
    Pids = [
        spawn(fun() ->
            {ok, _} = bondy_oplog_core:subscribe(NS, all),
            Parent ! {ready, self()},
            receive
                {bondy_oplog_core_bootstrap_event, _, _} = M ->
                    Parent ! {got, self(), M}
            after 5000 -> Parent ! {timeout, self()}
            end
        end)
     || _ <- lists:seq(1, 3)
    ],
    _ = [
        receive
            {ready, P} -> ok
        after 5000 -> error({subscriber_never_ready, P})
        end
     || P <- Pids
    ],
    ok = bondy_oplog_core:publish_bootstrap(NS, <<"b">>),
    _ = [
        receive
            {got, P, _} -> ok;
            {timeout, P} -> error({subscriber_missed_bootstrap, P})
        after 10000 -> error({no_reply, P})
        end
     || P <- Pids
    ],
    ok.

subscribe_returns_a_reference() ->
    {ok, Ref} = bondy_oplog_core:subscribe(some_ns(), all),
    ?assert(is_reference(Ref)),
    ok = bondy_oplog_core:unsubscribe(Ref).

all_pattern_receives_every_event() ->
    NS = some_ns(),
    {ok, Ref} = bondy_oplog_core:subscribe(NS, all),
    ok = bondy_oplog_core:publish(NS, <<"a">>, 1, op_a),
    ok = bondy_oplog_core:publish(NS, <<"b">>, 2, op_b),
    Msgs = drain(),
    ?assertEqual(
        [
            {bondy_oplog_core_event, NS, <<"a">>, 1, op_a},
            {bondy_oplog_core_event, NS, <<"b">>, 2, op_b}
        ],
        Msgs
    ),
    ok = bondy_oplog_core:unsubscribe(Ref).

exact_pattern_receives_only_matching_key() ->
    NS = some_ns(),
    {ok, Ref} = bondy_oplog_core:subscribe(NS, {exact, <<"want">>}),
    ok = bondy_oplog_core:publish(NS, <<"nope">>, 1, x),
    ok = bondy_oplog_core:publish(NS, <<"want">>, 2, y),
    ok = bondy_oplog_core:publish(NS, <<"also-nope">>, 3, z),
    ?assertEqual(
        [{bondy_oplog_core_event, NS, <<"want">>, 2, y}],
        drain()
    ),
    ok = bondy_oplog_core:unsubscribe(Ref).

prefix_binary_pattern_matches_by_prefix() ->
    NS = some_ns(),
    {ok, Ref} = bondy_oplog_core:subscribe(NS, {prefix, <<"user:">>}),
    ok = bondy_oplog_core:publish(NS, <<"user:42">>, 1, hit1),
    ok = bondy_oplog_core:publish(NS, <<"other:7">>, 2, miss),
    ok = bondy_oplog_core:publish(NS, <<"user:99">>, 3, hit2),
    %% A key shorter than the prefix never matches.
    ok = bondy_oplog_core:publish(NS, <<"us">>, 4, miss2),
    ?assertEqual(
        [
            {bondy_oplog_core_event, NS, <<"user:42">>, 1, hit1},
            {bondy_oplog_core_event, NS, <<"user:99">>, 3, hit2}
        ],
        drain()
    ),
    ok = bondy_oplog_core:unsubscribe(Ref).

prefix_list_pattern_matches_by_prefix() ->
    NS = some_ns(),
    {ok, Ref} = bondy_oplog_core:subscribe(NS, {prefix, [a, b]}),
    ok = bondy_oplog_core:publish(NS, [a, b, c], 1, hit),
    ok = bondy_oplog_core:publish(NS, [a, x], 2, miss),
    ok = bondy_oplog_core:publish(NS, [a, b], 3, hit2),
    ?assertEqual(
        [
            {bondy_oplog_core_event, NS, [a, b, c], 1, hit},
            {bondy_oplog_core_event, NS, [a, b], 3, hit2}
        ],
        drain()
    ),
    ok = bondy_oplog_core:unsubscribe(Ref).

prefix_pattern_with_type_mismatch_does_not_match() ->
    %% A binary prefix against a list key is a no-match, not a crash.
    NS = some_ns(),
    {ok, Ref} = bondy_oplog_core:subscribe(NS, {prefix, <<"p">>}),
    ok = bondy_oplog_core:publish(NS, [a, b], 1, _Op = z),
    ?assertEqual([], drain()),
    ok = bondy_oplog_core:unsubscribe(Ref).

match_fun_pattern_filters_events() ->
    NS = some_ns(),
    Pred = fun
        (K) when is_binary(K) -> byte_size(K) > 3;
        (_) -> false
    end,
    {ok, Ref} = bondy_oplog_core:subscribe(NS, {match, Pred}),
    ok = bondy_oplog_core:publish(NS, <<"ab">>, 1, miss),
    ok = bondy_oplog_core:publish(NS, <<"abcd">>, 2, hit),
    ok = bondy_oplog_core:publish(NS, <<"abcde">>, 3, hit2),
    ?assertEqual(
        [
            {bondy_oplog_core_event, NS, <<"abcd">>, 2, hit},
            {bondy_oplog_core_event, NS, <<"abcde">>, 3, hit2}
        ],
        drain()
    ),
    ok = bondy_oplog_core:unsubscribe(Ref).

match_fun_throwing_is_treated_as_false() ->
    %% A predicate that throws on some inputs must not propagate; the
    %% dispatcher silently treats it as a non-match.
    NS = some_ns(),
    Pred = fun(K) when is_binary(K) -> byte_size(K) > 3 end,
    {ok, Ref} = bondy_oplog_core:subscribe(NS, {match, Pred}),
    ok = bondy_oplog_core:publish(NS, not_a_binary, 1, miss),
    ok = bondy_oplog_core:publish(NS, <<"abcd">>, 2, hit),
    ?assertEqual(
        [{bondy_oplog_core_event, NS, <<"abcd">>, 2, hit}],
        drain()
    ),
    ok = bondy_oplog_core:unsubscribe(Ref).

unsubscribe_stops_delivery() ->
    NS = some_ns(),
    {ok, Ref} = bondy_oplog_core:subscribe(NS, all),
    ok = bondy_oplog_core:publish(NS, <<"k">>, 1, before),
    ok = bondy_oplog_core:unsubscribe(Ref),
    ok = bondy_oplog_core:publish(NS, <<"k">>, 2, ignored),
    ?assertEqual(
        [{bondy_oplog_core_event, NS, <<"k">>, 1, before}],
        drain()
    ).

subscriber_down_cleans_up_subscription() ->
    NS = some_ns(),
    Parent = self(),
    Pid = spawn(fun() ->
        {ok, _Ref} = bondy_oplog_core:subscribe(NS, all),
        Parent ! ready,
        receive
            go_down -> ok
        end
    end),
    Mon = erlang:monitor(process, Pid),
    receive
        ready -> ok
    end,
    Before = bondy_oplog_core_dispatcher:subscription_count(),
    ?assert(Before >= 1),
    Pid ! go_down,
    receive
        {'DOWN', Mon, process, Pid, _} -> ok
    end,
    %% Give the dispatcher a brief moment to process the DOWN.
    ok = sync_with_dispatcher(),
    After = bondy_oplog_core_dispatcher:subscription_count(),
    ?assertEqual(Before - 1, After).

ns_isolation_other_ns_events_not_delivered() ->
    NS1 = some_ns(),
    NS2 = some_ns(),
    {ok, Ref} = bondy_oplog_core:subscribe(NS1, all),
    ok = bondy_oplog_core:publish(NS2, <<"k">>, 1, irrelevant),
    ok = bondy_oplog_core:publish(NS1, <<"k">>, 2, mine),
    ?assertEqual(
        [{bondy_oplog_core_event, NS1, <<"k">>, 2, mine}],
        drain()
    ),
    ok = bondy_oplog_core:unsubscribe(Ref).

multiple_subscribers_all_receive_matching() ->
    %% Two subscribers, both `all` on the same NS — both must receive.
    %% Use spawned subscribers so we can collect from them independently.
    NS = some_ns(),
    Parent = self(),
    Sub1 = spawn(fun() ->
        {ok, _R} = bondy_oplog_core:subscribe(NS, all),
        Parent ! {ready, 1},
        Msgs = drain(50),
        Parent ! {msgs, 1, Msgs}
    end),
    Sub2 = spawn(fun() ->
        {ok, _R} = bondy_oplog_core:subscribe(NS, all),
        Parent ! {ready, 2},
        Msgs = drain(50),
        Parent ! {msgs, 2, Msgs}
    end),
    receive
        {ready, 1} -> ok
    end,
    receive
        {ready, 2} -> ok
    end,
    ok = bondy_oplog_core:publish(NS, <<"k">>, 1, op),
    Msgs1 =
        receive
            {msgs, 1, M1} -> M1
        after 200 -> []
        end,
    Msgs2 =
        receive
            {msgs, 2, M2} -> M2
        after 200 -> []
        end,
    ?assertEqual([{bondy_oplog_core_event, NS, <<"k">>, 1, op}], Msgs1),
    ?assertEqual([{bondy_oplog_core_event, NS, <<"k">>, 1, op}], Msgs2),
    %% Subscribers exit on their own; DOWN cleans up.
    _ = Sub1,
    _ = Sub2,
    ok.

unsubscribe_unknown_ref_is_idempotent() ->
    %% Unsubscribing a ref that was never registered is a no-op.
    ?assertEqual(ok, bondy_oplog_core:unsubscribe(erlang:make_ref())).

%% =============================================================================
%% Helpers
%% =============================================================================

some_ns() ->
    list_to_atom(
        "mst_db_sub_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

drain() ->
    drain(20).

%% `drain/2` receives only the 5-tuple change event, so it is structurally
%% blind to the 3-tuple bootstrap event. Kept separate rather than widened:
%% the existing tests rely on `drain/0` filtering everything else out.
drain_bootstrap() ->
    drain_bootstrap(20, []).

drain_bootstrap(TimeoutMs, Acc) ->
    receive
        {bondy_oplog_core_bootstrap_event, _, _} = M ->
            drain_bootstrap(TimeoutMs, [M | Acc])
    after TimeoutMs ->
        lists:reverse(Acc)
    end.

drain(TimeoutMs) ->
    drain(TimeoutMs, []).

drain(TimeoutMs, Acc) ->
    receive
        {bondy_oplog_core_event, _, _, _, _} = M -> drain(TimeoutMs, [M | Acc])
    after TimeoutMs ->
        lists:reverse(Acc)
    end.

%% Force a flush of pending casts/info messages through the dispatcher
%% via a synchronous call. Returns when the dispatcher mailbox has
%% drained past whatever was queued before this call.
sync_with_dispatcher() ->
    _ = bondy_oplog_core_dispatcher:subscription_count(),
    %% subscription_count() is a plain ets:info — it does not flush.
    %% Use a real gen_server roundtrip:
    _ = sys:get_state(bondy_oplog_core_dispatcher),
    ok.
