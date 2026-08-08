%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_mime).

-moduledoc """
Turns a validated request into the bytes that go on the wire.

Encoding is `mimemail`, which ships inside `gen_smtp`. This module's job is
choosing the right structure for what the request actually contains, and
deciding which headers appear.

## Structure

The simplest thing that carries the content, so that a plain-text message is
not wrapped in multipart machinery it does not need:

| Request | Structure |
| --- | --- |
| text only | `text/plain` |
| html only | `text/html` |
| both | `multipart/alternative`, text first |
| any attachment | `multipart/mixed` wrapping the above |

`multipart/alternative` lists the least-rich part first, which is what tells a
client the parts are the same message in different forms and that the last one
it understands is the one to show.

## Bcc

Blind recipients appear in the envelope handed to the relay and in no header.
That is the whole meaning of the field, and it is why `bondy_mail_header`
refuses a caller-supplied `Bcc` outright.

## Size

The encoded message is measured after encoding, against the relay's limit.
`bondy_mail_request` already applied a smaller budget to the decoded
attachments, so this rarely fires -- but base64 and headers are only estimated
there, and only the finished message can be measured exactly.
""".

-include("bondy_mail.hrl").

%% `mimemail`'s prose documentation describes the parameters element as a
%% proplist keyed by binaries. Its `parameters()` type, and the code, use a map
%% keyed by atoms. The code wins: a proplist raises `badmap` inside
%% `ensure_content_headers/7`.
-define(CHARSET, [{~"charset", ~"utf-8"}]).

%% API
-export([encode/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Encode a request into a message.

Answers `{ok, Message}` or `{error, {too_large_payload, Size, Max}}` when the
finished message exceeds the relay's limit.
""".
-spec encode(Request :: #bondy_mail_request{}, Relay :: #bondy_mail_relay{}) ->
    {ok, binary()} | {error, any()}.

encode(#bondy_mail_request{} = Request, #bondy_mail_relay{} = Relay) ->
    try
        Message = mimemail:encode(mime_tuple(Request)),
        Max = Relay#bondy_mail_relay.max_message_size,
        case byte_size(Message) of
            Size when Size > Max ->
                {error, {too_large_payload, Size, Max}};
            _ ->
                {ok, Message}
        end
    catch
        Class:Reason:Stacktrace ->
            %% Encoding failing is a defect rather than bad input -- the request
            %% was validated -- so keep the detail for the log and give the
            %% caller something it can act on.
            {error, {mime_encoding_failed, {Class, Reason, Stacktrace}}}
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
mime_tuple(#bondy_mail_request{attachments = []} = Request) ->
    {Type, SubType, Params, Body} = body(Request),
    {Type, SubType, headers(Request), Params, Body};
mime_tuple(#bondy_mail_request{attachments = Attachments} = Request) ->
    {Type, SubType, Params, Body} = body(Request),
    BodyPart = {Type, SubType, [], Params, Body},
    Parts = [BodyPart | [attachment(A) || A <- Attachments]],
    {~"multipart", ~"mixed", headers(Request), #{}, Parts}.

%% @private
%% The narrowest structure that carries what the request holds.
body(#bondy_mail_request{text = Text, html = undefined}) ->
    {~"text", ~"plain", text_params(), Text};
body(#bondy_mail_request{text = undefined, html = Html}) ->
    {~"text", ~"html", text_params(), Html};
body(#bondy_mail_request{text = Text, html = Html}) ->
    %% Least-rich first: that ordering is what tells a client these are the
    %% same message in different forms, and to prefer the last it understands.
    Parts = [
        {~"text", ~"plain", [], text_params(), Text},
        {~"text", ~"html", [], text_params(), Html}
    ],
    {~"multipart", ~"alternative", #{}, Parts}.

%% @private
text_params() ->
    #{content_type_params => ?CHARSET, disposition => ~"inline"}.

%% @private
attachment(#bondy_mail_attachment{} = A) ->
    #bondy_mail_attachment{
        filename = Filename,
        content_type = ContentType,
        data = Data
    } = A,
    {Type, SubType} = split_content_type(ContentType),
    Params = #{
        content_type_params => content_type_params(Type, Filename),
        disposition => ~"attachment",
        disposition_params => [{~"filename", Filename}],
        %% Attachments are arbitrary bytes, so they have to survive a transport
        %% that only promises 7 bits.
        transfer_encoding => ~"base64"
    },
    {Type, SubType, [], Params, Data}.

%% @private
%% A `text` attachment declares its charset, and not because the charset is
%% interesting.
%%
%% `mimemail` omits the entire `Content-Type` header for a `text/plain` part
%% whose body is ASCII, on the grounds that `us-ascii` is the default
%% (`mimemail.erl:783-805`) -- and takes the `name` parameter with it. The part
%% then arrives carrying only a disposition, and a receiving client has no
%% declared type for it: Mailpit does not list it as an attachment at all.
%% Naming a charset takes that branch out of play.
%%
%% Only `text/plain` is affected -- every other type reaches the clause above
%% it, which always writes the header -- but every `text` subtype declares one,
%% because a rule with an exception is a rule someone will apply wrongly later.
content_type_params(~"text", Filename) ->
    ?CHARSET ++ [{~"name", Filename}];
content_type_params(_Type, Filename) ->
    [{~"name", Filename}].

%% @private
split_content_type(ContentType) ->
    case binary:split(ContentType, ~"/") of
        [Type, SubType] -> {Type, SubType};
        _ -> {~"application", ~"octet-stream"}
    end.

%% @private
%% `Bcc` is deliberately absent: blind recipients are an envelope concern.
%% `mimemail` supplies `Date`, `Message-ID` and `MIME-Version` itself.
headers(#bondy_mail_request{} = Request) ->
    #bondy_mail_request{
        from = From,
        from_name = FromName,
        to = To,
        cc = Cc,
        reply_to = ReplyTo,
        reply_to_name = ReplyToName,
        subject = Subject,
        headers = Custom
    } = Request,

    %% The only place a display name is put back together. The record holds the
    %% address and the name apart precisely so that the envelope and the
    %% `allowed_from` check cannot see one; this is the header, so it can.
    %%
    %% `mimemail` re-parses this value, RFC 2047-encodes the name when it is not
    %% ASCII, and re-quotes only where it must -- so nothing here has to know
    %% which characters are special.
    Base = [
        {~"From", bondy_mail_address:format_mailbox(FromName, From)},
        {~"To", join(To)},
        {~"Subject", Subject}
    ],
    WithCc = maybe_header(~"Cc", join_optional(Cc), Base),
    WithReplyTo = maybe_header(
        ~"Reply-To", reply_to(ReplyToName, ReplyTo), WithCc
    ),

    %% Custom headers last. They cannot collide with anything above: every name
    %% set here is refused by bondy_mail_header:validate/1.
    WithReplyTo ++ Custom.

%% @private
reply_to(_Name, undefined) ->
    undefined;
reply_to(Name, Address) ->
    bondy_mail_address:format_mailbox(Name, Address).

%% @private
maybe_header(_Name, undefined, Headers) ->
    Headers;
maybe_header(Name, Value, Headers) ->
    Headers ++ [{Name, Value}].

%% @private
join_optional([]) ->
    undefined;
join_optional(L) ->
    join(L).

%% @private
join(L) ->
    iolist_to_binary(lists:join(~", ", L)).
