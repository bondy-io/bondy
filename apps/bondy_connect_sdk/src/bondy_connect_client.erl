%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_client).

-moduledoc """
Public API for the `bondy_connect_sdk` WAMP client.

```erlang
{ok, Conn} = bondy_connect_client:connect(#{
    transport => tcp,
    endpoint  => {"127.0.0.1", 18082},
    realm     => <<"com.example.realm">>,
    auth      => #{method => <<"anonymous">>}
}),
{ok, Result} = bondy_connect_client:call(Conn, <<"bondy.session.self">>, []),
ok = bondy_connect_client:disconnect(Conn).
```

`connect/1,2` blocks until the WAMP session is established and returns an
**opaque** connection handle (`conn()`). Treat it as an abstract token — pass it
back to the API functions, do not inspect it. (Today it wraps the connection
process pid or, for a named connection, its name; keeping it opaque lets the
representation evolve — e.g. to a registry reference that survives a process
restart — without an API break.) A named connection (`connect/2`) can also be
referenced from elsewhere via `named/1`.

All four client roles — **caller**, **callee**, **publisher**, **subscriber** —
are supported over the raw TCP transport (M2). Handlers (`handler()`) run in
isolated, load-regulated worker processes; a crashing handler never affects the
connection.
""".

-opaque conn() :: {bondy_connect_client, pid() | atom()}.
-type handler() :: bondy_connect_handler_spec:handler().
-type call_result() :: #{args := list(), kwargs := map(), details := map()}.
-doc """
The named, structured client-side failures reachable from `call/*`,
`register/*`, `unregister/2`, `subscribe/*`, `unsubscribe/2` and
`publish_ack/*` — a local precondition check, a per-request timeout, a
connection drop, or a `gen_statem:call/3` exit (`term()` covers the last
case, plus any raw transport `send/2` failure, both open-ended by nature).
""".
-type call_client_reason() ::
    timeout
    | not_connected
    | disconnected
    | no_such_registration
    | no_such_subscription
    | {invalid_option, receive_progress}
    | {invalid_handler, term()}
    | term().
-doc """
A failed operation.

`kind => wamp` is an ERROR sent by the router. It is a `bondy_error:t()` - so
it also carries `message`, `nature`, `details` and the rest - extended with the
raw `args` and `kwargs` of the WAMP message. Prefer `uri` to identify it and
`nature` to decide whether retrying can help.

`kind => client` is a local failure, and carries the Erlang term as `reason`.
""".
-type call_error() ::
    #{
        kind := wamp,
        uri := binary(),
        args := list(),
        kwargs := map(),
        message := binary(),
        nature := bondy_error:nature(),
        _ => _
    }
    | #{kind := client, reason := call_client_reason()}.

-export_type([conn/0]).
-export_type([handler/0]).
-export_type([call_result/0]).
-export_type([call_client_reason/0]).
-export_type([call_error/0]).

%% How long `connect/1,2` waits for the session to *establish* after the manager
%% spawns the connection (handshake + auth, possibly across reconnects). Distinct
%% from the connection's per-attempt socket `?CONNECT_TIMEOUT` (5s).
-define(AWAIT_READY_TIMEOUT, 30000).

-export([connect/1]).
-export([connect/2]).
-export([named/1]).
-export([disconnect/1]).
-export([status/1]).
-export([call/2]).
-export([call/3]).
-export([call/4]).
-export([call/5]).
-export([call_async/3]).
-export([call_async/4]).
-export([call_async/5]).
-export([call_stream/5]).
-export([send_input/4]).
-export([finish_input/4]).
-export([cancel/2]).
-export([cancel/3]).
-export([register/3]).
-export([register/4]).
-export([unregister/2]).
-export([subscribe/3]).
-export([subscribe/4]).
-export([unsubscribe/2]).
-export([publish/3]).
-export([publish/4]).
-export([publish/5]).
-export([publish_ack/3]).
-export([publish_ack/4]).
-export([publish_ack/5]).

%% =============================================================================
%% API
%% =============================================================================

