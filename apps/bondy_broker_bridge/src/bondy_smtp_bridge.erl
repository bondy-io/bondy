%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_smtp_bridge).

-moduledoc """
Bridge implementation that sends email through `bondy_mail`.

Thin by construction: a `mops`-expanded action becomes a send request and is
handed to `bondy_mail:send_async/3`. No transport, no MIME, no retry, no
authority logic -- all of that lives one layer down, in the module the
`bondy.mail.*` API also passes through, so the two surfaces cannot drift apart
on what is allowed.

## Why `send_async/2` and not `send/2`

`apply_action/1` runs inside the subscriber process that is delivering the
event. Waiting there for an SMTP conversation would put a relay's latency onto
the router's event path, and a stalled relay would stall event delivery -- which
is the coupling this whole design exists to avoid. So the message is queued and
the subscriber returns.

The consequence is that this callback reports whether the message was
*accepted*, never whether it was delivered. A delivery failure is a dead letter:
it is logged and counted, and the event is not redelivered. A queue that is full
is different -- nothing was accepted, so that is reported as `{retry, _}` and
the subscriber tries the event again.

## Relays are named, never described

An action names a relay; it cannot describe one. Hosts, credentials and TLS
settings live in `bondy.conf` under `mail.relay.$name.*`, which a bridge
specification cannot reach. `init/1` publishes the configured relay names into
the `mops` context, so a specification can write `{{mail.default_relay}}` rather
than repeating a name.

## The realm

The action carries the calling realm, and a specification should take it from
the event: `"realm": "{{event.realm}}"` is the subscription's own realm.

This callback cannot verify it. `apply_action/1` receives only the action, so
the bridge has no way to see which subscription produced it, and making the
realm authoritative would mean widening the `bondy_broker_bridge` behaviour that
four other bridges implement.

What bounds it instead is who writes specifications. They are loaded from
operator-owned configuration -- there is no WAMP procedure that creates one --
and `bondy_mail` still enforces `mail.relay.$name.realms` for whatever realm is
named. So an operator naming a realm here can reach exactly the relays they have
already granted that realm, which is the same decision they made in
`bondy.conf`.

## Action specification

| Key | Required | Notes |
|-----|----------|-------|
| `realm` | yes | The calling realm. Use `{{event.realm}}`. |
| `relay` | no | Relay name. Defaults to `mail.default_relay`. |
| `to` | yes | Address or list of addresses. |
| `cc`, `bcc` | no | Address or list of addresses. |
| `from` | no | Defaults to the relay's sender; must be inside `allowed_from`. |
| `reply_to` | no | |
| `subject` | yes | |
| `text`, `html` | one of | At least one is required. |
| `headers` | no | Map. Envelope and security headers are refused. |
| `attachments` | no | List of `#{filename, content_type, data}`. |
| `id` | no | Idempotency key. |
| `options` | no | Reserved. Accepted and ignored. |

A `mops` expression referring to a key the event does not have raises
`{badkeypath, _}`, which fails the action. A half-rendered email is never sent.
""".

-behaviour(bondy_broker_bridge).

-include_lib("kernel/include/logger.hrl").

%% Validation proper belongs to `bondy_mail_request:new/2`, which both surfaces
%% share. This checks only what has to be right before the action is worth
%% passing on: that a realm is present and is a URI. Duplicating the rest here
%% is how the bridge and the API would come to disagree about what is valid.
-define(ACTION_SPEC, #{
    ~"realm" => #{
        alias => realm,
        key => ~"realm",
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => binary
    }
}).

%% Everything the request contract knows about. Anything else in an action is
%% rejected here rather than silently dropped, so a misspelled `subjekt` is a
%% failed action and not an email with no subject.
-define(KNOWN_KEYS, [
    ~"attachments",
    ~"bcc",
    ~"cc",
    ~"from",
    ~"headers",
    ~"html",
    ~"id",
    ~"options",
    ~"realm",
    ~"relay",
    ~"reply_to",
    ~"subject",
    ~"text",
    ~"timeout",
    ~"to"
]).

%% Not part of a send request: `realm` is the first argument and `options` is
%% reserved for the bridge itself.
-define(NON_REQUEST_KEYS, [~"realm", ~"options"]).

