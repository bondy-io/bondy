%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_mailpit_SUITE).

-moduledoc """
The send path against Mailpit: a real relay, a real TLS handshake, and a real
MIME parser on the far side.

`bondy_mail_send_SUITE` already covers the protocol conversation against
`mock_smtp_server`, and asserts on the bytes Bondy put on the wire. That is the
right place for classification and retry, and the wrong place for two
questions it cannot answer, because the mock records the message rather than
interpreting it:

- **Are those bytes a message a real parser reads back as what we meant?**
  Encoded-word subjects, quoted-printable soft line breaks, multipart
  boundaries and attachment parts are all encodings that a recorder preserves
  and a decoder judges. Every case here asserts on what Mailpit decoded, not on
  what Bondy sent.
- **Does TLS work?** The mock speaks plain SMTP. Here there is a certificate,
  so `verify_peer` has something to verify -- and, in one case, something to
  refuse.

## Running it

    cd examples/mailpit && docker compose up -d

Without that stack the suite skips itself. It is not tagged out of CI by
configuration: the skip is the reachability check in `init_per_suite`, so the
suite runs wherever a container runtime exists and stays silent where one does
not.

## What Mailpit still cannot tell us

It accepts everything, and its certificate is one we generated. It cannot
exercise a public certificate chain, a provider's own `EHLO` capabilities, or
a real greylisting 4xx against the retry budget. `bondy_mail_live_SUITE` runs
those against a real relay.

## One trap, found the hard way

Mailpit's `/raw` endpoint **reconstructs** a `Bcc` header from the envelope
recipients before returning the source, so it cannot be used to assert that
Bondy did not send one -- the header is there either way. That assertion lives
in `bondy_mail_send_SUITE`, against the bytes the mock recorded. What is
asserted here instead is the half only a real server can answer: that the
blind recipient was delivered to at all.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_mail/include/bondy_mail.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, ~"com.example.app").
-define(FROM, ~"no-reply@bondy.test").
-define(HOST, ~"localhost").

%% Plain and STARTTLS, no authentication.
-define(PLAIN_PORT, 1025).
-define(PLAIN_API, "http://localhost:8025").

%% Implicit TLS, authentication required.
-define(TLS_PORT, 1465).
-define(TLS_API, "http://localhost:8026").

-define(USERNAME, ~"bondy").
-define(PASSWORD, ~"s3cret").

suite() ->
    [{timetrap, {minutes, 2}}].

all() ->
    [
        {group, plain},
        {group, starttls},
        {group, implicit_tls}
    ].

groups() ->
    [
        {plain, [sequence], [
            message_is_delivered_and_parsed,
            html_and_text_are_both_parsed,
            unicode_subject_survives_encoding,
            long_line_survives_transfer_encoding,
            attachment_survives_a_real_mime_parser,
            both_bodies_and_an_attachment_nest_correctly,
            bcc_is_delivered_as_an_envelope_recipient,
            display_name_is_parsed_as_a_name
        ]},
        {starttls, [sequence], [
            starttls_delivers_when_the_certificate_verifies,
            starttls_delivers_without_verification,
            verify_peer_refuses_an_untrusted_certificate
        ]},
        {implicit_tls, [sequence], [
            implicit_tls_delivers_with_authentication,
            wrong_credentials_fail_without_delivering
        ]}
    ].

init_per_suite(Config) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(gproc),
    {ok, _} = application:ensure_all_started(bondy_regulator),

    case fixture() of
        {ok, CaCertFile} ->
            [{cacertfile, CaCertFile} | Config];
        {error, Reason} ->
            {skip, Reason}
    end.

end_per_suite(_Config) ->
    _ = application:stop(bondy_mail),
    ok.

init_per_group(implicit_tls, Config) ->
    [{api, ?TLS_API} | Config];
init_per_group(_Group, Config) ->
    [{api, ?PLAIN_API} | Config].

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    %% Both mailboxes, not just this group's: a message left behind by another
    %% group would be indistinguishable from one this case sent.
    ok = clear(?PLAIN_API),
    ok = clear(?TLS_API),
    ok = restart(relays(?config(cacertfile, Config))),
    Config.

end_per_testcase(_Case, _Config) ->
    _ = application:stop(bondy_mail),
    ok.

%% =============================================================================
%% PLAIN
%% =============================================================================

message_is_delivered_and_parsed(Config) ->
    {ok, _} = send(#{~"relay" => ~"plain"}),

    Msg = await_message(Config),
    ?assertEqual(?FROM, address(maps:get(~"From", Msg))),
    ?assertEqual([~"user@example.com"], addresses(maps:get(~"To", Msg))),
    ?assertEqual(~"Hello", maps:get(~"Subject", Msg)),
    ?assertEqual(~"Body", trim(maps:get(~"Text", Msg))).

-doc """
A message with both bodies is parsed as both bodies.

