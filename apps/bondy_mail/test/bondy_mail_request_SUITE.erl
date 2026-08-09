%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_request_SUITE).

-moduledoc """
The request contract, and the authority applied to it.

Most of this suite is about two questions: may this realm use this relay, and
may it send as this address. Both are enforced here rather than in either
surface, because `bondy_mail_request:new/2` is the only code the broker bridge
and the `bondy.mail.*` API both pass through.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_mail/include/bondy_mail.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, ~"com.example.app").
-define(OTHER_REALM, ~"com.example.other").
-define(MASTER, ~"com.leapsight.bondy").

all() ->
    [
        %% Shape
        unknown_keys_are_named,
        recipients_are_required,
        a_body_is_required,
        invalid_recipient_is_named,
        single_recipient_may_be_a_binary,
        %% Relay authority
        unlisted_realm_may_not_use_a_relay,
        listed_realm_may_use_a_relay,
        wildcard_relay_admits_any_realm,
        master_realm_may_use_any_relay,
        prototype_admits_the_realms_that_inherit_from_it,
        prototype_does_not_admit_an_unrelated_realm,
        unknown_relay_is_named,
        default_relay_is_used_when_unnamed,
        %% Sender authority
        sender_defaults_to_the_relay,
        caller_cannot_set_a_sender_by_default,
        caller_may_set_a_permitted_sender,
        caller_may_not_set_an_unpermitted_sender,
        caller_may_set_a_display_name,
        a_display_name_cannot_smuggle_a_sender_past_the_allow_list,
        a_display_name_may_not_carry_control_characters,
        a_display_name_may_not_be_invalid_utf8,
        relay_may_configure_a_display_name,
        reply_to_may_carry_a_display_name,
        %% Headers
        reserved_header_is_refused,
        injected_header_is_refused,
        %% Attachments
        attachment_is_decoded,
        oversized_attachments_are_refused,
        attachment_must_be_base64,
        attachment_filename_may_not_be_a_path,
        attachment_filename_may_not_carry_control_characters,
        %% Deadline
        timeout_is_capped_by_the_relay
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    _ = application:stop(bondy_mail),
    ok.

init_per_testcase(_Case, Config) ->
    _ = application:stop(bondy_mail),
    ok = bondy_mail_test_realm:uninstall(),
    ok = application:set_env(bondy_mail, default_relay, undefined),
    ok = application:set_env(bondy_mail, relays, relays()),
    {ok, _} = application:ensure_all_started(bondy_mail),
    Config.

end_per_testcase(_Case, _Config) ->
    _ = application:stop(bondy_mail),
    ok = bondy_mail_test_realm:uninstall(),
    ok.

%% =============================================================================
%% SHAPE
%% =============================================================================

-doc """
A key the contract does not know is named, not dropped.

`maps_utils:validate/2` silently discards what it does not recognise, so a
misspelled `subjekt` would otherwise become a message with no subject and no
complaint.
""".
unknown_keys_are_named(_) ->
    Req = (base())#{~"subjekt" => ~"typo", ~"whatever" => 1},
    ?assertEqual(
        {error, {unknown_keys, [~"subjekt", ~"whatever"]}},
        new(?REALM, Req)
    ).

recipients_are_required(_) ->
    Req = maps:remove(~"to", base()),
    ?assertMatch({error, {invalid_request, _}}, new(?REALM, Req)),
    ?assertEqual(
        {error, {invalid_request, no_recipients}},
        new(?REALM, (base())#{~"to" => []})
    ).

a_body_is_required(_) ->
    Req = maps:remove(~"text", base()),
    ?assertEqual({error, {invalid_request, no_body}}, new(?REALM, Req)).

invalid_recipient_is_named(_) ->
    Req = (base())#{~"to" => [~"good@example.com", ~"not-an-address"]},
    ?assertEqual(
        {error, {invalid_recipient, ~"not-an-address"}},
        new(?REALM, Req)
    ).

single_recipient_may_be_a_binary(_) ->
    Req = (base())#{~"to" => ~"one@example.com"},
    {ok, R} = new(?REALM, Req),
    ?assertEqual([~"one@example.com"], R#bondy_mail_request.to).

%% =============================================================================
%% RELAY AUTHORITY
%% =============================================================================

-doc """
A realm not listed by a relay may not use it.

