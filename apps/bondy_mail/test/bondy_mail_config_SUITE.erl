%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_config_SUITE).

-moduledoc """
Relay configuration, dormancy, and failing closed.

`bondy_mail` does not depend on the router, so this suite starts the
application on its own rather than through `bondy_ct`.

The theme is that misconfiguration must never take a node down: no relays means
a dormant application, and one bad relay means one disabled relay rather than a
failed boot.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_mail/include/bondy_mail.hrl").

-compile([nowarn_export_all, export_all]).

-define(VAR, "BONDY_MAIL_SUITE_SECRET").

all() ->
    [
        dormant_without_relays,
        relay_defaults_are_applied,
        wildcard_realms_and_senders_are_accepted,
        default_relay_accepts_a_string,
        single_relay_is_the_default,
        several_relays_need_an_explicit_default,
        explicit_default_relay_is_used,
        unknown_default_relay_is_reported,
        invalid_relay_is_dropped_and_others_survive,
        unresolvable_secret_disables_the_relay,
        env_secret_is_resolved,
        literal_secret_is_resolved,
        secret_does_not_appear_when_formatted,
        relay_info_carries_nothing_sensitive,
        restarting_reparses_the_declaration
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    _ = application:stop(bondy_mail),
    ok.

%% `app_config` caches configuration in `persistent_term`, and
%% `application:unset_env/2` does not clear it -- so a key set by one case would
%% still be readable in the next. Overwriting with `undefined` is what actually
%% resets it. A real node is unaffected: `persistent_term` lives and dies with
%% the VM, and cuttlefish regenerates the environment on every boot.
init_per_testcase(_Case, Config) ->
    _ = application:stop(bondy_mail),
    ok = application:set_env(bondy_mail, relays, []),
    ok = application:set_env(bondy_mail, default_relay, undefined),
    os:unsetenv(?VAR),
    Config.

end_per_testcase(_Case, _Config) ->
    _ = application:stop(bondy_mail),
    os:unsetenv(?VAR),
    ok.

%% =============================================================================
%% TESTS
%% =============================================================================

-doc """
With nothing configured the application starts and supervises nothing.

Configuring email is an operator's choice. A node that has not made it must
still boot, so this is the default state of every stock installation.
""".
dormant_without_relays(_Config) ->
    ok = start([]),

    ?assertEqual(false, bondy_mail:is_configured()),
    ?assertEqual([], bondy_mail:relay_names()),
    ?assertEqual([], bondy_mail:relays()),
    ?assertEqual({error, no_such_relay}, bondy_mail_config:default_relay()),

    %% The tree is up but empty, and no relay supervisor was started.
    ?assert(is_pid(whereis(bondy_mail_sup))),
    ?assertEqual([], supervisor:which_children(bondy_mail_sup)),
    ?assertEqual(undefined, whereis(bondy_mail_relay_sup)).

-doc """
A relay declaring only a host gets the documented defaults.

The two that matter for security are asserted explicitly: STARTTLS rather than
plain, and certificate verification on.
""".
relay_defaults_are_applied(_Config) ->
    ok = start([#{name => ~"r1", host => ~"smtp.example.com"}]),

    {ok, Relay} = bondy_mail_config:relay(~"r1"),

    ?assertEqual(587, Relay#bondy_mail_relay.port),
    ?assertEqual(starttls, Relay#bondy_mail_relay.transport),
    ?assertEqual(verify_peer, Relay#bondy_mail_relay.tls_verify),
    ?assertEqual(if_available, Relay#bondy_mail_relay.auth),
    ?assertEqual(undefined, Relay#bondy_mail_relay.secret),

    %% Both authority fields default closed: no realm may use it except the
    %% master realm, and no caller may choose a sender.
    ?assertEqual([], Relay#bondy_mail_relay.realms),
    ?assertEqual([], Relay#bondy_mail_relay.allowed_from).

-doc """
`*` for realms or senders survives validation as `any`.

