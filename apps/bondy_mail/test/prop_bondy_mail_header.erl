%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(prop_bondy_mail_header).

-moduledoc """
Header injection, as a property rather than a list of examples.

This is a security test. A caller who can get a CR or an LF into a header value
can end that header and write whatever comes next -- another header, or the
body. Adding recipients that way bypasses every authorisation check the request
already passed, because those checks looked at the envelope and this happens
after it.

Example-based tests can only show that the payloads someone thought of are
refused. The property here is the one that actually matters, and it is stated
over arbitrary input: **nothing that survives validation contains a control
character**. Whether a given input is refused for being injection, for being
reserved, or for being malformed is beside the point -- what must never happen
is that it is accepted.
""".

-include_lib("proper/include/proper.hrl").

%% =============================================================================
%% PROPERTIES
%% =============================================================================

-doc """
Nothing that survives validation carries a control character.

The strongest statement of the invariant: it does not care why an input was
refused, only that no accepted output can terminate a header line.
""".
prop_accepted_headers_carry_no_controls() ->
    ?FORALL(
        Map,
        header_map(),
        case bondy_mail_header:validate(Map) of
            {ok, Headers} ->
                lists:all(
                    fun({Name, Value}) ->
                        no_controls(Name) andalso no_controls(Value)
                    end,
                    Headers
                );
            {error, _} ->
                true
        end
    ).

