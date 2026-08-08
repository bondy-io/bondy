%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_error_test).

-moduledoc """
The translation from a send failure to a catalogue error.

This is the last thing between a relay's own words and a caller, so most of
what is checked here is what does *not* come through: no hostname, no
credential, no SMTP banner. The relay's configured name does, because the
caller supplied it.

`no_message_has_an_unsubstituted_placeholder` is the case worth reading.
`bondy_error` leaves an absent `%{key}` visible rather than blanking it -- the
right choice, since a silently missing substitution is worse than an obvious
one -- which means a catalogue message referring to a value its own callers
cannot supply ships `%{relay}` to a user. Nothing else catches that.
""".

-include_lib("eunit/include/eunit.hrl").

%% Every failure `bondy_mail` can produce, gathered from the modules that
%% return them. A reason that stops being produced should be deleted from here
%% deliberately, not left to rot.
-define(REASONS, [
    %% bondy_mail
    not_configured,
    {transient, rate_limited, ~"relay-a"},
    {transient, owner_unavailable, 'a@127.0.0.1'},
    {transient, status_unavailable, ~"id"},
    {transient, timeout, 1000},
    %% bondy_mail_request
    {invalid_request, badarg},
    {invalid_request, no_body},
    {invalid_request, no_recipients},
    {invalid_request, missing_sender},
    {unknown_keys, [~"subjekt"]},
    no_such_relay,
    {no_such_relay, ~"relay-a"},
    {relay_not_permitted, ~"relay-a"},
    {sender_not_permitted, ~"relay-a", ~"eve@example.com"},
    {invalid_recipient, ~"not-an-address"},
    {too_large_payload, 100, 50},
    %% bondy_mail_header
    {header_injection, ~"X-Evil"},
    {reserved_header, ~"Bcc"},
    {invalid_header, ~"X-"},
    %% bondy_mail_worker
    {transient, queue_full, ~"relay-a"},
    {transient, queue_unavailable, down},
    {transient, deadline, 3},
    {permanent, no_such_relay, ~"relay-a"},
    {permanent, too_large_payload, {too_large_payload, 100, 50}},
    {permanent, encoding_failed, mime},
    %% bondy_mail_transport_smtp
    {permanent, rejected, ~"550"},
    {transient, deferred, ~"451"},
    {transient, timeout, timeout},
    {transient, network, econnrefused},
    {permanent, missing_requirement, tls},
    {transient, unexpected_response, unexpected_response},
    {permanent, configuration, no_credentials},
    {transient, unknown, unknown}
]).

%% =============================================================================
%% TOTALITY
%% =============================================================================

%% Anything at all can be translated, and the result is always a well-formed
%% error. A translation that raised would turn a failed send into a crash.
every_reason_translates_test() ->
    [
        ?assert(bondy_error:is_type(bondy_mail:to_error(R)))
     || R <- ?REASONS
    ].

