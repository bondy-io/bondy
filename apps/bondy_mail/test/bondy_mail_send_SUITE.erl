%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_send_SUITE).

-moduledoc """
The send path, against a real SMTP server.

`mock_smtp_server` is a `gen_smtp_server_session` callback module, not a mock
of the client, so these cases exercise the actual protocol conversation:
`MAIL FROM`, `RCPT TO`, `DATA`, the reply codes, and the bytes on the wire.

The classification cases are the ones worth reading. A `4xx` and a `5xx` are
both "the relay said no", and the entire retry policy turns on telling them
apart -- so each is asserted by the number of times the relay was actually
asked, not by the shape of the return value alone.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_mail/include/bondy_mail.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, ~"com.example.app").

all() ->
    [
        %% Delivery
        message_is_delivered,
        envelope_carries_every_recipient,
        bcc_is_in_the_envelope_but_not_the_headers,
        custom_headers_reach_the_message,
        html_and_text_produce_alternatives,
        attachment_is_delivered,
        send_async_returns_before_delivery,
        %% Classification
        permanent_failure_is_not_retried,
        transient_failure_is_retried_to_the_limit,
        transient_failure_then_success,
        rejected_recipient_is_permanent,
        dropped_connection_is_transient,
        unoffered_starttls_is_permanent,
        unreachable_relay_is_transient,
        deadline_stops_retrying_before_the_attempt_budget,
        %% Authentication
        auth_succeeds_when_credentials_match,
        auth_failure_is_permanent,
        %% Limits
        oversized_message_is_refused,
        oversized_is_measured_across_every_field,
        too_many_recipients_are_refused,
        encoded_size_is_checked_exactly,
        rate_limit_refuses_transiently,
        queue_full_refuses_transiently,
        %% Dormancy
        dormant_node_reports_not_configured
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

init_per_testcase(dormant_node_reports_not_configured, Config) ->
    ok = restart(Config, []),
    Config;
init_per_testcase(_Case, Config) ->
    ok = mock_smtp_server:clear(),
    ok = restart(Config, relays(?config(port, Config))),
    Config.

end_per_testcase(_Case, _Config) ->
    _ = application:stop(bondy_mail),
    ok.

%% =============================================================================
%% DELIVERY
%% =============================================================================

message_is_delivered(_) ->
    {ok, Result} = send(base()),
    ?assertMatch(#{receipt := _, attempts := 1}, Result),

    [Msg] = mock_smtp_server:messages(),
    ?assertEqual(~"no-reply@example.com", maps:get(from, Msg)),
    ?assertEqual([~"user@example.com"], maps:get(to, Msg)),
    ?assertEqual(~"Hello", header(~"subject", Msg)).

envelope_carries_every_recipient(_) ->
    Req = (base())#{
        ~"to" => [~"a@example.com"],
        ~"cc" => [~"b@example.com"],
        ~"bcc" => [~"c@example.com"]
    },
    {ok, _} = send(Req),

    [Msg] = mock_smtp_server:messages(),
    ?assertEqual(
        [~"a@example.com", ~"b@example.com", ~"c@example.com"],
        maps:get(to, Msg)
    ).

-doc """
A blind recipient is delivered to and does not appear in the message.