%% Attribution only: it reaches telemetry and nothing else. Neither surface is
%% granted anything the other is not.
-define(OPTS, #{surface => bridge}).

%% BONDY_BROKER_BRIDGE CALLBACKS
-export([apply_action/1]).
-export([init/1]).
-export([terminate/1]).
-export([terminate/2]).
-export([validate_action/1]).

%% =============================================================================
%% BONDY_BROKER_BRIDGE CALLBACKS
%% =============================================================================

-doc """
Publish the configured relay names into the `mops` context.

Answers `{ok, #{~"mail" => #{~"relays" => [Name], ~"default_relay" => Name}}}`,
so a specification can name a relay without repeating a string that also lives
in `bondy.conf`.

Starting with no relay configured is not an error. `bondy_mail` is dormant until
an operator declares one, and a bridge that refused to start would turn a
deliberate choice into a boot failure. It does warn, because a bridge that is
enabled and cannot send is worth saying out loud.
""".
init(Config) ->
    _ = warn_if_dormant(Config),
    {ok, #{
        ~"mail" => #{
            ~"relays" => bondy_mail:relay_names(),
            ~"default_relay" => bondy_mail:default_relay()
        }
    }}.

-doc """
Check the action before it is worth passing on.

Unknown keys are named rather than dropped. Everything else is checked by
`bondy_mail_request:new/2` when the message is built, which is the same
validation the `bondy.mail.*` API goes through.
""".
validate_action(Action0) when is_map(Action0) ->
    case unknown_keys(Action0) of
        [] ->
            try maps_utils:validate(Action0, ?ACTION_SPEC) of
                _ -> {ok, Action0}
            catch
                _:Reason -> {error, Reason}
            end;
        Unknown ->
            {error, {unknown_keys, Unknown}}
    end;
validate_action(Action) ->
    {error, {invalid_action, Action}}.

-doc """
Queue the message.

`ok` once it has been accepted, `{retry, Reason}` when nothing was accepted and
trying the event again could work, and `{error, Reason}` when it could not.

The distinction is `bondy_mail`'s own `transient`/`permanent` classification, so
a refused recipient is not retried and a full queue is.
""".
apply_action(Action) when is_map(Action) ->
    RealmUri = maps:get(~"realm", Action),
    Request = maps:without(?NON_REQUEST_KEYS, Action),

    case bondy_mail:send_async(RealmUri, Request, ?OPTS) of
        {ok, #{id := Id}} ->
            ?LOG_DEBUG(#{
                description => "Queued mail from broker bridge",
                message_id => Id,
                realm_uri => RealmUri
            }),
            ok;
        {error, {transient, _, _} = Reason} ->
            ok = log_failure(warning, RealmUri, Action, Reason),
            {retry, Reason};
        {error, Reason} ->
            ok = log_failure(error, RealmUri, Action, Reason),
            {error, Reason}
    end.

-doc """
Nothing to tear down.

The bridge owns no connection: relays, their pools and their queues belong to
`bondy_mail`, which outlives any one bridge and is stopped with the node.
""".
terminate(_Reason, _State) ->
    ok.

-doc """
Arity-1 form, kept for a manager that has not been updated.

`bondy_broker_bridge` declares `terminate/2`; the manager called `terminate/1`
for a long time, which meant `undef` at every shutdown. Both are exported until
no caller is left.
""".
terminate(_Reason) ->
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
unknown_keys(Action) ->
    lists:sort(maps:keys(maps:without(?KNOWN_KEYS, Action))).

%% @private
warn_if_dormant(Config) ->
    case bondy_mail:is_configured() of
        true ->
            ok;
        false ->
            ?LOG_WARNING(#{
                description =>
                    "The SMTP broker bridge is enabled but no mail relay is "
                    "configured, so every action will fail. Declare a "
                    "mail.relay.$name.* in bondy.conf.",
                config => key_value:get(enabled, Config, false)
            }),
            ok
    end.

%% @private
%% Never the body, never the recipients. The topic and the realm are what an
%% operator needs to find the subscription that produced this.
log_failure(Level, RealmUri, Action, Reason) ->
    ?LOG(Level, #{
        description => "Could not queue mail from broker bridge",
        realm_uri => RealmUri,
        relay => maps:get(~"relay", Action, default),
        error_class => class(Reason)
    }),
    ok.

%% @private
class({_Nature, Class, _}) -> Class;
class(Reason) when is_atom(Reason) -> Reason;
class({Class, _}) when is_atom(Class) -> Class;
class(_) -> unknown.
