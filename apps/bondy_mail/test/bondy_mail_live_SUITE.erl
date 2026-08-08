%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_live_SUITE).

-moduledoc """
The send path against a real relay. Optional, and never a build dependency.

`bondy_mail_mailpit_SUITE` covers everything a cooperative server can be made
to do. Three things it cannot cover, because they are properties of the wider
world rather than of a container:

- **A public certificate chain.** Mailpit's certificate is one the compose
  stack generated and the suite then trusts. Verifying against the operating
  system's trust store is a different mechanism, and the one production uses.
- **A provider's own `EHLO`.** Which AUTH mechanisms are offered, in what
  order, and over what transport is a decision each provider makes
  differently. Mailpit offers what it was told to.
- **Whether `verify_peer` is load-bearing at all.** Against a real chain, a
  deliberate hostname mismatch has to fail. If it does not, verification is
  decorative -- and every passing case in every other suite would look the
  same.

## Running it

Put the relay's details in `.env` at the repository root -- the same file
`make node1` reads, already ignored by git (`.gitignore:43`):

    BONDY_TEST_SMTP_HOST=smtp.example.com
    BONDY_TEST_SMTP_PORT=587
    BONDY_TEST_SMTP_TRANSPORT=starttls
    BONDY_TEST_SMTP_USERNAME=apikey
    BONDY_TEST_SMTP_PASSWORD=...
    BONDY_TEST_SMTP_FROM=no-reply@example.com
    BONDY_TEST_SMTP_TO=you@example.com

Without them the suite skips. A missing `.env` is a skip and never a failure,
which is what keeps this out of the build.

**This sends real email** to `BONDY_TEST_SMTP_TO`, from a relay whose quota is
somebody's. That is why nothing here runs unless an address was supplied on
purpose.

## The password is not read directly

It is declared as `#{provider => env, var => ...}` and resolved through
`bondy_secret_resolver`, which is the path a production node uses for
`mail.relay.$name.password.provider = env`. Reading the variable here with
`os:getenv/1` would test one line less and be one line shorter.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_mail/include/bondy_mail.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, ~"com.example.app").
-define(PASSWORD_VAR, ~"BONDY_TEST_SMTP_PASSWORD").

suite() ->
    [{timetrap, {minutes, 3}}].

all() ->
    [
        message_is_accepted_by_a_real_relay,
        credentials_resolve_through_the_env_provider,
        verify_peer_refuses_a_hostname_mismatch
    ].

init_per_suite(Config) ->
    _ = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(gproc),
    {ok, _} = application:ensure_all_started(jobs),
    {ok, _} = application:ensure_all_started(bondy_regulator),

    ok = load_dotenv(),

    case relay_config() of
        {ok, Relay} ->
            ok = restart(Relay),
            [{relay, Relay} | Config];
        {error, Missing} ->
            {skip, skip_reason(Missing)}
    end.

end_per_suite(_Config) ->
    _ = application:stop(bondy_mail),
    ok.

%% =============================================================================
%% CASES
%% =============================================================================

-doc """
A real relay accepts a message, over TLS it verified against the public trust
store.

`tls_cacertfile` is deliberately unset, so verification runs against
`public_key:cacerts_get/0` -- the operating system's store, which is the
mechanism every relay that is not a test fixture is checked with.
""".
message_is_accepted_by_a_real_relay(_Config) ->
    Result = bondy_mail:send(?REALM, request(~"live")),
    ?assertMatch({ok, #{status := sent}}, Result).

-doc """
The credential came from the environment through the resolver.

Asserted rather than assumed: `init_per_suite` declared the password as an
`env` reference, so a successful authenticated send is evidence that
`bondy_secret_resolver` resolved it. A relay whose credential failed to resolve
is dropped at startup rather than started unauthenticated, so its absence from
the relay list would be the symptom.
""".
credentials_resolve_through_the_env_provider(Config) ->
    Name = maps:get(name, ?config(relay, Config)),

    case authenticated(Config) of
        false ->
            {skip,
                "No BONDY_TEST_SMTP_USERNAME: the relay does not authenticate"};
        true ->
            %% Present at all, which is the fail-closed contract: an
            %% unresolvable credential drops the relay.
            ?assert(lists:member(Name, bondy_mail:relay_names())),
            ?assertMatch({ok, _}, bondy_mail_config:relay(Name)),

            %% And it authenticates, which is what makes the resolved value the
            %% right one rather than merely a value.
            Result = bondy_mail:send(?REALM, request(~"live auth")),
            ?assertMatch({ok, #{status := sent}}, Result)
    end.

-doc """
`verify_peer` refuses a certificate that is valid for a name we did not ask
for.

The relay is addressed by its IP address, so the connection reaches the same
server with a reference identity its certificate does not carry. Everything
else about the handshake is unchanged, which is what makes the hostname the
variable under test.

