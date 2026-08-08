%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_smtp_bridge_SUITE).

-moduledoc """
Publish to a topic, read the email off a real SMTP server.

The whole path is exercised: a `bondy_broker_bridge` specification loaded from
JSON, a `mops`-expanded action, `bondy_mail`, and `gen_smtp` talking to a server
on the other end of a socket. Nothing is stubbed.

Two cases carry the design's central claims.
`missing_template_variable_sends_nothing` is the one that matters most for
correctness: a `mops` expression naming a key the event does not have must fail
the whole action, never render as an empty string. An email with a blank
greeting is worse than no email, because nobody finds out.

`stalled_relay_does_not_stall_publishing` is the claim the architecture exists
for: mail is queued, not sent, inside the subscriber, so a relay that stops
answering degrades email and leaves event handling alone. It is measured through
the subscriber's throughput rather than through how long `publish` takes --
delivery to a local subscriber is a cast, so the publisher returns before the
callback has run and would look fast however badly that callback behaved.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, ~"com.example.smtp_bridge.test").

all() ->
    [
        event_becomes_an_email,
        template_renders_into_the_message,
        relay_can_be_named_from_the_bridge_context,
        idempotency_key_sends_one_email,
        missing_template_variable_sends_nothing,
        unknown_action_key_is_rejected,
        action_without_a_realm_is_rejected,
        refused_sender_sends_nothing,
        stalled_relay_does_not_stall_publishing,
        dormant_mail_does_not_stop_the_bridge
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    ok = add_realm(?REALM),
    {ok, Port} = mock_smtp_server:start(),
    [{port, Port} | Config].

end_per_suite(_Config) ->
    _ = application:stop(bondy_broker_bridge),
    _ = application:stop(bondy_mail),
    ok = mock_smtp_server:stop(),
    ok.

init_per_testcase(dormant_mail_does_not_stop_the_bridge, Config) ->
    ok = mock_smtp_server:clear(),
    ok = restart_mail([]),
    [{topic, topic(dormant_mail_does_not_stop_the_bridge)} | Config];
init_per_testcase(Case, Config) ->
    ok = mock_smtp_server:clear(),
    ok = restart_mail(relays(?config(port, Config))),
    [{topic, topic(Case)} | Config].

end_per_testcase(_Case, _Config) ->
    _ = application:stop(bondy_broker_bridge),
    ok.

%% =============================================================================
%% TESTS
%% =============================================================================

event_becomes_an_email(Config) ->
    Topic = ?config(topic, Config),
    {ok, _} = start_bridge(Config, [subscription(Topic, action())]),

    ok = publish(Topic, [], #{~"email" => ~"user@example.com"}),

    [Msg] = await_messages(1),
    ?assertEqual([~"user@example.com"], maps:get(to, Msg)),
    ?assertEqual(~"no-reply@example.com", maps:get(from, Msg)).

-doc """
The action is a `mops` template and its expansion is what reaches the message.
""".
template_renders_into_the_message(Config) ->
    Topic = ?config(topic, Config),
    Action = (action())#{
        ~"subject" => ~"\"Welcome, {{event.kwargs.name}}\"",
        ~"text" => ~"\"Hello {{event.kwargs.name}}.\""
    },
    {ok, _} = start_bridge(Config, [subscription(Topic, Action)]),

    ok = publish(Topic, [], #{
        ~"email" => ~"user@example.com",
        ~"name" => ~"Ada"
    }),

    [Msg] = await_messages(1),
    ?assertEqual(~"Welcome, Ada", header(~"subject", Msg)),
    ?assertMatch({_, _}, binary:match(maps:get(data, Msg), ~"Hello Ada.")).

-doc """
`init/1` publishes the configured relay names, so a specification can name one
without repeating a string that also lives in `bondy.conf`.
""".
relay_can_be_named_from_the_bridge_context(Config) ->
    Topic = ?config(topic, Config),
    Action = (action())#{~"relay" => ~"{{mail.default_relay}}"},
    {ok, _} = start_bridge(Config, [subscription(Topic, Action)]),

    ok = publish(Topic, [], #{~"email" => ~"user@example.com"}),
    ?assertEqual(1, length(await_messages(1))).

-doc """
Two events carrying one idempotency key produce one email.
""".
idempotency_key_sends_one_email(Config) ->
    Topic = ?config(topic, Config),
    Action = (action())#{~"id" => ~"\"order-{{event.kwargs.order}}\""},
    {ok, _} = start_bridge(Config, [subscription(Topic, Action)]),

    KWArgs = #{~"email" => ~"user@example.com", ~"order" => ~"42"},
    ok = publish(Topic, [], KWArgs),
    _ = await_messages(1),

    ok = publish(Topic, [], KWArgs),
    %% Long enough that a second email would have arrived.
    timer:sleep(1000),
    ?assertEqual(1, length(mock_smtp_server:messages())),

    %% A different key does send, so the case above is deduplication rather
    %% than a second publish that quietly did nothing.
    ok = publish(Topic, [], KWArgs#{~"order" => ~"43"}),
    ?assertEqual(2, length(await_messages(2))).

-doc """
A template naming a key the event does not carry fails the action and sends
nothing.

