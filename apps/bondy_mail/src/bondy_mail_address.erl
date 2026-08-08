%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_address).

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

%% API
-export([domain/1]).
-export([is_valid/1]).
-export([validate/1]).
-export([validate_many/1]).
-export([is_domain_allowed/2]).

%% =============================================================================
%% API
%% =============================================================================

-doc "Return `true` when `Term` is a syntactically valid address.".
-spec is_valid(Term :: any()) -> boolean().

is_valid(Term) ->
    validate(Term) =/= error.

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

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
validate_many([], Acc) ->
    {ok, lists:reverse(Acc)};
validate_many([H | T], Acc) ->
    case validate(H) of
        {ok, Address} -> validate_many(T, [Address | Acc]);
        error -> {error, {invalid_recipient, H}}
    end.

%% @private
%% No control characters anywhere. CR and LF are the header-injection vector and
%% matter most, but a NUL or a bare tab has no business in an address either.
is_clean(Bin) ->
    binary:match(Bin, [~"\r", ~"\n", ~"\0", ~"\t", ~" "]) == nomatch.

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