-doc "Open an (unnamed) connection and wait for the session to establish.".
-spec connect(Spec :: map()) -> {ok, conn()} | {error, term()}.
connect(Spec) ->
    connect(undefined, Spec).

-doc "Open a named connection and wait for the session to establish.".
-spec connect(Name :: atom() | undefined, Spec :: map()) ->
    {ok, conn()} | {error, term()}.
connect(Name, Spec) ->
    case bondy_connect_manager:connect(Name, Spec) of
        {ok, Pid} ->
            case
                bondy_connect_connection:await_ready(Pid, ?AWAIT_READY_TIMEOUT)
            of
                ok ->
                    {ok, {bondy_connect_client, Pid}};
                {error, Reason} ->
                    _ = bondy_connect_manager:disconnect(Pid),
                    {error, Reason}
            end;
        {error, _} = Error ->
            Error
    end.

-doc """
A handle for a previously **named** connection (the `Name` passed to
`connect/2`), so it can be referenced from a process that does not hold the
original handle. Resolution to a live connection happens lazily on each call.
""".
-spec named(atom()) -> conn().
named(Name) when is_atom(Name) ->
    {bondy_connect_client, Name}.

-doc "Close a connection.".
-spec disconnect(conn()) -> ok.
disconnect({bondy_connect_client, PidOrName}) ->
    bondy_connect_manager:disconnect(PidOrName).

-doc "The connection's status.".
-spec status(conn()) ->
    connecting | establishing | established | reconnecting | down.
status(Conn) ->
    case resolve(Conn) of
        undefined -> down;
        Pid -> bondy_connect_connection:status(Pid)
    end.