This is the case worth reading. `mops` raises `{badkeypath, _}` rather than
rendering an empty string, so a half-addressed or half-written email is never
produced. A control subscription on a second topic proves the harness would
have delivered an email if one had been sent -- without it, this case would be
satisfied by a broker that delivered no events at all.
""".
missing_template_variable_sends_nothing(Config) ->
    Topic = ?config(topic, Config),
    Control = <<Topic/binary, ".control">>,

    Broken = (action())#{~"to" => ~"{{event.kwargs.does_not_exist}}"},
    {ok, _} = start_bridge(Config, [
        subscription(Topic, Broken),
        subscription(Control, action())
    ]),

    ok = publish(Topic, [], #{~"email" => ~"user@example.com"}),
    ok = publish(Control, [], #{~"email" => ~"control@example.com"}),

    %% The control email arrives, so the path works.
    [Msg] = await_messages(1),
    ?assertEqual([~"control@example.com"], maps:get(to, Msg)),

    %% And nothing else does.
    timer:sleep(500),
    ?assertEqual(1, length(mock_smtp_server:messages())).

-doc """
A key the request contract does not know is named rather than dropped, so a
misspelled field fails the action instead of producing an email missing it.
""".
unknown_action_key_is_rejected(_Config) ->
    Action = (action())#{~"subjekt" => ~"typo"},
    ?assertEqual(
        {error, {unknown_keys, [~"subjekt"]}},
        bondy_smtp_bridge:validate_action(Action)
    ).

action_without_a_realm_is_rejected(_Config) ->
    ?assertMatch(
        {error, _},
        bondy_smtp_bridge:validate_action(maps:remove(~"realm", action()))
    ).

-doc """
A sender outside the relay's `allowed_from` sends nothing.

The bridge does not enforce this and must not: it is enforced in `bondy_mail`,
which is the only layer the `bondy.mail.*` API also passes through. This case
exists to prove the bridge inherits it rather than bypassing it.
""".
refused_sender_sends_nothing(Config) ->
    Topic = ?config(topic, Config),
    Action = (action())#{
        ~"relay" => ~"branded",
        ~"from" => ~"ceo@bank.example"
    },
    {ok, _} = start_bridge(Config, [subscription(Topic, Action)]),

    ok = publish(Topic, [], #{~"email" => ~"user@example.com"}),

    timer:sleep(500),
    ?assertEqual([], mock_smtp_server:messages()).

-doc """
A stalled relay does not serialise event handling.

This is the design's central claim, and it is measured rather than assumed.

Note what is NOT measured: how long `publish` takes. Delivery to a local
subscriber is a cast, so the publisher returns before the subscriber has run and
would look fast however badly the callback behaved. What distinguishes the two
designs is the subscriber's own throughput. The relay holds every connection for
three seconds and the pool is four workers wide, so eight messages take exactly
two rounds -- about six seconds -- when the callback queues them. A callback that
waited for delivery would handle one event at a time and need `8 x 3s = 24s`.

"Exactly" because workers are chosen by rotation. While they were chosen by
hashing an eight-message burst landed 3/2/2/1 as readily as 2/2/2/2, and this
case passed or failed on the draw -- which is what surfaced the uneven spread
in the first place.