Default deny: the relay declares who may send through it, and nothing else
grants access.
""".
unlisted_realm_may_not_use_a_relay(_) ->
    Req = (base())#{~"relay" => ~"scoped"},
    ?assertEqual(
        {error, {relay_not_permitted, ~"scoped"}},
        new(?OTHER_REALM, Req)
    ).

listed_realm_may_use_a_relay(_) ->
    Req = (base())#{~"relay" => ~"scoped"},
    ?assertMatch({ok, _}, new(?REALM, Req)).

wildcard_relay_admits_any_realm(_) ->
    Req = (base())#{~"relay" => ~"open"},
    ?assertMatch({ok, _}, new(?OTHER_REALM, Req)),
    ?assertMatch({ok, _}, new(~"com.anything.at.all", Req)).

-doc """
The master realm may use a relay that lists no realms at all.

That is how an operator-only relay is expressed: an empty list admits nobody
except the operator's own realm.
""".
master_realm_may_use_any_relay(_) ->
    Req = (base())#{~"relay" => ~"operator"},
    ?assertEqual(
        {error, {relay_not_permitted, ~"operator"}},
        new(?REALM, Req)
    ),
    ?assertMatch({ok, _}, new(?MASTER, Req)).

-doc """
Listing a prototype admits every realm that inherits from it.

The same inheritance that governs grants, so a family of tenant realms is
admitted by naming their prototype once rather than by listing each one.
""".
prototype_admits_the_realms_that_inherit_from_it(_) ->
    ok = bondy_mail_test_realm:install(#{
        ~"com.tenant.a" => ~"com.example.proto",
        ~"com.tenant.b" => ~"com.example.proto"
    }),

    Req = (base())#{~"relay" => ~"by_prototype"},
    ?assertMatch({ok, _}, new(~"com.tenant.a", Req)),
    ?assertMatch({ok, _}, new(~"com.tenant.b", Req)).

-doc """
A realm inheriting from a different prototype is still refused.

Guards against the check degenerating into "has any prototype at all".
""".
prototype_does_not_admit_an_unrelated_realm(_) ->
    ok = bondy_mail_test_realm:install(#{
        ~"com.tenant.a" => ~"com.example.proto",
        ~"com.stranger" => ~"com.other.proto"
    }),

    Req = (base())#{~"relay" => ~"by_prototype"},
    ?assertMatch({ok, _}, new(~"com.tenant.a", Req)),
    ?assertEqual(
        {error, {relay_not_permitted, ~"by_prototype"}},
        new(~"com.stranger", Req)
    ),
    %% And a realm with no prototype at all.
    ?assertEqual(
        {error, {relay_not_permitted, ~"by_prototype"}},
        new(~"com.orphan", Req)
    ).

unknown_relay_is_named(_) ->
    Req = (base())#{~"relay" => ~"absent"},
    ?assertEqual({error, {no_such_relay, ~"absent"}}, new(?REALM, Req)).

default_relay_is_used_when_unnamed(_) ->
    ok = application:stop(bondy_mail),
    ok = application:set_env(bondy_mail, default_relay, ~"open"),
    {ok, _} = application:ensure_all_started(bondy_mail),

    {ok, R} = new(?REALM, base()),
    ?assertEqual(~"open", R#bondy_mail_request.relay).

%% =============================================================================
%% SENDER AUTHORITY
%% =============================================================================

-doc """
A request that names no sender gets the relay's.