The mock suite asserts that `text/plain` and `text/html` appear in the bytes.
That a real parser then offers each one back separately is the claim
`multipart/alternative` actually makes, and only a parser can settle it.
""".
html_and_text_are_both_parsed(Config) ->
    {ok, _} = send(#{
        ~"relay" => ~"plain",
        ~"text" => ~"plain body",
        ~"html" => ~"<h1>rich body</h1>"
    }),

    Msg = await_message(Config),
    ?assertEqual(~"plain body", trim(maps:get(~"Text", Msg))),
    ?assertEqual(~"<h1>rich body</h1>", trim(maps:get(~"HTML", Msg))).

-doc """
A non-ASCII subject arrives as the same characters it left as.

A header carries bytes, so anything outside ASCII travels as an encoded word
(RFC 2047) and comes back only if the encoder and the decoder agree. Asserting
the decoded subject is asserting that round trip; asserting the encoded bytes
would only assert that we encoded something.
""".
unicode_subject_survives_encoding(Config) ->
    Subject = ~"Café — résumé ✉",
    {ok, _} = send(#{~"relay" => ~"plain", ~"subject" => Subject}),

    Msg = await_message(Config),
    ?assertEqual(Subject, maps:get(~"Subject", Msg)).

-doc """
A body far longer than a line survives the transfer encoding.

SMTP bounds a line at 998 octets, so a longer one has to be broken and put back
together. A recorder cannot tell a correct soft line break from a corrupting
one -- both are bytes in the DATA -- and a decoder can.
""".
long_line_survives_transfer_encoding(Config) ->
    %% One line, no newlines of its own, so nothing about the comparison turns
    %% on CRLF normalisation. The non-ASCII character forces an encoding that
    %% has to fold. It ends on a word rather than a space because quoted-
    %% printable encodes trailing whitespace specially, and the comparison
    %% should be about folding rather than about that.
    Repeated = binary:copy(
        ~"the quick brown fox jumps over the lazy dog é ", 100
    ),
    Text = <<Repeated/binary, "end">>,
    {ok, _} = send(#{~"relay" => ~"plain", ~"text" => Text}),

    Msg = await_message(Config),
    ?assertEqual(Text, trim(maps:get(~"Text", Msg))).

attachment_survives_a_real_mime_parser(Config) ->
    Content = ~"attached body",
    {ok, _} = send(#{
        ~"relay" => ~"plain",
        ~"attachments" => [
            #{
                ~"filename" => ~"note.txt",
                ~"content_type" => ~"text/plain",
                ~"data" => base64:encode(Content)
            }
        ]
    }),

    Msg = await_message(Config),
    [Attachment] = maps:get(~"Attachments", Msg),
    ?assertEqual(~"note.txt", maps:get(~"FileName", Attachment)),
    ?assertEqual(~"text/plain", maps:get(~"ContentType", Attachment)),

    %% And the bytes, not merely the announcement of them.
    Api = ?config(api, Config),
    Path =
        "/api/v1/message/" ++ binary_to_list(maps:get(~"ID", Msg)) ++
            "/part/" ++ binary_to_list(maps:get(~"PartID", Attachment)),
    {ok, Body} = get(Api, Path),
    ?assertEqual(Content, Body).

-doc """
Both bodies and an attachment: one message with two renderings, plus a file.

The nesting a parser notices and a substring match cannot. `multipart/mixed`
wrapping a `multipart/alternative` is one message a client can show two ways
with a file beside it; the same parts flattened into a single `mixed` is a
message with two competing bodies, and a client picks one.