That is the entire meaning of the field, and it is why a caller-supplied `Bcc`
header is refused: it would publish exactly what the field exists to hide.
""".
bcc_is_in_the_envelope_but_not_the_headers(_) ->
    Req = (base())#{
        ~"to" => [~"a@example.com"],
        ~"bcc" => [~"secret@example.com"]
    },
    {ok, _} = send(Req),

    [Msg] = mock_smtp_server:messages(),
    %% In the envelope.
    ?assert(lists:member(~"secret@example.com", maps:get(to, Msg))),
    %% Not in any header, and not anywhere else in the message either.
    ?assertEqual(undefined, header(~"bcc", Msg)),
    ?assertEqual(
        nomatch,
        binary:match(maps:get(data, Msg), ~"secret@example.com")
    ).

custom_headers_reach_the_message(_) ->
    Req = (base())#{~"headers" => #{~"X-Campaign" => ~"spring"}},
    {ok, _} = send(Req),

    [Msg] = mock_smtp_server:messages(),
    ?assertEqual(~"spring", header(~"x-campaign", Msg)).

html_and_text_produce_alternatives(_) ->
    Req = (base())#{~"text" => ~"plain body", ~"html" => ~"<b>rich</b>"},
    {ok, _} = send(Req),

    [Msg] = mock_smtp_server:messages(),
    ContentType = header(~"content-type", Msg),
    ?assertMatch({_, _}, binary:match(ContentType, ~"multipart/alternative")),

    Data = maps:get(data, Msg),
    ?assertMatch({_, _}, binary:match(Data, ~"text/plain")),
    ?assertMatch({_, _}, binary:match(Data, ~"text/html")).

attachment_is_delivered(_) ->
    Req = (base())#{
        ~"attachments" => [
            #{
                ~"filename" => ~"note.txt",
                ~"content_type" => ~"text/plain",
                ~"data" => base64:encode(~"attached body")
            }
        ]
    },
    {ok, _} = send(Req),

    [Msg] = mock_smtp_server:messages(),
    ContentType = header(~"content-type", Msg),
    ?assertMatch({_, _}, binary:match(ContentType, ~"multipart/mixed")),
    ?assertMatch(
        {_, _}, binary:match(maps:get(data, Msg), ~"note.txt")
    ).

-doc """
`send_async/2` returns before the relay has seen anything.

The relay is made slow so the return cannot be confused with delivery. What a
successful return means is that the message was queued -- nothing more.
""".
send_async_returns_before_delivery(_) ->
    ok = mock_smtp_server:latency(400),

    {ok, Result} = bondy_mail:send_async(?REALM, base()),
    ?assertMatch(#{status := queued, id := <<_/binary>>}, Result),
    ?assertEqual([], mock_smtp_server:messages()),

    ok = await_messages(1),
    ?assertEqual(1, length(mock_smtp_server:messages())).

%% =============================================================================
%% CLASSIFICATION
%% =============================================================================

-doc """
A 5xx is permanent: the relay is asked exactly once.

Asserting on the attempt count rather than the return value is deliberate. A
classification bug that reported `permanent` while still retrying would satisfy
a weaker assertion, and would quietly hammer a relay that had already refused.
""".
permanent_failure_is_not_retried(_) ->
    ok = mock_smtp_server:fail_data("550 mailbox unavailable"),

    Result = send(base()),
    ?assertMatch({error, {permanent, rejected, _}}, Result),
    ?assertEqual(1, rcpt_count()).

-doc """
A 4xx is transient: the relay is asked until the attempt budget runs out.

`retry.max_attempts` is 2 for this relay, so one attempt plus two retries.
""".
transient_failure_is_retried_to_the_limit(_) ->
    ok = mock_smtp_server:fail_data("451 try again later"),

    Result = send(base()),
    ?assertMatch({error, {transient, deferred, _}}, Result),
    ?assertEqual(3, rcpt_count()).

-doc """
A relay that refuses once and then accepts gets the message.

The case the retry budget exists for: greylisting refuses the first attempt on
purpose.
""".
transient_failure_then_success(_) ->
    ok = mock_smtp_server:fail_next_data({1, "451 greylisted"}),

    {ok, Result} = send(base()),
    ?assertEqual(2, maps:get(attempts, Result)),
    ?assertEqual(1, length(mock_smtp_server:messages())).

rejected_recipient_is_permanent(_) ->
    ok = mock_smtp_server:fail_rcpt("550 no such user"),

    Result = send(base()),
    ?assertMatch({error, {permanent, rejected, _}}, Result).

-doc """
A connection dropped mid-`DATA` is transient.

