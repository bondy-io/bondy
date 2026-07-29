<!--
SPDX-FileCopyrightText: 2016 - 2026 Leapsight
SPDX-License-Identifier: Apache-2.0
-->

# Tutorial — `bondy_connect`

A hands-on guide to the `bondy_connect` WAMP client: connecting, authenticating,
and using all four WAMP roles (**caller**, **callee**, **publisher**,
**subscriber**), plus resilience, load regulation, and the in-VM transport.

Every code snippet uses only the public API (the `m:bondy_connect` facade) and
mirrors the behaviour exercised by the test suite, so you can paste it into a
shell or a module and expect it to work against a running Bondy router.


## Contents

- [1. Concepts](#1-concepts)
- [2. Setup](#2-setup)
- [3. Connecting](#3-connecting)
- [4. Authentication](#4-authentication)
- [5. Caller — calling procedures](#5-caller--calling-procedures)
- [6. Callee — registering procedures](#6-callee--registering-procedures)
- [7. Publisher](#7-publisher)
- [8. Subscriber](#8-subscriber)
- [9. Handlers in depth](#9-handlers-in-depth)
- [10. Resilience](#10-resilience)
- [11. Load regulation](#11-load-regulation)
- [12. The in-VM (local) transport](#12-the-in-vm-local-transport)
- [13. TLS](#13-tls)
- [14. A complete worked example](#14-a-complete-worked-example)
- [15. Error reference](#15-error-reference)
- [16. API cheat-sheet](#16-api-cheat-sheet)

---

## 1. Concepts

A few ideas underpin the whole API:

- **One connection ⇒ one WAMP session ⇒ one realm.** Open as many connections as
  you need; each is independent and runs its own supervised process tree.
- **`connect/1,2` blocks until the session is established** (handshake + auth,
  possibly across reconnect attempts) and returns an **opaque** handle,
  `t:bondy_connect:conn/0`. Treat it as a token — pass it back to the API, never
  inspect it.
- **Handlers are isolated.** Every inbound invocation (callee) or event
  (subscriber) runs your handler in a separate, monitored, load-regulated worker
  process. **A crashing handler never affects the connection** — it is reported
  as a WAMP error (callee) or simply dropped (subscriber).
- **Events are ordered per subscription** (FIFO) by default; opt into concurrent
  delivery with `#{ordered => false}`.
- **Resilient by default.** Once a session has established, a dropped link is
  re-established with bounded, backed-off retries, and the connection's declared
  registrations and subscriptions are **replayed** automatically.
- **Standalone.** `bondy_connect` has **no dependency on the `bondy` router
  app** — it can be embedded in any Erlang/Elixir service to talk to a remote
  Bondy. (On a node that *is* a Bondy router, the `local` transport additionally
  lets you connect in-VM with no socket.)

The connection moves through these statuses, reported by `bondy_connect:status/1`:

```
connecting → establishing → established
                  ▲              │ (link drops)
                  └── reconnecting ◀┘     … → down (gave up / closed)
```

---

## 2. Setup

### Dependency

`bondy_connect` is part of the Bondy umbrella. To embed it in an external
project, depend on it via `git_subdir` in `rebar.config`:

```erlang
{deps, [
    {bondy_connect,
        {git_subdir, "https://github.com/bondy-io/bondy.git",
            {branch, "master"}, "apps/bondy_connect"}}
]}.
```

### Starting the application

`bondy_connect` is an OTP application; start it (and its dependencies) before
opening any connection:

```erlang
{ok, _} = application:ensure_all_started(bondy_connect).
```

### What you need on the router side

To follow along you need a running Bondy router with a realm your client can
authenticate to. For the simplest case — anonymous auth — the realm must permit
the `anonymous` user and grant the WAMP permissions you intend to use
(`wamp.call`, `wamp.register`, `wamp.subscribe`, `wamp.publish`). The examples
below assume a realm `com.example.realm` listening for raw TCP on
`127.0.0.1:18082` (Bondy's default `wamp_tcp` listener).

---

## 3. Connecting

`connect/1` takes a **spec** map. Only `realm` is strictly required; everything
else has a sensible default.

```erlang
{ok, Conn} = bondy_connect:connect(#{
    transport => tcp,
    endpoint  => {"127.0.0.1", 18082},
    realm     => <<"com.example.realm">>,
    auth      => #{method => <<"anonymous">>},
    serializers => [json]
}),

established = bondy_connect:status(Conn),

%% … use Conn …

ok = bondy_connect:disconnect(Conn).
```

### Spec reference

| Key | Default | Meaning |
|-----|---------|---------|
| `realm` | — (**required**) | WAMP realm URI (binary). |
| `transport` | `tcp` | `tcp` \| `tls` \| `uds` \| `ws` \| `wss` \| `local`. |
| `endpoint` | `undefined` | Transport-specific (see below). |
| `auth` | `#{method => <<"anonymous">>}` | Authentication (see [§4](#4-authentication)). |
| `serializers` | `[json]` | Preferred order of `json` \| `msgpack` \| `cbor`. |
| `roles` | full advanced profile | WAMP roles/features to advertise. |
| `agent` | Bondy default | Agent string sent in `HELLO`. |
| `reconnect` | see [§10](#10-resilience) | Reconnect/backoff policy. |
| `ping` | see [§10](#10-resilience) | Idle keepalive (ping/pong). |
| `network_timeout` | `60000` | Wait for network recovery (partisan nodes only). |
| `handler` | `#{}` | Handler load regulation (see [§11](#11-load-regulation)). |
| `tls` | `#{verify => verify_peer}` | TLS options for `tls`/`wss` (see [§13](#13-tls)). |
| `ws_path` | `<<"/ws">>` | HTTP path for `ws`/`wss`. |
| `max_message_length` | `16777216` | Max inbound/outbound payload (16 MB). |

### Endpoint by transport

```erlang
%% Raw TCP
#{transport => tcp,  endpoint => {"127.0.0.1", 18082}, realm => Realm}

%% Raw TLS (secure-by-default; see §13)
#{transport => tls,  endpoint => {"router.example.com", 18085}, realm => Realm}

%% Unix domain socket
#{transport => uds,  endpoint => {local, "/var/run/bondy/wamp.sock"}, realm => Realm}

%% WebSocket (path defaults to /ws)
#{transport => ws,   endpoint => {"127.0.0.1", 18080}, ws_path => <<"/ws">>, realm => Realm}

%% Secure WebSocket
#{transport => wss,  endpoint => {"router.example.com", 18083}, realm => Realm}

%% In-VM (only on a node running the Bondy router — see §12)
#{transport => local, endpoint => local, realm => Realm}
```

### Named connections

Give a connection a name so other processes can reach it without holding the
original handle:

```erlang
{ok, _} = bondy_connect:connect(my_service_conn, #{
    transport => tcp,
    endpoint  => {"127.0.0.1", 18082},
    realm     => <<"com.example.realm">>
}),

%% Elsewhere, from any process:
Conn = bondy_connect:named(my_service_conn),
{ok, R} = bondy_connect:call(Conn, <<"com.example.echo">>, [<<"hi">>]).
```

`named/1` resolves to the live connection lazily on each call, so it keeps
working across the connection's internal reconnects.

---

## 4. Authentication

The `auth` map's `method` selects the mechanism. Supported methods:
`anonymous`, `wampcra`, `cryptosign`, `ticket`.

```erlang
%% Anonymous — no credentials
#{method => <<"anonymous">>}

%% WAMP-CRA (challenge–response with a shared secret)
#{method => <<"wampcra">>,
  authid   => <<"alice">>,
  password => <<"secret">>}

%% Cryptosign (Ed25519). privkey is the hex-encoded private key.
#{method => <<"cryptosign">>,
  authid  => <<"alice">>,
  privkey => <<"a1b2c3…">>}     %% e.g. bondy_wamp_cryptosign:encode_hex(Seed)

%% Ticket (a pre-issued bearer token)
#{method => <<"ticket">>,
  authid => <<"alice">>,
  ticket => <<"…token…">>}
```

A credential-bearing method that the router welcomes **without** issuing a
challenge is rejected (`{welcome_without_challenge, _}`) — only `anonymous` may
establish unchallenged. This prevents a silent downgrade of your authentication.

---

## 5. Caller — calling procedures

### Synchronous

`call/2,3,4,5` blocks for the result. On success you get
`{ok, #{args := [...], kwargs := #{...}}}`.

```erlang
%% No args
{ok, R0} = bondy_connect:call(Conn, <<"bondy.session.self">>),

%% Positional args
{ok, R1} = bondy_connect:call(Conn, <<"com.example.add">>, [2, 3]),
[5] = maps:get(args, R1),

%% Positional + keyword args
{ok, R2} = bondy_connect:call(Conn, <<"com.example.greet">>, [<<"Alice">>], #{lang => <<"en">>}),

%% With options (per-call timeout in ms)
case bondy_connect:call(Conn, <<"com.example.slow">>, [], #{}, #{timeout => 5000}) of
    {ok, #{args := Args}}        -> {done, Args};
    {error, timeout}             -> retry_later;
    {error, #{uri := ErrUri}}    -> {wamp_error, ErrUri}
end.
```

Errors come back as:

- `{error, #{uri := <<"wamp.error.no_such_procedure">>}}` — nothing registered.
- `{error, #{uri := BusinessErrorUri, ...}}` — the callee returned `{error, …}`.
- `{error, timeout}` — the call exceeded its `timeout`.
- `{error, not_connected}` — the connection is gone.

### Asynchronous

`call_async/3,4,5` returns immediately with a token; the reply is delivered to
the **calling process** as a message.

```erlang
{ok, Token} = bondy_connect:call_async(Conn, <<"com.example.slow">>, [<<"job-1">>]),
receive
    {bondy_connect, Token, {ok, #{args := Args}}} -> {done, Args};
    {bondy_connect, Token, {error, Reason}}       -> {failed, Reason}
after 10000 ->
    timeout
end.
```

### Cancelling an in-flight call

Cancel an outstanding async call by its token. `Mode` is `skip` | `kill` |
`killnowait` (default `killnowait`). The async caller still receives a
terminating `{error, _}` reply for the token.

```erlang
{ok, Token} = bondy_connect:call_async(Conn, <<"com.example.long">>, []),
ok = bondy_connect:cancel(Conn, Token),            %% killnowait
%% or: bondy_connect:cancel(Conn, Token, skip)
receive {bondy_connect, Token, {error, _}} -> cancelled end.
```

---

## 6. Callee — registering procedures

`register/3,4` publishes a procedure backed by a **handler**. It returns
`{ok, RegistrationId}`. The handler runs in an isolated worker on every
invocation.

```erlang
Echo = fun(Args, KWArgs, _Details) ->
    {reply, Args, KWArgs}
end,
{ok, RegId} = bondy_connect:register(Conn, <<"com.example.echo">>, Echo),

%% later
ok = bondy_connect:unregister(Conn, RegId).        %% by id …
%% ok = bondy_connect:unregister(Conn, <<"com.example.echo">>).  %% … or by URI
```

### Handler return values (callee)

The connection maps your handler's return to a WAMP `YIELD` or `ERROR`:

| Return | Wire result |
|--------|-------------|
| `{reply, Args}` | `YIELD` with positional args |
| `{reply, Args, KWArgs}` | `YIELD` with args + kwargs |
| `ok` / `noreply` | empty `YIELD` |
| `{error, Uri}` | `ERROR` |
| `{error, Uri, Args}` | `ERROR` with args |
| `{error, Uri, Args, KWArgs}` | `ERROR` with args + kwargs |
| *(an exception)* | `ERROR` `wamp.error.internal_error` (handler crash is contained) |

```erlang
Divide = fun([_A, 0], _KWArgs, _Details) ->
                {error, <<"com.example.div_by_zero">>};
            ([A, B], _KWArgs, _Details) ->
                {reply, [A div B]}
         end,
{ok, _} = bondy_connect:register(Conn, <<"com.example.divide">>, Divide).
```

### Pattern-based registration

Pass match options through `register/4` (e.g. prefix or wildcard matching, if
your realm grants allow it):

```erlang
{ok, _} = bondy_connect:register(
    Conn, <<"com.example.api">>, Handler, #{match => <<"prefix">>}
).
```

---

## 7. Publisher

`publish/3,4,5` sends an event. By default it is fire-and-forget and returns
`ok`. With `#{acknowledge => true}` it waits for the router and returns
`{ok, PublicationId}`.

```erlang
%% Fire-and-forget
ok = bondy_connect:publish(Conn, <<"com.example.events">>, [<<"tick">>]),

%% With keyword args
ok = bondy_connect:publish(Conn, <<"com.example.events">>, [<<"tick">>], #{seq => 1}),

%% Acknowledged
{ok, PubId} = bondy_connect:publish(
    Conn, <<"com.example.events">>, [<<"tick">>], #{}, #{acknowledge => true}
).
```

---

## 8. Subscriber

`subscribe/3,4` registers a handler invoked once per event; it returns
`{ok, SubscriptionId}`. The handler's return value is ignored.

```erlang
Self = self(),
Handler = fun(Args, _KWArgs, _Details) ->
    Self ! {event, Args}
end,
{ok, SubId} = bondy_connect:subscribe(Conn, <<"com.example.events">>, Handler),

receive
    {event, Args} -> handle(Args)
end,

ok = bondy_connect:unsubscribe(Conn, SubId).       %% by id, or by topic URI
```

### Ordering

Events for a subscription are delivered **FIFO** by default: the next event is
not dispatched until the current handler finishes. For independent events where
throughput matters more than order, opt into concurrent delivery:

```erlang
{ok, _} = bondy_connect:subscribe(
    Conn, <<"com.example.events">>, Handler, #{ordered => false}
).
```

---

## 9. Handlers in depth

A `t:bondy_connect_handler_spec:handler/0` is one of three shapes — used
identically for callees and subscribers:

```erlang
%% 1. An anonymous (or named) fun of arity 3
fun(Args, KWArgs, Details) -> {reply, Args} end

%% 2. {Module, Function} — called as Module:Function(Args, KWArgs, Details)
{my_handlers, echo}

%% 3. {Module, Function, Extra} — called as Module:Function(Args, KWArgs, Details, Extra)
{my_handlers, echo, #{tenant => <<"acme">>}}
```

```erlang
%% my_handlers.erl
-module(my_handlers).
-export([echo/3, echo/4]).

echo(Args, KWArgs, _Details) ->
    {reply, Args, KWArgs}.

echo(Args, _KWArgs, _Details, Extra) ->
    {reply, Args, #{extra => Extra}}.
```

Notes:

- **`Details`** is a map of WAMP call/event metadata (e.g. caller/publisher id
  when disclosed, the matched topic/procedure, etc.).
- Handlers run **off the connection process**, each in its own monitored worker.
  A handler that crashes, blocks, or loops cannot stall or kill the connection;
  for a callee it becomes an `ERROR`, for a subscriber the event is dropped.
- Because handlers are isolated, do **not** rely on process-dictionary or
  mailbox state from the caller of `register/subscribe` — pass what you need via
  the `{M, F, Extra}` form or a closure.

---

## 10. Resilience

### Reconnect & replay

Once a session has established at least once, a dropped link triggers a bounded,
backed-off reconnect loop. On re-establishment the connection **replays its
declared registrations and subscriptions**, so your callee procedures and
subscriptions become live again automatically.

The `reconnect` map (merged over the defaults):

```erlang
#{transport => tcp, endpoint => {"127.0.0.1", 18082}, realm => Realm,
  reconnect => #{
      enabled               => true,    %% master switch
      retry_initial_connect => false,   %% retry the FIRST connect too?
      max_retries           => 10,
      interval              => 3000,     %% base delay (ms)
      deadline              => 60000,    %% give up after this long (0 = no deadline)
      backoff_enabled       => true,
      backoff_min           => 1000,
      backoff_max           => 60000
  }}
```

By default `connect/1` is **fail-fast on the first attempt**: a dead endpoint
returns `{error, _}` immediately rather than blocking on retries. Set
`retry_initial_connect => true` to retry the initial connect within the budget
too. When the budget is exhausted the connection gives up and terminates with
`{shutdown, {reconnect_failed, _}}`; `status/1` then reports `down`.

### Keepalive (ping/pong)

An idle raw-socket connection is probed with WAMP pings; unanswered pings tear
the link down and trigger a reconnect.

```erlang
#{ping => #{
      enabled      => true,
      idle_timeout => 30000,   %% ping after this much silence (ms)
      timeout      => 10000,   %% wait this long for each pong (ms)
      max_attempts => 3        %% give up (→ reconnect) after this many misses
  }}
```

### Fail-fast on disconnect

When the link drops, **in-flight calls fail immediately** with
`{error, disconnected}` rather than hanging, and new calls on a down connection
return `{error, not_connected}`.

---

## 11. Load regulation

A callee can bound how much concurrent work inbound invocations may spawn, via
the `handler` spec — both a hard in-flight cap **and** a token-bucket rate limit
(both must admit a request). This protects the node from a flood of calls.

```erlang
{ok, Conn} = bondy_connect:connect(#{
    transport => tcp,
    endpoint  => {"127.0.0.1", 18082},
    realm     => <<"com.example.realm">>,
    handler   => #{
        max_concurrency => 50,            %% at most 50 invocations in flight (0 = unlimited)
        rate            => #{capacity => 100}  %% bondy_regulator token-bucket spec
    }
}).
```

When an invocation cannot be admitted (cap reached or bucket empty), the caller
receives `{error, #{uri := <<"wamp.error.unavailable">>}}` — the connection stays
healthy and keeps serving admitted work. Events (subscriptions) are not
load-regulated.

---

## 12. The in-VM (local) transport

On a node that **is** running the Bondy router, `transport => local` opens a
session in-process — no socket, no serialization, no handshake — while looking
exactly like a remote client to your code.

```erlang
{ok, Conn} = bondy_connect:connect(#{
    transport => local,
    endpoint  => local,
    realm     => <<"com.example.realm">>
}),
{ok, R} = bondy_connect:call(Conn, <<"bondy.session.self">>, []).
```

How it stays standalone: `bondy_connect_local` is a transport that holds **zero**
references to any `bondy` module. It defines a *handler behaviour* and a
`persistent_term` registry; the router app implements the behaviour
(`bondy_connect_local_handler`) and registers it at boot. On a node where no
handler is registered (a plain peer that isn't a router), the local transport is
**unavailable** and `connect/2` returns `{error, local_transport_unavailable}` —
a clean, terminal failure, never a crash.

An in-VM peer is inside the trusted BEAM, so the WAMP challenge methods do not
apply: the session opens **anonymous**, with the realm's authorization (grants,
sources) still fully enforced.

---

## 13. TLS

`tls` and `wss` are **secure-by-default**: peer verification is on
(`verify_peer`) using the system/configured CA bundle, with SNI/hostname checks.
Supply `tls` options to point at your CA, present a client certificate (mTLS), or
(explicitly, and at your own risk) relax verification.

```erlang
%% Verify the server against a specific CA bundle
#{transport => tls, endpoint => {"router.example.com", 18085}, realm => Realm,
  tls => #{cacertfile => "/etc/ssl/certs/ca.pem"}}

%% Mutual TLS — present a client certificate
#{transport => tls, endpoint => {"router.example.com", 18085}, realm => Realm,
  tls => #{cacertfile => "/etc/ssl/certs/ca.pem",
           certfile   => "/etc/ssl/certs/client.pem",
           keyfile    => "/etc/ssl/private/client.key"}}

%% Disable verification — explicit opt-in only; logged at WARNING
#{transport => tls, endpoint => {"127.0.0.1", 18085}, realm => Realm,
  tls => #{verify => verify_none}}
```

The same `tls` options apply to `wss`.

---

## 14. A complete worked example

A small `gen_server` that owns a connection, registers a procedure, and exposes
calls — including reconnect-resilient behaviour (the procedure is replayed
automatically after a drop):

```erlang
-module(price_service).
-behaviour(gen_server).

-export([start_link/0, latest/1]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Public API: ask the service for a price via WAMP.
latest(Symbol) ->
    gen_server:call(?MODULE, {latest, Symbol}).

init([]) ->
    {ok, _} = application:ensure_all_started(bondy_connect),
    {ok, Conn} = bondy_connect:connect(price_conn, #{
        transport => tcp,
        endpoint  => {"127.0.0.1", 18082},
        realm     => <<"com.example.realm">>,
        auth      => #{method => <<"anonymous">>}
    }),

    %% Register a procedure served by this node.
    Quote = fun([Symbol], _KWArgs, _Details) ->
        {reply, [Symbol, quote_for(Symbol)]}
    end,
    {ok, _RegId} = bondy_connect:register(Conn, <<"com.example.quote">>, Quote),

    %% Subscribe to a topic; print each event.
    OnTick = fun(Args, _KWArgs, _Details) ->
        logger:info("tick: ~p", [Args])
    end,
    {ok, _SubId} = bondy_connect:subscribe(Conn, <<"com.example.ticks">>, OnTick),

    {ok, #{conn => Conn}}.

handle_call({latest, Symbol}, _From, #{conn := Conn} = State) ->
    Reply =
        case bondy_connect:call(Conn, <<"com.example.quote">>, [Symbol]) of
            {ok, #{args := [Symbol, Price]}} -> {ok, Price};
            {error, _} = Error               -> Error
        end,
    {reply, Reply, State}.

handle_cast(_, State) -> {noreply, State}.

terminate(_Reason, #{conn := Conn}) ->
    bondy_connect:disconnect(Conn).

quote_for(_Symbol) -> 42.
```

---

## 15. Error reference

| Error | Where | Meaning |
|-------|-------|---------|
| `{error, not_connected}` | any op | The connection handle resolves to no live process. |
| `{error, disconnected}` | in-flight call | The link dropped mid-call (fail-fast). |
| `{error, timeout}` | `call/5` | The call exceeded its `timeout` option. |
| `{error, #{uri := <<"wamp.error.no_such_procedure">>}}` | `call` | Nothing registered for the URI. |
| `{error, #{uri := <<"wamp.error.unavailable">>}}` | `call` | The callee's load regulator rejected the invocation. |
| `{error, #{uri := <<"wamp.error.internal_error">>}}` | `call` | The callee handler crashed (contained). |
| `{error, #{uri := Uri, ...}}` | `call` | Business error returned by the callee. |
| `{error, {invalid_handler, _}}` | `register`/`subscribe` | The handler isn't a fun/3, `{M,F}`, or `{M,F,Extra}`. |
| `{error, local_transport_unavailable}` | `connect` (`local`) | No router handler registered on this node. |
| `{error, {welcome_without_challenge, _}}` | `connect` | A credentialed method was welcomed unchallenged (downgrade refused). |
| `{shutdown, {reconnect_failed, _}}` | (exit) | The reconnect budget was exhausted; `status/1` → `down`. |

---

## 16. API cheat-sheet

```erlang
%% Lifecycle
{ok, Conn} = bondy_connect:connect(Spec).
{ok, Conn} = bondy_connect:connect(Name, Spec).
Conn       = bondy_connect:named(Name).
Status     = bondy_connect:status(Conn).   %% connecting|establishing|established|reconnecting|down
ok         = bondy_connect:disconnect(Conn).

%% Caller
{ok, R} | {error, _} = bondy_connect:call(Conn, Uri[, Args[, KWArgs[, Opts]]]).
{ok, Token}          = bondy_connect:call_async(Conn, Uri, Args[, KWArgs[, Opts]]).
ok | {error, _}      = bondy_connect:cancel(Conn, Token[, Mode]).  %% skip|kill|killnowait

%% Callee
{ok, RegId} = bondy_connect:register(Conn, Uri, Handler[, Opts]).
ok          = bondy_connect:unregister(Conn, RegId | Uri).

%% Publisher
ok | {ok, PubId} = bondy_connect:publish(Conn, Topic, Args[, KWArgs[, Opts]]).

%% Subscriber
{ok, SubId} = bondy_connect:subscribe(Conn, Topic, Handler[, Opts]).
ok          = bondy_connect:unsubscribe(Conn, SubId | Topic).
```

That covers the common surface. The one part left out here is progressive
calls — `call_stream/5`, `send_input/4`, and `finish_input/4` — for streaming
arguments into a call. For per-function detail see the `m:bondy_connect` module
reference; for background, the app [`README.md`](../README.md).
