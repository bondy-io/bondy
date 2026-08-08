%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_api_SUITE).

-moduledoc """
The `bondy.mail.*` WAMP surface, against a real SMTP server.

The cases worth reading are the ones about the realm.
`naming_another_realm_is_refused` is the whole of the anti-spoofing argument at
this layer: a caller in one realm has nowhere to say it is acting for another,
and the attempt is refused rather than quietly reinterpreted.
`relay_list_hides_unpermitted_relays` is the same idea read the other way -- a
realm is not shown relays it would be refused, because a list of things you
cannot have is an invitation to try them.

Everything is driven through `bondy_wamp_api:handle_call/3`, the same entry
point the dealer uses, so the dispatcher's prefix chain is exercised rather
than assumed. The dealer's own `bondy_rbac:authorize(<<"wamp.call">>, Uri,
Ctxt)` runs before that entry point and is covered separately by
`granting_the_uri_is_what_gates_the_call`.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_uris.hrl").
-include("bondy.hrl").
-include("bondy_security.hrl").

-compile([export_all, nowarn_export_all]).

-define(REALM, ~"com.mail.api.test").
-define(OTHER, ~"com.mail.api.other").

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        %% Dispatch
        unknown_mail_procedure_is_reported,
        %% Send
        send_returns_an_id_and_a_status,
        send_async_returns_queued,
        send_reports_a_rejected_recipient,
        send_reports_an_unknown_relay,
        send_reports_an_unpermitted_sender,
        %% Realm
        realm_is_taken_from_the_session,
        naming_the_session_realm_is_accepted,
        naming_another_realm_is_refused,
        master_realm_may_act_for_another_realm,
        %% Status
        status_reports_a_sent_message,
        status_is_unknown_for_another_realm,
        mail_families_reach_the_prometheus_exposition,
        status_rejects_a_non_binary_id,
        %% Relays
        relay_list_hides_unpermitted_relays,
        relay_list_never_exposes_relay_internals,
        %% Test procedure
        test_is_refused_outside_the_master_realm,
        test_sends_through_the_relay,
        %% Arity
        too_many_arguments_is_reported,
        too_few_arguments_is_reported,
        %% Authorization
        granting_the_uri_is_what_gates_the_call,
        %% Dormancy
        dormant_node_reports_mail_not_configured
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),

    _ = bondy_realm:create(?REALM),
    _ = bondy_realm:create(?OTHER),
    ok = bondy_realm:disable_security(bondy_realm:fetch(?REALM)),
    ok = bondy_realm:disable_security(bondy_realm:fetch(?OTHER)),

    {ok, Port} = mock_smtp_server:start(),
    [
        {port, Port},
        {ctxt, bondy_context:local_context(?REALM)},
        {other_ctxt, bondy_context:local_context(?OTHER)},
        {admin_ctxt, bondy_context:local_context(?MASTER_REALM_URI)}
        | Config
    ].

end_per_suite(_Config) ->
    _ = application:stop(bondy_mail),
    ok = mock_smtp_server:stop(),
    ok.

init_per_testcase(dormant_node_reports_mail_not_configured, Config) ->
    ok = restart([]),
    Config;
init_per_testcase(_Case, Config) ->
    ok = mock_smtp_server:clear(),
    ok = restart(relays(?config(port, Config))),
    Config.

end_per_testcase(_Case, _Config) ->
    ok.

%% =============================================================================
%% DISPATCH
%% =============================================================================

-doc """
An unknown `bondy.mail.*` procedure is reported as such rather than crashing
the dispatcher, which is what a bare prefix clause with no catch-all would do.
""".
unknown_mail_procedure_is_reported(Config) ->
    E = call_error(~"bondy.mail.does_not_exist", [], Config),
    ?assertEqual(?WAMP_NO_SUCH_PROCEDURE, E#error.error_uri).

%% =============================================================================
%% SEND
%% =============================================================================

send_returns_an_id_and_a_status(Config) ->
    Result = call_ok(?BONDY_MAIL_SEND, [request()], Config),

    ?assertMatch(
        [#{id := <<_/binary>>, status := sent, attempts := 1}],
        Result#result.args
    ),
    ?assertEqual(1, length(mock_smtp_server:messages())).

send_async_returns_queued(Config) ->
    Result = call_ok(?BONDY_MAIL_SEND_ASYNC, [request()], Config),
    ?assertMatch([#{id := <<_/binary>>, status := queued}], Result#result.args),

    ok = await_messages(1).

-doc """
A relay's permanent refusal reaches the caller as `bondy.error.mail_rejected`,
carrying the reply code and none of the relay's own words.
""".
send_reports_a_rejected_recipient(Config) ->
    ok = mock_smtp_server:fail_data("550 5.1.1 <user@example.com> unknown"),

    E = call_error(?BONDY_MAIL_SEND, [request()], Config),

    ?assertEqual(~"bondy.error.mail_rejected", E#error.error_uri),

    %% The reply code and nothing else. Each needle below is a distinct part of
    %% the banner the relay actually sent, so a translation that passed any of
    %% it through fails here rather than only on an exact-string match that the
    %% banner never contained in the first place.
    ?assertEqual(
        #{~"code" => ~"550"}, maps:get(~"details", E#error.kwargs)
    ),
    Rendered = rendered(E),
    [
        ?assertEqual(nomatch, binary:match(Rendered, Needle))
     || Needle <- [~"5.1.1", ~"user@example.com", ~"unknown"]
    ].

send_reports_an_unknown_relay(Config) ->
    Req = (request())#{~"relay" => ~"nope"},
    E = call_error(?BONDY_MAIL_SEND, [Req], Config),

    ?assertEqual(~"bondy.error.no_such_relay", E#error.error_uri),
    ?assertMatch(#{~"relay" := ~"nope"}, maps:get(~"details", E#error.kwargs)).

-doc """
The spoofing case, end to end. `branded` allows `example.com` and nothing else,
so a caller claiming another domain is refused before anything is queued.
""".
send_reports_an_unpermitted_sender(Config) ->
    Req = (request())#{
        ~"relay" => ~"branded",
        ~"from" => ~"ceo@bank.example"
    },
    E = call_error(?BONDY_MAIL_SEND, [Req], Config),

    ?assertEqual(~"bondy.error.sender_not_permitted", E#error.error_uri),
    ?assertEqual([], mock_smtp_server:messages()).

%% =============================================================================
%% REALM
%% =============================================================================

-doc """
A caller sends no realm and gets its own.
""".
realm_is_taken_from_the_session(Config) ->
    _ = call_ok(?BONDY_MAIL_SEND, [request()], Config),
    ?assertEqual(1, length(mock_smtp_server:messages())).

naming_the_session_realm_is_accepted(Config) ->
    _ = call_ok(?BONDY_MAIL_SEND, [?REALM, request()], Config),
    ?assertEqual(1, length(mock_smtp_server:messages())).

-doc """
A session in one realm cannot act for another.

