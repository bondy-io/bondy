%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_broker_bridge_manager_SUITE).

-moduledoc """
Regression suite for `bondy_broker_bridge_manager`.

Every case here corresponds to a defect that made the subsystem unusable: the
manager could not start once a bridge was enabled, `subscribe/5` reported an
error for a subscription it had just created, `terminate/2` was never reached,
and evaluating an action made a `gen_server` call into the manager on every
single event.

The suite drives the real boot path -- `application:start/1` reading the
`bridges` app env and the JSON specification named by `config_file` -- because
that is where the first defect lived. `bondy_test_bridge` stands in for a real
sink, so nothing here needs a broker or a network.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.bondy_broker_bridge.test">>).

all() ->
    [
        enabled_bridge_with_subscription_starts,
        disabled_bridge_creates_no_subscription,
        event_is_bridged,
        base_context_reaches_template,
        unresolvable_template_variable_drops_event,
        bad_subscription_does_not_stop_manager,
        subscribe_returns_the_subscription_id,
        bridging_survives_a_busy_manager,
        resubscribe_after_restart_delivers,
        terminate_is_called_with_reason_and_context
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    ok = add_realm(?REALM),
    ok = bondy_test_bridge:start(),
    {module, _} = code:ensure_loaded(bondy_test_bridge),
    Config.

end_per_suite(_Config) ->
    _ = stop_bridge_app(),
    ok = bondy_test_bridge:stop(),
    ok.

%% Each case gets its own topic. Tearing the app down unsubscribes its
%% subscribers, but the registry drops their entries asynchronously, so cases
%% sharing a topic race each other. `resubscribe_after_restart_delivers`
%% exercises reuse of a single topic deliberately, which is the case a
%% specification reload actually hits.
init_per_testcase(Case, Config) ->
    ok = bondy_test_bridge:reset(),
    Topic = <<"com.example.bridge.", (atom_to_binary(Case, utf8))/binary>>,
    [{topic, Topic} | Config].

end_per_testcase(_Case, _Config) ->
    _ = stop_bridge_app(),
    ok.

%% =============================================================================
%% TESTS
%% =============================================================================

-doc """
The manager starts with an enabled bridge whose specification declares a
subscription.

`bondy_broker:subscribe/4` answers `{ok, {Id, Pid}}` for a fun subscriber, but
`load_config/2` asserted `{ok, _, _}`. The resulting badmatch escaped
`handle_continue/2` and stopped the manager, so enabling any bridge at all took
the subsystem down at boot. Every other case in this suite depends on this one.
""".
enabled_bridge_with_subscription_starts(Config) ->
    Topic = ?config(topic, Config),
    ?assertMatch({ok, _}, start_bridge_app(Config, [subscription(Topic)])),
    ?assert(is_pid(whereis(bondy_broker_bridge_manager))),
    ?assertEqual(1, length(subscriptions())).

-doc """
A subscription naming a disabled bridge is skipped rather than instantiated.

Disabled is the default for every bridge, so this is the state a stock node
boots in.
""".
disabled_bridge_creates_no_subscription(Config) ->
    Topic = ?config(topic, Config),
    Bridges = [{bondy_test_bridge, [{enabled, false}]}],
    ?assertMatch(
        {ok, _}, start_bridge_app(Config, [subscription(Topic)], Bridges)
    ),
    ?assertEqual([], subscriptions()).

-doc """
A published event reaches the bridge with its action template evaluated.
""".
event_is_bridged(Config) ->
    Topic = ?config(topic, Config),
    {ok, _} = start_bridge_app(Config, [subscription(Topic)]),

    ok = publish(Topic, [<<"payload">>], #{<<"k">> => <<"v">>}),

    [Action] = await_actions(1),
    ?assertEqual(<<"payload">>, maps:get(<<"body">>, Action)).

-doc """
The map returned by a bridge's `init/1` is in scope inside an action template.

This is also the assertion that the base context is resolved at all: it used to
be fetched per event through a `gen_server` call into the manager.
""".
base_context_reaches_template(Config) ->
    Topic = ?config(topic, Config),
    {ok, _} = start_bridge_app(Config, [subscription(Topic)]),

    ok = publish(Topic, [<<"x">>], #{}),

    [Action] = await_actions(1),
    ?assertEqual(<<"from_init">>, maps:get(<<"tag">>, Action)).

-doc """
An action referencing a variable that is not in scope sends nothing.