This is what makes spoofing impossible by default rather than by check: there
is no path from caller input to the sender unless the relay opened one.
""".
sender_defaults_to_the_relay(_) ->
    {ok, R} = new(?REALM, (base())#{~"relay" => ~"scoped"}),
    ?assertEqual(~"no-reply@example.com", R#bondy_mail_request.from).

-doc """
With no `allowed_from`, a caller cannot choose a sender at all.

The default. A relay whose owner has not said which domains it owns does not
let a caller pick one.
""".
caller_cannot_set_a_sender_by_default(_) ->
    Req = (base())#{~"relay" => ~"scoped", ~"from" => ~"anyone@example.com"},
    ?assertEqual(
        {error, {sender_not_permitted, ~"scoped", ~"anyone@example.com"}},
        new(?REALM, Req)
    ).

caller_may_set_a_permitted_sender(_) ->
    Req = (base())#{~"relay" => ~"branded", ~"from" => ~"sales@example.com"},
    {ok, R} = new(?REALM, Req),
    ?assertEqual(~"sales@example.com", R#bondy_mail_request.from).

caller_may_not_set_an_unpermitted_sender(_) ->
    Req = (base())#{~"relay" => ~"branded", ~"from" => ~"ceo@bank.example"},
    ?assertEqual(
        {error, {sender_not_permitted, ~"branded", ~"ceo@bank.example"}},
        new(?REALM, Req)
    ).

-doc """
A display name is accepted and kept apart from the address.

`from` stays a bare address because it feeds the SMTP envelope and the
`allowed_from` check; the name travels beside it and is put back together only
when the `From` header is built.
""".
caller_may_set_a_display_name(_) ->
    Req = (base())#{
        ~"relay" => ~"branded",
        ~"from" => ~"Acme Sales <sales@example.com>"
    },
    {ok, R} = new(?REALM, Req),
    ?assertEqual(~"sales@example.com", R#bondy_mail_request.from),
    ?assertEqual(~"Acme Sales", R#bondy_mail_request.from_name).

-doc """
**A display name cannot be used to smuggle a sender past `allowed_from`.**

This is the case the whole split exists for. `allowed_from` is matched against
the ADDRESS, so a name that looks like a permitted domain buys nothing: were it
matched against the value the caller supplied, `Trusted <x@evil.example>` would
be accepted by a relay scoped to `example.com` and the derived-sender guarantee
would be worthless.
""".
a_display_name_cannot_smuggle_a_sender_past_the_allow_list(_) ->
    Attempts = [
        ~"sales@example.com <attacker@evil.example>",
        ~"example.com <attacker@evil.example>",
        ~"\"sales@example.com\" <attacker@evil.example>"
    ],
    lists:foreach(
        fun(From) ->
            Req = (base())#{~"relay" => ~"branded", ~"from" => From},
            ?assertEqual(
                {error,
                    {sender_not_permitted, ~"branded",
                        ~"attacker@evil.example"}},
                new(?REALM, Req),
                binary_to_list(From)
            )
        end,
        Attempts
    ).

-doc """
A display name is header data and takes the header injection rule.

Rejected rather than stripped, exactly as a header value is: a truncation
changes what a message means without saying so.
""".
a_display_name_may_not_carry_control_characters(_) ->
    Attempts = [
        ~"Acme\r\nBcc: victim@evil.example <sales@example.com>",
        ~"Acme\n <sales@example.com>",
        ~"Acme\0 <sales@example.com>"
    ],
    lists:foreach(
        fun(From) ->
            Req = (base())#{~"relay" => ~"branded", ~"from" => From},
            ?assertMatch({error, {invalid_recipient, _}}, new(?REALM, Req))
        end,
        Attempts
    ).

-doc """
A relay may configure a display name of its own.