That is the shape cuttlefish produces for `mail.relay.$name.realms = *`. A
plain `{list, binary}` datatype rejects it, which would disable the relay
rather than open it -- safe, but silently the opposite of what was asked for.
Found by running the schema through cuttlefish rather than by reading it.
""".
wildcard_realms_and_senders_are_accepted(_Config) ->
    ok = start([
        #{
            name => ~"open",
            host => ~"smtp.internal",
            realms => any,
            allowed_from => any
        }
    ]),

    {ok, Relay} = bondy_mail_config:relay(~"open"),
    ?assertEqual(any, Relay#bondy_mail_relay.realms),
    ?assertEqual(any, Relay#bondy_mail_relay.allowed_from).

-doc """
A default relay set as a string resolves the same as a binary.

The schema normalises this, but `sys.config` bypasses the schema, and the
failure mode otherwise looks like a missing relay rather than a type mismatch.
""".
default_relay_accepts_a_string(_Config) ->
    ok = application:set_env(bondy_mail, default_relay, "b"),
    ok = start([
        #{name => ~"a", host => ~"a.example.com"},
        #{name => ~"b", host => ~"b.example.com"}
    ]),
    ?assertEqual({ok, ~"b"}, bondy_mail_config:default_relay()).

-doc "With exactly one relay declared, it is the default without saying so.".
single_relay_is_the_default(_Config) ->
    ok = start([#{name => ~"only", host => ~"smtp.example.com"}]),
    ?assertEqual({ok, ~"only"}, bondy_mail_config:default_relay()).

-doc """
With several relays and no default, a caller must name one.

Picking one arbitrarily would mean mail silently leaving through a relay the
operator did not intend.
""".
several_relays_need_an_explicit_default(_Config) ->
    ok = start([
        #{name => ~"a", host => ~"a.example.com"},
        #{name => ~"b", host => ~"b.example.com"}
    ]),
    ?assertEqual({error, no_such_relay}, bondy_mail_config:default_relay()).

-doc "`mail.default_relay` selects among several relays.".
explicit_default_relay_is_used(_Config) ->
    ok = application:set_env(bondy_mail, default_relay, ~"b"),
    ok = start([
        #{name => ~"a", host => ~"a.example.com"},
        #{name => ~"b", host => ~"b.example.com"}
    ]),
    ?assertEqual({ok, ~"b"}, bondy_mail_config:default_relay()).

-doc """
A default naming a relay that does not exist is reported, not invented.

This is the shape of a typo, and it must not resolve to some other relay.
""".
unknown_default_relay_is_reported(_Config) ->
    ok = application:set_env(bondy_mail, default_relay, ~"absent"),
    ok = start([#{name => ~"a", host => ~"a.example.com"}]),
    ?assertEqual({error, no_such_relay}, bondy_mail_config:default_relay()).

-doc """
One malformed relay disables that relay only.

A declaration with no host cannot be used, but it must not stop the node or the
relays declared alongside it.
""".
invalid_relay_is_dropped_and_others_survive(_Config) ->
    ok = start([
        #{name => ~"good", host => ~"good.example.com"},
        #{name => ~"bad"}
    ]),

    ?assertEqual([~"good"], bondy_mail:relay_names()),
    ?assertMatch({ok, _}, bondy_mail_config:relay(~"good")),
    ?assertEqual({error, no_such_relay}, bondy_mail_config:relay(~"bad")).

-doc """
A relay whose credential cannot be resolved is disabled, not started anyway.

Starting it would mean attempting delivery unauthenticated. Failing closed is
visible: the relay is absent from `relay_names/0`, and the reason was logged.
""".
unresolvable_secret_disables_the_relay(_Config) ->
    %% The variable is deliberately not set.
    ok = start([
        #{
            name => ~"needs_secret",
            host => ~"smtp.example.com",
            secret => #{provider => env, var => list_to_binary(?VAR)}
        },
        #{name => ~"no_secret", host => ~"other.example.com"}
    ]),

    ?assertEqual([~"no_secret"], bondy_mail:relay_names()).

-doc """
The `env` provider resolves a credential from the environment.

