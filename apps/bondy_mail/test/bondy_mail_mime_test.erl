%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_mime_test).

-moduledoc """
The structure `bondy_mail_mime` chooses, and the headers it decides to write.

## Why this does not use `mimemail:decode/1`

It would be the obvious thing, and it does not work here: `mimemail` converts
every part it decodes through `iconv`, an optional NIF that this tree does not
carry. Adding a C dependency so that a unit test can parse is the wrong trade
when a real parser is already in the suite -- `bondy_mail_mailpit_SUITE` sends
these messages to Mailpit and reads back what Mailpit made of them, which is a
stronger statement than any in-process decode.

So the division is deliberate. Deep structure is asserted there, against a
parser nobody here wrote. What is asserted here is what needs no parser at all:
the header block, which is unambiguously the bytes before the first blank line,
and the size limit, which is a number.
""".

-include_lib("eunit/include/eunit.hrl").
-include_lib("bondy_mail/include/bondy_mail.hrl").

%% =============================================================================
%% STRUCTURE
%% =============================================================================

text_only_is_a_plain_part_test() ->
    Encoded = encoded(#{text => ~"body"}),

    %% Substrings, not the whole value: where `mimemail` folds a long header is
    %% its business, and an assertion on the exact bytes would break on a
    %% change that means nothing to any reader of the message.
    ?assertMatch({_, _}, binary:match(content_type(Encoded), ~"text/plain")),
    ?assertMatch({_, _}, binary:match(content_type(Encoded), ~"charset=utf-8")),
    ?assertMatch({_, _}, binary:match(Encoded, ~"body")).

-doc """
A `text/plain` part declares its charset.

Not because the charset is interesting: `mimemail` omits the entire
Content-Type header for an ASCII `text/plain` part on the grounds that
`us-ascii` is the default, and takes any parameter travelling with it -- which
is how an attachment lost the `name` that told a client it was one.
""".
plain_text_declares_a_charset_test() ->
    ?assertMatch(
        {_, _},
        binary:match(content_type(encoded(#{text => ~"body"})), ~"utf-8")
    ).

html_only_is_an_html_part_test() ->
    Encoded = encoded(#{html => ~"<b>hi</b>"}),

    ?assertMatch({_, _}, binary:match(content_type(Encoded), ~"text/html")),
    ?assertMatch({_, _}, binary:match(Encoded, ~"<b>hi</b>")).

-doc """
Both bodies produce `multipart/alternative`, least rich first.

The order is the whole meaning of `alternative`: it tells a client these are the
same message in different forms and that the last one it understands is the one
to show. Reversed, every client would render the plain text.
""".
both_bodies_produce_alternative_test() ->
    Encoded = encoded(#{text => ~"plain", html => ~"<b>rich</b>"}),

    ?assertMatch(
        {_, _}, binary:match(content_type(Encoded), ~"multipart/alternative")
    ),
    ?assert(index(Encoded, ~"text/plain") < index(Encoded, ~"text/html")).

-doc """
An attachment wraps the body in `multipart/mixed`, body part first.

With both bodies *and* an attachment the message is a `mixed` whose first part
is an `alternative`. A structure that flattened the two would still deliver, and
would show a client two competing bodies rather than one with two renderings.
`bondy_mail_mailpit_SUITE` asserts the same nesting through a real parser.
""".
attachment_wraps_the_body_test() ->
    Encoded = encoded(#{
        text => ~"plain",
        html => ~"<b>rich</b>",
        attachments => [attachment(~"note.txt", ~"text/plain", ~"attached")]
    }),

    ?assertMatch(
        {_, _}, binary:match(content_type(Encoded), ~"multipart/mixed")
    ),
    %% The alternative is inside, and before the attachment.
    ?assert(
        index(Encoded, ~"multipart/alternative") <
            index(Encoded, ~"note.txt")
    ),
    ?assertMatch(
        {_, _}, binary:match(Encoded, ~"Content-Disposition: attachment")
    ).

-doc """
An attachment is base64 encoded.

Not decoration: an attachment is arbitrary bytes on a transport that only
promises seven of every eight bits. The bytes here include a bare CR and LF,
which is what would corrupt if the part went out as-is.
""".
binary_attachment_is_base64_encoded_test() ->
    Bytes = <<0, 1, 2, 255, 254, 128, 10, 13>>,
    Encoded = encoded(#{
        text => ~"see attached",
        attachments => [
            attachment(~"blob.bin", ~"application/octet-stream", Bytes)
        ]
    }),

    ?assertMatch(
        {_, _}, binary:match(Encoded, ~"Content-Transfer-Encoding: base64")
    ),
    ?assertMatch({_, _}, binary:match(Encoded, base64:encode(Bytes))).

%% =============================================================================
%% HEADERS
%% =============================================================================

-doc """
`Bcc` is in the envelope and in no header.

That is the entire meaning of the field. The envelope is built separately, by
`bondy_mail_request:recipients/1`; this asserts the other half, that nothing
here puts a blind recipient back into the message. The assertion is over the
whole message rather than the header block, because "nowhere" is the claim.
""".
bcc_never_reaches_the_message_test() ->
    Request = (request(#{text => ~"body"}))#bondy_mail_request{
        to = [~"a@example.com"],
        bcc = [~"secret@example.com"]
    },
    {ok, Encoded} = encode(Request),

    ?assertEqual(nomatch, binary:match(Encoded, ~"secret@example.com")),
    ?assertEqual(undefined, header(~"Bcc", Encoded)).

custom_headers_are_carried_test() ->
    Request = (request(#{text => ~"body"}))#bondy_mail_request{
        headers = [{~"X-Campaign", ~"spring"}]
    },
    {ok, Encoded} = encode(Request),

    ?assertEqual(~"spring", header(~"X-Campaign", Encoded)).

-doc """
A display name reaches the `From` header and nothing else.

The record holds the name and the address apart so that neither the envelope
nor the `allowed_from` check can see a name. This is the one place they are put
back together.
""".
display_name_reaches_the_from_header_test() ->
    Request = (request(#{text => ~"body"}))#bondy_mail_request{
        from = ~"no-reply@example.com",
        from_name = ~"Acme Ltd"
    },
    {ok, Encoded} = encode(Request),

    ?assertEqual(
        ~"Acme Ltd <no-reply@example.com>", header(~"From", Encoded)
    ).

-doc """
A non-ASCII display name becomes an encoded word, not raw bytes.

`mimemail` does this, which is why `bondy_mail_address:format_mailbox/2` quotes
the name and stops there: RFC 2047 encoding is not worth reimplementing beside
a library that already has it. The comma is in the name on purpose -- it is an
RFC 5322 special, so an unencoded rendering would parse as two addresses.
""".
non_ascii_display_name_is_encoded_test() ->
    Request = (request(#{text => ~"body"}))#bondy_mail_request{
        from = ~"no-reply@example.com",
        from_name = <<"Caf", 233/utf8, ", Ltd">>
    },
    {ok, Encoded} = encode(Request),

    From = header(~"From", Encoded),
    ?assertMatch({_, _}, binary:match(From, ~"=?UTF-8?")),
    %% And it still round-trips through a parser that is not ours.
    ?assertMatch(
        {ok, [{_, "no-reply@example.com"}]},
        smtp_util:parse_rfc5322_addresses(From)
    ).

-doc """
Nothing a caller supplied can put a control character into a header.

The end of the chain `bondy_mail_header:has_control/1` starts: everything that
reaches a header goes through that one predicate, so a message built from a
validated request cannot carry a byte that would end a header line early.
""".
no_header_carries_a_control_character_test() ->
    Request = (request(#{text => ~"body"}))#bondy_mail_request{
        from_name = ~"Acme Ltd",
        reply_to = ~"reply@example.com",
        reply_to_name = ~"Acme Support",
        cc = [~"cc@example.com"],
        headers = [{~"X-A", ~"one"}, {~"X-B", ~"two"}]
    },
    {ok, Encoded} = encode(Request),

    Lines = binary:split(header_block(Encoded), ~"\r\n", [global]),
    ?assert(
        lists:all(
            fun(Line) -> not has_bare_control(Line) end,
            Lines
        )
    ).

%% =============================================================================
%% SIZE
%% =============================================================================

-doc """
The encoded message is measured against the relay's limit, exactly.

`bondy_mail_request` applies a scaled-down budget to the decoded request before
anything is queued; that is an estimate, and this is not. Both exist because the
cheap approximate check keeps oversized messages out of the queue, and this one
is the truth.
""".
oversized_encoded_message_is_refused_test() ->
    Request = request(#{text => binary:copy(~"a", 4096)}),

    ?assertMatch({ok, _}, bondy_mail_mime:encode(Request, relay(100000))),
    ?assertMatch(
        {error, {too_large_payload, _, 1024}},
        bondy_mail_mime:encode(Request, relay(1024))
    ).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
encode(Request) ->
    bondy_mail_mime:encode(Request, relay(1000000)).

%% @private
encoded(Overrides) ->
    {ok, Encoded} = encode(request(Overrides)),
    Encoded.

%% @private
%% The bytes before the first blank line. Unambiguous by definition -- that
%% blank line is what separates headers from a body in every internet message
%% format -- which is why this is a safe thing to parse by hand and the body is
%% not.
header_block(Encoded) ->
    [Block | _] = binary:split(Encoded, ~"\r\n\r\n"),
    Block.

%% @private
%% Unfolds continuation lines, so a header wrapped across several lines is read
%% as the one value it is.
header(Name, Encoded) ->
    Prefix = <<Name/binary, ": ">>,
    Fold = fun(Line, Acc) ->
        case {Acc, Line} of
            {undefined, <<P:(byte_size(Prefix))/binary, V/binary>>} when
                P == Prefix
            ->
                V;
            {V, <<C, _/binary>>} when
                is_binary(V) andalso (C == $\s orelse C == $\t)
            ->
                <<V/binary, Line/binary>>;
            {V, _} when is_binary(V) ->
                {done, V};
            _ ->
                Acc
        end
    end,
    case lists:foldl(Fold, undefined, lines(Encoded)) of
        {done, Value} -> Value;
        Other -> Other
    end.

%% @private
lines(Encoded) ->
    binary:split(header_block(Encoded), ~"\r\n", [global]).

%% @private
content_type(Encoded) ->
    header(~"Content-Type", Encoded).

%% @private
index(Bin, Needle) ->
    {Pos, _} = binary:match(Bin, Needle),
    Pos.

%% @private
%% A folded header line legitimately begins with a tab; nothing else in a header
%% may carry a control character at all.
has_bare_control(<<$\t, Rest/binary>>) ->
    bondy_mail_header:has_control(Rest);
has_bare_control(Line) ->
    bondy_mail_header:has_control(Line).

%% @private
%% Built directly rather than through `bondy_mail_request:new/2`: this module is
%% about the shape of the message, and going through validation would make every
%% case here depend on a configured relay as well.
request(Overrides) ->
    Base = #bondy_mail_request{
        id = undefined,
        message_id = ~"node/abc",
        realm = ~"com.example.app",
        relay = ~"r",
        from = ~"no-reply@example.com",
        from_name = undefined,
        to = [~"user@example.com"],
        cc = [],
        bcc = [],
        reply_to = undefined,
        reply_to_name = undefined,
        subject = ~"Hello",
        text = undefined,
        html = undefined,
        headers = [],
        attachments = [],
        size_bytes = 0,
        priority = normal,
        timeout = 30000,
        deadline = erlang:monotonic_time(millisecond) + 30000
    },
    maps:fold(fun set/3, Base, Overrides).

%% @private
set(text, V, R) -> R#bondy_mail_request{text = V};
set(html, V, R) -> R#bondy_mail_request{html = V};
set(attachments, V, R) -> R#bondy_mail_request{attachments = V}.

%% @private
attachment(Filename, ContentType, Data) ->
    #bondy_mail_attachment{
        filename = Filename,
        content_type = ContentType,
        data = Data
    }.

%% @private
relay(MaxSize) ->
    #bondy_mail_relay{
        name = ~"r",
        host = ~"127.0.0.1",
        port = 25,
        transport = plain,
        username = undefined,
        secret = undefined,
        auth = never,
        tls_verify = verify_peer,
        tls_cacertfile = undefined,
        from = ~"no-reply@example.com",
        allowed_from = [],
        realms = any,
        transport_mod = bondy_mail_transport_smtp,
        pool_size = 1,
        pool_cursor = atomics:new(1, [{signed, false}]),
        queue_counters = atomics:new(2, [{signed, true}]),
        queue_max_size = 1,
        queue_max_bytes = 1,
        queue_ttl = 1,
        timeout = 30000,
        retry_max_attempts = 0,
        retry_backoff_min = 1,
        retry_backoff_max = 1,
        rate_limit_rate = 0,
        rate_limit_burst = 1,
        max_message_size = MaxSize,
        max_recipients = 100,
        health_failure_threshold = 3,
        health_success_threshold = 1
    }.