That is where the brand a recipient sees belongs: it applies to every message
the relay sends, and no caller had to ask for it. It is not checked against
`allowed_from` -- it IS the permitted sender.
""".
relay_may_configure_a_display_name(_) ->
    {ok, R} = new(?REALM, (base())#{~"relay" => ~"named"}),
    ?assertEqual(~"no-reply@example.com", R#bondy_mail_request.from),
    ?assertEqual(~"Acme Ltd", R#bondy_mail_request.from_name).

-doc "A display name on `Reply-To`, which is header-only and never routed.".
reply_to_may_carry_a_display_name(_) ->
    Req = (base())#{~"reply_to" => ~"Support <help@example.com>"},
    {ok, R} = new(?REALM, Req),
    ?assertEqual(~"help@example.com", R#bondy_mail_request.reply_to),
    ?assertEqual(~"Support", R#bondy_mail_request.reply_to_name).

-doc """
A display name that is not valid UTF-8 is refused, not crashed on.

Found by `prop_bondy_mail_header:prop_the_control_rule_is_one_rule/0`, which is
the whole argument for the property: `string:trim/1` raises `badarg` on a
binary that is not valid UTF-8, so a single stray byte in a caller-supplied
`from` took down the process validating it rather than producing an error.

Refused rather than repaired for the reason this module refuses everything
else: a name that is not UTF-8 cannot be written as the UTF-8 encoded word
`mimemail` would label it, and quietly dropping the byte would send a message
that differs from the one the caller described.
""".
a_display_name_may_not_be_invalid_utf8(_) ->
    Bad = <<"Acme", 128, " <a@bondy.test>">>,
    ?assertMatch(
        {error, {invalid_recipient, _}},
        new(?REALM, (base())#{~"from" => Bad})
    ).

%% =============================================================================
%% HEADERS
%% =============================================================================

reserved_header_is_refused(_) ->
    Req = (base())#{~"headers" => #{~"Bcc" => ~"victim@evil.com"}},
    ?assertEqual({error, {reserved_header, ~"Bcc"}}, new(?REALM, Req)).

injected_header_is_refused(_) ->
    Req = (base())#{
        ~"headers" => #{~"X-Test" => ~"a\r\nBcc: victim@evil.com"}
    },
    ?assertEqual({error, {header_injection, ~"X-Test"}}, new(?REALM, Req)).

%% =============================================================================
%% ATTACHMENTS
%% =============================================================================

attachment_is_decoded(_) ->
    Req = (base())#{
        ~"attachments" => [
            #{
                ~"filename" => ~"note.txt",
                ~"content_type" => ~"text/plain",
                ~"data" => base64:encode(~"hello")
            }
        ]
    },
    {ok, R} = new(?REALM, Req),
    [A] = R#bondy_mail_request.attachments,
    ?assertEqual(~"hello", A#bondy_mail_attachment.data),
    ?assertEqual(~"note.txt", A#bondy_mail_attachment.filename).

-doc """
Attachments are bounded by the relay's maximum, before anything is queued.

The budget is on decoded bytes with headroom for encoding, so a request
accepted here is unlikely to be refused by the relay for size afterwards.
""".
oversized_attachments_are_refused(_) ->
    %% `tiny` allows 1000 bytes, so ~700 after headroom.
    Data = binary:copy(~"a", 2000),
    Req = (base())#{
        ~"relay" => ~"tiny",
        ~"attachments" => [
            #{~"filename" => ~"big.bin", ~"data" => base64:encode(Data)}
        ]
    },
    ?assertMatch({error, {too_large_payload, _, _}}, new(?REALM, Req)).

attachment_must_be_base64(_) ->
    Req = (base())#{
        ~"attachments" => [
            #{~"filename" => ~"note.txt", ~"data" => ~"!!!not base64!!!"}
        ]
    },
    ?assertMatch({error, {invalid_request, _}}, new(?REALM, Req)).

-doc """
An attachment filename may not look like a path.

It lands in a `Content-Disposition` header, so it is subject to the header
injection rule; separators are refused as well, because a recipient's client
decides where a file goes and a name that looks like a path invites it to
decide badly.
""".
attachment_filename_may_not_be_a_path(_) ->
    [
        ?assertMatch(
            {error, {invalid_request, _}},
            new(?REALM, (base())#{
                ~"attachments" => [
                    #{~"filename" => N, ~"data" => base64:encode(~"x")}
                ]
            })
        )
     || N <- [~"../../etc/passwd", ~"a/b.txt", ~"a\\b.txt", ~"a\r\nb.txt", ~""]
    ].

-doc """
An attachment filename may not carry a control character.