-doc """
A header that is safe by construction is accepted, unchanged.

Without this, `prop_accepted_headers_carry_no_controls` would hold vacuously: a
validator that refused everything satisfies it perfectly. This is the property
that says the validator has no false positives, and together the two pin both
directions.
""".
prop_safe_headers_are_accepted() ->
    ?FORALL(
        {Name, Value},
        {acceptable_name(), safe_text()},
        bondy_mail_header:validate(#{Name => Value}) ==
            {ok, [{Name, Value}]}
    ).

-doc """
A CRLF anywhere in a value is refused as injection.

Sharper than the invariant above: the name is known-good and non-reserved, so
the only thing that can be wrong is the value, and the reported reason must say
so. A caller given `invalid_header` for this would go looking in the wrong
place.
""".
prop_crlf_in_a_value_is_reported_as_injection() ->
    ?FORALL(
        {Prefix, Sep, Suffix},
        {safe_text(), line_break(), safe_text()},
        begin
            Value = <<Prefix/binary, Sep/binary, Suffix/binary>>,
            Result = bondy_mail_header:validate(#{~"X-Test" => Value}),
            Result == {error, {header_injection, ~"X-Test"}}
        end
    ).

-doc """
A CRLF anywhere in a name is refused as injection.

The name is the other half of the same attack: `X\\r\\nBcc` splits into a
harmless header and a recipient.
""".
prop_crlf_in_a_name_is_reported_as_injection() ->
    ?FORALL(
        {Prefix, Sep, Suffix},
        {safe_name(), line_break(), safe_name()},
        begin
            Name = <<Prefix/binary, Sep/binary, Suffix/binary>>,
            case bondy_mail_header:validate(#{Name => ~"value"}) of
                {error, {header_injection, _}} -> true;
                _ -> false
            end
        end
    ).

-doc """
A display name can never carry a line break into a header.

The `From` header is built from a caller-supplied display name, so it is the
same attack surface as any other header value -- and a more attractive one,
because a display name is the field a caller most expects to be free text.
`Acme\\r\\nBcc: victim@evil.example <a@b.com>` must be refused outright, not
trimmed into something that looks fine.

Generated around the break rather than fixed, because the interesting failures
are at the edges: a break at the very start or end of the name is exactly where
a trim-then-check implementation stops noticing it.
""".
prop_crlf_in_a_display_name_is_refused() ->
    ?FORALL(
        {Prefix, Sep, Suffix},
        {display_name_text(), line_break(), display_name_text()},
        begin
            Name = <<Prefix/binary, Sep/binary, Suffix/binary>>,
            From = <<Name/binary, " <a@b.com>">>,
            bondy_mail_address:parse_mailbox(From) == error
        end
    ).

-doc """
Whatever is accepted is re-encodable.

The round trip is the property that matters: a value this module accepts is one
`format_mailbox/2` renders and `mimemail` then parses back to the same name and
the same address. An accepted-but-unrenderable name would be a validation that
passes and an encode that fails later, on a worker, with the caller already
gone.
""".
prop_an_accepted_display_name_round_trips() ->
    ?FORALL(
        Name,
        display_name_text(),
        begin
            From = <<Name/binary, " <a@b.com>">>,
            case bondy_mail_address:parse_mailbox(From) of
                error ->
                    true;
                {ok, {Parsed, Address}} ->
                    Header = bondy_mail_address:format_mailbox(Parsed, Address),
                    case smtp_util:parse_rfc5322_addresses(Header) of
                        {ok, [{ReName, ReAddress}]} ->
                            list_to_binary(ReAddress) == Address andalso
                                same_name(ReName, Parsed);
                        _ ->
                            false
                    end
            end
        end
    ).

-doc """
A reserved header is refused whatever its casing.

Header names are case-insensitive, so a check that is not would let `bCc`
through a list containing `bcc`.
""".
prop_reserved_headers_are_refused_in_any_case() ->
    ?FORALL(
        {Name, Value},
        {reserved_name(), safe_text()},
        case bondy_mail_header:validate(#{Name => Value}) of
            {error, {reserved_header, _}} -> true;
            %% A value that is itself injection is refused earlier, which is
            %% also correct.
            {error, {header_injection, _}} -> false;
            _ -> false
        end
    ).

%% =============================================================================
%% GENERATORS
%% =============================================================================

%% A map of arbitrary binaries. Deliberately unconstrained: the point is that
%% validation holds for input nobody designed.
header_map() ->
    ?LET(
        Pairs,
        list({header_name_or_junk(), header_value_or_junk()}),
        maps:from_list(Pairs)
    ).

header_name_or_junk() ->
    oneof([safe_name(), binary(), reserved_name()]).

header_value_or_junk() ->
    oneof([safe_text(), binary(), injected_value()]).

injected_value() ->
    ?LET(
        {A, Sep, B},
        {safe_text(), line_break(), safe_text()},
        <<A/binary, Sep/binary, B/binary>>
    ).

%% Every way a line can be broken, not just the canonical pair.
line_break() ->
    oneof([~"\r\n", ~"\r", ~"\n", ~"\n\r", ~"\r\n\r\n"]).

%% A legal field name that is not reserved. `safe_name/0` draws from letters,
%% so it can and does generate `to`, `cc` and `date` -- which are refused, and
%% would make an acceptance property fail for an entirely correct reason.
acceptable_name() ->
    ?SUCHTHAT(Name, safe_name(), not bondy_mail_header:is_reserved(Name)).

%% Printable ASCII, no colon: the shape of a legal field name.
safe_name() ->
    ?LET(
        L,
        non_empty(list(oneof(lists:seq($a, $z) ++ lists:seq($A, $Z) ++ "-_"))),
        list_to_binary(lists:sublist(L, 40))
    ).

%% Printable ASCII with no controls, so it cannot itself be the injection.
safe_text() ->
    ?LET(
        L,
        list(oneof(lists:seq($\s, $~))),
        list_to_binary(lists:sublist(L, 100))
    ).

%% Printable ASCII minus the characters a display name may not contain, so the
%% generator explores names that are ACCEPTED and the property is about what
%% happens to them rather than about them being rejected.
display_name_text() ->
    ?LET(
        L,
        list(oneof(lists:seq($\s, $~) -- "<>\"\\")),
        list_to_binary(lists:sublist(L, 60))
    ).

%% `undefined` when the name was empty or all spaces: both parse to a bare
%% address, and `format_mailbox/2` then emits one.
same_name(undefined, undefined) -> true;
same_name(undefined, _) -> false;
same_name(ReName, Name) -> unicode:characters_to_binary(ReName) == Name.

%% A reserved name in arbitrary casing.
reserved_name() ->
    ?LET(
        {Name, Flips},
        {oneof(bondy_mail_header:reserved()), list(boolean())},
        recase(Name, Flips)
    ).

%% =============================================================================
%% PRIVATE
%% =============================================================================

no_controls(Bin) ->
    lists:all(fun(C) -> C >= 32 andalso C =/= 127 end, binary_to_list(Bin)).

%% Flip the case of each character according to `Flips`, cycling when it runs
%% out, so the generated casing is varied rather than uniformly upper or lower.
recase(Bin, []) ->
    Bin;
recase(Bin, Flips) ->
    Chars = binary_to_list(Bin),
    list_to_binary(recase(Chars, Flips, Flips)).

recase([], _, _) ->
    [];
recase(Chars, [], All) ->
    recase(Chars, All, All);
recase([C | T], [true | Ft], All) ->
    [upper(C) | recase(T, Ft, All)];
recase([C | T], [false | Ft], All) ->
    [C | recase(T, Ft, All)].

upper(C) when C >= $a andalso C =< $z -> C - 32;
upper(C) -> C.
