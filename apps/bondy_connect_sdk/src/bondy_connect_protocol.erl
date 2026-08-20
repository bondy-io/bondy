%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_protocol).

-moduledoc """
The client-side WAMP **session** state machine — the client mirror of the
router's `bondy_wamp_protocol`.

This is a **pure functional** module (no process, no I/O). It operates on
decoded WAMP **records** (the codec/framing live in the transports) and is
owned and driven by the connection process (`bondy_connect_connection`). The connection feeds it inbound records and ships the records it
returns.

## Session FSM

```
closed --start--> establishing --CHALLENGE--> challenging --WELCOME--> established
                       \\---------------------WELCOME------------------/
established --GOODBYE/close--> shutting_down
```

## Contract

- `init/1` — build the state from a validated config.
- `start/1` — produce the `HELLO` record (the client initiates).
- `handle_message/2` — consume one inbound record and run the FSM:
  - `{reply, [Msg], St}` — e.g. `AUTHENTICATE` in response to a `CHALLENGE`.
  - `{established, Session, St}` — on `WELCOME`.
  - `{stop, Reason, [Msg], St}` — `ABORT`/`GOODBYE` (the `[Msg]` are any final
    records to send first, e.g. a client `ABORT` or `GOODBYE` ack).
  - `{passthrough, Msg, St}` — an application record the connection routes.
- `outbound/2` — validate/annotate an application record before it is sent.
- `terminate/1`, `format_status/1`.

Following `bondy_wamp_protocol`, **protocol and auth errors are mapped to a
clean `ABORT`/stop, never asserted** — malformed *bytes* are caught one layer
down in the transport and surfaced as a record this module turns into an
`ABORT`.
""".

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-record(state, {
    state_name = closed :: state_name(),
    realm_uri :: binary() | undefined,
    roles :: map(),
    agent :: binary(),
    auth :: bondy_connect_auth:t() | undefined,
    session :: bondy_connect_session:t() | undefined,
    goodbye_reason :: binary() | undefined
}).

-type state() :: #state{}.
-type state_name() ::
    closed
    | establishing
    | challenging
    | established
    | shutting_down.
-type message() :: bondy_wamp_message:t().
-type result() ::
    {reply, [message()], state()}
    | {established, bondy_connect_session:t(), state()}
    | {stop, Reason :: term(), [message()], state()}
    | {passthrough, message(), state()}.

-export_type([state/0]).
-export_type([state_name/0]).
-export_type([result/0]).