The failure a reply code cannot express, and the one a mocked client would
never produce: the relay took the message and then went away, so nothing was
said about it either way. Transient is the only honest reading -- it may well
work next time -- and it is retried to the attempt budget like any other.
""".
dropped_connection_is_transient(_) ->
    ok = mock_smtp_server:drop_data(true),

    ?assertMatch({error, {transient, _, _}}, send(base())),
    ?assertEqual([], mock_smtp_server:messages()),
    %% Retried: three attempts on a relay whose budget is two retries.
    ?assertEqual(3, rcpt_count()).

-doc """
A relay that does not offer `STARTTLS` to a relay declared `starttls` fails,
permanently, without sending.

Both halves matter. Continuing in plaintext would make asking for STARTTLS mean
nothing, and retrying would only ask a relay that has already said what it
supports to say it again. `gen_smtp` reports this as `missing_requirement`, and
`bondy_mail:to_error/1` turns it into `mail_not_configured` -- because that is
what it is, and telling an operator the relay rejected their mail would send
them to look at the wrong end.
""".
unoffered_starttls_is_permanent(Config) ->
    ok = mock_smtp_server:starttls(false),
    Relays = [
        R#{name => ~"upgrade", transport => starttls, tls_verify => verify_none}
     || R <- [common(?config(port, Config))]
    ],
    ok = restart(Config, Relays),

    Result = bondy_mail:send(?REALM, (base())#{~"relay" => ~"upgrade"}),
    ?assertMatch({error, {permanent, missing_requirement, _}}, Result),
    ?assertEqual([], mock_smtp_server:messages()),

    Error = bondy_mail:to_error(element(2, Result)),
    ?assertEqual(mail_not_configured, maps:get(type, Error)).

-doc """
A relay with nothing listening on its port is a transient network failure.

Not permanent: a relay that is being restarted is exactly this, and refusing to
retry would turn a thirty-second maintenance window into lost mail.
""".
unreachable_relay_is_transient(Config) ->
    %% A port nothing is bound to. Chosen by binding and immediately closing,
    %% so it is genuinely free rather than merely unlikely.
    {ok, Socket} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Dead} = inet:port(Socket),
    ok = gen_tcp:close(Socket),

    Relays = [(common(Dead))#{name => ~"gone", retry_max_attempts => 0}],
    ok = restart(Config, Relays),

    ?assertMatch(
        {error, {transient, network, _}},
        bondy_mail:send(?REALM, (base())#{~"relay" => ~"gone"})
    ).

-doc """
The request's deadline stops the retries, even with attempts left over.

Two budgets bound a retry and this is the one that is easy to get wrong: with
`max_attempts` set high and a short deadline, a worker that only counted
attempts would sit in backoff long after anyone stopped waiting for the answer.
""".
deadline_stops_retrying_before_the_attempt_budget(Config) ->
    ok = mock_smtp_server:fail_data("451 try again later"),

    %% Twenty retries allowed, each backing off at least 200ms, against a
    %% request that may take 300ms in total. The attempt budget cannot be what
    %% ends this.
    Relays = [
        (common(?config(port, Config)))#{
            name => ~"impatient",
            retry_max_attempts => 20,
            retry_backoff_min => 200,
            retry_backoff_max => 200
        }
    ],
    ok = restart(Config, Relays),

    Req = (base())#{~"relay" => ~"impatient", ~"timeout" => 300},
    ?assertMatch(
        {error, {transient, deadline, _}}, bondy_mail:send(?REALM, Req)
    ),
    ?assert(rcpt_count() < 20).

%% =============================================================================
%% AUTHENTICATION
%% =============================================================================

auth_succeeds_when_credentials_match(Config) ->
    ok = mock_smtp_server:auth_required({"mailer", "s3cret"}),
    ok = restart(Config, relays(?config(port, Config))),

    {ok, _} = send((base())#{~"relay" => ~"authed"}),
    ?assertEqual(1, length(mock_smtp_server:messages())).

-doc """
Wrong credentials fail permanently, and the credential does not leak.

