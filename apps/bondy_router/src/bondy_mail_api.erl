%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mail_api).

-moduledoc """
The `bondy.mail.*` WAMP API.

A thin surface over `bondy_mail`. Nothing here decides whether a message may be
sent, which relay it may use or what sender it may claim -- those live one layer
down, in the only module the broker bridge also passes through, so that the two
surfaces cannot drift apart on what is allowed.

This module lives in `bondy_router` rather than in `bondy_mail` because it has
to: the `bondy.*` dispatcher is a fixed prefix chain inside `bondy_wamp_api`
and the URIs are macros in `bondy_uris.hrl`, so an application cannot register
a `bondy.*` namespace from outside.

## The realm is not an argument

Every procedure takes the calling realm as argument 0, and
`bondy_wamp_api_utils` supplies it from the session when it is absent. Supplying
one that is not the session's realm is refused -- unless the session is in the
master realm, which is how an operator acts on another realm, and which comes
from that shared helper rather than from anything here.

So a caller cannot send on behalf of another realm, because there is nowhere to
say so.

## Authorization

Three checks, none of them new.

1. **May this session call this URI?** The dealer already ran
   `bondy_rbac:authorize(<<"wamp.call">>, Uri, Ctxt)` with the URI as the
   resource before this module was reached, so `bondy.mail.send` is grantable
   per realm and per group today, with prototype inheritance, and needs no
   permission of its own.
2. **May the realm use this relay?** `mail.relay.$name.realms`, enforced in
   `bondy_mail`.
3. **May it claim this sender?** `mail.relay.$name.allowed_from`, enforced in
   `bondy_mail`.

Checks 2 and 3 are deliberately not here. Putting them here would leave the
bridge unguarded.

## Positional arguments, not keyword arguments

The request is `Args[1]`, after the realm. It cannot also be accepted as
`KWArgs`: `bondy_wamp_api_utils` reads `Args[0]` as the realm whenever one is
present, so a shape that admits both makes a caller's first positional argument
mean two different things depending on how many they sent.
""".

-behaviour(bondy_wamp_api).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_uris.hrl").

%% Attribution only: it reaches telemetry and nothing else. Neither surface is
%% granted anything the other is not.
-define(OPTS, #{surface => rpc}).

-export([handle_call/3]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Handle a `bondy.mail.*` call.

| Procedure | Arguments | Answers |
| --- | --- | --- |
| `bondy.mail.send` | `[Request]` | `#{id, status, receipt, attempts}` once the relay has accepted the message |
| `bondy.mail.send_async` | `[Request]` | `#{id, status}` once the message is queued -- see `bondy_mail:send_async/2` for what that does *not* promise |
| `bondy.mail.status.get` | `[Id]` | What is known about a message, or `#{status := unknown}` |
| `bondy.mail.relay.list` | `[]` | The relays this realm may use, filtered rather than annotated |
| `bondy.mail.test` | `[Address]` | Master realm only: sends a fixed message to prove a relay works |

Each also accepts the realm as argument 0; it is supplied from the session when
absent and refused when it is not the session's realm. Every failure is
translated by `bondy_mail:to_error/1`, the same function the broker bridge
uses.
""".
-spec handle_call(
    Proc :: uri(), M :: bondy_wamp_message:call(), Ctxt :: bondy_context:t()
) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined
    )}
    | {reply, wamp_result() | wamp_error()}.

handle_call(?BONDY_MAIL_SEND, #call{} = M, Ctxt) ->
    [RealmUri, Request] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    reply(bondy_mail:send(RealmUri, Request, ?OPTS), M);
handle_call(?BONDY_MAIL_SEND_ASYNC, #call{} = M, Ctxt) ->
    [RealmUri, Request] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    reply(bondy_mail:send_async(RealmUri, Request, ?OPTS), M);
handle_call(?BONDY_MAIL_STATUS_GET, #call{} = M, Ctxt) ->
    [RealmUri, Id] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    case is_binary(Id) of
        true ->
            reply(bondy_mail:status(RealmUri, Id), M);
        false ->
            reply({error, {invalid_request, {message_id, Id}}}, M)
    end;
handle_call(?BONDY_MAIL_RELAY_LIST, #call{} = M, Ctxt) ->
    [RealmUri] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 1),
    case bondy_mail:is_configured() of
        true ->
            reply({ok, bondy_mail:relays(RealmUri)}, M);
        false ->
            reply({error, not_configured}, M)
    end;
handle_call(?BONDY_MAIL_TEST, #call{} = M, Ctxt) ->
    %% Master realm only, from the shared helper. A test send is an operator's
    %% check that a relay works, and it names a recipient without any of the
    %% authority a realm's own traffic goes through.
    [RealmUri, Address] = bondy_wamp_api_utils:validate_admin_call_args(
        M, Ctxt, 2
    ),
    reply(
        bondy_mail:send(RealmUri, test_request(Address, kwargs(M)), ?OPTS), M
    );
handle_call(_, #call{} = M, _) ->
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Every failure goes through `bondy_mail:to_error/1`, which is also what the
%% broker bridge uses. Translating here as well is how the two surfaces would
%% come to report different URIs for the same cause.
reply({ok, Result}, M) ->
    {reply, bondy_wamp_message:result(M#call.request_id, #{}, [Result])};
reply({error, Reason}, M) ->
    Error = bondy_mail:to_error(Reason),
    {reply, bondy_wamp_api_utils:error(Error, M)}.

%% @private
kwargs(#call{kwargs = undefined}) -> #{};
kwargs(#call{kwargs = KWArgs}) when is_map(KWArgs) -> KWArgs;
kwargs(#call{}) -> #{}.

%% @private
%% Deliberately plain. A test message exists to prove the path works, and one
%% that failed because of its own content would be a worse test than no test.
test_request(Address, KWArgs) ->
    Base = #{
        ~"to" => [Address],
        ~"subject" => ~"Bondy mail relay test",
        ~"text" =>
            <<
                "This is a test message sent by bondy.mail.test. "
                "Receiving it means the relay accepted a message from this "
                "node."
            >>
    },
    case maps:get(~"relay", KWArgs, maps:get(relay, KWArgs, undefined)) of
        Name when is_binary(Name) -> Base#{~"relay" => Name};
        _ -> Base
    end.