Mailpit reporting both a Text and an HTML body *and* an attachment is exactly
the statement that the nesting is right -- a flattened message would show the
plain text as a second attachment, or lose it.
""".
both_bodies_and_an_attachment_nest_correctly(Config) ->
    {ok, _} = send(#{
        ~"relay" => ~"plain",
        ~"text" => ~"plain body",
        ~"html" => ~"<h1>rich body</h1>",
        ~"attachments" => [
            #{
                ~"filename" => ~"note.txt",
                ~"content_type" => ~"text/plain",
                ~"data" => base64:encode(~"attached body")
            }
        ]
    }),

    Msg = await_message(Config),
    ?assertEqual(~"plain body", trim(maps:get(~"Text", Msg))),
    ?assertEqual(~"<h1>rich body</h1>", trim(maps:get(~"HTML", Msg))),

    %% One attachment, not two: the plain-text body is a rendering of this
    %% message, not a file that came with it.
    [Attachment] = maps:get(~"Attachments", Msg),
    ?assertEqual(~"note.txt", maps:get(~"FileName", Attachment)).

-doc """
A display name arrives as a name, not as part of the address.

Only a real parser can settle this. The header Bondy emits is a quoted string,
which `mimemail` re-parses and re-renders -- unquoting it, RFC 2047-encoding
the name when it is not ASCII, and re-quoting only where it must. Asserting on
the bytes we sent would assert that we quoted something; asserting on Mailpit's
parse asserts that the result means what we intended.

The non-ASCII name is the interesting half: it goes out as an encoded word and
has to come back as the characters it started as.
""".
display_name_is_parsed_as_a_name(Config) ->
    {ok, _} = send(#{
        ~"relay" => ~"plain",
        ~"from" => ~"Acmé, Ltd <no-reply@bondy.test>",
        ~"reply_to" => ~"Support <help@bondy.test>"
    }),

    Msg = await_message(Config),
    From = maps:get(~"From", Msg),
    ?assertEqual(~"Acmé, Ltd", maps:get(~"Name", From)),
    ?assertEqual(~"no-reply@bondy.test", maps:get(~"Address", From)),

    [ReplyTo] = maps:get(~"ReplyTo", Msg),
    ?assertEqual(~"Support", maps:get(~"Name", ReplyTo)),
    ?assertEqual(~"help@bondy.test", maps:get(~"Address", ReplyTo)).

-doc """
A blind recipient is delivered to.

The other half of the contract -- that the address does not appear in the
message -- is asserted in `bondy_mail_send_SUITE` against the recorded bytes.
It cannot be asserted here: Mailpit reconstructs a `Bcc` header from the
envelope before serving the raw source, so the header is present whatever
Bondy sent. What Mailpit can settle is that the envelope carried the address,
which is what the field is for and what a mock cannot demonstrate.
""".
bcc_is_delivered_as_an_envelope_recipient(Config) ->
    {ok, _} = send(#{
        ~"relay" => ~"plain",
        ~"to" => [~"user@example.com"],
        ~"bcc" => [~"secret@example.com"]
    }),

    Msg = await_message(Config),
    ?assertEqual([~"secret@example.com"], addresses(maps:get(~"Bcc", Msg))),
    %% And it was blind: not a visible recipient.
    ?assertEqual([~"user@example.com"], addresses(maps:get(~"To", Msg))),
    ?assertEqual([], addresses(maps:get(~"Cc", Msg))).

%% =============================================================================
%% STARTTLS
%% =============================================================================

starttls_delivers_when_the_certificate_verifies(Config) ->
    {ok, _} = send(#{~"relay" => ~"starttls"}),
    Msg = await_message(Config),
    ?assertEqual(~"Hello", maps:get(~"Subject", Msg)).

-doc """
`verify_none` delivers to a relay whose certificate nothing vouches for.

Worth asserting because it is the only difference between this case and the
one below, and an implementation that ignored `tls.verify` entirely would pass
one of them by accident.
""".
starttls_delivers_without_verification(Config) ->
    {ok, _} = send(#{~"relay" => ~"starttls_insecure"}),
    Msg = await_message(Config),
    ?assertEqual(~"Hello", maps:get(~"Subject", Msg)).

-doc """
`verify_peer` against a certificate the trust store does not know refuses, and
sends nothing.

This is the case that gives the other two their meaning. `verify_peer` is the
default, and a default that verified nothing would look identical in every
other test in this suite.