If this case ever passes a message through, hostname verification is not
happening and `tls.verify` means nothing -- so it fails loudly rather than
skipping. A relay that genuinely carries an IP address in its certificate would
fail here too; that is worth knowing, and worth looking at, rather than
silently tolerating.
""".
verify_peer_refuses_a_hostname_mismatch(Config) ->
    Relay = ?config(relay, Config),
    Host = binary_to_list(maps:get(host, Relay)),

    case inet:getaddr(Host, inet) of
        {ok, Address} ->
            Mismatched = Relay#{
                name => ~"mismatched",
                host => list_to_binary(inet:ntoa(Address))
            },
            ok = restart(Mismatched),

            Result = bondy_mail:send(?REALM, (request(~"live mismatch"))#{
                ~"relay" => ~"mismatched"
            }),
            ?assertEqual({error, {transient, deferred, tls_failed}}, Result);
        {error, Reason} ->
            ct:fail({could_not_resolve, Host, Reason})
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
request(Tag) ->
    #{
        ~"relay" => ~"live",
        ~"to" => [getenv(~"BONDY_TEST_SMTP_TO")],
        ~"subject" => <<"Bondy ", Tag/binary, " test">>,
        ~"text" => ~"Sent by bondy_mail_live_SUITE."
    }.

%% @private
restart(Relay) ->
    _ = application:stop(bondy_mail),
    ok = application:set_env(bondy_mail, relays, [Relay]),
    ok = application:set_env(bondy_mail, default_relay, undefined),
    {ok, _} = application:ensure_all_started(bondy_mail),
    ok.

%% @private
%% The relay under test, or the names of the variables that were missing.
relay_config() ->
    Required = [
        ~"BONDY_TEST_SMTP_HOST",
        ~"BONDY_TEST_SMTP_FROM",
        ~"BONDY_TEST_SMTP_TO"
    ],
    case [V || V <- Required, getenv(V) == undefined] of
        [] ->
            {ok, relay()};
        Missing ->
            {error, Missing}
    end.

%% @private
relay() ->
    Base = #{
        name => ~"live",
        host => getenv(~"BONDY_TEST_SMTP_HOST"),
        port => getenv_int(~"BONDY_TEST_SMTP_PORT", 587),
        transport => getenv_atom(
            ~"BONDY_TEST_SMTP_TRANSPORT", starttls, [plain, starttls, tls]
        ),
        from => getenv(~"BONDY_TEST_SMTP_FROM"),
        realms => any,
        %% Against the operating system trust store: no `tls_cacertfile`, which
        %% is the whole point of this suite.
        tls_verify => verify_peer,
        %% A real relay may greylist, and one deferral should not be reported
        %% as a failure of the transport.
        retry_max_attempts => 2,
        retry_backoff_min => 2000,
        retry_backoff_max => 10000,
        timeout => 30000
    },
    case getenv(~"BONDY_TEST_SMTP_USERNAME") of
        undefined ->
            Base#{auth => never};
        Username ->
            Base#{
                auth => always,
                username => Username,
                %% Through the resolver, not through os:getenv/1. See the
                %% module documentation.
                secret => #{provider => env, var => ?PASSWORD_VAR}
            }
    end.

%% @private
authenticated(Config) ->
    maps:get(auth, ?config(relay, Config)) =/= never.

%% @private
skip_reason(Missing) ->
    lists:flatten(
        io_lib:format(
            "No live relay configured. Set ~s in .env at the repository "
            "root. See the bondy_mail_live_SUITE module documentation.",
            [lists:join(", ", [binary_to_list(V) || V <- Missing])]
        )
    ).

%% =============================================================================
%% PRIVATE -- ENVIRONMENT
%% =============================================================================

%% @private
%% Load `.env` into the environment, without overwriting anything already
%% there: a variable exported in the shell is the more specific statement of
%% intent, and CI has no `.env` at all.
load_dotenv() ->
    case dotenv() of
        {ok, Path} ->
            {ok, Bin} = file:read_file(Path),
            Lines = binary:split(Bin, [~"\n", ~"\r\n"], [global, trim_all]),
            ok = lists:foreach(fun put_line/1, Lines);
        error ->
            ok
    end.

%% @private
put_line(<<$#, _/binary>>) ->
    ok;
put_line(Line) ->
    case binary:split(string:trim(Line), ~"=") of
        [Name, Value] when byte_size(Name) > 0 ->
            put_var(binary_to_list(Name), unquote(string:trim(Value)));
        _ ->
            ok
    end.

%% @private
put_var(Name, Value) ->
    case os:getenv(Name) of
        false -> os:putenv(Name, binary_to_list(Value));
        _ -> ok
    end,
    ok.

%% @private
unquote(<<$", Rest/binary>>) when byte_size(Rest) > 0 ->
    case binary:last(Rest) of
        $" -> binary:part(Rest, 0, byte_size(Rest) - 1);
        _ -> <<$", Rest/binary>>
    end;
unquote(<<$', Rest/binary>>) when byte_size(Rest) > 0 ->
    case binary:last(Rest) of
        $' -> binary:part(Rest, 0, byte_size(Rest) - 1);
        _ -> <<$', Rest/binary>>
    end;
unquote(Value) ->
    Value.

%% @private
%% Walk up from the working directory: Common Test runs from a log directory
%% under `_build`, so `.env` is never in the current one.
dotenv() ->
    {ok, Cwd} = file:get_cwd(),
    dotenv(Cwd).

%% @private
dotenv(Dir) ->
    Path = filename:join(Dir, ".env"),
    case filelib:is_regular(Path) of
        true ->
            {ok, Path};
        false ->
            case filename:dirname(Dir) of
                Dir -> error;
                Parent -> dotenv(Parent)
            end
    end.

%% @private
getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> undefined;
        "" -> undefined;
        Value -> list_to_binary(Value)
    end.

%% @private
getenv_int(Name, Default) ->
    case getenv(Name) of
        undefined -> Default;
        Value -> binary_to_integer(Value)
    end.

%% @private
getenv_atom(Name, Default, Allowed) ->
    case getenv(Name) of
        undefined ->
            Default;
        Value ->
            Atom = binary_to_atom(Value, utf8),
            lists:member(Atom, Allowed) orelse
                error({badarg, {Name, Value}}),
            Atom
    end.
