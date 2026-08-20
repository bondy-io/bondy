%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_local).

-moduledoc """
**In-VM (local) WAMP transport** — and the dependency-inversion seam that keeps
`bondy_connect_sdk` standalone.

`bondy_connect_sdk` must compile and run on a *peer* node that does **not** bundle
the `bondy` router app. So this transport holds **no** reference to any `bondy`
module. Instead it defines a **handler behaviour** (the router-adapter contract)
and a process-wide **singleton registry**: the router app implements the
behaviour (`bondy_connect_local_handler` in `apps/bondy`) and registers it at
boot with `register_handler/1`. Every in-VM operation dispatches to that
registered handler.

```
bondy_connect_connection ──(bondy_connect_transport)──▶ bondy_connect_local
                                                              │  (dispatch)
                              register_handler/1             ▼
   bondy (router) ── -behaviour(bondy_connect_local) ──▶ <registered handler>
                                                              │
                                                              ▼  bondy_router, …
```

The dependency direction is one-way: **`bondy → bondy_connect_sdk`** (to implement
the behaviour and register). `bondy_connect_sdk` never names a `bondy` module.

## Availability

On a node with no registered handler (a peer that isn't a router), the local
transport is **unavailable**: `connect/2` returns `{error,
local_transport_unavailable}` — a clean, terminal, non-retriable failure (a
missing handler will not appear by retrying), never a crash. On a router node
the handler is registered by the router app at startup, so `transport => local`
works.

## Mailbox / handshake

Router replies (RESULT/ERROR/EVENT/INVOCATION/…) are delivered by the router
straight to the connection process's mailbox (the session ref targets it). The
handler owns that tag shape via the `handle_info/2` callback, so the router's
`{$bondy_request, …}` protocol detail never leaks into `bondy_connect_sdk`. There is
no transport handshake; the session is opened (and the `WELCOME` synthesized) by
the handler in `open/3`, and `send/2` self-delivers that `WELCOME` when the
connection's `HELLO` goes out — making the in-VM peer look exactly like a remote
one to the protocol FSM.

## Authentication

An in-VM peer is inside the trusted BEAM as the router, so the WAMP challenge
methods do not apply; the handler opens an **anonymous** session (realm
authorization still enforced). See `bondy_connect_local_handler`.
""".

-behaviour(bondy_connect_transport).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").

%% Our own internal self-delivery tag (the synthesized WELCOME, keepalive pong).
%% Router-originated messages are interpreted by the handler, so this transport
%% never needs to know the router's `{$bondy_request, …}` tag.
-define(LOCAL_MSG, '$bondy_connect_local_msg').
-define(PT_KEY, {?MODULE, handler}).
-define(LOCAL_PEER, {{127, 0, 0, 1}, 0}).

-record(state, {
    handler :: module(),
    session :: term(),
    welcome :: bondy_wamp_message:t()
}).

%% Handler registry / availability
-export([register_handler/1]).
-export([unregister_handler/0]).
-export([handler/0]).
-export([is_available/0]).

%% bondy_connect_transport callbacks
-export([connect/2]).
-export([handshake/2]).
-export([send/2]).
-export([ping/2]).
-export([pong/2]).
-export([recv/2]).
-export([handle_data/2]).
-export([handle_info/2]).
-export([setopts/2]).
-export([messages/0]).
-export([peername/1]).
-export([close/1]).

%% =============================================================================
%% HANDLER BEHAVIOUR — implemented by the router app (e.g. bondy)
%% =============================================================================

-doc """
Open an in-VM session for `RealmUri` with the client's `Roles`, returning an
opaque session handle and the `WELCOME` to hand back to the client. The handler
MUST run in (and target replies at) the calling process — the connection — so
router deliveries land in its mailbox.
""".
-callback open(RealmUri :: binary(), Roles :: map(), Opts :: map()) ->
    {ok, Session :: term(), Welcome :: bondy_wamp_message:t()}
    | {error, term()}.

-doc """
Forward an outbound WAMP record to the router. Replies normally arrive
asynchronously in the connection mailbox (see `handle_info/2`); a `{reply, M}`
is for the rare synchronous case.
""".
-callback forward(Msg :: bondy_wamp_message:t(), Session :: term()) ->
    ok | {reply, bondy_wamp_message:t()} | {error, term()}.

-doc """
Interpret a process `info` message delivered by the router to the connection
mailbox, returning the inbound WAMP records it carries (or `ignore`). This is
where the router's mailbox-tag shape is owned, keeping it out of
`bondy_connect_sdk`.
""".
-callback handle_info(Info :: term(), Session :: term()) ->
    {ok, [bondy_wamp_message:t()]} | ignore.

-doc "Close the in-VM session (tearing down its registrations/subscriptions).".
-callback close(Session :: term()) -> ok.

%% =============================================================================
%% HANDLER REGISTRY
%% =============================================================================

-doc """
Register the singleton router-adapter handler (called by the router app at
boot). The handler module must implement the callbacks above.
""".
-spec register_handler(module()) -> ok.
register_handler(Mod) when is_atom(Mod) ->
    persistent_term:put(?PT_KEY, Mod),
    ok.

-doc "Remove the registered handler (the local transport becomes unavailable).".
-spec unregister_handler() -> ok.
unregister_handler() ->
    _ = persistent_term:erase(?PT_KEY),
    ok.

-doc "The registered handler module, or `undefined` if none.".
-spec handler() -> module() | undefined.
handler() ->
    persistent_term:get(?PT_KEY, undefined).