This is the anti-spoofing property at this layer. Note what is being refused:
not a bad sender address, but the very idea that a caller can nominate whose
mail this is. Everything downstream -- which relay, which `From` -- is decided
from the realm, so a caller that could choose the realm could choose the rest.
""".
naming_another_realm_is_refused(Config) ->
    E = call_error(?BONDY_MAIL_SEND, [?OTHER, request()], Config),

    ?assertEqual(?WAMP_NOT_AUTHORIZED, E#error.error_uri),
    ?assertEqual([], mock_smtp_server:messages()).

-doc """
The master realm is the one exception, and it comes from the shared helper
every `bondy.*` procedure uses rather than from anything mail-specific.
""".
master_realm_may_act_for_another_realm(Config) ->
    Ctxt = ?config(admin_ctxt, Config),
    _ = handle_ok(?BONDY_MAIL_SEND, [?REALM, request()], Ctxt),
    ?assertEqual(1, length(mock_smtp_server:messages())).

%% =============================================================================
%% STATUS
%% =============================================================================

status_reports_a_sent_message(Config) ->
    Sent = call_ok(?BONDY_MAIL_SEND, [request()], Config),
    [#{id := Id}] = Sent#result.args,

    Got = call_ok(?BONDY_MAIL_STATUS_GET, [Id], Config),
    ?assertMatch([#{id := Id, status := sent}], Got#result.args).

-doc """
Another realm gets `unknown`, not a refusal: a distinguishable answer would
turn message ids into a cross-tenant existence oracle.
""".
status_is_unknown_for_another_realm(Config) ->
    Sent = call_ok(?BONDY_MAIL_SEND, [request()], Config),
    [#{id := Id}] = Sent#result.args,

    %% Visible to the realm that sent it, so `unknown` below cannot be coming
    %% from a record that was never written.
    Mine = call_ok(?BONDY_MAIL_STATUS_GET, [Id], Config),
    ?assertMatch([#{status := sent}], Mine#result.args),

    Other = ?config(other_ctxt, Config),
    Got = handle_ok(?BONDY_MAIL_STATUS_GET, [Id], Other),
    ?assertMatch([#{status := unknown}], Got#result.args).

status_rejects_a_non_binary_id(Config) ->
    E = call_error(?BONDY_MAIL_STATUS_GET, [12345], Config),
    ?assertEqual(~"bondy.error.invalid_request", E#error.error_uri).

%% =============================================================================
%% RELAYS
%% =============================================================================

-doc """
A realm sees the relays it may use and no others.
""".
relay_list_hides_unpermitted_relays(Config) ->
    Result = call_ok(?BONDY_MAIL_RELAY_LIST, [], Config),
    [Relays] = Result#result.args,
    Names = lists:sort([maps:get(name, R) || R <- Relays]),

    %% `elsewhere` is scoped to a realm this session is not in.
    ?assertEqual([~"branded", ~"default"], Names),

    %% And the realm it IS scoped to sees it.
    Other = handle_ok(?BONDY_MAIL_RELAY_LIST, [], ?config(other_ctxt, Config)),
    [OtherRelays] = Other#result.args,
    ?assert(
        lists:member(~"elsewhere", [maps:get(name, R) || R <- OtherRelays])
    ).

-doc """
Never the host, the username or the credential. A relay is operator-owned
infrastructure and a realm administrator is not its operator.
""".
relay_list_never_exposes_relay_internals(Config) ->
    Result = call_ok(?BONDY_MAIL_RELAY_LIST, [], Config),
    [Relays] = Result#result.args,

    [
        ?assertEqual(
            [from, name, status, transport], lists:sort(maps:keys(R))
        )
     || R <- Relays
    ],

    Flat = iolist_to_binary(io_lib:format("~p", [Relays])),
    [
        ?assertEqual(nomatch, binary:match(Flat, Needle))
     || Needle <- [~"127.0.0.1", ~"mailer", ~"s3cret"]
    ].

%% =============================================================================
%% TEST PROCEDURE
%% =============================================================================

test_is_refused_outside_the_master_realm(Config) ->
    E = call_error(?BONDY_MAIL_TEST, [~"ops@example.com"], Config),
    ?assertEqual(?WAMP_NOT_AUTHORIZED, E#error.error_uri),
    ?assertEqual([], mock_smtp_server:messages()).

test_sends_through_the_relay(Config) ->
    Ctxt = ?config(admin_ctxt, Config),
    _ = handle_ok(?BONDY_MAIL_TEST, [~"ops@example.com"], Ctxt),

    [Msg] = mock_smtp_server:messages(),
    ?assertEqual([~"ops@example.com"], maps:get(to, Msg)).

%% =============================================================================
%% ARITY
%% =============================================================================

too_many_arguments_is_reported(Config) ->
    E = call_error(?BONDY_MAIL_SEND, [?REALM, request(), extra], Config),
    ?assertEqual(?WAMP_INVALID_ARGUMENT, E#error.error_uri).

too_few_arguments_is_reported(Config) ->
    E = call_error(?BONDY_MAIL_SEND, [], Config),
    ?assertEqual(?WAMP_INVALID_ARGUMENT, E#error.error_uri).

%% =============================================================================
%% AUTHORIZATION
%% =============================================================================

-doc """
`bondy.mail.send` needs no permission of its own.

