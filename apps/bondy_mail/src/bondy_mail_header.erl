%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_header).

-moduledoc """
Validation of caller-supplied message headers.

Two things are being prevented here, and they are worth stating separately.

**Header injection.** A header value carrying a CR or an LF ends the header and
begins whatever the caller wrote next -- another header, or the message body.
A caller who can do that can add recipients that no authorisation check ever
saw. Such a value is *rejected*, never stripped or folded: silently repairing
it would send a message that differs from the one the caller described, and the
caller would have no idea. This is the property the property-based test in the
suite exists to hold.

**Header spoofing.** Some headers decide where a message goes, who it appears
to come from, or whether it is considered authentic. Those are set from the
request and the relay's configuration, so a caller-supplied copy is refused
rather than allowed to override or duplicate them.

Everything else -- `X-` headers, `List-Unsubscribe`, and the rest -- passes
through unchanged.
""".

%% Set from the request or the relay. A caller-supplied copy would either
%% override an authorisation decision or duplicate a header whose meaning is
%% then ambiguous, so it is refused.
%%
%% `bcc` is on the list because it is an envelope concern: blind recipients are
%% delivered to without appearing in the message, and a `Bcc:` header would
%% publish exactly what it is supposed to hide.
-define(RESERVED, [
    ~"bcc",
    ~"cc",
    ~"content-transfer-encoding",
    ~"content-type",
    ~"date",
    ~"dkim-signature",
    ~"from",
    ~"message-id",
    ~"mime-version",
    ~"received",
    ~"reply-to",
    ~"return-path",
    ~"sender",
    ~"subject",
    ~"to",
    %% Authentication verdicts, written by receiving infrastructure. A caller
    %% asserting one is claiming a check that never happened.
    ~"arc-authentication-results",
    ~"arc-message-signature",
    ~"arc-seal",
    ~"authentication-results",
    ~"dkim-filter",
    ~"domainkey-signature"
]).

-define(MAX_NAME, 76).
-define(MAX_VALUE, 998).

%% API
-export([has_control/1]).
-export([is_reserved/1]).
-export([reserved/0]).
-export([validate/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc "Return the reserved header names, lowercased.".
-spec reserved() -> [binary()].

reserved() ->
    ?RESERVED.

-doc """
Return `true` when `Bin` carries a byte that has no business in header data.

Any C0 control, or DEL. **This is the one definition**, and every caller-supplied
value that ends up in a header goes through it: header names and values here, a
display name in `bondy_mail_address`, an attachment filename and a content type
in `bondy_mail_request`.

That it is one definition is the point. It used to be four -- addresses and
display names refusing `\\r \\n \\0 \\t`, filenames refusing `\\r \\n \\0 / \\\\`,
content types refusing `\\r \\n \\0` and space, and only this module refusing the
whole control range. They agreed on the bytes that matter, which is why nothing
was ever exploitable, and disagreed on the rest: a vertical tab was refused in a
custom header and accepted in the display name of a `From`, where `mimemail`
passes it through unencoded because it is ASCII. Four spellings of one rule is
how the fifth one gets it wrong.

CR and LF are why this exists -- they end a header and begin whatever the caller
wrote next -- but the whole range is refused, so a value cannot carry a NUL or a
bare tab into an encoder whose handling of them is its own business.
""".
-spec has_control(Bin :: binary()) -> boolean().

has_control(<<C, _/binary>>) when C < 32 orelse C == 127 ->
    true;
has_control(<<_, Rest/binary>>) ->
    has_control(Rest);
has_control(<<>>) ->
    false.

-doc """
Return `true` when `Name` is set by Bondy and may not be supplied by a caller.

Comparison is case-insensitive, because header names are.
""".
-spec is_reserved(Name :: binary()) -> boolean().

is_reserved(Name) when is_binary(Name) ->
    lists:member(string:lowercase(Name), ?RESERVED).

-doc """
Validate a caller-supplied header map into an ordered list.

Answers `{ok, Headers}`, or the first problem found:

- `{error, {reserved_header, Name}}` -- set by Bondy, see the module docs.
- `{error, {header_injection, Name}}` -- a CR, LF or NUL in the name or value.
- `{error, {invalid_header, Name}}` -- empty, over-long, or not a binary.

The result is sorted by name so that a message built twice from one request is
byte-identical, which makes both the tests and any downstream signature stable.
""".
-spec validate(Term :: any()) ->
    {ok, [{binary(), binary()}]} | {error, any()}.

validate(Map) when is_map(Map) ->
    validate_pairs(lists:sort(maps:to_list(Map)), []);
validate(undefined) ->
    {ok, []};
validate(Other) ->
    {error, {invalid_header, Other}}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
validate_pairs([], Acc) ->
    {ok, lists:reverse(Acc)};
validate_pairs([{Name, Value} | T], Acc) when
    is_binary(Name) andalso is_binary(Value)
->
    case validate_pair(Name, Value) of
        ok -> validate_pairs(T, [{Name, Value} | Acc]);
        {error, _} = Error -> Error
    end;
validate_pairs([{Name, _} | _], _) ->
    {error, {invalid_header, Name}}.

%% @private
%% Order matters: injection is checked before anything else, so that a value
%% carrying a newline is always reported as injection rather than as, say, an
%% over-long value that happened to contain one.
validate_pair(Name, Value) ->
    case has_control(Name) orelse has_control(Value) of
        true ->
            {error, {header_injection, Name}};
        false ->
            validate_shape(Name, Value)
    end.

%% @private
validate_shape(Name, Value) ->
    NameSize = byte_size(Name),
    case NameSize > 0 andalso NameSize =< ?MAX_NAME of
        false ->
            {error, {invalid_header, Name}};
        true ->
            case byte_size(Value) =< ?MAX_VALUE andalso is_token(Name) of
                false -> {error, {invalid_header, Name}};
                true -> validate_reserved(Name)
            end
    end.

%% @private
validate_reserved(Name) ->
    case is_reserved(Name) of
        true -> {error, {reserved_header, Name}};
        false -> ok
    end.

%% @private
%% RFC 5322 field names are printable ASCII excluding the colon, which is what
%% separates a name from its value.
%%
%% Walked as a binary, like `has_control/1`: both run on every header of every
%% message, and neither has any business building a list to look at bytes.
is_token(<<C, Rest/binary>>) when C > 32 andalso C < 127 andalso C =/= $: ->
    is_token(Rest);
is_token(<<>>) ->
    true;
is_token(_) ->
    false.