-doc "Call a procedure with no arguments.".
-spec call(conn(), binary()) -> {ok, call_result()} | {error, call_error()}.
call(Conn, Uri) ->
    call(Conn, Uri, [], #{}, #{}).

-doc "Call a procedure with positional arguments.".
-spec call(conn(), binary(), Args :: list()) ->
    {ok, call_result()} | {error, call_error()}.
call(Conn, Uri, Args) ->
    call(Conn, Uri, Args, #{}, #{}).

-doc "Call a procedure with positional + keyword arguments.".
-spec call(conn(), binary(), Args :: list(), KWArgs :: map()) ->
    {ok, call_result()} | {error, call_error()}.
call(Conn, Uri, Args, KWArgs) ->
    call(Conn, Uri, Args, KWArgs, #{}).

-doc """
Call a procedure. `Opts` may carry `timeout` (ms). Returns
`{ok, call_result()}` or `{error, call_error()}` — the latter discriminated
by `kind`: `#{kind := wamp, uri := binary(), ...}` for a router ERROR,
`#{kind := client, reason := term()}` for a local/transport failure.

`receive_progress` is rejected here — progressive call results require
`call_async/5`.
""".
-spec call(conn(), binary(), Args :: list(), KWArgs :: map(), Opts :: map()) ->
    {ok, call_result()} | {error, call_error()}.
call(Conn, Uri, Args, KWArgs, Opts) ->
    with_conn(Conn, fun(Pid) ->
        bondy_connect_connection:call(Pid, Uri, Args, KWArgs, Opts)
    end).

-doc "Asynchronous call with positional arguments. See `call_async/5`.".
-spec call_async(conn(), binary(), list()) ->
    {ok, reference()} | {error, call_error()}.
call_async(Conn, Uri, Args) ->
    call_async(Conn, Uri, Args, #{}, #{}).

-doc "Asynchronous call with positional + keyword arguments. See `call_async/5`.".
-spec call_async(conn(), binary(), list(), map()) ->
    {ok, reference()} | {error, call_error()}.
call_async(Conn, Uri, Args, KWArgs) ->
    call_async(Conn, Uri, Args, KWArgs, #{}).

-doc """
Issue a call without blocking. Returns `{ok, Token}`; the reply is later sent to
the calling process as
`{bondy_connect_client, Token, {ok, call_result()} | {error, call_error()}}`.

With `Opts` carrying `receive_progress => true` (and the router supporting
progressive call results) each progressive result arrives first as
`{bondy_connect_client, Token, {progress, Result}}`; the `{ok, _}`/`{error, _}`
delivery remains the single terminal message.
""".
-spec call_async(conn(), binary(), list(), map(), map()) ->
    {ok, reference()} | {error, call_error()}.
call_async(Conn, Uri, Args, KWArgs, Opts) ->
    with_conn(Conn, fun(Pid) ->
        bondy_connect_connection:call_async(Pid, Uri, Args, KWArgs, Opts)
    end).

-doc """
Begin a **progressive call** — stream the CALL arguments to the callee in chunks.
Sends the first CALL with `Options.progress = true` and returns `{ok, Token}`;
send further chunks with `send_input/4` and the last with `finish_input/4` (all
reuse the one request id). The reply is delivered as for `call_async/5`. Requires
the router and the callee to have announced the `progressive_calls` feature.
""".
-spec call_stream(conn(), binary(), list(), map(), map()) ->
    {ok, reference()} | {error, call_error()}.
call_stream(Conn, Uri, Args, KWArgs, Opts) ->
    with_conn(Conn, fun(Pid) ->
        bondy_connect_connection:call_stream(Pid, Uri, Args, KWArgs, Opts)
    end).

-doc "Send a non-final argument chunk of a progressive call. See `call_stream/5`.".
-spec send_input(conn(), reference(), list(), map()) -> ok | {error, term()}.
send_input(Conn, Token, Args, KWArgs) ->
    with_conn(Conn, fun(Pid) ->
        bondy_connect_connection:send_input(Pid, Token, Args, KWArgs)
    end).

-doc """
Send the final argument chunk of a progressive call, completing the input stream.
See `call_stream/5`.
""".
-spec finish_input(conn(), reference(), list(), map()) -> ok | {error, term()}.
finish_input(Conn, Token, Args, KWArgs) ->
    with_conn(Conn, fun(Pid) ->
        bondy_connect_connection:finish_input(Pid, Token, Args, KWArgs)
    end).

-doc "Cancel an in-flight async call (mode `killnowait`). See `cancel/3`.".
-spec cancel(conn(), reference()) -> ok | {error, term()}.
cancel(Conn, Token) ->
    cancel(Conn, Token, killnowait).

-doc """
Cancel an in-flight async call identified by the `Token` returned from
`call_async`. `Mode` is `skip` | `kill` | `killnowait`. The async caller still
receives a terminating `{bondy_connect_client, Token, {error, _}}` reply.
""".
-spec cancel(conn(), reference(), skip | kill | killnowait) ->
    ok | {error, term()}.
cancel(Conn, Token, Mode) ->
    with_conn(Conn, fun(Pid) ->
        bondy_connect_connection:cancel(Pid, Token, Mode)
    end).

-doc "Register a procedure. See `register/4`.".
-spec register(conn(), binary(), handler()) ->
    {ok, pos_integer()} | {error, call_error()}.
register(Conn, Uri, Handler) ->
    register(Conn, Uri, Handler, #{}).

-doc """
Register `Uri` as a procedure served by `Handler`. The handler runs in an
isolated worker on each invocation; see `m:bondy_connect_handler_spec` for the
contract. Returns `{ok, RegistrationId}`.
""".
-spec register(conn(), binary(), handler(), map()) ->
    {ok, pos_integer()} | {error, call_error()}.
register(Conn, Uri, Handler, Opts) ->
    with_conn(Conn, fun(Pid) ->
        bondy_connect_connection:register(Pid, Uri, Handler, Opts)
    end).

-doc "Unregister a procedure by its registration id or URI.".
-spec unregister(conn(), pos_integer() | binary()) ->
    ok | {error, call_error()}.
unregister(Conn, RegRef) ->
    with_conn(Conn, fun(Pid) ->
        bondy_connect_connection:unregister(Pid, RegRef)
    end).

-doc "Subscribe to a topic. See `subscribe/4`.".
-spec subscribe(conn(), binary(), handler()) ->
    {ok, pos_integer()} | {error, call_error()}.
subscribe(Conn, Topic, Handler) ->
    subscribe(Conn, Topic, Handler, #{}).

-doc """
Subscribe to `Topic`; `Handler` is invoked per event. Events are delivered
**FIFO per subscription** by default — pass `Opts` `#{ordered => false}` for
concurrent delivery. Returns `{ok, SubscriptionId}`.
""".
-spec subscribe(conn(), binary(), handler(), map()) ->
    {ok, pos_integer()} | {error, call_error()}.
subscribe(Conn, Topic, Handler, Opts) ->
    with_conn(Conn, fun(Pid) ->
        bondy_connect_connection:subscribe(Pid, Topic, Handler, Opts)
    end).

-doc "Unsubscribe from a topic by its subscription id or URI.".
-spec unsubscribe(conn(), pos_integer() | binary()) ->
    ok | {error, call_error()}.
unsubscribe(Conn, SubRef) ->
    with_conn(Conn, fun(Pid) ->
        bondy_connect_connection:unsubscribe(Pid, SubRef)
    end).

-doc "Fire-and-forget publish with positional arguments. See `publish/5`.".
-spec publish(conn(), binary(), list()) -> ok | {error, term()}.
publish(Conn, Topic, Args) ->
    publish(Conn, Topic, Args, #{}, #{}).

-doc "Fire-and-forget publish with positional + keyword arguments. See `publish/5`.".
-spec publish(conn(), binary(), list(), map()) -> ok | {error, term()}.
publish(Conn, Topic, Args, KWArgs) ->
    publish(Conn, Topic, Args, KWArgs, #{}).

-doc """
Publish to `Topic`, fire-and-forget (`ok` once the message is on the wire).
`Opts` may carry publisher options (`exclude`, `exclude_me`, `eligible`,
`disclose_me`, `retain`, ...) but **not** `acknowledge` — use
`publish_ack/3,4,5` for an acknowledged publish; an explicit
`acknowledge => true` here is rejected with `{error, badarg}` rather than
silently honoured (that would reintroduce the return-type ambiguity
`publish_ack/*` exists to remove).
""".
-spec publish(conn(), binary(), list(), map(), map()) -> ok | {error, term()}.
publish(_Conn, _Topic, _Args, _KWArgs, #{acknowledge := true}) ->
    {error, badarg};
publish(Conn, Topic, Args, KWArgs, Opts) ->
    with_conn(Conn, fun(Pid) ->
        bondy_connect_connection:publish(Pid, Topic, Args, KWArgs, Opts)
    end).

-doc "Acknowledged publish with positional arguments. See `publish_ack/5`.".
-spec publish_ack(conn(), binary(), list()) ->
    {ok, pos_integer()} | {error, call_error()}.
publish_ack(Conn, Topic, Args) ->
    publish_ack(Conn, Topic, Args, #{}, #{}).

-doc """
Acknowledged publish with positional + keyword arguments. See
`publish_ack/5`.
""".
-spec publish_ack(conn(), binary(), list(), map()) ->
    {ok, pos_integer()} | {error, call_error()}.
publish_ack(Conn, Topic, Args, KWArgs) ->
    publish_ack(Conn, Topic, Args, KWArgs, #{}).

-doc """
Publish to `Topic` and wait for the router's `PUBLISHED`, returning
`{ok, PublicationId}`. `Opts` may carry the same publisher options as
`publish/5`; `acknowledge` is forced to `true` regardless of what `Opts`
carries.
""".
-spec publish_ack(conn(), binary(), list(), map(), map()) ->
    {ok, pos_integer()} | {error, call_error()}.
publish_ack(Conn, Topic, Args, KWArgs, Opts) ->
    with_conn(Conn, fun(Pid) ->
        bondy_connect_connection:publish_ack(Pid, Topic, Args, KWArgs, Opts)
    end).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
with_conn(Conn, Fun) ->
    case resolve(Conn) of
        undefined -> {error, not_connected};
        Pid -> Fun(Pid)
    end.

%% @private Resolve an opaque handle to a live connection pid (or `undefined`).
resolve({bondy_connect_client, Pid}) when is_pid(Pid) ->
    Pid;
resolve({bondy_connect_client, Name}) when is_atom(Name) ->
    bondy_connect_manager:whereis_name(Name).