The failure is transient, not permanent: a handshake can fail because a chain
is being rotated, and the relay may well verify on the next attempt.
""".
verify_peer_refuses_an_untrusted_certificate(Config) ->
    Result = send(#{~"relay" => ~"starttls_untrusted"}),
    ?assertEqual({error, {transient, deferred, tls_failed}}, Result),
    ?assertEqual([], messages(?config(api, Config))).

%% =============================================================================
%% IMPLICIT TLS AND AUTHENTICATION
%% =============================================================================

implicit_tls_delivers_with_authentication(Config) ->
    {ok, _} = send(#{~"relay" => ~"tls"}),
    Msg = await_message(Config),
    ?assertEqual(~"Hello", maps:get(~"Subject", Msg)).

-doc """
A rejected credential fails permanently, sends nothing, and does not leak.

Permanent because retrying a rejected password only locks the account out. The
returned reason is checked for the credential too -- the relay's rejection text
is one of the places a password can end up being quoted back.
""".
wrong_credentials_fail_without_delivering(Config) ->
    Result = send(#{~"relay" => ~"tls_badcreds"}),
    ?assertMatch({error, {permanent, _, _}}, Result),
    ?assertEqual([], messages(?config(api, Config))),

    Formatted = lists:flatten(io_lib:format("~p", [Result])),
    ?assertEqual(nomatch, string:find(Formatted, "wrong-password")),
    ?assertEqual(nomatch, string:find(Formatted, binary_to_list(?PASSWORD))).

%% =============================================================================
%% PRIVATE -- SENDING
%% =============================================================================

%% @private
send(Overrides) ->
    Base = #{
        ~"to" => [~"user@example.com"],
        ~"subject" => ~"Hello",
        ~"text" => ~"Body"
    },
    bondy_mail:send(?REALM, maps:merge(Base, Overrides)).

%% @private
restart(Relays) ->
    _ = application:stop(bondy_mail),
    ok = application:set_env(bondy_mail, relays, Relays),
    ok = application:set_env(bondy_mail, default_relay, undefined),
    {ok, _} = application:ensure_all_started(bondy_mail),
    ok.

%% @private
relays(CaCertFile) ->
    Common = #{
        host => ?HOST,
        from => ?FROM,
        realms => any,
        auth => never,
        %% These cases assert on one attempt's outcome, so a retry would only
        %% make a failing case slow.
        retry_max_attempts => 0,
        timeout => 15000
    },
    Verified = Common#{
        transport => starttls,
        tls_verify => verify_peer,
        tls_cacertfile => CaCertFile
    },
    [
        %% `allowed_from` is set only on this relay, and only so that
        %% `display_name_is_parsed_as_a_name` can supply a sender. Every other
        %% relay here leaves it closed, which is the default and is what the
        %% first version of that case ran into.
        Common#{
            name => ~"plain",
            port => ?PLAIN_PORT,
            transport => plain,
            allowed_from => [~"bondy.test"]
        },
        Verified#{name => ~"starttls", port => ?PLAIN_PORT},
        Common#{
            name => ~"starttls_insecure",
            port => ?PLAIN_PORT,
            transport => starttls,
            tls_verify => verify_none
        },
        %% No `tls_cacertfile`, so verification runs against the operating
        %% system trust store -- which has never heard of the certificate the
        %% compose stack generated.
        Common#{
            name => ~"starttls_untrusted",
            port => ?PLAIN_PORT,
            transport => starttls,
            tls_verify => verify_peer
        },
        Verified#{
            name => ~"tls",
            port => ?TLS_PORT,
            transport => tls,
            auth => always,
            username => ?USERNAME,
            secret => #{provider => none, value => ?PASSWORD}
        },
        Verified#{
            name => ~"tls_badcreds",
            port => ?TLS_PORT,
            transport => tls,
            auth => always,
            username => ?USERNAME,
            secret => #{provider => none, value => ~"wrong-password"}
        }
    ].

%% =============================================================================
%% PRIVATE -- MAILPIT
%% =============================================================================

%% @private
%% Both Mailpit instances and the certificate they share, or the reason to
%% skip. Reported as one message rather than three, because they come from one
%% `docker compose up` and are missing together.
fixture() ->
    case cacertfile() of
        {ok, File} ->
            case reachable(?PLAIN_API) andalso reachable(?TLS_API) of
                true -> {ok, File};
                false -> {error, skip_reason()}
            end;
        error ->
            {error, skip_reason()}
    end.

%% @private
skip_reason() ->
    "Mailpit is not running. Start it with: "
    "cd examples/mailpit && docker compose up -d".

%% @private
%% The authority the compose stack generated and signed Mailpit's certificate
%% with. Not Mailpit's own certificate: a self-signed leaf is refused as
%% `selfsigned_peer` however trusted it is, so verifying against one would test
%% nothing that could ever pass.
cacertfile() ->
    case repo_root() of
        {ok, Root} ->
            File = filename:join([
                Root, "examples", "mailpit", "certs", "ca.pem"
            ]),
            case filelib:is_regular(File) of
                true -> {ok, list_to_binary(File)};
                false -> error
            end;
        error ->
            error
    end.

%% @private
%% Walk up from the working directory looking for the compose file. CT runs
%% from a log directory under `_build`, and rebar3 copies the suite into
%% `_build/test/lib/bondy_mail/test`, so neither the suite's own path nor the
%% application's give the repository root directly.
repo_root() ->
    {ok, Cwd} = file:get_cwd(),
    repo_root(Cwd).

%% @private
repo_root(Dir) ->
    case
        filelib:is_regular(
            filename:join([Dir, "examples", "mailpit", "docker-compose.yml"])
        )
    of
        true ->
            {ok, Dir};
        false ->
            case filename:dirname(Dir) of
                Dir -> error;
                Parent -> repo_root(Parent)
            end
    end.

%% @private
reachable(Api) ->
    case get(Api, "/api/v1/info") of
        {ok, _} -> true;
        {error, _} -> false
    end.

%% @private
clear(Api) ->
    Url = Api ++ "/api/v1/messages",
    Request = {Url, [], "application/json", <<"{}">>},
    case httpc:request(delete, Request, [{timeout, 5000}], []) of
        {ok, {{_, Status, _}, _, _}} when Status >= 200 andalso Status < 300 ->
            ok;
        Other ->
            ct:fail({could_not_clear_mailpit, Api, Other})
    end.

%% @private
messages(Api) ->
    {ok, Body} = get(Api, "/api/v1/messages?limit=50"),
    maps:get(~"messages", json:decode(Body)).

%% @private
%% The full message, which is a different endpoint from the listing: the
%% listing carries a snippet, and the bodies, attachment parts and decoded
%% headers every case here asserts on come from the message itself.
await_message(Config) ->
    Api = ?config(api, Config),
    Summary = await_message(Api, 100),
    {ok, Body} = get(
        Api, "/api/v1/message/" ++ binary_to_list(maps:get(~"ID", Summary))
    ),
    json:decode(Body).

%% @private
await_message(Api, 0) ->
    ct:fail({no_message_arrived_at, Api});
await_message(Api, Retries) ->
    case messages(Api) of
        [Summary] ->
            Summary;
        [] ->
            timer:sleep(100),
            await_message(Api, Retries - 1);
        Many ->
            ct:fail({expected_one_message, length(Many)})
    end.

%% @private
get(Api, Path) ->
    Request = {Api ++ Path, []},
    Options = [{body_format, binary}],
    case httpc:request(get, Request, [{timeout, 5000}], Options) of
        {ok, {{_, 200, _}, _, Body}} -> {ok, Body};
        {ok, {{_, Status, _}, _, _}} -> {error, Status};
        {error, _} = Error -> Error
    end.

%% =============================================================================
%% PRIVATE -- ASSERTIONS
%% =============================================================================

%% @private
address(#{~"Address" := Address}) ->
    Address.

%% @private
addresses(List) ->
    [address(A) || A <- List].

%% @private
%% Mailpit returns a decoded body with the message's own trailing newline.
%%
%% `string:trim/1` and not `string:trim(Body, trailing, "\r\n")`: the third
%% argument is a list of grapheme clusters, CRLF is one cluster, and the
%% two-character list does not name it -- so that call returns the binary
%% unchanged and every body assertion here would compare against a value it
%% never trimmed. No case in this suite has meaningful leading or trailing
%% whitespace, so trimming all of it is unambiguous.
trim(Body) ->
    string:trim(Body).