Retrying a rejected password only locks accounts, so this must not be
transient. The reason a caller receives is asserted to carry neither the
password nor the username.
""".
auth_failure_is_permanent(Config) ->
    ok = mock_smtp_server:auth_required({"mailer", "different"}),
    ok = restart(Config, relays(?config(port, Config))),

    Result = send((base())#{~"relay" => ~"authed"}),
    ?assertMatch({error, {permanent, _, _}}, Result),

    Formatted = lists:flatten(io_lib:format("~p", [Result])),
    ?assertEqual(nomatch, string:find(Formatted, "s3cret")),
    ?assertEqual(nomatch, string:find(Formatted, "mailer")).

%% =============================================================================
%% LIMITS
%% =============================================================================

-doc """
An oversized message is refused at admission, naming the size and the limit.

The body counts. It did not use to: only attachments were measured, so the same
megabytes were refused as an attachment and accepted as a body -- and a body was
not measured at all until a worker had taken the message off a queue it had been
occupying all along. A limit whose answer depends on which field the caller used
is not a limit anyone can work with.
""".
oversized_message_is_refused(_) ->
    Big = binary:copy(~"a", 20000),
    Req = (base())#{~"relay" => ~"tiny", ~"text" => Big},

    ?assertMatch({error, {too_large_payload, 20005, _}}, send(Req)),
    ?assertEqual([], mock_smtp_server:messages()).

-doc """
Headers and attachments are measured on the same budget as the body.

Three fields, one limit. Each of these is under the limit on its own and over
it together, which is the property a per-field check does not have.
""".
oversized_is_measured_across_every_field(_) ->
    Third = binary:copy(~"a", 700),
    Req = (base())#{
        ~"relay" => ~"tiny",
        ~"text" => Third,
        ~"headers" => #{~"X-Padding" => Third},
        ~"attachments" => [
            #{
                ~"filename" => ~"pad.bin",
                ~"content_type" => ~"application/octet-stream",
                ~"data" => base64:encode(Third)
            }
        ]
    },

    ?assertMatch({error, {too_large_payload, _, _}}, send(Req)),
    ?assertEqual([], mock_smtp_server:messages()).

-doc """
A message naming more recipients than the relay allows is refused.

`to`, `cc` and `bcc` are counted together because they all become `RCPT TO`
commands in one transaction, so their sum is what a relay actually sees.
""".
too_many_recipients_are_refused(_) ->
    Address = fun(N) ->
        <<"user", (integer_to_binary(N))/binary, "@example.com">>
    end,
    Req = (base())#{
        ~"relay" => ~"few",
        ~"to" => [Address(N) || N <- lists:seq(1, 2)],
        ~"cc" => [Address(N) || N <- lists:seq(3, 4)]
    },

    ?assertMatch({error, {too_many_recipients, 4, 3}}, send(Req)),
    ?assertEqual([], mock_smtp_server:messages()).

-doc """
The encoded message is still measured exactly, after encoding.

Admission works on the decoded request scaled by a headroom factor, which is an
estimate; this is the check that is not. It is reached directly here because a
request that passes the first check and fails the second is, by construction,
hard to build -- which is the point of the headroom.
""".
encoded_size_is_checked_exactly(_) ->
    {ok, Built} = bondy_mail_request:new(
        ?REALM, (base())#{~"relay" => ~"tiny", ~"text" => ~"small enough"}
    ),
    {ok, Record} = bondy_mail_config:relay(~"tiny"),

    ?assertMatch({ok, _}, bondy_mail_mime:encode(Built, Record)),

    Tiny = Record#bondy_mail_relay{max_message_size = 10},
    ?assertMatch(
        {error, {too_large_payload, _, 10}},
        bondy_mail_mime:encode(Built, Tiny)
    ).

-doc """
Exceeding the rate limit is refused transiently, before anything is queued.