A filename becomes a `Content-Disposition` parameter, so it is header data and
is held to the same rule as any other header data. It used to be held to a
shorter one -- CR, LF and NUL only -- so a filename could carry a vertical tab
or a DEL that the very same bytes in a custom header would have been refused
for. One rule, one function: `bondy_mail_header:has_control/1`.
""".
attachment_filename_may_not_carry_control_characters(_) ->
    Attachment = fun(Name) ->
        #{
            ~"filename" => Name,
            ~"content_type" => ~"text/plain",
            ~"data" => base64:encode(~"x")
        }
    end,

    [
        ?assertMatch(
            {error, {invalid_request, {attachment_filename, _}}},
            new(?REALM, (base())#{~"attachments" => [Attachment(Name)]})
        )
     || Name <- [
            <<"a", 11, "b.txt">>,
            <<"a", 127, "b.txt">>,
            <<"a", 0, "b.txt">>,
            <<"a", 12, "b.txt">>
        ]
    ],

    %% And an ordinary one is still accepted.
    ?assertMatch(
        {ok, _},
        new(?REALM, (base())#{~"attachments" => [Attachment(~"notes.txt")]})
    ).

%% =============================================================================
%% DEADLINE
%% =============================================================================

-doc """
A caller may ask for less time than the relay allows, never more.

The relay's timeout is what bounds how long one of its workers can be held, so
a caller cannot extend it.
""".
timeout_is_capped_by_the_relay(_) ->
    %% `scoped` allows 30s.
    {ok, Short} = new(?REALM, (base())#{
        ~"relay" => ~"scoped", ~"timeout" => 5000
    }),
    ?assertEqual(5000, Short#bondy_mail_request.timeout),

    {ok, Capped} = new(?REALM, (base())#{
        ~"relay" => ~"scoped", ~"timeout" => 600000
    }),
    ?assertEqual(30000, Capped#bondy_mail_request.timeout).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
new(RealmUri, Map) ->
    bondy_mail_request:new(RealmUri, Map).

%% @private
base() ->
    #{
        ~"relay" => ~"open",
        ~"to" => [~"user@example.com"],
        ~"subject" => ~"Hello",
        ~"text" => ~"Body"
    }.

%% @private
relays() ->
    [
        %% Any realm, any sender.
        #{
            name => ~"open",
            host => ~"smtp.example.com",
            from => ~"no-reply@example.com",
            realms => any,
            allowed_from => any
        },
        %% One realm; sender fixed by the relay.
        #{
            name => ~"scoped",
            host => ~"smtp.example.com",
            from => ~"no-reply@example.com",
            realms => [?REALM]
        },
        %% One realm, and callers may choose within one domain.
        #{
            name => ~"branded",
            host => ~"smtp.example.com",
            from => ~"no-reply@example.com",
            realms => [?REALM],
            allowed_from => [~"example.com"]
        },
        %% A relay whose configured sender carries a display name.
        #{
            name => ~"named",
            host => ~"smtp.example.com",
            from => ~"Acme Ltd <no-reply@example.com>",
            realms => [?REALM]
        },
        %% No realms listed: the master realm only.
        #{
            name => ~"operator",
            host => ~"smtp.example.com",
            from => ~"ops@example.com"
        },
        %% Admits whatever inherits from the named prototype.
        #{
            name => ~"by_prototype",
            host => ~"smtp.example.com",
            from => ~"no-reply@example.com",
            realms => [~"com.example.proto"]
        },
        %% A small size budget, for the attachment case.
        #{
            name => ~"tiny",
            host => ~"smtp.example.com",
            from => ~"no-reply@example.com",
            realms => any,
            max_message_size => 1000
        }
    ].