-doc "Whether the in-VM transport is available on this node.".
-spec is_available() -> boolean().
is_available() ->
    handler() =/= undefined.

%% =============================================================================
%% bondy_connect_transport CALLBACKS
%% =============================================================================

-spec connect(bondy_connect_transport:endpoint() | local | undefined, map()) ->
    {ok, #state{}} | {error, term()}.

connect(Endpoint, Opts) when
    Endpoint == local; Endpoint == undefined; element(1, Endpoint) == router
->
    case handler() of
        undefined ->
            {error, local_transport_unavailable};
        Mod ->
            case maps:find(realm, Opts) of
                {ok, RealmUri} when is_binary(RealmUri) ->
                    open(Mod, RealmUri, Opts);
                _ ->
                    {error, missing_realm}
            end
    end;
connect(Endpoint, _Opts) ->
    {error, {unsupported_endpoint, Endpoint}}.

-spec handshake(bondy_connect_transport:subprotocol(), #state{}) ->
    {ok, bondy_connect_transport:subprotocol(), #state{}} | {error, term()}.

%% No transport handshake in-VM; the session is already open. We conform to the
%% behaviour's `subprotocol()' type with a value the connection discards.
handshake(_Sub, #state{} = St) ->
    {ok, {raw, binary, erl}, St}.

-spec send(bondy_wamp_message:t(), #state{}) -> ok | {error, term()}.

%% The connection's HELLO: the session is already open (connect/2), so answer
%% locally by delivering the synthesized WELCOME to the connection mailbox.
send(#hello{}, #state{welcome = Welcome} = St) ->
    deliver(Welcome, St);
%% A client GOODBYE/ABORT: nothing to forward — the session is closed in
%% `close/1' (which also tears down its registrations/subscriptions).
send(#goodbye{}, #state{}) ->
    ok;
send(#abort{}, #state{}) ->
    ok;
%% Any other WAMP record is forwarded to the router via the handler. Replies
%% arrive asynchronously in the connection mailbox (see handle_info/2).
send(Msg, #state{handler = Mod, session = Session} = St) ->
    case Mod:forward(Msg, Session) of
        ok ->
            ok;
        {reply, Reply} ->
            deliver(Reply, St);
        {error, _} = Error ->
            Error
    end.

-spec ping(binary(), #state{}) -> ok | {error, term()}.

%% In-VM keepalive is meaningless, but answer ourselves so the connection
%% tolerates ping being enabled (a missing pong would otherwise drop the link).
ping(Payload, #state{} = St) ->
    deliver({pong, Payload}, St).

-spec pong(binary(), #state{}) -> ok | {error, term()}.

pong(_Payload, #state{}) ->
    ok.

-spec recv(timeout(), #state{}) ->
    {ok, [bondy_connect_transport:inbound()], #state{}} | {error, term()}.

%% Synchronous read (for completeness/tests; the active flow uses handle_info/2).
recv(Timeout, #state{handler = Mod, session = Session} = St) ->
    receive
        {?LOCAL_MSG, M} ->
            {ok, [M], St};
        Info ->
            case Mod:handle_info(Info, Session) of
                {ok, Msgs} -> {ok, Msgs, St};
                ignore -> recv(Timeout, St)
            end
    after Timeout ->
        {error, timeout}
    end.

-spec handle_data(binary(), #state{}) ->
    {ok, [bondy_connect_transport:inbound()], #state{}}
    | {error, term(), #state{}}.

%% There is no byte stream in-VM; nothing to decode.
handle_data(_Data, #state{} = St) ->
    {ok, [], St}.

-spec handle_info(term(), #state{}) ->
    {ok, [bondy_connect_transport:inbound()], #state{}}
    | {error, term(), #state{}}
    | closed
    | ignore.

%% Our own self-delivered records (synthesized WELCOME, keepalive pong).
handle_info({?LOCAL_MSG, M}, #state{} = St) ->
    {ok, [M], St};
%% Anything else is interpreted by the handler (it owns the router's tag shape).
handle_info(Info, #state{handler = Mod, session = Session} = St) ->
    case Mod:handle_info(Info, Session) of
        {ok, Msgs} -> {ok, Msgs, St};
        ignore -> ignore
    end.

-spec setopts(list() | map(), #state{}) -> ok | {error, term()}.

%% No socket to configure; the active `{active, once}' cycle does not apply.
setopts(_Opts, #state{}) ->
    ok.

-spec messages() -> {atom(), atom(), atom()}.
messages() ->
    {?LOCAL_MSG, '$bondy_connect_local_closed', '$bondy_connect_local_error'}.

-spec peername(#state{}) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
peername(#state{}) ->
    {ok, ?LOCAL_PEER}.

-spec close(#state{}) -> ok.
close(#state{handler = undefined}) ->
    ok;
close(#state{handler = Mod, session = Session}) ->
    _ =
        try
            Mod:close(Session)
        catch
            _:_ -> ok
        end,
    ok.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
open(Mod, RealmUri, Opts) ->
    Roles = maps:get(roles, Opts, #{}),
    case Mod:open(RealmUri, Roles, Opts) of
        {ok, Session, Welcome} ->
            {ok, #state{handler = Mod, session = Session, welcome = Welcome}};
        {error, _} = Error ->
            Error
    end.

%% @private Self-deliver an inbound record to the connection mailbox so
%% handle_info/2 turns it into an inbound record (used for the synthesized
%% WELCOME, a synchronous router reply, and the keepalive pong).
deliver(Msg, #state{}) ->
    self() ! {?LOCAL_MSG, Msg},
    ok.