-export([init/1]).
-export([start/1]).
-export([handle_message/2]).
-export([outbound/2]).
-export([terminate/1]).
-export([format_status/1]).
%% Accessors
-export([state_name/1]).
-export([realm_uri/1]).
-export([session/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc "Initialise the protocol state from a validated `bondy_connect_config` map.".
-spec init(Config :: map()) -> {ok, state()} | {error, term()}.

init(Config) when is_map(Config) ->
    case maps:find(realm, Config) of
        {ok, Realm} ->
            AuthConfig = maps:get(auth, Config, #{method => ?WAMP_ANON_AUTH}),
            case bondy_connect_auth:init(AuthConfig) of
                {ok, Auth} ->
                    {ok, #state{
                        state_name = closed,
                        realm_uri = Realm,
                        roles = maps:get(roles, Config, #{}),
                        agent = maps:get(agent, Config, ?BONDY_CONNECT_AGENT),
                        auth = Auth
                    }};
                {error, _} = Error ->
                    Error
            end;
        error ->
            {error, missing_realm}
    end.

-doc "Produce the `HELLO` record. Valid only from the `closed` state.".
-spec start(state()) -> {ok, message(), state()} | {error, term()}.

start(#state{state_name = closed} = St) ->
    #state{realm_uri = Realm, roles = Roles, agent = Agent, auth = Auth} = St,
    Details = hello_details(Roles, Agent, Auth),
    Hello = bondy_wamp_message:hello(Realm, Details),
    {ok, Hello, St#state{state_name = establishing}};
start(#state{state_name = Name}) ->
    {error, {invalid_state, Name}}.

-doc "Run the FSM over one inbound WAMP record.".
-spec handle_message(message() | term(), state()) -> result().

handle_message(#challenge{} = Msg, #state{state_name = establishing} = St) ->
    handle_challenge(Msg, St);
%% A WELCOME from `challenging` means we answered the router's CHALLENGE — the
%% configured credential gated the session, so it is always valid.
handle_message(#welcome{} = Msg, #state{state_name = challenging} = St) ->
    welcome(Msg, St);
%% A WELCOME straight from `establishing` (no CHALLENGE seen) is only valid for
%% a method that does not gate the session on a challenge — `anonymous`. For a
%% credential-bearing method (`cra`/`cryptosign`/`ticket`) the client never got
%% to present its credential, so silently accepting it would downgrade the
%% operator's chosen security posture. Reject it with an ABORT.
handle_message(#welcome{} = Msg, #state{state_name = establishing} = St) ->
    Method = bondy_connect_auth:method(St#state.auth),
    case requires_challenge(Method) of
        false ->
            welcome(Msg, St);
        true ->
            abort(
                <<"Router welcomed the session without a challenge.">>,
                {welcome_without_challenge, Method},
                St
            )
    end;
handle_message(#abort{reason_uri = Reason, details = Details}, St) ->
    %% Router abandoned the handshake; stop without replying.
    {stop, {shutdown, {abort, Reason, Details}}, [], St};
handle_message(#goodbye{}, #state{state_name = shutting_down} = St) ->
    %% Our GOODBYE has been acknowledged.
    {stop, normal, [], St};
handle_message(
    #goodbye{reason_uri = Reason}, #state{state_name = established} = St
) ->
    %% Router-initiated GOODBYE: acknowledge and stop.
    Ack = bondy_wamp_message:goodbye(#{}, ?WAMP_GOODBYE_AND_OUT),
    NewSt = St#state{state_name = shutting_down, goodbye_reason = Reason},
    {stop, {shutdown, {goodbye, Reason}}, [Ack], NewSt};
handle_message(Msg, #state{state_name = established} = St) ->
    case bondy_wamp_message:is_message(Msg) of
        true ->
            {passthrough, Msg, St};
        false ->
            protocol_violation(<<"Unexpected non-WAMP message.">>, St)
    end;
handle_message(_Msg, St) ->
    protocol_violation(<<"Unexpected message for the current state.">>, St).

-doc """
Validate/annotate an outbound application record before the connection ships
it. Only valid once the session is `established`.
""".
-spec outbound(message(), state()) ->
    {ok, message(), state()} | {error, term(), state()}.

outbound(#goodbye{} = Msg, #state{state_name = established} = St) ->
    {ok, Msg, St#state{state_name = shutting_down}};
outbound(Msg, #state{state_name = established} = St) ->
    {ok, Msg, St};
outbound(_Msg, #state{state_name = Name} = St) ->
    {error, {not_established, Name}, St}.

-doc "Release any protocol resources. Currently a no-op.".
-spec terminate(state()) -> ok.
terminate(#state{}) ->
    ok.

-doc """
Scrub auth secrets (private keys, passwords, tickets held in the auth callback
state) before the state is logged or dumped. Paired with the connection's
scoped `process_flag(sensitive, true)` during the auth window.
""".
-spec format_status(state()) -> state().

format_status(#state{auth = Auth} = St) ->
    St#state{auth = redact_auth(Auth)}.

%% =============================================================================
%% ACCESSORS
%% =============================================================================

-spec state_name(state()) -> state_name().
state_name(#state{state_name = Name}) -> Name.

-spec realm_uri(state()) -> binary() | undefined.
realm_uri(#state{realm_uri = Val}) -> Val.

-spec session(state()) -> bondy_connect_session:t() | undefined.
session(#state{session = Val}) -> Val.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
handle_challenge(#challenge{auth_method = Method, extra = Extra}, St) ->
    #state{auth = Auth} = St,
    case bondy_connect_auth:method(Auth) of
        Method ->
            case bondy_connect_auth:authenticate(Extra, Auth) of
                {ok, Signature, AuthExtra, NewAuth} ->
                    Msg = bondy_wamp_message:authenticate(Signature, AuthExtra),
                    NewSt = St#state{
                        state_name = challenging, auth = NewAuth
                    },
                    {reply, [Msg], NewSt};
                {error, Reason} ->
                    abort(
                        <<"Client could not authenticate.">>,
                        {authentication_failed, Reason},
                        St
                    )
            end;
        _Other ->
            abort(
                <<"Router challenged with an unsupported authmethod.">>,
                {no_matching_authmethod, Method},
                St
            )
    end.

%% @private Build the established session from an accepted WELCOME.
welcome(#welcome{session_id = SessionId, details = Details}, St) ->
    Session = bondy_connect_session:new(SessionId, Details),
    {established, Session, St#state{
        state_name = established, session = Session
    }}.

%% @private Whether the method gates the session on a CHALLENGE/AUTHENTICATE
%% round before a WELCOME is acceptable. Only `anonymous` may be welcomed
%% straight from `establishing`; every credential-bearing method (including
%% `ticket`, which presents its secret in the AUTHENTICATE) must see a CHALLENGE
%% first, so we default-deny any other method.
requires_challenge(?WAMP_ANON_AUTH) -> false;
requires_challenge(_Other) -> true.

%% @private
hello_details(Roles, Agent, Auth) ->
    Details0 = #{roles => Roles, agent => Agent},
    Method = bondy_connect_auth:method(Auth),
    Details1 = Details0#{authmethods => [Method]},
    Details2 = maybe_put(authid, bondy_connect_auth:authid(Auth), Details1),
    case bondy_connect_auth:authextra(Auth) of
        Extra when map_size(Extra) == 0 ->
            Details2;
        Extra ->
            Details2#{authextra => Extra}
    end.

%% @private
maybe_put(_Key, undefined, Map) ->
    Map;
maybe_put(Key, Value, Map) ->
    Map#{Key => Value}.

%% @private
protocol_violation(Message, St) ->
    abort(?WAMP_PROTOCOL_VIOLATION, Message, {protocol_violation, Message}, St).

%% @private Build a client ABORT and stop. Two-arity helper defaults the URI to
%% a protocol violation.
abort(Message, StopReason, St) ->
    abort(?WAMP_PROTOCOL_VIOLATION, Message, StopReason, St).

%% @private
abort(ReasonUri, Message, StopReason, St) ->
    Abort = bondy_wamp_message:abort(#{message => Message}, ReasonUri),
    {stop, {shutdown, StopReason}, [Abort], St#state{
        state_name = shutting_down
    }}.

%% @private Scrub the auth `state` for status/crash dumps. Total by design: this
%% runs on the `format_status` path, so an auth method whose map carries no
%% `state` key must not crash it (which would mask the real crash reason).
redact_auth(undefined) ->
    undefined;
redact_auth(Auth) when is_map(Auth) ->
    case is_map_key(state, Auth) of
        true -> Auth#{state := '******'};
        false -> Auth
    end.