`mops` raises `{badkeypath, _}` rather than rendering an empty string, and
`bondy_subscriber` catches it, so the event is dropped. A half-rendered message
must never reach a sink.
""".
unresolvable_template_variable_drops_event(Config) ->
    Topic = ?config(topic, Config),
    GoodTopic = <<Topic/binary, ".good">>,
    %% The control subscription proves delivery works at all. Asserting only
    %% that nothing arrives would pass just as well if no event were ever
    %% delivered, which is exactly how this case first passed for the wrong
    %% reason.
    Subs = [
        subscription(Topic, <<"{{event.kwargs.absent}}">>),
        subscription(GoodTopic, <<"{{event.args |> head}}">>)
    ],
    {ok, _} = start_bridge_app(Config, Subs),
    ?assertEqual(2, length(subscriptions())),

    ok = publish(Topic, [<<"dropped">>], #{}),
    ok = publish(GoodTopic, [<<"delivered">>], #{}),

    [Action] = await_actions(1),
    ?assertEqual(<<"delivered">>, maps:get(<<"body">>, Action)),

    %% Give the bad one every chance to arrive late before concluding.
    ?assertEqual([<<"delivered">>], bodies(actions_after(500))),

    %% The failed action did not take its subscriber down with it.
    ?assertEqual(2, length(subscriptions())).

-doc """
One subscription that cannot be created does not stop the manager.

A specification is validated as a whole before anything starts, so a failure at
this point is environmental. Stopping here would turn a single bad subscription
into a supervisor restart loop that takes every other bridge with it.
""".
bad_subscription_does_not_stop_manager(Config) ->
    Topic = ?config(topic, Config),
    BadTopic = <<Topic/binary, ".bad">>,
    Bad = (subscription(BadTopic))#{
        <<"match">> => #{
            <<"realm">> => <<"com.example.realm.that.does.not.exist">>,
            <<"topic">> => BadTopic,
            <<"options">> => #{<<"match">> => <<"exact">>}
        }
    },
    ?assertMatch(
        {ok, _}, start_bridge_app(Config, [subscription(Topic), Bad])
    ),
    ?assert(is_pid(whereis(bondy_broker_bridge_manager))),

    %% The good subscription is live and still bridges.
    ok = publish(Topic, [<<"survivor">>], #{}),
    [Action] = await_actions(1),
    ?assertEqual(<<"survivor">>, maps:get(<<"body">>, Action)).

-doc """
`subscribe/5` answers `{ok, Id}` for a subscription it created.

It used to match `{ok, Id, _Pid}` inside a `try ... of`, so a successful
subscribe raised `try_clause` and was reported as an error -- after the
subscriber had been started.
""".
subscribe_returns_the_subscription_id(Config) ->
    Topic = ?config(topic, Config),
    {ok, _} = start_bridge_app(Config, []),

    Action = action(<<"{{event.args |> head}}">>),
    Result = bondy_broker_bridge_manager:subscribe(
        ?REALM,
        #{match => <<"exact">>},
        Topic,
        bondy_test_bridge,
        Action
    ),
    ?assertMatch({ok, Id} when is_integer(Id), Result),

    %% And the subscription it reported really does bridge events.
    ok = publish(Topic, [<<"via_api">>], #{}),
    [Applied] = await_actions(1),
    ?assertEqual(<<"via_api">>, maps:get(<<"body">>, Applied)).

-doc """
Events are bridged while the manager is blocked.

Evaluating an action used to call `bridge/1`, a `gen_server:call` into the
manager, on every event from every subscriber -- a single mailbox in front of
all bridge traffic on the node. Suspending the manager is the sharpest way to
show the dependency is gone: before the fix this case times out.
""".
bridging_survives_a_busy_manager(Config) ->
    Topic = ?config(topic, Config),
    {ok, _} = start_bridge_app(Config, [subscription(Topic)]),

    ok = sys:suspend(bondy_broker_bridge_manager),
    try
        ok = publish(Topic, [<<"while_suspended">>], #{}),
        [Action] = await_actions(1),
        ?assertEqual(<<"while_suspended">>, maps:get(<<"body">>, Action))
    after
        ok = sys:resume(bondy_broker_bridge_manager)
    end.

-doc """
Restarting the bridge on the same topic keeps delivering, exactly once.

This is what reloading a specification does. Subscribers live under
`bondy_subscribers_sup` in the router app rather than under this app's tree, so
if shutdown does not unsubscribe them the old generation stays live and every
event is delivered once per generation. Before `trap_exit`, `terminate/2` never
ran and this case saw two actions for one publish.
""".
resubscribe_after_restart_delivers(Config) ->
    Topic = ?config(topic, Config),

    {ok, _} = start_bridge_app(Config, [subscription(Topic)]),
    ok = publish(Topic, [<<"first">>], #{}),
    ?assertEqual([<<"first">>], bodies(await_actions(1))),

    ok = stop_bridge_app(),
    ok = bondy_test_bridge:reset(),

    {ok, _} = start_bridge_app(Config, [subscription(Topic)]),
    ?assertEqual(1, length(subscriptions())),

    ok = publish(Topic, [<<"second">>], #{}),
    ?assertEqual([<<"second">>], bodies(await_actions(1))),

    %% Exactly once: the previous generation of subscribers is gone.
    ?assertEqual([<<"second">>], bodies(actions_after(500))).

-doc """
Shutting the manager down calls `terminate/2` on every initialised bridge.