The dealer authorises every call with the procedure URI as the RBAC resource,
and grants match by prefix and resolve through the realm's prototype. So the
URI is grantable and revocable per realm today, which is why `?BONDY_PERMISSIONS`
gained nothing for mail.

Asserted against `bondy_rbac:authorize/3` directly. The dealer's call to it is
unconditional and sits ahead of the dispatcher, so what is in question here is
whether the grant means anything -- not whether the dealer performs it.
""".
granting_the_uri_is_what_gates_the_call(_Config) ->
    Realm = ~"com.mail.api.rbac",
    _ = bondy_realm:create(Realm),
    _ = bondy_rbac_group:add(
        Realm, bondy_rbac_group:new(#{name => ~"senders"})
    ),
    {ok, _} = bondy_rbac_user:add(
        Realm,
        bondy_rbac_user:new(#{
            username => ~"mailer",
            password => ~"Abcd1234!",
            groups => [~"senders"]
        })
    ),

    Grant = #{
        roles => [~"senders"],
        permissions => [~"wamp.call"],
        uri => ?BONDY_MAIL_SEND
    },

    %% The RBAC context is built from the realm and the user, which is what a
    %% session would hand the dealer. Going through it directly keeps the case
    %% about the grant rather than about session setup.
    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(
            ~"wamp.call", ?BONDY_MAIL_SEND, rbac_ctxt(Realm)
        )
    ),

    ok = bondy_rbac:grant(Realm, Grant),
    ?assertEqual(
        ok,
        bondy_rbac:authorize(
            ~"wamp.call", ?BONDY_MAIL_SEND, rbac_ctxt(Realm)
        )
    ),

    %% Revoked, refused again -- with no mail-specific code involved either way.
    ok = bondy_rbac:revoke(Realm, Grant),
    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(
            ~"wamp.call", ?BONDY_MAIL_SEND, rbac_ctxt(Realm)
        )
    ).

%% =============================================================================
%% DORMANCY
%% =============================================================================

-doc """
With no relay configured every procedure answers the same way, and the node
still runs. Configuring email is an operator's choice.
""".
dormant_node_reports_mail_not_configured(Config) ->
    [
        ?assertEqual(
            ~"bondy.error.mail_not_configured",
            (call_error(Proc, Args, Config))#error.error_uri
        )
     || {Proc, Args} <- [
            {?BONDY_MAIL_SEND, [request()]},
            {?BONDY_MAIL_SEND_ASYNC, [request()]},
            {?BONDY_MAIL_RELAY_LIST, []}
        ]
    ].

-doc """
The families the Grafana dashboard queries appear in the exposition, with the
label names it filters on.

