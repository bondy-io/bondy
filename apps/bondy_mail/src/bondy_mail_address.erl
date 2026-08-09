%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_address).

-include_lib("bondy_stdlib/include/bondy_stdlib.hrl").

-moduledoc """
Validation of email addresses, and of the domain policy applied to a sender.

Addresses are checked before a request is ever queued, so a malformed recipient
fails the caller immediately rather than a worker later. That also keeps the
one genuinely dangerous input -- a CR or LF smuggled into an address, which
would let a caller append headers of their own -- out of the system entirely
rather than relying on the MIME encoder to catch it.

This is deliberately stricter than RFC 5322. Quoted local parts, comments and
group syntax are all rejected: they are legal, essentially unused in practice,
and each is a parsing corner where a sanitiser and an encoder can disagree.
A caller that needs one of them is better served by an error than by a message
whose envelope does not say what they think it says.
""".

%% RFC 5321 limits: 64 octets of local part, 255 of domain, and the pair
%% together must fit a 256-octet path including the angle brackets.
-define(MAX_LOCAL, 64).
-define(MAX_DOMAIN, 255).
-define(MAX_ADDRESS, 254).

%% A display name is not length-limited by the standard, but a header line is,
%% and an unbounded name is an unbounded header.
-define(MAX_NAME, 255).