The behaviour declares `terminate/2` but the manager called `terminate/1`, so
shutdown failed with `undef` and no bridge ever got to release anything.
""".
terminate_is_called_with_reason_and_context(Config) ->
    Topic = ?config(topic, Config),
    {ok, _} = start_bridge_app(Config, [subscription(Topic)]),
    ?assertEqual([], bondy_test_bridge:terminations()),

    ok = stop_bridge_app(),

    [{Reason, Ctxt}] = bondy_test_bridge:terminations(),
    ?assertEqual(shutdown, Reason),
    %% The context is what `init/1` returned, so a bridge can release exactly
    %% what it acquired.
    ?assertEqual(#{<<"test">> => #{<<"tag">> => <<"from_init">>}}, Ctxt).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
start_bridge_app(Config, Subscriptions) ->
    start_bridge_app(
        Config, Subscriptions, [{bondy_test_bridge, [{enabled, true}]}]
    ).

%% @private
%% Drives the real boot path: the app reads `bridges` from its env and loads the
%% JSON specification named by `config_file` inside `handle_continue/2`.
start_bridge_app(Config, Subscriptions, Bridges) ->
    _ = stop_bridge_app(),
    File = write_spec(Config, Subscriptions),
    ok = application:set_env(bondy_broker_bridge, bridges, Bridges),
    ok = application:set_env(bondy_broker_bridge, config_file, File),
    Res = application:ensure_all_started(bondy_broker_bridge),
    ok = await_bridges_loaded(Res),
    Res.

%% @private
%% `application:ensure_all_started/1` returns once `init/1` has returned, but
%% the specification is loaded and the subscriptions created in
%% `handle_continue/2`, which runs afterwards. So a started app does not yet
%% imply a live subscriber, and publishing straight away loses the event.
%%
%% A `gen_server` call is an exact barrier: `handle_continue/2` is guaranteed to
%% run before the first `handle_call/3`, so by the time this returns every
%% subscription in the specification has been attempted.
await_bridges_loaded({ok, _}) ->
    _ = bondy_broker_bridge_manager:bridges(),
    ok;
await_bridges_loaded(_) ->
    ok.

%% @private
stop_bridge_app() ->
    application:stop(bondy_broker_bridge).

%% @private
write_spec(Config, Subscriptions) ->
    Spec = #{
        <<"id">> => <<"test">>,
        <<"kind">> => <<"broker_bridge">>,
        <<"version">> => <<"v1.0">>,
        <<"meta">> => #{},
        <<"subscriptions">> => Subscriptions
    },
    Dir = ?config(priv_dir, Config),
    File = filename:join(Dir, "broker_bridge_test_config.json"),
    ok = file:write_file(File, bondy_wamp_json:encode(Spec)),
    File.

%% @private
subscription(Topic) ->
    subscription(Topic, <<"{{event.args |> head}}">>).

%% @private
subscription(Topic, BodyTemplate) ->
    #{
        <<"bridge">> => <<"bondy_test_bridge">>,
        <<"meta">> => #{},
        <<"match">> => #{
            <<"realm">> => ?REALM,
            <<"topic">> => Topic,
            <<"options">> => #{<<"match">> => <<"exact">>}
        },
        <<"action">> => action(BodyTemplate)
    }.

%% @private
action(BodyTemplate) ->
    #{
        <<"tag">> => <<"{{test.tag}}">>,
        <<"body">> => BodyTemplate,
        <<"meta">> => #{}
    }.

%% @private
publish(Topic, Args, KWArgs) ->
    Ref = bondy_ref:new(internal, self()),
    Ctxt = bondy_context:local_context(?REALM, Ref),
    ReqId = bondy_message_id:global(),
    case bondy_broker:publish(ReqId, #{}, Topic, Args, KWArgs, Ctxt) of
        {ok, _} -> ok;
        Other -> Other
    end.

%% @private
subscriptions() ->
    bondy_broker_bridge_manager:subscriptions(bondy_test_bridge).

%% @private
bodies(Actions) ->
    [maps:get(<<"body">>, A) || A <- Actions].

%% @private
%% Delivery is asynchronous, so poll rather than sleep a fixed amount.
await_actions(N) ->
    await_actions(N, 50).

%% @private
await_actions(N, 0) ->
    Actions = bondy_test_bridge:actions(),
    ct:fail({expected_actions, N, got, Actions});
await_actions(N, Retries) ->
    case bondy_test_bridge:actions() of
        Actions when length(Actions) >= N ->
            Actions;
        _ ->
            timer:sleep(100),
            await_actions(N, Retries - 1)
    end.

%% @private
%% For the negative case: wait long enough that an action would have arrived.
actions_after(Millis) ->
    timer:sleep(Millis),
    bondy_test_bridge:actions().

%% @private
add_realm(RealmUri) ->
    Cfg = #{
        uri => RealmUri,
        security_enabled => false
    },
    _ = bondy_realm:create(Cfg),
    ok.
