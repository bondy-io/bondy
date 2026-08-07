%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_connection).

-moduledoc """
The connection process: a `gen_statem` that owns the transport, drives the
session handshake through the pure `bondy_connect_protocol` layer, and
correlates requests/replies — it speaks **records** to both the transport and
the protocol.

## Transport states

```
connecting --> handshaking --> establishing --> established
    ^                                               |
    +-----------------------------------------------+   (drop -> reconnect)
    |
waiting_for_network   (network down, partisan-gated)
```

`connecting` opens the transport (and owns the reconnect/backoff loop via
`bondy_retry`); `handshaking` runs the raw-socket transport handshake (passive)
then switches the socket to active and sends the HELLO the protocol layer
produces; `establishing` feeds inbound CHALLENGE/WELCOME/ABORT records to the
protocol layer until it reports `established` (or aborts); `established` services
the four client roles and runs idle ping/pong keepalive.

## Resilience (Phase 6)

A dropped session is re-established in-process: on a transport failure the
session state is torn down (in-flight calls fail-fast with `{error, disconnected}`,
in-flight workers are stopped, established registrations/subscriptions are
cleared but the **declared** set is kept), then `connecting` retries with
`bondy_retry` backoff. On re-establish the declared REGISTER/SUBSCRIBE set is
replayed. When partisan network monitoring is available, a network-down failure
parks in `waiting_for_network` until the network recovers. The initial connect
is fail-fast by default (configurable via `reconnect.retry_initial_connect`).

A router `ABORT` is classified before it is treated as fatal. Every Bondy abort
carries `bondy_error`'s `nature` key: `transient` means retrying the operation
unchanged could succeed, `permanent` means the request itself is at fault. A
transient abort — the HELLO load-admission gate shedding new sessions under deep
run queues with `wamp.error.unavailable` is the one that matters at scale —
takes the same backoff loop as a dropped link, **including on the first
connect**, because `retry_initial_connect`'s fail-fast intent is about
misconfiguration and a transient abort is the opposite of that. Permanent
aborts still fail fast. See `is_transient_abort/2`.

## Roles (M2)

- **caller** — `call/5` (synchronous) and `call_async/5` (a token reply to the
  caller pid); per-request timeouts; `RESULT`/`ERROR` correlation;
  `cancel/3`; progressive call results via `call_async/5` with
  `receive_progress => true` (each progressive result is delivered as
  `{bondy_connect, Token, {progress, map()}}` before the terminal reply).
- **callee** — `register/4`/`unregister/2`; inbound `INVOCATION` is dispatched
  to an isolated, monitored, load-regulated `bondy_connect_handler` worker
  whose result becomes a `YIELD` or `ERROR`; `INTERRUPT` kills the worker;
  when the caller requested progressive results the handler receives a
  `progress` fun in its details whose calls become progressive `YIELD`s.
- **publisher** — `publish/5` (fire-and-forget) or `publish_ack/5`
  (waits for the router's `PUBLISHED`).
- **subscriber** — `subscribe/4`/`unsubscribe/2`; inbound `EVENT` is dispatched
  to a worker, **FIFO per subscription** by default (opt-in `unordered`).

Correlation, the registry, the per-subscription dispatch queues and the load
counter all live in the `gen_statem` data — never shared ETS (fixes the awre
race), auto-reclaimed on death. `process_flag(sensitive, true)` is set while
authenticating and cleared on `established`. Progressive calls
(caller-side argument streaming) are not implemented.
""".

-behaviour(gen_statem).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-record(data, {
    config :: map(),
    conn_sup :: pid(),
    transport_mod :: module(),
    transport :: term() | undefined,
    subprotocol :: {raw, binary, atom()},
    protocol :: bondy_connect_protocol:state(),
    session :: bondy_connect_session:t() | undefined,
    ready_waiters = [] :: [gen_statem:from()],
    %% Resilience (Phase 6)
    reconnect_retry :: bondy_retry:t() | undefined,
    retry_initial = false :: boolean(),
    established_once = false :: boolean(),
    %% Set when we enter `connecting` as the CONTINUATION of a retry episode
    %% rather than the start of one, carrying the already-advanced `bondy_retry`
    %% delay. `connecting(enter, ...)` resets the budget and reconnects
    %% immediately, which is right for a fresh disconnection but catastrophic
    %% for a router that keeps refusing the handshake — see
    %% `backoff_into_connecting/2`.
    pending_delay :: non_neg_integer() | undefined,
    net_monitor = false :: boolean(),
    network_timeout :: pos_integer(),
    %% Idle keepalive (ping/pong) — pure state in bondy_connect_keepalive
    keepalive :: bondy_connect_keepalive:t(),
    next_request_id = 1 :: pos_integer(),
    %% ReqId => #{type, from, timer, meta}
    pending = #{} :: #{pos_integer() => map()},
    %% async-call token -> ReqId secondary index, kept in lockstep with the
    %% `call_async' entries in `pending' so cancel/3 is O(1) (review C1).
    async_index = #{} :: #{reference() => pos_integer()},
    handler_sup :: pid() | undefined,
    registry :: bondy_connect_registry:t(),
    %% Callee invocations, subscriber FIFO dispatch, worker lifecycle and the
    %% load regulator — pure state in bondy_connect_dispatch.
    dispatch :: bondy_connect_dispatch:t()
}).

-define(CONNECT_TIMEOUT, 5000).
-define(ESTABLISH_TIMEOUT, 10000).
-define(DEFAULT_CALL_TIMEOUT, 30000).
-define(DEFAULT_ADMIN_TIMEOUT, 15000).
%% Slack added to the WAMP call timeout when waiting on the gen_statem, so the
%% inner CALL timeout fires first (returning a proper WAMP error) before the
%% outer `gen_statem:call` would time out and exit the caller.
-define(CALL_TIMEOUT_SLACK, 5000).

-export([start_link/2]).
-export([await_ready/2]).
-export([call/5]).
-export([call_async/5]).
-export([call_stream/5]).
-export([send_input/4]).
-export([finish_input/4]).
-export([cancel/3]).
-export([register/4]).
-export([unregister/2]).
-export([subscribe/4]).
-export([unsubscribe/2]).
-export([publish/5]).
-export([publish_ack/5]).
-export([status/1]).

-export([callback_mode/0]).
-export([init/1]).
-export([terminate/3]).
-export([format_status/1]).
%% state functions
-export([connecting/3]).
-export([waiting_for_network/3]).
-export([handshaking/3]).
-export([establishing/3]).
-export([established/3]).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link(Config :: map(), ConnSup :: pid()) ->
    {ok, pid()} | {error, term()}.
start_link(Config, ConnSup) ->
    gen_statem:start_link(?MODULE, {Config, ConnSup}, []).

-doc "Block until the session is established (or it fails).".
-spec await_ready(pid(), timeout()) -> ok | {error, term()}.
await_ready(Pid, Timeout) ->
    call_safe(Pid, await_ready, Timeout).

-doc """
Issue a synchronous CALL and wait for the RESULT/ERROR.

`receive_progress` is rejected here: a synchronous single-reply API cannot
represent a stream of progressive results — use `call_async/5` for that.
""".
-spec call(pid(), uri(), list(), map(), map()) ->
    {ok, bondy_connect:call_result()} | {error, bondy_connect:call_error()}.