%% API
-export([domain/1]).
-export([format_mailbox/2]).
-export([parse_mailbox/1]).
-export([validate/1]).
-export([validate_many/1]).
-export([is_domain_allowed/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Validate one address.

Answers `{ok, Address}` with the address unchanged, or `error`. There is no
normalisation: the local part of an address is case-sensitive as far as the
standard is concerned, and rewriting what a caller asked for would be a
surprising thing for a mail system to do.
""".
-spec validate(Term :: any()) -> {ok, binary()} | error.

validate(Bin) when is_binary(Bin) ->
    Size = byte_size(Bin),
    case Size > 0 andalso Size =< ?MAX_ADDRESS andalso is_clean(Bin) of
        true ->
            split(Bin);
        false ->
            error
    end;
validate(_) ->
    error.

-doc """
Validate a list of addresses.

Answers `{ok, Addresses}` or `{error, {invalid_recipient, First}}` naming the
first address that failed, so the caller is told which one to fix.
""".
-spec validate_many(Term :: any()) ->
    {ok, [binary()]} | {error, {invalid_recipient, any()}}.

validate_many(L) when is_list(L) ->
    validate_many(L, []);
validate_many(Other) ->
    {error, {invalid_recipient, Other}}.

-doc "Return the domain part of a valid address.".
-spec domain(Address :: binary()) -> binary().

domain(Address) when is_binary(Address) ->
    [_, Domain] = binary:split(Address, ~"@"),
    Domain.

-doc """
Return `true` when `Address` may be sent as, given a relay's allow-list.

`any` permits any domain and turns off this check for the relay. `[]`, the
default, permits nothing: a relay that has not been told which domains it owns
does not let a caller pick one. Matching is on the domain only, and is
case-insensitive because domains are.
""".
-spec is_domain_allowed(Address :: binary(), Allowed :: [binary()] | any) ->
    boolean().

is_domain_allowed(_Address, any) ->
    true;
is_domain_allowed(_Address, []) ->
    false;
is_domain_allowed(Address, Allowed) when is_list(Allowed) ->
    Domain = string:lowercase(domain(Address)),
    lists:any(fun(D) -> string:lowercase(D) == Domain end, Allowed).

-doc """
Parse a mailbox: a bare address, or a display name and an address.

Answers `{ok, {Name, Address}}` where `Name` is `undefined` for a bare address,
or `error`. `Address` is always bare, and is validated exactly as `validate/1`
validates one -- which is what lets the caller keep using it for the envelope
and for the `allowed_from` domain check without knowing a display name was
involved.

    {ok, {undefined, <<"a@b.com">>}}  = parse_mailbox(<<"a@b.com">>).
    {ok, {<<"Acme">>, <<"a@b.com">>}} = parse_mailbox(<<"Acme <a@b.com>">>).

## What is refused, and why

A display name may not contain a control character, for the same reason an
address may not: it is header data, and CR or LF in it would let a caller
append headers of their own.

It may not contain `"` or `\\` either. Those are the two characters that make
the quoted form ambiguous, and `format_mailbox/2` always emits the quoted form
-- so accepting them would mean escaping, and escaping means a sanitiser and an
encoder that have to agree about it. This module already refuses quoted local
parts and comments on exactly that reasoning.

An unquoted name containing an RFC 5322 special (`,` most commonly) is
accepted, because `format_mailbox/2` quotes it on the way out. Left unquoted it
would be a header that `gen_smtp`'s own parser rejects, which is a validation
that passes and an encode that then fails.
""".
-spec parse_mailbox(Term :: any()) ->
    {ok, {optional(binary()), binary()}} | error.

parse_mailbox(<<>>) ->
    %% Ahead of the clause below, which would raise on `binary:last/1`.
    error;
parse_mailbox(Bin) when is_binary(Bin) ->
    case binary:last(Bin) == $> andalso binary:match(Bin, ~"<") =/= nomatch of
        true -> parse_named(Bin);
        false -> parse_bare(Bin)
    end;
parse_mailbox(_) ->
    error.

-doc """
Render a mailbox as a header value.

The display name is always quoted, which is what makes a name containing a
comma safe without this module knowing which characters are special. `mimemail`
strips the quotes, RFC 2047-encodes the name when it is not ASCII, and re-quotes
only if it still needs to -- so a non-ASCII name becomes an encoded word rather
than a quoted string, which is the correct rendering and not one this module has
to construct.
""".
-spec format_mailbox(Name :: optional(binary()), Address :: binary()) ->
    binary().

format_mailbox(undefined, Address) ->
    Address;
format_mailbox(Name, Address) ->
    <<$", Name/binary, $", $\s, $<, Address/binary, $>>>.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
parse_bare(Bin) ->
    case validate(Bin) of
        {ok, Address} -> {ok, {undefined, Address}};
        error -> error
    end.

%% @private
%% The LAST `<`, so a name that somehow contains one cannot shift where the
%% address is taken from. A name containing `<` is refused below in any case;
%% this makes the split independent of that check rather than dependent on it.
parse_named(Bin) ->
    Size = byte_size(Bin),
    case binary:matches(Bin, ~"<") of
        [] ->
            error;
        Matches ->
            {Pos, 1} = lists:last(Matches),
            Name = binary:part(Bin, 0, Pos),
            Address = binary:part(Bin, Pos + 1, Size - Pos - 2),
            case validate(Address) of
                {ok, Valid} -> named(Name, Valid);
                error -> error
            end
    end.

%% @private
%% The control-character check runs on the RAW name, before anything is
%% trimmed, and only spaces are trimmed afterwards.
%%
%% Order matters here, and getting it wrong is silent: `string:trim/1` treats CR
%% and LF as whitespace, so trimming first would quietly turn `Acme\n <a@b>`
%% into the name `Acme` and accept it. Stripping a control character out of
%% header data is the behaviour this module refuses everywhere else -- a
%% truncation changes what a message means without saying so -- and a caller
%% who sent one is better told.
named(Raw, Address) ->
    case bondy_mail_header:has_control(Raw) of
        true ->
            error;
        false ->
            Name = trim_spaces(unquote(trim_spaces(Raw))),
            case is_valid_name(Name) of
                {ok, <<>>} -> {ok, {undefined, Address}};
                {ok, Valid} -> {ok, {Valid, Address}};
                error -> error
            end
    end.

%% @private
%% Spaces only, and at the byte level.
%%
%% Two reasons, and both were learned the hard way. `string:trim/1` treats CR
%% and LF as whitespace, so it would quietly turn `Acme\n <a@b>` into the name
%% `Acme` and accept it -- see named/2. And every `string` function raises
%% `badarg` on a binary that is not valid UTF-8, so `string:trim(<<128>>, ...)`
%% took down the calling process: a router pool process, over a display name a
%% peer chose. Validation may refuse anything it likes and must crash at
%% nothing.
trim_spaces(<<$\s, Rest/binary>>) ->
    trim_spaces(Rest);
trim_spaces(Bin) ->
    trim_trailing_spaces(Bin).

%% @private
trim_trailing_spaces(<<>>) ->
    <<>>;
trim_trailing_spaces(Bin) ->
    case binary:last(Bin) of
        $\s -> trim_trailing_spaces(binary:part(Bin, 0, byte_size(Bin) - 1));
        _ -> Bin
    end.

%% @private
unquote(<<$", Rest/binary>>) when byte_size(Rest) > 0 ->
    case binary:last(Rest) of
        $" -> binary:part(Rest, 0, byte_size(Rest) - 1);
        _ -> <<$", Rest/binary>>
    end;
unquote(Name) ->
    Name.

%% @private
%% Valid UTF-8 as well as the character and length rules.
%%
%% A display name is header data, and the only way non-ASCII header data can be
%% written is as an RFC 2047 encoded word naming a charset. `mimemail` names
%% UTF-8, so a name that is not valid UTF-8 would be labelled as something it is
%% not -- and refusing it here is the same decision this module makes about
%% every other malformed input, rather than letting an encoder further down
%% either mangle it or raise on a worker with the caller already gone.
is_valid_name(Name) ->
    Bad = binary:match(Name, [~"<", ~">", ~"\"", ~"\\"]),
    Valid =
        Bad == nomatch andalso
            byte_size(Name) =< ?MAX_NAME andalso
            is_utf8(Name),
    case Valid of
        true -> {ok, Name};
        false -> error
    end.

%% @private
is_utf8(Bin) ->
    is_binary(unicode:characters_to_binary(Bin, utf8, utf8)).

%% @private
validate_many([], Acc) ->
    {ok, lists:reverse(Acc)};
validate_many([H | T], Acc) ->
    case validate(H) of
        {ok, Address} -> validate_many(T, [Address | Acc]);
        error -> {error, {invalid_recipient, H}}
    end.

%% @private
%% No control character anywhere -- `bondy_mail_header:has_control/1` is the one
%% definition of that -- and no space either, which is legal in a quoted local
%% part and refused here along with the rest of the quoted form.
is_clean(Bin) ->
    binary:match(Bin, ~" ") == nomatch andalso
        not bondy_mail_header:has_control(Bin).

%% @private
%% Exactly one `@`: `binary:split/2` without `global` stops at the first, so the
%% domain is re-checked for a second one rather than silently accepting it.
split(Bin) ->
    case binary:split(Bin, ~"@") of
        [Local, Domain] ->
            case is_local(Local) andalso is_domain(Domain) of
                true -> {ok, Bin};
                false -> error
            end;
        _ ->
            error
    end.

%% @private
is_local(<<>>) ->
    false;
is_local(Local) when byte_size(Local) > ?MAX_LOCAL ->
    false;
is_local(Local) ->
    %% A dot may separate atoms but may not lead, trail or repeat.
    binary:first(Local) =/= $. andalso
        binary:last(Local) =/= $. andalso
        binary:match(Local, ~"..") == nomatch andalso
        all_bytes(Local, fun is_local_char/1).

%% @private
is_domain(<<>>) ->
    false;
is_domain(Domain) when byte_size(Domain) > ?MAX_DOMAIN ->
    false;
is_domain(Domain) ->
    binary:match(Domain, ~"@") == nomatch andalso
        binary:first(Domain) =/= $. andalso
        binary:last(Domain) =/= $. andalso
        binary:first(Domain) =/= $- andalso
        binary:last(Domain) =/= $- andalso
        binary:match(Domain, ~"..") == nomatch andalso
        all_bytes(Domain, fun is_domain_char/1).

%% @private
all_bytes(Bin, Pred) ->
    lists:all(Pred, binary_to_list(Bin)).

%% @private
%% RFC 5322 atext, plus the dot handled by the caller. Quoted local parts are
%% not accepted -- see the module documentation.
is_local_char(C) ->
    is_alphanumeric(C) orelse
        lists:member(C, "!#$%&'*+-/=?^_`{|}~.").

%% @private
is_domain_char(C) ->
    is_alphanumeric(C) orelse C == $- orelse C == $..

%% @private
is_alphanumeric(C) ->
    (C >= $a andalso C =< $z) orelse
        (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9).