A rate limit protects the relay, so the refusal has to happen on the caller's
side of the queue.
""".
rate_limit_refuses_transiently(_) ->
    %% `limited` allows one message per second with no burst.
    %%
    %% The burst uses `send_async/2` on purpose. Sending synchronously would
    %% wait for a full SMTP conversation each time, and five of those take more
    %% than a second -- long enough for the bucket to refill, so the limit would
    %% never be seen and the case would pass or fail on how fast the machine is.
    Results = [
        bondy_mail:send_async(?REALM, (base())#{~"relay" => ~"limited"})
     || _ <- lists:seq(1, 10)
    ],

    ?assert(
        lists:any(
            fun
                ({error, {transient, rate_limited, _}}) -> true;
                (_) -> false
            end,
            Results
        )
    ),
    %% And the first one was allowed: a limiter that refused everything would
    %% satisfy the assertion above just as well.
    ?assertMatch({ok, _}, hd(Results)).

-doc """
A full queue refuses rather than blocking the caller.

This is the backpressure contract. A caller that blocked on a stalled relay
would simply have moved the stall somewhere else -- and in the bridge's case,
that somewhere else is a subscriber processing router events.
""".
queue_full_refuses_transiently(_) ->
    %% `slow` holds each message for a while, and its queue bound is 1.
    ok = mock_smtp_server:latency(3000),

    Results = [
        bondy_mail:send_async(?REALM, (base())#{~"relay" => ~"slow"})
     || _ <- lists:seq(1, 20)
    ],

    ?assert(
        lists:any(
            fun
                ({error, {transient, queue_full, _}}) -> true;
                (_) -> false
            end,
            Results
        )
    ).

%% =============================================================================
%% DORMANCY
%% =============================================================================

dormant_node_reports_not_configured(_) ->
    ?assertEqual({error, not_configured}, bondy_mail:send(?REALM, base())),
    ?assertEqual(
        {error, not_configured}, bondy_mail:send_async(?REALM, base())
    ).

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
header(Name, Msg) ->
    maps:get(Name, maps:get(headers, Msg), undefined).

%% @private
%% How many times the relay was asked to accept a recipient. The attempt count
%% is what distinguishes "classified permanent" from "classified permanent and
%% retried anyway".
rcpt_count() ->
    MS = [{{{rcpt_to, '$1'}, '_'}, [], ['$1']}],
    length(ets:select(mock_smtp_server, MS)).

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
restart(_Config, Relays) ->
    _ = application:stop(bondy_mail),
    ok = application:set_env(bondy_mail, relays, Relays),
    ok = application:set_env(bondy_mail, default_relay, undefined),
    {ok, _} = application:ensure_all_started(bondy_mail),
    ok.

%% @private
%% The shape every relay in this suite shares. Named so a case that needs one
%% relay configured differently can build it without restating the rest.
common(Port) ->
    #{
        host => ~"127.0.0.1",
        port => Port,
        %% The mock speaks plain SMTP: TLS is exercised against Mailpit in the
        %% integration suite, where there is a certificate to verify.
        transport => plain,
        auth => never,
        from => ~"no-reply@example.com",
        realms => any,
        retry_backoff_min => 10,
        retry_backoff_max => 50
    }.

relays(Port) ->
    Common = common(Port),
    [
        Common#{name => ~"default", retry_max_attempts => 2},
        Common#{name => ~"tiny", max_message_size => 2000},
        Common#{
            name => ~"authed",
            auth => always,
            username => ~"mailer",
            secret => #{provider => none, value => ~"s3cret"}
        },
        Common#{
            name => ~"limited",
            rate_limit_rate => 1,
            rate_limit_burst => 1,
            retry_max_attempts => 0
        },
        Common#{name => ~"few", max_recipients => 3},
        Common#{
            name => ~"slow",
            pool_size => 1,
            queue_max_size => 1,
            retry_max_attempts => 0,
            timeout => 10000
        }
    ].