This is the counterpart to `unresolvable_secret_disables_the_relay`. Without
it, that case would pass just as well if the reference shape were wrong and the
resolver were rejecting it outright -- the relay would be disabled either way,
for entirely different reasons.
""".
env_secret_is_resolved(_Config) ->
    true = os:putenv(?VAR, "from-the-environment"),

    ok = start([
        #{
            name => ~"needs_secret",
            host => ~"smtp.example.com",
            secret => #{provider => env, var => list_to_binary(?VAR)}
        }
    ]),

    ?assertEqual([~"needs_secret"], bondy_mail:relay_names()),

    {ok, Relay} = bondy_mail_config:relay(~"needs_secret"),
    ?assertEqual(
        ~"from-the-environment",
        bondy_mail_secret:expose(Relay#bondy_mail_relay.secret)
    ).

-doc """
A literal credential is accepted, and reaches the relay.

Supported so a development setup needs no environment variable. It warns at
every boot naming the relay; forbidding it outright would just relocate the
secret to a variable called `changeme`.
""".
literal_secret_is_resolved(_Config) ->
    ok = start([
        #{
            name => ~"literal",
            host => ~"smtp.example.com",
            secret => #{provider => none, value => ~"hunter2"}
        }
    ]),

    {ok, Relay} = bondy_mail_config:relay(~"literal"),
    Secret = Relay#bondy_mail_relay.secret,
    ?assert(bondy_mail_secret:is_type(Secret)),
    ?assertEqual(~"hunter2", bondy_mail_secret:expose(Secret)).

-doc """
Formatting a credential does not reveal it.

This is the point of the wrapper: leaking a secret should take a deliberate
`expose/1`, not a stray `~p` in a log map or an error payload. The relay record
is formatted whole here, the way a crash report would format it.
""".
secret_does_not_appear_when_formatted(_Config) ->
    ok = start([
        #{
            name => ~"literal",
            host => ~"smtp.example.com",
            secret => #{provider => none, value => ~"hunter2"}
        }
    ]),

    {ok, Relay} = bondy_mail_config:relay(~"literal"),

    Formatted = lists:flatten(io_lib:format("~p", [Relay])),
    ?assertEqual(nomatch, string:find(Formatted, "hunter2")),

    %% And the same for the secret on its own.
    Secret = Relay#bondy_mail_relay.secret,
    Alone = lists:flatten(io_lib:format("~p", [Secret])),
    ?assertEqual(nomatch, string:find(Alone, "hunter2")).

-doc """
What a caller can be told about a relay excludes everything sensitive.

`bondy.mail.relay.list` is built from this, so the assertion is on the exact
key set rather than on the absence of any particular key.
""".
relay_info_carries_nothing_sensitive(_Config) ->
    ok = start([
        #{
            name => ~"r1",
            host => ~"smtp.internal.example.com",
            username => ~"apikey",
            from => ~"no-reply@example.com",
            secret => #{provider => none, value => ~"hunter2"}
        }
    ]),

    [Info] = bondy_mail:relays(),
    ?assertEqual(
        lists:sort([name, transport, status, from]),
        lists:sort(maps:keys(Info))
    ),
    ?assertEqual(~"r1", maps:get(name, Info)),

    Formatted = lists:flatten(io_lib:format("~p", [Info])),
    ?assertEqual(nomatch, string:find(Formatted, "hunter2")),
    ?assertEqual(nomatch, string:find(Formatted, "apikey")),
    ?assertEqual(nomatch, string:find(Formatted, "smtp.internal.example.com")).

-doc """
Stopping and starting the application parses the declaration again.

The validated relays are held under their own key precisely so that this works:
writing them back over the raw declaration would leave a map where cuttlefish
had put a list, and the second start would find no relays at all.
""".
restarting_reparses_the_declaration(_Config) ->
    Relays = [#{name => ~"r1", host => ~"smtp.example.com"}],

    ok = start(Relays),
    ?assertEqual([~"r1"], bondy_mail:relay_names()),

    ok = application:stop(bondy_mail),
    {ok, _} = application:ensure_all_started(bondy_mail),

    ?assertEqual([~"r1"], bondy_mail:relay_names()),
    ?assertEqual(true, bondy_mail:is_configured()).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
start(Relays) ->
    ok = application:set_env(bondy_mail, relays, Relays),
    {ok, _} = application:ensure_all_started(bondy_mail),
    ok.