unrecognised_reasons_translate_test() ->
    [
        ?assert(bondy_error:is_type(bondy_mail:to_error(R)))
     || R <- [undefined, ~"a binary", {a, b, c, d}, [1, 2, 3], #{}, 42]
    ].

%% A known failure must not fall through to `internal_error`: that is reserved
%% for what Bondy cannot describe, and using it for a rejected recipient would
%% hide an answer the caller could act on behind a trace id.
no_known_reason_becomes_internal_test() ->
    Internal = [
        R
     || R <- ?REASONS,
        maps:get(type, bondy_mail:to_error(R)) == internal_error
    ],
    %% An encoding failure is Bondy's own defect and is meant to land here.
    ?assertEqual([{permanent, encoding_failed, mime}], Internal).

%% Each of M001-M009 must be reachable. An entry no failure produces is
%% documentation of something that cannot happen.
every_mail_entry_is_reachable_test() ->
    Produced = lists:usort([
        maps:get(type, bondy_mail:to_error(R))
     || R <- ?REASONS
    ]),
    Mail = [
        mail_not_configured,
        no_such_relay,
        relay_not_permitted,
        sender_not_permitted,
        invalid_recipient,
        mail_rejected,
        mail_delivery_failed,
        relay_unavailable,
        mail_queue_full
    ],
    ?assertEqual([], Mail -- Produced).

%% =============================================================================
%% CONTRACT
%% =============================================================================

-doc """
`nature` decides whether a client retries, so a mistranslation here either
hammers a relay that has permanently refused or abandons a message that would
have gone through on the next attempt.
""".
nature_survives_translation_test() ->
    Wrong = [
        {R, Nature, maps:get(nature, bondy_mail:to_error(R))}
     || {Nature, _, _} = R <- ?REASONS,
        Nature == permanent orelse Nature == transient,
        maps:get(nature, bondy_mail:to_error(R)) =/= Nature
    ],
    %% One deliberate exception. An encoding failure is Bondy's own defect, and
    %% `internal_error` is transient because a retry may well reach a node or a
    %% version where the same message encodes.
    ?assertEqual(
        [{{permanent, encoding_failed, mime}, permanent, transient}], Wrong
    ).

-doc """
A message that interpolates `%{key}` must be given that key by every caller
that can produce it.

`bondy_error` deliberately leaves an absent placeholder visible, so a mismatch
between a catalogue message and the details its producers supply reaches a user
as literal `%{relay}`.
""".
no_message_has_an_unsubstituted_placeholder_test() ->
    Leaky = [
        {R, Message}
     || R <- ?REASONS,
        #{message := Message} <- [bondy_mail:to_error(R)],
        binary:match(Message, ~"%{") =/= nomatch
    ],
    ?assertEqual([], Leaky).

no_description_has_an_unsubstituted_placeholder_test() ->
    Leaky = [
        {R, Description}
     || R <- ?REASONS,
        #{description := Description} <- [bondy_mail:to_error(R)],
        binary:match(Description, ~"%{") =/= nomatch
    ],
    ?assertEqual([], Leaky).

%% =============================================================================
%% WHAT A CALLER NEVER RECEIVES
%% =============================================================================

-doc """
A relay's rejection text does not reach a caller, even if one arrives here
whole.

The transport already truncates to the reply code, so this checks the gate
rather than the guard behind it: an SMTP banner is written by someone other
than us and routinely quotes the recipient it just refused.
""".
banner_text_is_not_echoed_test() ->
    Banner = ~"550 5.1.1 <bob@secret.example.com>: recipient rejected",
    Error = bondy_mail:to_error({permanent, rejected, Banner}),

    ?assertEqual(mail_rejected, maps:get(type, Error)),
    ?assertEqual(#{}, maps:get(details, Error)),
    ?assertEqual(nomatch, binary:match(render(Error), ~"secret.example.com")).

-doc """
A three-digit reply code does survive: it is the part a caller can act on, and
it says nothing about the relay beyond what it decided.
""".
reply_code_is_kept_test() ->
    %% `bondy_error:sanitise/1` renders every details key as a binary, because
    %% the payload has to be JSON-encodable.
    Error = bondy_mail:to_error({permanent, rejected, ~"550"}),
    ?assertEqual(#{~"code" => ~"550"}, maps:get(details, Error)),

    Deferred = bondy_mail:to_error({transient, deferred, ~"451"}),
    ?assertEqual(#{~"code" => ~"451"}, maps:get(details, Deferred)).

-doc """
Anything shaped like a code but not a reply code is dropped rather than passed
through. `1xx` to `5xx` are the only codes SMTP defines.
""".
non_reply_codes_are_dropped_test() ->
    [
        ?assertEqual(
            #{},
            maps:get(details, bondy_mail:to_error({permanent, rejected, C}))
        )
     || C <- [~"", ~"55", ~"5500", ~"abc", ~"650", ~"050", not_a_binary]
    ].

-doc """
No translation carries a hostname, a username or a credential.

None of the reasons hold one today. This asserts that none acquires one, which
is the part a later change can break without anyone noticing.
""".
no_relay_internals_are_exposed_test() ->
    Secrets = [
        ~"smtp.internal.example.com",
        ~"apikey",
        ~"s3cret",
        ~"127.0.0.1"
    ],
    Leaks = [
        {R, S}
     || R <- ?REASONS,
        S <- Secrets,
        binary:match(render(bondy_mail:to_error(R)), S) =/= nomatch
    ],
    ?assertEqual([], Leaks).

-doc """
The relay's configured name does come through, because the caller named it.

Without this the previous case would pass by translating everything into an
empty error.
""".
relay_name_is_reported_test() ->
    [
        ?assertEqual(
            #{~"relay" => ~"relay-a"},
            maps:get(details, bondy_mail:to_error(R))
        )
     || R <- [
            {no_such_relay, ~"relay-a"},
            {relay_not_permitted, ~"relay-a"},
            {permanent, no_such_relay, ~"relay-a"},
            {transient, queue_full, ~"relay-a"},
            {transient, rate_limited, ~"relay-a"}
        ]
    ].

-doc """
An unnamed relay with no default says so, rather than reporting a relay called
`undefined`.
""".
missing_default_relay_names_no_relay_test() ->
    Error = bondy_mail:to_error(no_such_relay),
    ?assertEqual(no_such_relay, maps:get(type, Error)),
    ?assertEqual(#{}, maps:get(details, Error)),
    ?assertEqual(
        nomatch, binary:match(maps:get(message, Error), ~"undefined")
    ).

-doc """
An internal error carries a trace id, which is the whole of what makes it
useful: the operator finds the same id on the log entry holding the real
reason.
""".
internal_errors_carry_a_trace_id_test() ->
    Error = bondy_mail:to_error({permanent, encoding_failed, mime}),
    TraceId = maps:get(trace_id, Error),

    ?assertMatch(<<_:32/binary>>, TraceId),
    %% And the reason is in metadata, which is not part of the peer's payload.
    ?assertMatch(#{reason := _}, maps:get(metadata, Error)),
    ?assertNot(maps:is_key(metadata, bondy_error:to_map(Error))).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Everything a peer actually receives, flattened, so a check for a leak cannot
%% miss it by looking in the wrong field.
render(Error) ->
    iolist_to_binary(io_lib:format("~p", [bondy_error:to_map(Error)])).