A dashboard that provisions cleanly still renders empty if a label is called
something other than what the panel says, and nothing else in the test suite
would notice: the emitter is consistent with itself, the sink is consistent
with the emitter, and only the query disagrees. This asserts the names on the
wire, which is the thing the panels are written against.

Only the two families a single successful send produces are asserted. The
others need a failure, a full queue or a rate limit to exist at all, and they
are covered by `bondy_mail_telemetry_SUITE` at the sink.
""".
mail_families_reach_the_prometheus_exposition(Config) ->
    _ = call_ok(?BONDY_MAIL_SEND, [request()], Config),

    Text = iolist_to_binary(bondy_prometheus:report()),

    %% The counter, with the label the dashboard groups by.
    ?assertMatch({_, _}, binary:match(Text, ~"bondy_mail_sent_total{")),
    ?assertMatch({_, _}, binary:match(Text, ~"relay=\"default\"")),

    %% The histogram, under the `_bucket` name and `le` the quantile queries
    %% use rather than the family name they are declared with.
    ?assertMatch(
        {_, _},
        binary:match(Text, ~"bondy_mail_send_duration_milliseconds_bucket{")
    ),

    %% And the surface label, which is the one thing about these families that
    %% is not derived from the relay.
    ?assertMatch({_, _}, binary:match(Text, ~"surface=\"rpc\"")).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Through the dispatcher rather than straight to `bondy_mail_api`, so the
%% prefix clause in `bondy_wamp_api` is covered by every case here.
handle(Proc, Args, Ctxt) ->
    M = bondy_wamp_message:call(1, #{}, Proc, Args),
    bondy_wamp_api:handle_call(M, Ctxt).

%% @private
handle_ok(Proc, Args, Ctxt) ->
    case handle(Proc, Args, Ctxt) of
        {reply, #result{} = R} -> R;
        Other -> ct:fail({expected_result, Other})
    end.

%% @private
call_ok(Proc, Args, Config) ->
    handle_ok(Proc, Args, ?config(ctxt, Config)).

%% @private
%% An arity or authorization failure is thrown rather than returned, because
%% `bondy_wamp_api_utils` reports those by raising. Both shapes are accepted so
%% a case does not have to know which one its procedure produces.
call_error(Proc, Args, Config) ->
    Ctxt = ?config(ctxt, Config),
    try handle(Proc, Args, Ctxt) of
        {reply, #error{} = E} -> E;
        Other -> ct:fail({expected_error, Other})
    catch
        error:#error{} = E -> E
    end.

%% @private
rendered(#error{} = E) ->
    iolist_to_binary(io_lib:format("~p", [{E#error.args, E#error.kwargs}])).

%% @private
request() ->
    #{
        ~"to" => [~"user@example.com"],
        ~"subject" => ~"Hello",
        ~"text" => ~"Body"
    }.

%% @private
%% Rebuilt on each assertion: a context is a snapshot of the grants at the
%% moment it was made, so reusing one across a grant would test nothing.
rbac_ctxt(RealmUri) ->
    bondy_rbac:get_context(RealmUri, ~"mailer").

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
restart(Relays) ->
    _ = application:stop(bondy_mail),
    ok = application:set_env(bondy_mail, relays, Relays),
    ok = application:set_env(bondy_mail, default_relay, default_relay(Relays)),
    {ok, _} = application:ensure_all_started(bondy_mail),
    ok.

%% @private
%% Three relays are declared, so a request that names none needs a default;
%% without one `default_relay/0` refuses rather than guessing.
default_relay([]) -> undefined;
default_relay(_) -> ~"default".

%% @private
relays(Port) ->
    Common = #{
        host => ~"127.0.0.1",
        port => Port,
        transport => plain,
        auth => never,
        username => ~"mailer",
        secret => #{provider => none, value => ~"s3cret"},
        from => ~"no-reply@example.com",
        retry_max_attempts => 0,
        retry_backoff_min => 10,
        retry_backoff_max => 50
    },
    [
        %% Open to every realm, so it is also what the master realm's test
        %% procedure reaches.
        Common#{name => ~"default", realms => any},
        %% Scoped to this suite's realm, and allowing only one sender domain.
        Common#{
            name => ~"branded",
            realms => [?REALM],
            allowed_from => [~"example.com"]
        },
        %% Scoped to the other realm, so it must not appear in this one's list.
        Common#{name => ~"elsewhere", realms => [?OTHER]}
    ].