The bound sits between the two, far enough from six to tolerate a slow machine
and far enough from twenty-four to fail the shape that matters.
""".
stalled_relay_does_not_stall_publishing(Config) ->
    Topic = ?config(topic, Config),
    ok = mock_smtp_server:latency(3000),
    {ok, _} = start_bridge(Config, [subscription(Topic, action())]),

    Start = erlang:monotonic_time(millisecond),
    _ = [
        ok = publish(Topic, [], #{~"email" => ~"user@example.com"})
     || _ <- lists:seq(1, 8)
    ],
    _ = await_messages(8, 400),
    Elapsed = erlang:monotonic_time(millisecond) - Start,

    ?assert(
        Elapsed < 14000,
        lists:flatten(
            io_lib:format(
                "8 messages through a 4-worker pool took ~pms against a "
                "relay holding every connection for 3000ms. Two rounds is "
                "about 6000ms; one-at-a-time is about 24000ms, which is what "
                "waiting for delivery inside the subscriber would cost",
                [Elapsed]
            )
        )
    ).

-doc """
With no relay configured the bridge still starts, and the node with it.

Enabling email is an operator's choice; a bridge that refused to start would
turn a deliberate omission into a boot failure.
""".
dormant_mail_does_not_stop_the_bridge(Config) ->
    Topic = ?config(topic, Config),
    ?assertMatch(
        {ok, _}, start_bridge(Config, [subscription(Topic, action())])
    ),
    ?assert(is_pid(whereis(bondy_broker_bridge_manager))),

    ok = publish(Topic, [], #{~"email" => ~"user@example.com"}),
    timer:sleep(300),
    ?assertEqual([], mock_smtp_server:messages()).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
topic(Case) ->
    <<"com.example.smtp_bridge.", (atom_to_binary(Case, utf8))/binary>>.

%% @private
action() ->
    #{
        ~"realm" => ~"{{event.realm}}",
        ~"to" => ~"{{event.kwargs.email}}",
        ~"subject" => ~"Hello",
        ~"text" => ~"Body"
    }.

%% @private
subscription(Topic, Action) ->
    #{
        ~"bridge" => ~"bondy_smtp_bridge",
        ~"meta" => #{},
        ~"match" => #{
            ~"realm" => ?REALM,
            ~"topic" => Topic,
            ~"options" => #{~"match" => ~"exact"}
        },
        ~"action" => Action
    }.

%% @private
start_bridge(Config, Subscriptions) ->
    _ = application:stop(bondy_broker_bridge),
    File = write_spec(Config, Subscriptions),
    ok = application:set_env(bondy_broker_bridge, bridges, [
        {bondy_smtp_bridge, [{enabled, true}]}
    ]),
    ok = application:set_env(bondy_broker_bridge, config_file, File),
    Res = application:ensure_all_started(bondy_broker_bridge),
    %% Subscriptions are created in `handle_continue/2`, which runs before the
    %% first `handle_call/3` -- so this call is an exact barrier, and publishing
    %% without it races the subscriber into existence.
    _ = bondy_broker_bridge_manager:bridges(),
    Res.

%% @private
write_spec(Config, Subscriptions) ->
    Spec = #{
        ~"id" => ~"smtp_test",
        ~"kind" => ~"broker_bridge",
        ~"version" => ~"v1.0",
        ~"meta" => #{},
        ~"subscriptions" => Subscriptions
    },
    File = filename:join(?config(priv_dir, Config), "smtp_bridge_config.json"),
    ok = file:write_file(File, bondy_wamp_json:encode(Spec)),
    File.

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
add_realm(Uri) ->
    _ = bondy_realm:create(Uri),
    ok = bondy_realm:disable_security(bondy_realm:fetch(Uri)),
    ok.

%% @private
restart_mail(Relays) ->
    _ = application:stop(bondy_mail),
    ok = application:set_env(bondy_mail, relays, Relays),
    ok = application:set_env(
        bondy_mail, default_relay, default_relay(Relays)
    ),
    {ok, _} = application:ensure_all_started(bondy_mail),
    ok.

%% @private
default_relay([]) -> undefined;
default_relay(_) -> ~"default".

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
        Common#{name => ~"branded", allowed_from => [~"example.com"]}
    ].

%% @private
header(Name, Msg) ->
    maps:get(Name, maps:get(headers, Msg), undefined).

%% @private
await_messages(N) ->
    await_messages(N, 80).

%% @private
await_messages(N, 0) ->
    ct:fail({expected_messages, N, got, mock_smtp_server:messages()});
await_messages(N, Retries) ->
    case mock_smtp_server:messages() of
        Msgs when length(Msgs) >= N ->
            Msgs;
        _ ->
            timer:sleep(100),
            await_messages(N, Retries - 1)
    end.