call(_, _, _, _, #{receive_progress := true}) ->
    tag_error({error, {invalid_option, receive_progress}});
call(Pid, Uri, Args, KWArgs, Opts) ->
    Timeout = maps:get(timeout, Opts, ?DEFAULT_CALL_TIMEOUT),
    tag_error(
        call_safe(
            Pid, {call, Uri, Args, KWArgs, Opts}, Timeout + ?CALL_TIMEOUT_SLACK
        )
    ).

-doc """
Issue an asynchronous CALL. Returns `{ok, Token}`; the RESULT/ERROR is later
delivered to the calling process as `{bondy_connect, Token, Reply}` where
`Reply` is `{ok, bondy_connect:call_result()}` or
`{error, bondy_connect:call_error()}`.

With `receive_progress => true` any progressive results arrive first, each
as `{bondy_connect, Token, {progress, map()}}`; the terminal delivery
remains the single `{ok, _}`/`{error, _}` message. The per-call timeout
bounds the whole call — progressive results do not extend it.
""".
-spec call_async(pid(), uri(), list(), map(), map()) ->
    {ok, reference()} | {error, bondy_connect:call_error()}.
call_async(Pid, Uri, Args, KWArgs, Opts) ->
    tag_error(
        call_safe(
            Pid, {call_async, Uri, Args, KWArgs, Opts}, ?DEFAULT_ADMIN_TIMEOUT
        )
    ).

-doc """
Begin a progressive call (caller argument streaming): send the first CALL with
`Options.progress = true`, returning `{ok, Token}`. Subsequent chunks reuse the
one request id via `send_input/4` / `finish_input/4`.
""".
-spec call_stream(pid(), uri(), list(), map(), map()) ->
    {ok, reference()} | {error, bondy_connect:call_error()}.
call_stream(Pid, Uri, Args, KWArgs, Opts) ->
    tag_error(
        call_safe(
            Pid, {call_stream, Uri, Args, KWArgs, Opts}, ?DEFAULT_ADMIN_TIMEOUT
        )
    ).

-doc "Send a non-final argument chunk of a progressive call.".
-spec send_input(pid(), reference(), list(), map()) -> ok | {error, term()}.
send_input(Pid, Token, Args, KWArgs) ->
    call_safe(Pid, {send_input, Token, Args, KWArgs}, ?DEFAULT_ADMIN_TIMEOUT).

-doc "Send the final argument chunk of a progressive call.".
-spec finish_input(pid(), reference(), list(), map()) -> ok | {error, term()}.
finish_input(Pid, Token, Args, KWArgs) ->
    call_safe(Pid, {finish_input, Token, Args, KWArgs}, ?DEFAULT_ADMIN_TIMEOUT).

-doc """
Cancel an in-flight asynchronous call identified by its `Token` (returned by
`call_async/5`). `Mode` is `skip` | `kill` | `killnowait` (WAMP call-cancelling
modes). The original async caller still receives the terminating
`{error, #{kind := wamp, uri := <<"wamp.error.canceled">>, ...}}` reply.
""".
-spec cancel(pid(), reference(), skip | kill | killnowait) ->
    ok | {error, term()}.
cancel(Pid, Token, Mode) ->
    call_safe(Pid, {cancel, Token, Mode}, ?DEFAULT_ADMIN_TIMEOUT).

-doc "Register a procedure with a handler. Returns `{ok, RegistrationId}`.".
-spec register(pid(), uri(), bondy_connect_handler_spec:handler(), map()) ->
    {ok, pos_integer()} | {error, bondy_connect:call_error()}.
register(Pid, Uri, Handler, Opts) ->
    tag_error(
        call_safe(
            Pid, {register, Uri, Handler, Opts}, ?DEFAULT_ADMIN_TIMEOUT
        )
    ).

-doc "Unregister a procedure by its registration id or URI.".
-spec unregister(pid(), pos_integer() | uri()) ->
    ok | {error, bondy_connect:call_error()}.
unregister(Pid, RegRef) ->
    tag_error(call_safe(Pid, {unregister, RegRef}, ?DEFAULT_ADMIN_TIMEOUT)).

-doc "Subscribe to a topic with a handler. Returns `{ok, SubscriptionId}`.".
-spec subscribe(pid(), uri(), bondy_connect_handler_spec:handler(), map()) ->
    {ok, pos_integer()} | {error, bondy_connect:call_error()}.
subscribe(Pid, Topic, Handler, Opts) ->
    tag_error(
        call_safe(
            Pid, {subscribe, Topic, Handler, Opts}, ?DEFAULT_ADMIN_TIMEOUT
        )
    ).

-doc "Unsubscribe from a topic by its subscription id or URI.".
-spec unsubscribe(pid(), pos_integer() | uri()) ->
    ok | {error, bondy_connect:call_error()}.
unsubscribe(Pid, SubRef) ->
    tag_error(call_safe(Pid, {unsubscribe, SubRef}, ?DEFAULT_ADMIN_TIMEOUT)).

-doc """
Publish to a topic. With `Opts` `#{acknowledge => true}` it waits for the
router's `PUBLISHED` and returns `{ok, PublicationId}`; otherwise it returns
`ok` once the message is on the wire. Shared low-level implementation for
both `bondy_connect:publish/*` (acknowledge disallowed) and `publish_ack/5`
(acknowledge forced) — the branch on `Opts.acknowledge` is unaffected by
either caller.
""".
-spec publish(pid(), uri(), list(), map(), map()) ->
    ok | {ok, pos_integer()} | {error, term()}.
publish(Pid, Topic, Args, KWArgs, Opts) ->
    call_safe(
        Pid, {publish, Topic, Args, KWArgs, Opts}, ?DEFAULT_ADMIN_TIMEOUT
    ).

-doc """
Acknowledged publish — same wire behaviour as `publish/5` with
`Opts#{acknowledge => true}`, discriminated error.
""".
-spec publish_ack(pid(), uri(), list(), map(), map()) ->
    {ok, pos_integer()} | {error, bondy_connect:call_error()}.
publish_ack(Pid, Topic, Args, KWArgs, Opts) ->
    tag_error(publish(Pid, Topic, Args, KWArgs, Opts#{acknowledge => true})).

-doc "The public status of the connection.".
-spec status(pid()) ->
    connecting | establishing | established | reconnecting | down.
status(Pid) ->
    try
        gen_statem:call(Pid, status, 5000)
    catch
        _:_ -> down
    end.

%% @private
call_safe(Pid, Request, Timeout) ->
    try
        gen_statem:call(Pid, Request, Timeout)
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:{noproc, _} -> {error, not_connected};
        exit:{Reason, _} -> {error, Reason}
    end.

%% @private A map error is already `kind`-tagged by error_payload/1 (a router
%% ERROR); a bare term is a client-side failure (call_safe/3's catch, a local
%% precondition check, or a send_msg failure) that needs one. Applied at the
%% ops where both classes are reachable — call/call_async/call_stream,
%% register/unregister/subscribe/unsubscribe, publish_ack.
%%
%% Deliberately NOT enriched the way error_payload/1 is: this payload is
%% matched exactly by callers (`{error, #{kind => client, reason => timeout}}`),
%% so extra keys would break them, and the caller already holds the reason term.
tag_error({error, Reason}) when not is_map(Reason) ->
    {error, #{kind => client, reason => Reason}};
tag_error(Result) ->
    Result.

%% =============================================================================
%% GEN_STATEM CALLBACKS
%% =============================================================================

callback_mode() ->
    [state_functions, state_enter].

init({Config, ConnSup}) ->
    process_flag(trap_exit, true),
    Mod = transport_mod(maps:get(transport, Config, tcp)),
    Sub = subprotocol(Config),
    {ok, Protocol} = bondy_connect_protocol:init(Config),
    Reconnect = maps:get(reconnect, Config, #{}),
    Ping = maps:get(ping, Config, #{}),
    Data = #data{
        config = Config,
        conn_sup = ConnSup,
        transport_mod = Mod,
        subprotocol = Sub,
        protocol = Protocol,
        registry = bondy_connect_registry:new(),
        dispatch = bondy_connect_dispatch:new(
            bondy_connect_load:new(maps:get(handler, Config, #{}))
        ),
        reconnect_retry = init_reconnect_retry(Reconnect),
        retry_initial = maps:get(retry_initial_connect, Reconnect, false),
        net_monitor = enable_net_monitor(),
        network_timeout = maps:get(network_timeout, Config, 60000),
        keepalive = bondy_connect_keepalive:new(Ping)
    },
    {ok, connecting, Data}.

%% -----------------------------------------------------------------------------
%% connecting
%% -----------------------------------------------------------------------------

%% A 0-delay state_timeout kicks off the work (next_event is not allowed from a
%% state enter callback). transport:connect/2 carries its own connect timeout.
%% We reset the retry budget on entry (a fresh disconnection episode) — the
%% backoff loop below re-arms the timeout via `keep_state` so this enter does
%% not re-run between attempts.
connecting(enter, _Old, #data{pending_delay = undefined} = Data0) ->
    Data = reset_reconnect_retry(Data0),
    {keep_state, Data, [{state_timeout, 0, connect}]};
connecting(enter, _Old, #data{pending_delay = Delay} = Data0) ->
    %% Continuation of an in-progress retry episode: the budget has already
    %% been advanced by `backoff_into_connecting/2` and must NOT be reset here,
    %% or the backoff can never grow.
    Data = Data0#data{pending_delay = undefined},
    {keep_state, Data, [{state_timeout, Delay, connect}]};
connecting(state_timeout, connect, Data) ->
    #data{transport_mod = Mod, config = Config} = Data,
    {Endpoint, Opts} = endpoint(Config),
    case Mod:connect(Endpoint, Opts) of
        {ok, T} ->
            {next_state, handshaking, Data#data{transport = T}};
        {error, Reason} ->
            on_connect_failure({connect_error, Reason}, Data)
    end;
connecting(info, {network_disconnected, _}, Data) ->
    {next_state, waiting_for_network, Data};
connecting(EventType, Event, Data) ->
    handle_common(EventType, Event, connecting, Data).

%% -----------------------------------------------------------------------------
%% waiting_for_network (network down — partisan-gated)
%% -----------------------------------------------------------------------------

waiting_for_network(enter, _Old, Data) ->
    ?LOG_NOTICE(#{
        description =>
            "Network down; waiting for it to recover before reconnecting.",
        timeout => Data#data.network_timeout
    }),
    {keep_state, Data, [
        {state_timeout, Data#data.network_timeout, network_timeout}
    ]};
waiting_for_network(state_timeout, network_timeout, Data) ->
    stop_fail(network_timeout, Data);
waiting_for_network(info, {network_connected, _}, Data) ->
    {next_state, connecting, Data};
waiting_for_network(info, {network_disconnected, _}, Data) ->
    {keep_state, Data};
waiting_for_network(EventType, Event, Data) ->
    handle_common(EventType, Event, waiting_for_network, Data).

%% -----------------------------------------------------------------------------
%% handshaking (transport handshake + HELLO)
%% -----------------------------------------------------------------------------

handshaking(enter, _Old, Data) ->
    {keep_state, Data, [{state_timeout, 0, handshake}]};
handshaking(state_timeout, handshake, Data) ->
    #data{transport_mod = Mod, transport = T0, subprotocol = Sub} = Data,
    case Mod:handshake(Sub, T0) of
        {ok, _Negotiated, T1} ->
            ok = Mod:setopts([{active, once}], T1),
            {ok, Hello, P1} = bondy_connect_protocol:start(Data#data.protocol),
            Data1 = Data#data{transport = T1, protocol = P1},
            case Mod:send(Hello, T1) of
                ok ->
                    {next_state, establishing, Data1};
                {error, Reason} ->
                    on_transport_failure({send_error, Reason}, Data1)
            end;
        {error, Reason} ->
            on_transport_failure({handshake_error, Reason}, Data)
    end;
handshaking(EventType, Event, Data) ->
    handle_common(EventType, Event, handshaking, Data).

%% -----------------------------------------------------------------------------
%% establishing (WAMP session handshake)
%% -----------------------------------------------------------------------------

establishing(enter, _Old, Data) ->
    _ = process_flag(sensitive, true),
    {keep_state, Data, [{state_timeout, ?ESTABLISH_TIMEOUT, timeout}]};
establishing(state_timeout, timeout, Data) ->
    on_transport_failure(establish_timeout, Data);
establishing(info, Info, Data) ->
    handle_socket(Info, establishing, Data);
establishing(EventType, Event, Data) ->
    handle_common(EventType, Event, establishing, Data).

%% -----------------------------------------------------------------------------
%% established
%% -----------------------------------------------------------------------------

established(enter, _Old, Data0) ->
    _ = process_flag(sensitive, false),
    HSup = bondy_connect_conn_sup:handler_sup(Data0#data.conn_sup),
    Data1 = Data0#data{handler_sup = HSup},
    %% On a re-establish (we have established before) replay the declared
    %% REGISTER/SUBSCRIBE set against the fresh session.
    Data2 =
        case Data1#data.established_once of
            true -> replay_declared(Data1);
            false -> Data1
        end,
    Data3 = reply_waiters(ok, Data2#data{established_once = true}),
    %% A successful establish resets the reconnect budget and arms keepalive.
    Data4 = reset_reconnect_retry(Data3),
    {keep_state, Data4,
        bondy_connect_keepalive:idle_actions(Data4#data.keepalive)};
established({timeout, ping_idle}, ping_idle, Data) ->
    %% The idle timer fired — send a ping (arming its deadline), or reconnect
    %% once the attempts are exhausted.
    case bondy_connect_keepalive:on_idle(Data#data.keepalive) of
        disabled -> {keep_state, Data};
        give_up -> on_transport_failure(ping_timeout, Data);
        {ping, Deadline} -> arm_ping(Deadline, Data)
    end;
established({timeout, ping}, ping_timeout, Data) ->
    %% A ping went unanswered within its deadline — fail it and try again, or
    %% tear the link down (and reconnect) once the attempts are exhausted.
    case bondy_connect_keepalive:on_ping_timeout(Data#data.keepalive) of
        disabled ->
            {keep_state, Data};
        {give_up, KA1} ->
            on_transport_failure(ping_timeout, Data#data{keepalive = KA1});
        {ping, Deadline, KA1} ->
            arm_ping(Deadline, Data#data{keepalive = KA1})
    end;
established({call, From}, {call, Uri, Args, KWArgs, Opts}, Data) ->
    do_call({sync, From}, Uri, Args, KWArgs, Opts, Data);
established(
    {call, {Owner, _} = From}, {call_async, Uri, Args, KWArgs, Opts}, Data
) ->
    Token = make_ref(),
    %% A progressive call is marked in the pending entry's meta so inbound
    %% progressive RESULTs are delivered to the owner without settling it.
    %% The timeout is kept because — per the WAMP spec — for a progressive
    %% call it is an inter-result inactivity window that each progressive
    %% result restarts; the optional `_deadline` caps the total duration.
    Meta =
        case maps:get(receive_progress, Opts, false) of
            true ->
                #{
                    receive_progress => true,
                    timeout => call_timeout(Opts),
                    deadline => call_deadline(Opts)
                };
            false ->
                #{}
        end,
    Data1 = do_request(
        call,
        {async, Owner, Token},
        call_msg(Uri, Args, KWArgs, Opts),
        call_timeout(Opts),
        Meta,
        Data
    ),
    {keep_state, Data1, [{reply, From, {ok, Token}}]};
established(
    {call, {Owner, _} = From}, {call_stream, Uri, Args, KWArgs, Opts}, Data
) ->
    Token = make_ref(),
    %% First chunk of a progressive-input stream. The pending entry (for the
    %% terminal RESULT/ERROR) is stashed with the procedure URI so subsequent
    %% chunks — which reuse the request id — can rebuild a well-formed CALL
    %% (the dealer re-authorizes each CALL by URI). A `receive_progress` opt
    %% still enables progressive results on the way back.
    Meta0 =
        case maps:get(receive_progress, Opts, false) of
            true ->
                #{
                    receive_progress => true,
                    timeout => call_timeout(Opts),
                    deadline => call_deadline(Opts)
                };
            false ->
                #{}
        end,
    Data1 = do_request(
        call,
        {async, Owner, Token},
        call_msg(Uri, Args, KWArgs, Opts#{progress => true}),
        call_timeout(Opts),
        Meta0#{stream_uri => Uri},
        Data
    ),
    {keep_state, Data1, [{reply, From, {ok, Token}}]};
established({call, From}, {send_input, Token, Args, KWArgs}, Data) ->
    Reply = send_input_chunk(Token, Args, KWArgs, #{progress => true}, Data),
    {keep_state, Data, [{reply, From, Reply}]};
established({call, From}, {finish_input, Token, Args, KWArgs}, Data) ->
    Reply = send_input_chunk(Token, Args, KWArgs, #{}, Data),
    {keep_state, Data, [{reply, From, Reply}]};
established({call, From}, {cancel, Token, Mode}, Data) ->
    do_cancel(From, Token, Mode, Data);
established({call, From}, {register, Uri, Handler, Opts}, Data) ->
    do_register(From, Uri, Handler, Opts, Data);
established({call, From}, {unregister, RegRef}, Data) ->
    do_unregister(From, RegRef, Data);
established({call, From}, {subscribe, Topic, Handler, Opts}, Data) ->
    do_subscribe(From, Topic, Handler, Opts, Data);
established({call, From}, {unsubscribe, SubRef}, Data) ->
    do_unsubscribe(From, SubRef, Data);
established({call, From}, {publish, Topic, Args, KWArgs, Opts}, Data) ->
    do_publish(From, Topic, Args, KWArgs, Opts, Data);
established({call, From}, await_ready, Data) ->
    {keep_state, Data, [{reply, From, ok}]};
established(info, {handler_progress, ReqId, Args, KWArgs}, Data) ->
    %% A worker servicing an INVOCATION emitted a progressive result via
    %% its injected progress fun. Forwarded only while the invocation is
    %% still in flight — a worker racing its own INTERRUPT or completion
    %% is dropped silently. The final YIELD is produced by handler_done.
    case bondy_connect_dispatch:has_invocation(ReqId, disp(Data)) of
        true ->
            Yield = bondy_connect_dispatch:progressive_yield(
                ReqId, Args, KWArgs
            ),
            _ = send_msg(Yield, Data),
            {keep_state, Data};
        false ->
            {keep_state, Data}
    end;
established(info, {handler_done, ReqId, Reply}, Data) ->
    {keep_state,
        run_dispatch(
            bondy_connect_dispatch:handler_done(ReqId, Reply, disp(Data)), Data
        )};
established(info, {event_done, SubId, _Pid}, Data) ->
    {keep_state,
        run_dispatch(
            bondy_connect_dispatch:event_done(SubId, disp(Data)), Data
        )};
established(info, {timeout, TRef, {req_timeout, ReqId}}, Data) ->
    {keep_state, handle_req_timeout(ReqId, TRef, Data)};
established(info, {'DOWN', MonRef, process, _Pid, Reason}, Data) ->
    {keep_state,
        run_dispatch(
            bondy_connect_dispatch:worker_down(MonRef, Reason, disp(Data)), Data
        )};
established(info, Info, Data) ->
    handle_established_socket(Info, Data);
established(EventType, Event, Data) ->
    handle_common(EventType, Event, established, Data).

%% =============================================================================
%% GEN_STATEM (terminate / status)
%% =============================================================================

terminate(_Reason, StateName, Data) ->
    _ = disable_net_monitor(Data#data.net_monitor),
    _ = maybe_goodbye(StateName, Data),
    _ = close_transport(Data),
    _ = reply_pending({error, disconnected}, Data),
    _ = reply_waiters({error, disconnected}, Data),
    %% Free the rate-limiter's ETS row (no-op when no `rate` is configured).
    _ = bondy_connect_dispatch:delete(Data#data.dispatch),
    ok.

format_status(Status) ->
    maps:map(fun redact/2, Status).

%% =============================================================================
%% PRIVATE — common event handling
%% =============================================================================

%% @private
handle_common({call, From}, status, StateName, Data) ->
    {keep_state, Data, [{reply, From, public_status(StateName, Data)}]};
handle_common({call, From}, await_ready, _StateName, Data) ->
    {keep_state, add_waiter(From, Data)};
handle_common({call, From}, Request, _StateName, Data) when
    is_tuple(Request), element(1, Request) == call;
    is_tuple(Request), element(1, Request) == call_async;
    is_tuple(Request), element(1, Request) == cancel;
    is_tuple(Request), element(1, Request) == register;
    is_tuple(Request), element(1, Request) == unregister;
    is_tuple(Request), element(1, Request) == subscribe;
    is_tuple(Request), element(1, Request) == unsubscribe;
    is_tuple(Request), element(1, Request) == publish
->
    %% A role request before the session is established.
    {keep_state, Data, [{reply, From, {error, not_established}}]};
handle_common({call, From}, _Request, _StateName, Data) ->
    {keep_state, Data, [{reply, From, {error, badcall}}]};
%% Network monitor signals: while not in connecting/waiting_for_network the
%% socket status takes priority, so we ignore them here (a real drop arrives as
%% a transport close/error).
handle_common(info, {network_disconnected, _}, _StateName, Data) ->
    {keep_state, Data};
handle_common(info, {network_connected, _}, _StateName, Data) ->
    {keep_state, Data};
%% A transport `info` message reaching a state that does not actively read the
%% socket (e.g. handshaking): classify it via the transport so a closed/errored
%% link still triggers reconnect rather than being silently dropped.
handle_common(info, Info, _StateName, #data{transport = T} = Data) when
    T =/= undefined
->
    #data{transport_mod = Mod} = Data,
    case Mod:handle_info(Info, T) of
        {ok, _Records, T1} ->
            {keep_state, Data#data{transport = T1}};
        {error, Reason, T1} ->
            on_transport_failure(Reason, Data#data{transport = T1});
        closed ->
            on_transport_failure(connection_closed, Data);
        ignore ->
            {keep_state, Data}
    end;
handle_common(_EventType, _Event, _StateName, Data) ->
    {keep_state, Data}.

%% @private Process an inbound transport `info` message into records and route
%% them. The transport (not the connection) knows its own message-tag shapes and
%% re-arms its flow control, so this is transport-agnostic.
handle_socket(Info, StateName, Data) ->
    #data{transport_mod = Mod, transport = T0} = Data,
    case Mod:handle_info(Info, T0) of
        {ok, Records, T1} ->
            process_records(Records, StateName, Data#data{transport = T1});
        {error, Reason, T1} ->
            on_transport_failure(Reason, Data#data{transport = T1});
        closed ->
            on_transport_failure(connection_closed, Data);
        ignore ->
            {next_state, StateName, Data}
    end.

%% @private Process an inbound transport `info` message in the `established'
%% state and reset the idle keepalive — inbound traffic proves the link is alive.
%% Protocol-level stops (GOODBYE/ABORT) and reconnect transitions pass straight
%% through; an `ignore`d (non-transport) message must NOT reset the keepalive.
handle_established_socket(Info, Data) ->
    #data{transport_mod = Mod, transport = T0} = Data,
    case Mod:handle_info(Info, T0) of
        {ok, Records, T1} ->
            case
                process_records(Records, established, Data#data{transport = T1})
            of
                {next_state, established, Data1} ->
                    KA1 = bondy_connect_keepalive:on_activity(
                        Data1#data.keepalive
                    ),
                    Data2 = Data1#data{keepalive = KA1},
                    {keep_state, Data2,
                        bondy_connect_keepalive:reset_actions(KA1)};
                Result ->
                    Result
            end;
        {error, Reason, T1} ->
            on_transport_failure(Reason, Data#data{transport = T1});
        closed ->
            on_transport_failure(connection_closed, Data);
        ignore ->
            {keep_state, Data}
    end.

%% =============================================================================
%% PRIVATE — record routing
%% =============================================================================

%% @private
process_records([], StateName, Data) ->
    {next_state, StateName, Data};
process_records([Record | Rest], StateName, Data) ->
    case route(Record, StateName, Data) of
        {continue, StateName1, Data1} ->
            process_records(Rest, StateName1, Data1);
        {stop, Reason, Data1} ->
            on_protocol_stop(Reason, Data1)
    end.

%% @private The protocol layer asked to stop. A router ABORT is not
%% automatically fatal: the router tells us in the message whether it is —
%% `bondy_error`'s `nature` key is `transient` when retrying unchanged could
%% succeed. The HELLO load-admission gate is exactly that case; it sheds new
%% sessions under deep run queues with `wamp.error.unavailable`, expecting
%% well-behaved clients to back off and come back (possibly landing on another
%% node via their load balancer).
%%
%% Routing a transient abort through the ordinary failure path is what gets it
%% the backoff loop. Stopping here unconditionally — which is what this used to
%% do — bypassed `is_retriable/1` and `reconnect_allowed/2` entirely, so EVERY
%% abort killed the connection for good, including the one the router had
%% explicitly marked retryable.
on_protocol_stop(Reason, Data) ->
    case find_abort(Reason) of
        {ok, {abort, Uri, Details} = Abort} ->
            case is_transient_abort(Uri, Details) of
                true -> on_transport_failure(Abort, Data);
                false -> {stop, Reason, Data}
            end;
        error ->
            {stop, Reason, Data}
    end.

%% @private Dig the `{abort, Uri, Details}` payload out of a protocol stop
%% reason.
%%
%% `bondy_connect_protocol:handle_message/2` already wraps the abort in
%% `shutdown`, and `route_handshake/3` wraps the result again, so the reason
%% actually arrives as `{shutdown, {shutdown, {abort, _, _}}}`. Recursing on the
%% wrapper instead of matching a fixed nesting depth means adding or removing a
%% layer cannot silently turn a retryable refusal back into a fatal one — which
%% is precisely the bug this function exists to have fixed once.
find_abort({abort, _, _} = Abort) -> {ok, Abort};
find_abort({shutdown, Inner}) -> find_abort(Inner);
find_abort(_) -> error.

%% @private
%% Control frames. An inbound ping (router keepalive) is answered with a pong; a
%% pong (our keepalive answered) needs no record-level handling — the idle timer
%% and ping retry are reset by `handle_established_socket/2` for any inbound data.
route({ping, Payload}, StateName, Data) ->
    _ = pong_send(Payload, Data),
    {continue, StateName, Data};
route({pong, _Payload}, StateName, Data) ->
    {continue, StateName, Data};
route(Record, established, Data) ->
    route_established(Record, Data);
route(Record, StateName, Data) ->
    route_handshake(Record, StateName, Data).

%% @private Drive the protocol layer during the handshake states.
route_handshake(Record, StateName, Data) ->
    case bondy_connect_protocol:handle_message(Record, Data#data.protocol) of
        {reply, OutMsgs, P1} ->
            Data1 = Data#data{protocol = P1},
            case send_all(OutMsgs, Data1) of
                ok -> {continue, StateName, Data1};
                {error, R} -> {stop, {shutdown, {send_error, R}}, Data1}
            end;
        {established, Session, P1} ->
            {continue, established, Data#data{protocol = P1, session = Session}};
        {stop, Reason, OutMsgs, P1} ->
            Data1 = Data#data{protocol = P1},
            _ = send_all(OutMsgs, Data1),
            {stop, {shutdown, Reason}, Data1};
        {passthrough, _Msg, P1} ->
            {continue, StateName, Data#data{protocol = P1}}
    end.

%% @private Route inbound records in the established state.
route_established(Record, Data) ->
    case bondy_connect_protocol:handle_message(Record, Data#data.protocol) of
        {passthrough, Msg, P1} ->
            route_app(Msg, Data#data{protocol = P1});
        {stop, Reason, OutMsgs, P1} ->
            Data1 = Data#data{protocol = P1},
            _ = send_all(OutMsgs, Data1),
            {stop, {shutdown, Reason}, Data1};
        {reply, OutMsgs, P1} ->
            Data1 = Data#data{protocol = P1},
            _ = send_all(OutMsgs, Data1),
            {continue, established, Data1}
    end.

%% @private Application-message routing.
route_app(#result{request_id = ReqId, details = Details} = R, Data) ->
    case maps:get(progress, Details, false) of
        true ->
            %% A progressive RESULT does not settle the pending CALL.
            {continue, established,
                notify_progress(ReqId, result_payload(R), Data)};
        false ->
            Data1 = resolve_pending(ReqId, {ok, result_payload(R)}, Data),
            {continue, established, Data1}
    end;
route_app(#error{request_type = ?CALL, request_id = ReqId} = E, Data) ->
    Data1 = resolve_pending(ReqId, {error, error_payload(E)}, Data),
    {continue, established, Data1};
route_app(#registered{request_id = ReqId, registration_id = RegId}, Data) ->
    {continue, established, confirm_registration(ReqId, RegId, Data)};
route_app(#subscribed{request_id = ReqId, subscription_id = SubId}, Data) ->
    {continue, established, confirm_subscription(ReqId, SubId, Data)};
route_app(#unregistered{request_id = ReqId}, Data) when ReqId =/= 0 ->
    {continue, established, confirm_unregister(ReqId, Data)};
route_app(#unregistered{request_id = 0, details = Details}, Data) ->
    %% Unsolicited UNREGISTERED — the router revoked one of our registrations
    %% (registration_revocation, advanced profile). Drop it from the registry.
    {continue, established, handle_revocation(Details, Data)};
route_app(#unsubscribed{request_id = ReqId}, Data) ->
    {continue, established, confirm_unsubscribe(ReqId, Data)};
route_app(#published{request_id = ReqId, publication_id = PubId}, Data) ->
    {continue, established, resolve_pending(ReqId, {ok, PubId}, Data)};
route_app(#error{request_id = ReqId} = E, Data) ->
    %% REGISTER/SUBSCRIBE/UNREGISTER/UNSUBSCRIBE/PUBLISH failure.
    {continue, established,
        resolve_pending(ReqId, {error, error_payload(E)}, Data)};
route_app(#invocation{} = Msg, Data) ->
    {continue, established, handle_invocation(Msg, Data)};
route_app(#event{} = Msg, Data) ->
    {continue, established, handle_event(Msg, Data)};
route_app(#interrupt{request_id = InvReqId, options = Opts}, Data) ->
    %% The router is cancelling an in-flight INVOCATION we are servicing.
    {continue, established, handle_interrupt(InvReqId, Opts, Data)};
route_app(Other, Data) ->
    %% Never-assert backstop: any other inbound application record (e.g. an
    %% advanced feature we do not implement) is ignored rather than crashing
    %% the connection — but logged so it is observable rather than silent.
    ?LOG_DEBUG(#{
        description => "Ignoring unhandled inbound application message.",
        message => element(1, Other)
    }),
    {continue, established, Data}.

%% =============================================================================
%% PRIVATE — outbound role requests
%% =============================================================================

%% @private (synchronous CALL — reply is deferred to RESULT/ERROR)
do_call(From, Uri, Args, KWArgs, Opts, Data) ->
    Data1 = do_request(
        call,
        From,
        call_msg(Uri, Args, KWArgs, Opts),
        call_timeout(Opts),
        #{},
        Data
    ),
    {keep_state, Data1}.

%% @private Cancel an in-flight async call. We find the pending CALL whose async
%% token matches and send a CANCEL with the requested mode; the pending entry is
%% left in place and is resolved by the resulting ERROR(canceled) the router
%% sends back. `From` is replied to synchronously (`ok` / `{error, _}`).
do_cancel(From, Token, Mode, Data) ->
    case cancel_mode(Mode) of
        {ok, ModeBin} ->
            case find_async_call(Token, Data) of
                {ok, ReqId} ->
                    Msg = bondy_wamp_message:cancel(ReqId, #{mode => ModeBin}),
                    Reply =
                        case send_msg(Msg, Data) of
                            ok -> ok;
                            {error, R} -> {error, R}
                        end,
                    {keep_state, Data, [{reply, From, Reply}]};
                error ->
                    {keep_state, Data, [{reply, From, {error, unknown_call}}]}
            end;
        error ->
            {keep_state, Data, [{reply, From, {error, invalid_cancel_mode}}]}
    end.

%% @private Resolve a `call_async` token to its pending CALL request id via the
%% O(1) secondary index (review C1), avoiding an O(n) scan of `pending` on every
%% cancel/3. The index is maintained in lockstep by store/resolve/timeout/reply.
find_async_call(Token, #data{async_index = Index}) ->
    maps:find(Token, Index).

%% @private
%% Send a subsequent (or final) argument chunk of a progressive call, reusing the
%% stream's request id and procedure URI (stashed on the pending entry). Does NOT
%% create a pending entry or bump the request-id counter — the terminal
%% RESULT/ERROR settles the single entry created by the first chunk. `ChunkOpts`
%% carries `progress => true` for a non-final chunk and is empty for the final.
send_input_chunk(Token, Args, KWArgs, ChunkOpts, Data) ->
    case find_async_call(Token, Data) of
        {ok, ReqId} ->
            case peek_pending(ReqId, Data) of
                {ok, #{meta := #{stream_uri := Uri}}} ->
                    Msg = set_request_id(
                        call_msg(Uri, Args, KWArgs, ChunkOpts), ReqId
                    ),
                    _ = send_msg(Msg, Data),
                    ok;
                _ ->
                    {error, not_a_progressive_call}
            end;
        error ->
            {error, unknown_token}
    end.

%% @private
cancel_mode(skip) -> {ok, <<"skip">>};
cancel_mode(kill) -> {ok, <<"kill">>};
cancel_mode(killnowait) -> {ok, <<"killnowait">>};
cancel_mode(_) -> error.

%% @private
do_register(From, Uri, Handler, Opts, Data) ->
    case bondy_connect_handler_spec:validate(Handler) of
        ok ->
            WireOpts = maps:with(
                [match, invoke, concurrency, disclose_caller, force_reregister],
                Opts
            ),
            Reg1 = bondy_connect_registry:declare_registration(
                Uri, Handler, Opts, Data#data.registry
            ),
            send_request(
                register,
                From,
                fun(ReqId) ->
                    bondy_wamp_message:register(ReqId, WireOpts, Uri)
                end,
                ?DEFAULT_ADMIN_TIMEOUT,
                #{uri => Uri},
                Data#data{registry = Reg1}
            );
        {error, _} = Error ->
            {keep_state, Data, [{reply, From, Error}]}
    end.

%% @private
do_unregister(From, RegRef, Data) ->
    case resolve_registration(RegRef, Data) of
        {ok, RegId} ->
            send_request(
                unregister,
                From,
                fun(ReqId) -> bondy_wamp_message:unregister(ReqId, RegId) end,
                ?DEFAULT_ADMIN_TIMEOUT,
                #{reg_id => RegId},
                Data
            );
        error ->
            {keep_state, Data, [{reply, From, {error, no_such_registration}}]}
    end.

%% @private
do_subscribe(From, Topic, Handler, Opts, Data) ->
    case bondy_connect_handler_spec:validate(Handler) of
        ok ->
            WireOpts = maps:with([match, get_retained, nkey], Opts),
            Reg1 = bondy_connect_registry:declare_subscription(
                Topic, Handler, Opts, Data#data.registry
            ),
            send_request(
                subscribe,
                From,
                fun(ReqId) ->
                    bondy_wamp_message:subscribe(ReqId, WireOpts, Topic)
                end,
                ?DEFAULT_ADMIN_TIMEOUT,
                #{uri => Topic},
                Data#data{registry = Reg1}
            );
        {error, _} = Error ->
            {keep_state, Data, [{reply, From, Error}]}
    end.

%% @private
do_unsubscribe(From, SubRef, Data) ->
    case resolve_subscription(SubRef, Data) of
        {ok, SubId} ->
            send_request(
                unsubscribe,
                From,
                fun(ReqId) -> bondy_wamp_message:unsubscribe(ReqId, SubId) end,
                ?DEFAULT_ADMIN_TIMEOUT,
                #{sub_id => SubId},
                Data
            );
        error ->
            {keep_state, Data, [{reply, From, {error, no_such_subscription}}]}
    end.

%% @private
do_publish(From, Topic, Args, KWArgs, Opts, Data) ->
    WireOpts = maps:with(
        [
            acknowledge,
            exclude,
            exclude_me,
            exclude_authid,
            exclude_authrole,
            eligible,
            eligible_authid,
            eligible_authrole,
            disclose_me,
            retain
        ],
        Opts
    ),
    case maps:get(acknowledge, Opts, false) of
        true ->
            send_request(
                publish,
                From,
                fun(ReqId) ->
                    bondy_wamp_message:publish(
                        ReqId, WireOpts, Topic, Args, KWArgs
                    )
                end,
                ?DEFAULT_ADMIN_TIMEOUT,
                #{},
                Data
            );
        false ->
            #data{next_request_id = ReqId} = Data,
            Msg = bondy_wamp_message:publish(
                ReqId, WireOpts, Topic, Args, KWArgs
            ),
            Reply =
                case send_msg(Msg, Data) of
                    ok -> ok;
                    {error, R} -> {error, R}
                end,
            Data1 = Data#data{next_request_id = next_id(ReqId)},
            {keep_state, Data1, [{reply, From, Reply}]}
    end.

%% @private Build the message with the next id, send it, and (on success) store
%% a pending entry replying to `From` on the matching ack. Used by the admin
%% roles (register/subscribe/...). The reply to `From` is deferred.
send_request(Type, From, MsgFun, Timeout, Meta, Data) ->
    #data{next_request_id = ReqId} = Data,
    Msg = MsgFun(ReqId),
    case send_msg(Msg, Data) of
        ok ->
            Data1 = store_pending(
                ReqId,
                #{type => Type, from => {sync, From}, meta => Meta},
                Timeout,
                Data#data{next_request_id = next_id(ReqId)}
            ),
            {keep_state, Data1};
        {error, Reason} ->
            {keep_state, Data, [{reply, From, {error, Reason}}]}
    end.

%% @private Lower-level: send an already-built CALL and store pending (used by
%% sync + async calls, where the reply target differs).
do_request(Type, ReplyTo, Msg, Timeout, Meta, Data) ->
    #data{next_request_id = ReqId} = Data,
    Msg1 = set_request_id(Msg, ReqId),
    case send_msg(Msg1, Data) of
        ok ->
            store_pending(
                ReqId,
                #{type => Type, from => ReplyTo, meta => Meta},
                Timeout,
                Data#data{next_request_id = next_id(ReqId)}
            );
        {error, Reason} ->
            _ = dispatch_reply(ReplyTo, {error, Reason}),
            Data
    end.

%% =============================================================================
%% PRIVATE — inbound ack handling
%% =============================================================================

%% @private
confirm_registration(ReqId, RegId, Data) ->
    case peek_pending(ReqId, Data) of
        {ok, #{meta := #{uri := Uri}}} ->
            Reg1 = bondy_connect_registry:confirm_registration(
                Uri, RegId, Data#data.registry
            ),
            resolve_pending(ReqId, {ok, RegId}, Data#data{registry = Reg1});
        _ ->
            Data
    end.

%% @private
confirm_subscription(ReqId, SubId, Data) ->
    case peek_pending(ReqId, Data) of
        {ok, #{meta := #{uri := Uri}}} ->
            Reg1 = bondy_connect_registry:confirm_subscription(
                Uri, SubId, Data#data.registry
            ),
            resolve_pending(ReqId, {ok, SubId}, Data#data{registry = Reg1});
        _ ->
            Data
    end.

%% @private
confirm_unregister(ReqId, Data) ->
    case peek_pending(ReqId, Data) of
        {ok, #{type := unregister, meta := #{reg_id := RegId}}} ->
            Reg1 = bondy_connect_registry:undeclare_registration(
                RegId, Data#data.registry
            ),
            resolve_pending(ReqId, ok, Data#data{registry = Reg1});
        _ ->
            Data
    end.

%% @private
confirm_unsubscribe(ReqId, Data) ->
    case peek_pending(ReqId, Data) of
        {ok, #{type := unsubscribe, meta := #{sub_id := SubId}}} ->
            Reg1 = bondy_connect_registry:undeclare_subscription(
                SubId, Data#data.registry
            ),
            Data1 = run_dispatch(
                bondy_connect_dispatch:clear_subscription(SubId, disp(Data)),
                Data
            ),
            resolve_pending(ReqId, ok, Data1#data{registry = Reg1});
        _ ->
            Data
    end.

%% @private An unsolicited UNREGISTERED carries the revoked registration id in
%% its details (`#{registration => RegId}`). Drop only the *established* state
%% (`forget_registration/2`); the *declared* entry is kept so the registration
%% re-establishes on the next reconnect. A router revocation is scoped to the
%% current session — Bondy has no durable sessions — so it must not survive a
%% reconnect. Until then, inbound INVOCATIONs for it are answered with
%% `no_such_registration`.
handle_revocation(Details, Data) when is_map(Details) ->
    case revoked_registration_id(Details) of
        {ok, RegId} ->
            Reg1 = bondy_connect_registry:forget_registration(
                RegId, Data#data.registry
            ),
            Data#data{registry = Reg1};
        error ->
            Data
    end;
handle_revocation(_Details, Data) ->
    Data.

%% @private Read the revoked registration id from the details (atom key from the
%% decoder, binary key as a defensive fallback).
revoked_registration_id(Details) ->
    case maps:find(registration, Details) of
        {ok, Id} when is_integer(Id) ->
            {ok, Id};
        _ ->
            case maps:find(<<"registration">>, Details) of
                {ok, Id} when is_integer(Id) -> {ok, Id};
                _ -> error
            end
    end.

%% =============================================================================
%% PRIVATE — callee (INVOCATION)
%% =============================================================================

%% @private The connection finds the registration and builds the Job; the
%% dispatch helper charges the load regulator and decides whether to spawn a
%% worker (or answer the router with `no_such_registration`/`unavailable`).
handle_invocation(#invocation{} = Msg, Data) ->
    #invocation{
        request_id = ReqId,
        registration_id = RegId,
        details = Details,
        args = Args,
        kwargs = KWArgs
    } = Msg,
    case bondy_connect_dispatch:has_invocation(ReqId, disp(Data)) of
        true ->
            %% A subsequent argument chunk of a progressive-input call: route it
            %% to the worker already servicing this invocation rather than
            %% spawning a second one (the router reuses the invocation id for
            %% every chunk of the stream).
            _ = route_input_chunk(ReqId, Details, Args, KWArgs, Data),
            Data;
        false ->
            case
                bondy_connect_registry:registration(RegId, Data#data.registry)
            of
                {ok, #{handler := Handler}} ->
                    Job = #{
                        kind => invocation,
                        conn => self(),
                        req_id => ReqId,
                        handler => Handler,
                        args => undefined_to(Args, []),
                        kwargs => undefined_to(KWArgs, #{}),
                        details => Details
                    },
                    run_dispatch(
                        bondy_connect_dispatch:admit_invocation(
                            ReqId, Job, disp(Data)
                        ),
                        Data
                    );
                error ->
                    Err = bondy_wamp_message:error(
                        ?INVOCATION, ReqId, #{}, ?WAMP_NO_SUCH_REGISTRATION
                    ),
                    _ = send_msg(Err, Data),
                    Data
            end
    end.

%% @private
%% Deliver a progressive-input argument chunk to the worker already servicing the
%% invocation. `progress => true` in the details marks a non-final chunk; its
%% absence marks the final one (input complete). If the worker is gone (e.g. the
%% invocation was interrupted) the chunk is dropped.
route_input_chunk(ReqId, Details, Args, KWArgs, Data) ->
    IsFinal = not maps:get(progress, Details, false),
    case bondy_connect_dispatch:worker_pid(ReqId, disp(Data)) of
        {ok, Pid} ->
            Pid !
                {handler_input, undefined_to(Args, []),
                    undefined_to(KWArgs, #{}), IsFinal},
            ok;
        {error, not_found} ->
            ok
    end.

%% @private The router asked us to cancel an in-flight INVOCATION (the caller
%% issued a CANCEL with mode `kill`/`killnowait`). The dispatch helper cancels
%% **forcefully** — emitting a `{kill, Pid}` for the servicing worker and an
%% `ERROR(?INTERRUPT, canceled)` (cooperative interruption is future work).
%% Unknown/already-finished invocations are ignored.
handle_interrupt(InvReqId, Opts, Data) ->
    run_dispatch(
        bondy_connect_dispatch:interrupt(InvReqId, Opts, disp(Data)), Data
    ).

%% =============================================================================
%% PRIVATE — subscriber (EVENT), per-subscription FIFO
%% =============================================================================

%% @private The connection finds the subscription and builds the Job; the
%% dispatch helper enforces per-subscription FIFO (or fires unordered).
handle_event(#event{} = Msg, Data) ->
    #event{
        subscription_id = SubId,
        details = Details,
        args = Args,
        kwargs = KWArgs
    } = Msg,
    case bondy_connect_registry:subscription(SubId, Data#data.registry) of
        {ok, #{handler := Handler, options := Opts}} ->
            Job = #{
                kind => event,
                conn => self(),
                sub_id => SubId,
                handler => Handler,
                args => undefined_to(Args, []),
                kwargs => undefined_to(KWArgs, #{}),
                details => Details
            },
            run_dispatch(
                bondy_connect_dispatch:dispatch_event(
                    SubId, maps:get(ordered, Opts, true), Job, disp(Data)
                ),
                Data
            );
        error ->
            Data
    end.

%% =============================================================================
%% PRIVATE — dispatch effect interpreter + worker lifecycle
%% =============================================================================

%% @private Read/write the opaque dispatch state out of/into the statem data.
disp(#data{dispatch = D}) -> D.

store_dispatch(D, Data) -> Data#data{dispatch = D}.

%% @private Interpret a dispatch step: apply its effects (an event spawn may
%% recurse to drain the FIFO, mirroring the pre-A2 `next_event/4` recursion) and
%% store the resulting dispatch state back into the statem data.
run_dispatch({D, Effects}, Data) ->
    {D1, Data1} = lists:foldl(fun apply_effect/2, {D, Data}, Effects),
    store_dispatch(D1, Data1).

%% @private
apply_effect({send, Msg}, {D, Data}) ->
    _ = send_msg(Msg, Data),
    {D, Data};
apply_effect({spawn_nomon, Job}, {D, Data}) ->
    _ = start_worker_nomon(Job, Data),
    {D, Data};
apply_effect({kill, Pid}, {D, Data}) ->
    _ = exit(Pid, kill),
    {D, Data};
apply_effect({spawn, Tag, Key, Job}, {D0, Data}) ->
    %% The connection owns the spawn+monitor; feed the result back so the helper
    %% records the monitor (or releases the load / advances the FIFO on failure).
    Res = start_worker(Job, Data),
    {D1, Effects} = bondy_connect_dispatch:worker_started(Tag, Key, Res, D0),
    lists:foldl(fun apply_effect/2, {D1, Data}, Effects).

%% @private Start (and monitor) a handler worker. Returns `{error, _}` rather
%% than crashing on a `start_child` failure — a failed worker start must not take
%% down the connection (and, via the `one_for_all` conn_sup, every other
%% in-flight worker). The dispatch helper handles the error like the worker-DOWN
%% path: release the load token, synthesize an ERROR / advance the FIFO (review
%% B1).
start_worker(Job, #data{handler_sup = HSup}) ->
    case bondy_connect_handler_sup:start_worker(HSup, Job) of
        {ok, Pid} ->
            MonRef = erlang:monitor(process, Pid),
            {ok, {Pid, MonRef}};
        {error, _} = Error ->
            Error
    end.

%% @private
start_worker_nomon(Job, #data{handler_sup = HSup}) ->
    bondy_connect_handler_sup:start_worker(HSup, Job).

%% =============================================================================
%% PRIVATE — pending / correlation
%% =============================================================================

%% @private
store_pending(ReqId, Entry0, Timeout, Data) ->
    TRef = erlang:start_timer(Timeout, self(), {req_timeout, ReqId}),
    Entry = Entry0#{timer => TRef},
    Data#data{
        pending = maps:put(ReqId, Entry, Data#data.pending),
        async_index = index_async(Entry, ReqId, Data#data.async_index)
    }.

%% @private
peek_pending(ReqId, #data{pending = Pending}) ->
    maps:find(ReqId, Pending).

%% @private
resolve_pending(ReqId, Reply, #data{pending = Pending} = Data) ->
    case maps:take(ReqId, Pending) of
        {#{from := From, timer := TRef} = Entry, Pending1} ->
            _ = cancel_timer(TRef),
            _ = dispatch_reply(From, Reply),
            Data#data{
                pending = Pending1,
                async_index = unindex_async(Entry, Data#data.async_index)
            };
        error ->
            Data
    end.

%% @private A progressive RESULT for a pending CALL: deliver a
%% `{progress, Payload}` notification to the async owner and re-arm the
%% entry's timer — per the WAMP spec a progressive call's timeout is the
%% limit between results, so each progressive result restarts it (capped
%% by the `_deadline` option when given); the final RESULT/ERROR settles
%% the entry. Sync calls never request progressive results (call/5
%% rejects the option), so a progressive RESULT for a sync or unmarked
%% entry means the router sent progress we did not ask for: drop it
%% rather than surface an unexpected reply shape.
notify_progress(ReqId, Payload, #data{pending = Pending} = Data) ->
    case maps:find(ReqId, Pending) of
        {ok,
            #{
                from := {async, Pid, Token},
                meta := #{receive_progress := true},
                timer := TRef
            } = Entry} ->
            Pid ! {bondy_connect, Token, {progress, Payload}},
            _ = cancel_timer(TRef),
            Entry1 = Entry#{timer := restart_req_timer(ReqId, Entry)},
            Data#data{pending = maps:put(ReqId, Entry1, Pending)};
        {ok, _} ->
            ?LOG_DEBUG(#{
                description =>
                    "Ignoring progressive RESULT for a call that did not "
                    "request progressive results.",
                request_id => ReqId
            }),
            Data;
        error ->
            Data
    end.

%% @private Re-arm a progressive entry's inactivity timer: the per-call
%% timeout, capped so it never fires later than the call's absolute
%% deadline (when one was given).
restart_req_timer(ReqId, #{meta := Meta}) ->
    Timeout = maps:get(timeout, Meta, ?DEFAULT_CALL_TIMEOUT),
    After =
        case maps:get(deadline, Meta, infinity) of
            infinity ->
                Timeout;
            Deadline ->
                Remaining = Deadline - erlang:monotonic_time(millisecond),
                max(0, min(Timeout, Remaining))
        end,
    erlang:start_timer(After, self(), {req_timeout, ReqId}).

%% @private A per-request timeout fired before its ack/result arrived. Bypasses
%% resolve_pending/3 (there is no router ERROR to interpret), so the reply is
%% tagged here rather than relying on error_payload/1 — this is the only
%% client-side error that reaches an async owner directly (call_async/5's own
%% immediate `{ok, Token}`/`{error, _}` is tagged at its own boundary; this is
%% the *delivered* terminal message for an async entry, or the sync reply for
%% a sync one).
handle_req_timeout(ReqId, TRef, #data{pending = Pending} = Data) ->
    case maps:find(ReqId, Pending) of
        {ok, #{timer := TRef, from := From} = Entry} ->
            _ = dispatch_reply(From, tag_error({error, timeout})),
            Data#data{
                pending = maps:remove(ReqId, Pending),
                async_index = unindex_async(Entry, Data#data.async_index)
            };
        _ ->
            Data
    end.

%% @private Add a `call_async' entry's token to the secondary index (review C1).
%% Non-async entries (`sync`/`undefined' from) carry no token and are skipped.
index_async(#{from := {async, _, Token}}, ReqId, Index) ->
    maps:put(Token, ReqId, Index);
index_async(_Entry, _ReqId, Index) ->
    Index.

%% @private Drop a removed entry's token from the secondary index (review C1).
unindex_async(#{from := {async, _, Token}}, Index) ->
    maps:remove(Token, Index);
unindex_async(_Entry, Index) ->
    Index.

%% @private
dispatch_reply({sync, From}, Reply) ->
    gen_statem:reply(From, Reply);
dispatch_reply({async, Pid, Token}, Reply) ->
    Pid ! {bondy_connect, Token, Reply},
    ok;
dispatch_reply(undefined, _Reply) ->
    ok.

%% @private Fail every pending call/call_async/call_stream/register/
%% subscribe/unregister/unsubscribe/publish_ack entry with `Reply` (a
%% teardown-time bare client-side reason, e.g. `disconnected`) — tagged here
%% for the same reason as handle_req_timeout/3: this bypasses
%% resolve_pending/3, so there is no error_payload/1 to have already tagged
%% it.
reply_pending(Reply, #data{pending = Pending} = Data) ->
    Tagged = tag_error(Reply),
    _ = [
        begin
            _ = cancel_timer(maps:get(timer, E, undefined)),
            dispatch_reply(maps:get(from, E, undefined), Tagged)
        end
     || E <- maps:values(Pending)
    ],
    Data#data{pending = #{}, async_index = #{}}.

%% @private
cancel_timer(undefined) ->
    ok;
cancel_timer(TRef) ->
    _ = erlang:cancel_timer(TRef),
    ok.

%% =============================================================================
%% PRIVATE — helpers
%% =============================================================================

%% @private Terminal failure: reply outstanding waiters/pending with the error
%% and stop. The supervisor will not restart us (transient + shutdown); the
%% manager's monitor tears down the per-connection supervisor.
stop_fail(Reason, Data) ->
    ?LOG_WARNING(#{
        description => "Connection giving up.",
        reason => Reason
    }),
    Data1 = reply_waiters({error, Reason}, Data),
    Data2 = reply_pending({error, Reason}, Data1),
    {stop, {shutdown, Reason}, Data2}.

%% =============================================================================
%% PRIVATE — resilience (reconnect / backoff / network)
%% =============================================================================

%% @private A connect attempt failed *while in `connecting'* — loop with backoff
%% (or park on the network / give up).
on_connect_failure(Reason, Data) ->
    case reconnect_allowed(Reason, Data) andalso is_retriable(Reason) of
        true ->
            case is_netdown(Reason) andalso Data#data.net_monitor of
                true -> {next_state, waiting_for_network, Data};
                false -> backoff_retry(Reason, Data)
            end;
        false ->
            stop_fail(Reason, Data)
    end.

%% @private A transport failure *outside* `connecting' (lost link, ping timeout,
%% handshake/establish failure). Tear down the session, then reconnect (or park
%% on the network / give up). The reconnect re-enters `connecting', which resets
%% the retry budget and attempts immediately; subsequent attempts back off.
on_transport_failure(Reason, Data0) ->
    Data = teardown_session(Data0),
    case reconnect_allowed(Reason, Data) andalso is_retriable(Reason) of
        true ->
            ?LOG_NOTICE(#{
                description => "Session dropped; reconnecting.",
                reason => Reason
            }),
            case is_netdown(Reason) andalso Data#data.net_monitor of
                true ->
                    {next_state, waiting_for_network, Data};
                false ->
                    reconnect_after_failure(Reason, Data)
            end;
        false ->
            stop_fail(Reason, Data)
    end.

%% @private A dropped LINK is one episode: re-entering `connecting' resets the
%% budget and reconnects at once, which is what you want — the next attempt
%% either works or starts backing off through `on_connect_failure/2'.
%%
%% A refused HANDSHAKE is not that. The transport connect SUCCEEDS every time
%% (the router is up, it is shedding), so `on_connect_failure/2' — the only
%% caller of `backoff_retry/2' — is never reached. Left as a plain transition
%% each refusal would reset the budget and re-dial on a 0ms timer, i.e. a
%% full-speed reconnect loop against a router that is already overloaded. That
%% is the exact storm the load gate exists to stop, so a refusal has to advance
%% the same `bondy_retry' ladder (jittered by default) that every other failure
%% uses, and carry the delay into `connecting'.
reconnect_after_failure({abort, _, _} = Reason, Data) ->
    backoff_into_connecting(Reason, Data);
reconnect_after_failure(_Reason, Data) ->
    {next_state, connecting, Data}.

%% @private
backoff_into_connecting(Reason, #data{reconnect_retry = R0} = Data) ->
    case bondy_retry:fail(R0) of
        {Delay, R1} when is_integer(Delay) ->
            ?LOG_NOTICE(#{
                description =>
                    "Router refused the session; will retry after delay.",
                delay => Delay,
                reason => Reason
            }),
            {next_state, connecting, Data#data{
                reconnect_retry = R1, pending_delay = Delay
            }};
        {Limit, R1} when Limit == deadline; Limit == max_retries ->
            stop_fail({reconnect_failed, Reason}, Data#data{
                reconnect_retry = R1
            })
    end.

%% @private The backoff loop within `connecting': advance the retry state and
%% schedule the next attempt, or give up once the budget is exhausted.
backoff_retry(Reason, #data{reconnect_retry = R0} = Data) ->
    case bondy_retry:fail(R0) of
        {Delay, R1} when is_integer(Delay) ->
            ?LOG_NOTICE(#{
                description => "Failed to connect; will retry after delay.",
                delay => Delay,
                reason => Reason
            }),
            {keep_state, Data#data{reconnect_retry = R1}, [
                {state_timeout, Delay, connect}
            ]};
        {Limit, R1} when Limit == deadline; Limit == max_retries ->
            stop_fail({reconnect_failed, Reason}, Data#data{
                reconnect_retry = R1
            })
    end.

%% @private Reconnect is allowed when it is enabled and either we have already
%% established once (a genuine drop) or the user opted into retrying the initial
%% connect.
reconnect_allowed(_Reason, #data{reconnect_retry = undefined}) ->
    false;
reconnect_allowed(_Reason, #data{established_once = true}) ->
    true;
reconnect_allowed(_Reason, #data{retry_initial = true}) ->
    true;
reconnect_allowed({abort, _, _}, #data{}) ->
    %% `retry_initial_connect` defaults to `false` so that a MISCONFIGURED
    %% `connect/1` — wrong URL, wrong realm, bad credentials — fails fast
    %% instead of disappearing into a backoff loop. A transient ABORT is the
    %% opposite of a misconfiguration: nothing about the request is wrong, and
    %% the router has said so in the message. Honouring fail-fast here would
    %% make every client give up at precisely the moment the router is
    %% shedding load — which is when retrying is the whole point, and which is
    %% overwhelmingly a FIRST connect (a fleet coming up against a busy
    %% cluster). Permanent aborts do not reach this clause: the caller's
    %% `is_retriable/1` has already rejected them.
    true;
reconnect_allowed(_Reason, #data{}) ->
    false.

%% @private
reset_reconnect_retry(#data{reconnect_retry = undefined} = Data) ->
    Data;
reset_reconnect_retry(#data{reconnect_retry = R} = Data) ->
    {_, R1} = bondy_retry:succeed(R),
    Data#data{reconnect_retry = R1}.

%% @private
init_reconnect_retry(#{enabled := true} = Opts) ->
    bondy_retry:init(connect, Opts);
init_reconnect_retry(_) ->
    undefined.

%% @private Tear down session-scoped state on a disconnect: fail in-flight calls
%% fast, stop in-flight workers, close the (dead) transport, drop the
%% established registry ids (keeping the declared set for replay) and reset the
%% load counter. The protocol/registry-declared/keepalive config survive.
teardown_session(Data0) ->
    Data1 = reply_pending({error, disconnected}, Data0),
    %% Kill in-flight invocation workers + demonitor event workers, then clear
    %% the dispatch maps and reset (not re-create) the load token bucket — a
    %% fresh `new/1` would orphan a bondy_regulator ETS row each time (review B4).
    Data2 = run_dispatch(bondy_connect_dispatch:kill_all(disp(Data1)), Data1),
    Data3 = store_dispatch(bondy_connect_dispatch:reset(disp(Data2)), Data2),
    _ = close_transport(Data3),
    Reg1 = bondy_connect_registry:clear_established(Data3#data.registry),
    %% The protocol layer is a stateful machine that has been driven to its
    %% terminal `established' state; a reconnect needs a fresh handshake, so
    %% re-initialise it (this also clears any auth material).
    {ok, Protocol1} = bondy_connect_protocol:init(Data3#data.config),
    Data3#data{
        protocol = Protocol1,
        registry = Reg1,
        session = undefined,
        transport = undefined
    }.

%% @private Replay the declared REGISTER/SUBSCRIBE set after a reconnect. Each
%% sends a fresh request whose ack re-confirms the registry id; no user reply is
%% involved (`from => undefined`).
replay_declared(Data) ->
    Regs = bondy_connect_registry:declared_registrations(Data#data.registry),
    Subs = bondy_connect_registry:declared_subscriptions(Data#data.registry),
    ?LOG_NOTICE(#{
        description => "Replaying declared registrations/subscriptions.",
        registrations => length(Regs),
        subscriptions => length(Subs)
    }),
    Data1 = lists:foldl(
        fun({Uri, _Handler, Opts}, D) ->
            WireOpts = maps:with(
                [match, invoke, concurrency, disclose_caller, force_reregister],
                Opts
            ),
            send_internal_request(
                register,
                fun(ReqId) ->
                    bondy_wamp_message:register(ReqId, WireOpts, Uri)
                end,
                #{uri => Uri},
                D
            )
        end,
        Data,
        Regs
    ),
    lists:foldl(
        fun({Uri, _Handler, Opts}, D) ->
            WireOpts = maps:with([match, get_retained, nkey], Opts),
            send_internal_request(
                subscribe,
                fun(ReqId) ->
                    bondy_wamp_message:subscribe(ReqId, WireOpts, Uri)
                end,
                #{uri => Uri},
                D
            )
        end,
        Data1,
        Subs
    ).

%% @private Like `send_request/6` but with no `From` to reply to (used by replay).
send_internal_request(Type, MsgFun, Meta, Data) ->
    #data{next_request_id = ReqId} = Data,
    Msg = MsgFun(ReqId),
    case send_msg(Msg, Data) of
        ok ->
            store_pending(
                ReqId,
                #{type => Type, from => undefined, meta => Meta},
                ?DEFAULT_ADMIN_TIMEOUT,
                Data#data{next_request_id = next_id(ReqId)}
            );
        {error, _Reason} ->
            %% The link dropped again mid-replay; the next reconnect replays anew.
            Data
    end.

%% @private Enable partisan network monitoring if available (capability-gated).
%% Returns whether monitoring is active; without partisan we behave as a plain
%% reconnecting client.
enable_net_monitor() ->
    _ = code:ensure_loaded(partisan_inet),
    case erlang:function_exported(partisan_inet, monitor, 1) of
        true ->
            try
                partisan_inet:monitor(true) =:= ok
            catch
                _:_ -> false
            end;
        false ->
            false
    end.

%% @private
disable_net_monitor(true) ->
    _ = catch partisan_inet:monitor(false),
    ok;
disable_net_monitor(false) ->
    ok.

%% @private Failure reasons we treat as recoverable (worth reconnecting).
is_retriable({abort, Uri, Details}) -> is_transient_abort(Uri, Details);
is_retriable(connection_closed) -> true;
is_retriable(establish_timeout) -> true;
is_retriable(ping_timeout) -> true;
is_retriable({ping_send_error, _}) -> true;
is_retriable({send_error, _}) -> true;
is_retriable({protocol_error, _}) -> true;
is_retriable({connection_error, _}) -> true;
is_retriable({connect_error, R}) -> is_retriable_posix(R);
is_retriable({handshake_error, R}) -> is_retriable_posix(R);
is_retriable(_) -> false.

%% @private Whether a router ABORT describes a condition that could clear.
%%
%% The authority is the router's own `nature` key, which every Bondy ABORT
%% carries (`bondy_error:to_map/1`): `transient` means "retrying the operation
%% unchanged could succeed", `permanent` means the request itself is at fault
%% and will fail identically forever. Trusting the flag rather than a URI table
%% means a new transient condition on the router is handled by clients that
%% predate it.
%%
%% The URI fallback covers a router too old to send `nature`, or a non-Bondy
%% WAMP router. It is deliberately an allow-list: an ABORT we cannot classify
%% stays fatal, because retrying a genuinely permanent failure forever is worse
%% than surfacing it.
is_transient_abort(Uri, Details) when is_map(Details) ->
    case maps:get(~"nature", Details, undefined) of
        ~"transient" -> true;
        ~"permanent" -> false;
        _ -> is_transient_abort_uri(Uri)
    end;
is_transient_abort(Uri, _) ->
    is_transient_abort_uri(Uri).

%% @private
is_transient_abort_uri(?WAMP_UNAVAILABLE) -> true;
is_transient_abort_uri(~"bondy.error.unavailable") -> true;
is_transient_abort_uri(_) -> false.

%% @private
is_retriable_posix(R) ->
    is_netdown_posix(R) orelse
        lists:member(R, [
            timeout,
            closed,
            econnrefused,
            econnreset,
            ehostdown,
            enotconn,
            etimedout
        ]).

%% @private Network-absence reasons (route to `waiting_for_network' when
%% monitoring is active).
is_netdown({connect_error, R}) -> is_netdown_posix(R);
is_netdown({connection_error, R}) -> is_netdown_posix(R);
is_netdown(_) -> false.

%% @private
is_netdown_posix(enetdown) -> true;
is_netdown_posix(ehostunreach) -> true;
is_netdown_posix(enetunreach) -> true;
is_netdown_posix(_) -> false.

%% =============================================================================
%% PRIVATE — idle keepalive (ping/pong)
%% =============================================================================

%% @private Send a ping and arm its deadline, or reconnect if the send fails.
%% The keepalive budget/decision lives in `bondy_connect_keepalive'; the statem
%% owns the transport send and the `{timeout, ping}' deadline.
arm_ping(Deadline, Data) ->
    case ping_send(Data) of
        ok ->
            {keep_state, Data, [{{timeout, ping}, Deadline, ping_timeout}]};
        {error, Reason} ->
            on_transport_failure({ping_send_error, Reason}, Data)
    end.

%% @private
ping_send(#data{transport_mod = Mod, transport = T, keepalive = KA}) ->
    Mod:ping(bondy_connect_keepalive:payload(KA), T).

%% @private
pong_send(Payload, #data{transport_mod = Mod, transport = T}) ->
    Mod:pong(Payload, T).

%% @private
add_waiter(From, #data{ready_waiters = Ws} = Data) ->
    Data#data{ready_waiters = [From | Ws]}.

%% @private
reply_waiters(_Reply, #data{ready_waiters = []} = Data) ->
    Data;
reply_waiters(Reply, #data{ready_waiters = Ws} = Data) ->
    _ = [gen_statem:reply(From, Reply) || From <- Ws],
    Data#data{ready_waiters = []}.

%% @private
resolve_registration(RegId, _Data) when is_integer(RegId) ->
    {ok, RegId};
resolve_registration(Uri, Data) when is_binary(Uri) ->
    bondy_connect_registry:registration_id(Uri, Data#data.registry).

%% @private
resolve_subscription(SubId, _Data) when is_integer(SubId) ->
    {ok, SubId};
resolve_subscription(Uri, Data) when is_binary(Uri) ->
    bondy_connect_registry:subscription_id(Uri, Data#data.registry).

%% @private
call_msg(Uri, Args, KWArgs, Opts) ->
    %% Advanced-profile caller options passed through to the dealer:
    %% `timeout`/`disclose_me` (caller_identification), `runmode`/`rkey`
    %% (sharded/partitioned routing), `retries` (call_retries),
    %% `receive_progress` (progressive_call_results, call_async only) and
    %% `_deadline` (Bondy extension: absolute cap for a progressive call,
    %% whose `timeout` is an inter-result inactivity window).
    WireOpts = maps:with(
        [
            timeout,
            disclose_me,
            receive_progress,
            %% progressive_calls: marks a non-final CALL of an argument stream.
            progress,
            runmode,
            rkey,
            retries,
            '_deadline'
        ],
        Opts
    ),
    %% request id is filled in by do_request/set_request_id.
    bondy_wamp_message:call(1, WireOpts, Uri, Args, KWArgs).

%% @private
set_request_id(#call{} = M, ReqId) ->
    M#call{request_id = ReqId}.

%% @private
call_timeout(Opts) ->
    maps:get(timeout, Opts, ?DEFAULT_CALL_TIMEOUT).

%% @private Absolute (monotonic) deadline from the `_deadline` option, or
%% `infinity`.
call_deadline(Opts) ->
    case maps:get('_deadline', Opts, undefined) of
        D when is_integer(D) andalso D > 0 ->
            erlang:monotonic_time(millisecond) + D;
        _ ->
            infinity
    end.

%% @private
send_msg(Msg, #data{transport_mod = Mod, transport = T}) ->
    Mod:send(Msg, T).

%% @private
send_all([], _Data) ->
    ok;
send_all([Msg | Rest], Data) ->
    case send_msg(Msg, Data) of
        ok -> send_all(Rest, Data);
        {error, _} = Error -> Error
    end.

%% @private
maybe_goodbye(established, Data) ->
    Goodbye = bondy_wamp_message:goodbye(#{}, ?WAMP_CLOSE_NORMAL),
    send_msg(Goodbye, Data);
maybe_goodbye(_StateName, _Data) ->
    ok.

%% @private
close_transport(#data{transport = undefined}) ->
    ok;
close_transport(#data{transport_mod = Mod, transport = T}) ->
    catch Mod:close(T),
    ok.

%% @private
next_id(Id) when Id >= ?MAX_ID -> 1;
next_id(Id) -> Id + 1.

%% @private
undefined_to(undefined, Default) -> Default;
undefined_to(Value, _Default) -> Value.

%% @private
result_payload(#result{details = Details, args = Args, kwargs = KWArgs}) ->
    #{
        args => undefined_to(Args, []),
        kwargs => undefined_to(KWArgs, #{}),
        details => undefined_to(Details, #{})
    }.

%% @private A router-sent ERROR, shared by every request kind that awaits one
%% (CALL, REGISTER, SUBSCRIBE, UNREGISTER, UNSUBSCRIBE, acknowledged PUBLISH)
%% via resolve_pending/3 (route_app/2). `kind => wamp` discriminates this from
%% a client-side `{error, Reason}` at the tag_error/1 boundary.
%%
%% The payload is a `bondy_error:t()` carrying the router's error, with `kind`,
%% `args` and `kwargs` retained so existing matches keep working. `message` and
%% `nature` are the useful additions: a caller can tell a retryable refusal from
%% a permanent one without parsing the URI.
error_payload(#error{args = Args, kwargs = KWArgs} = M) ->
    Error = bondy_wamp_error:from_wamp(M),
    Error#{
        kind => wamp,
        args => undefined_to(Args, []),
        kwargs => undefined_to(KWArgs, #{})
    }.

%% @private A connection that has established at least once and is back in
%% `connecting'/`waiting_for_network' is *reconnecting*; the first time through
%% it is merely *connecting*.
public_status(connecting, #data{established_once = true}) -> reconnecting;
public_status(connecting, #data{}) -> connecting;
public_status(waiting_for_network, #data{}) -> reconnecting;
public_status(handshaking, #data{}) -> connecting;
public_status(establishing, #data{}) -> establishing;
public_status(established, #data{}) -> established;
public_status(_, #data{}) -> down.

%% @private
transport_mod(tcp) -> bondy_connect_transport_tcp;
transport_mod(tls) -> bondy_connect_transport_tls;
transport_mod(uds) -> bondy_connect_transport_uds;
transport_mod(ws) -> bondy_connect_transport_ws;
transport_mod(wss) -> bondy_connect_transport_ws;
transport_mod(local) -> bondy_connect_local;
transport_mod(Other) -> error({unsupported_transport, Other}).

%% @private
subprotocol(Config) ->
    Serializers = maps:get(serializers, Config, [json]),
    Enc = hd(Serializers),
    {raw, binary, Enc}.

%% @private
endpoint(Config) ->
    Endpoint = maps:get(endpoint, Config),
    Opts = #{
        connect_timeout => ?CONNECT_TIMEOUT,
        max_message_length => maps:get(max_message_length, Config, 16#1000000),
        tls => maps:get(tls, Config, #{verify => verify_peer}),
        %% Consumed by the WebSocket transport (ignored by the raw transports).
        scheme => maps:get(transport, Config, tcp),
        serializers => maps:get(serializers, Config, [json]),
        ws_path => maps:get(ws_path, Config, <<"/ws">>),
        %% Consumed by the local (in-VM) transport, which opens the session
        %% itself; ignored by the socket transports.
        realm => maps:get(realm, Config, undefined),
        roles => maps:get(roles, Config, #{})
    },
    {Endpoint, Opts}.

%% @private Scrub the protocol's auth material from status/crash dumps.
redact(data, #data{protocol = P} = Data) ->
    Data#data{protocol = bondy_connect_protocol:format_status(P)};
redact(_Key, Value) ->
    Value.
