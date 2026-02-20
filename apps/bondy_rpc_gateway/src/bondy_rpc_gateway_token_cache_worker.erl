%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rpc_gateway_token_cache_worker).

-moduledoc """
Per-service token worker.

Each instance manages exactly one service's authentication token.
Workers are created on demand by `bondy_rpc_gateway_token_cache` and
supervised under `bondy_rpc_gateway_token_cache_sup` as `temporary`
children.

## Token lifecycle

```
                ┌─────────────┐
                │  no token   │ ← initial state
                └──────┬──────┘
                       │ get_token call
                       ▼
              ┌────────────────┐
              │ fetch_token/1  │ ← synchronous HTTP call
              └────────┬───────┘
                       │ success
                       ▼
              ┌────────────────┐
    refresh   │  token cached  │ ← serves get_token from state
  ┌──────────►│  timer running │──────────┐
  │           └────────────────┘          │ timer fires
  │                    │                  │ (TTL - margin)
  │                    │ invalidate       ▼
  │                    │           ┌──────────────┐
  │                    │           │   refresh    │
  │                    │           │ (background) │
  │                    │           └──────┬───────┘
  │                    │                  │ success
  │                    │                  │
  │                    ▼                  │
  │           ┌────────────────┐          │
  │           │  token cleared │          │
  │           └────────────────┘          │
  └───────────────────────────────────────┘
```

## Thundering herd protection

The gen_server serializes all `get_token` calls per service. If 100
concurrent requests hit a cold cache, they all queue in the worker's
mailbox. The first call fetches the token; subsequent calls find it in
state and return immediately.

## Cache configuration

The `cache` key in `auth_conf` controls timing:

```erlang
#{
    cache => #{
        default_ttl    => 3600,  %% seconds, used when no expires_in in meta
        refresh_margin => 60     %% seconds before expiry to preemptively refresh
    }
}
```
""".

-behaviour(gen_server).

%% API
-export([start_link/2]).
-export([get_token/4]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

-include_lib("kernel/include/logger.hrl").

-define(DEFAULT_TTL, 3600).
-define(DEFAULT_REFRESH_MARGIN, 60).

-record(state, {
    name :: atom()
}).

-record(rpc_gateway_token, {
    service_name    :: binary(),
    auth_mod        :: module(),
    auth_conf       :: map(),
    token           :: binary() | undefined,
    expires_at      :: integer() | undefined,
    timer_ref       :: reference() | undefined
}).

-type t() :: #state{}.
-type rpc_gateway_token() :: #rpc_gateway_token{}.


-export_type([rpc_gateway_token/0]).


%% =============================================================================
%% API
%% =============================================================================



-doc false.
-spec start_link(binary(), atom()) -> {ok, pid()} | {error, term()}.

start_link(PoolName, WorkerName) ->
    gen_server:start_link(
        {local, WorkerName}, ?MODULE, [PoolName, WorkerName], []
    ).


-doc """
Returns a token from the ets cache concurrently. If it is not found, call the
server to obtain a new token.
""".
-spec get_token(atom(), binary(), module(), map()) ->
    {ok, binary()} | {error, not_found}.

get_token(WorkerName, ServiceName, AuthMod, AuthConf) when is_atom(WorkerName) ->
    Default = undefined,
    Pos = #rpc_gateway_token.token,

    case ets:lookup_element(WorkerName, ServiceName, Pos, Default) of
        undefined ->
            Cmd = {get_token, ServiceName, AuthMod, AuthConf},
            gen_server:call(WorkerName, Cmd);

        Token ->
            {ok, Token}
    end.



%% ===================================================================
%% gen_server callbacks
%% ===================================================================

-doc false.
init([PoolName, WorkerName]) ->
    true = gproc_pool:connect_worker(PoolName, WorkerName),
    ets:new(
        WorkerName,
        [set, named_table, protected, {keypos, 2}, {read_concurrency, true}]
    ),
    {ok, #state{name = WorkerName}}.


-doc false.
handle_call({get_token, ServiceName, AuthMod, AuthConf}, _From, State) ->
    #state{name = WorkerName} = State,
    Now = erlang:system_time(second),

    case ets:lookup(WorkerName, ServiceName) of
        [#rpc_gateway_token{token = Token, expires_at = ExpiresAt}]
                when Token =/= undefined, ExpiresAt > Now ->
            {reply, {ok, Token}, State};

        _ ->
            %% Expired or not found
            case get_new_token(ServiceName, AuthMod, AuthConf, State) of
                {ok, Token} ->
                    {reply, {ok, Token}, State};

                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-doc false.
handle_cast({invalidate, ServiceName}, #state{} = State) ->
    Reply = clear_token(ServiceName, State),
    {noreply, Reply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info({refresh, ServiceName, AuthMod, AuthConf}, State) ->
    case get_new_token(ServiceName, AuthMod, AuthConf, State) of
        {ok, _} ->
            ?LOG_DEBUG(#{
                msg => <<"Preemptive token refresh succeeded">>,
                service => ServiceName
            }),
            {noreply, State};

        {error, Reason} ->
            ?LOG_WARNING(#{
                msg => <<"Preemptive token refresh failed">>,
                service => ServiceName,
                reason => Reason
            }),
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

-doc false.
terminate(_Reason, _State) ->
    ok.




%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
-spec get_new_token(binary(), module(), map(), t()) ->
    {ok, {binary(), pos_integer()}} | {error, term()}.

get_new_token(ServiceName, AuthMod, AuthConf, State) ->
    DefaultTTL = cache_opt(default_ttl, AuthConf, ?DEFAULT_TTL),

    resulto:then(
        AuthMod:fetch_token(AuthConf),
        fun
            ({Token, Meta}) when is_binary(Token), is_map(Meta) ->
                TTL = maps:get(expires_in, Meta, DefaultTTL),
                store_token(
                    ServiceName, AuthMod, AuthConf, Token, TTL, State
                );

            (Token) when is_binary(Token) ->
                store_token(
                    ServiceName, AuthMod, AuthConf, Token, DefaultTTL, State
                )
        end
    ).

%% @private
store_token(ServiceName, AuthMod, AuthConf, Token, TTL, State) ->
    ExpiresAt = erlang:system_time(second) + TTL,
    RefreshMargin = cache_opt(
        refresh_margin,
        AuthConf,
        ?DEFAULT_REFRESH_MARGIN
    ),
    RefreshIn = max(1, TTL - RefreshMargin),
    TimerRef = erlang:send_after(
        RefreshIn * 1000,
        self(),
        {refresh, ServiceName, AuthMod, AuthConf}
    ),

    T = #rpc_gateway_token{
        service_name = ServiceName,
        auth_mod = AuthMod,
        auth_conf = AuthConf,
        token = Token,
        expires_at = ExpiresAt,
        timer_ref = TimerRef
    },
    case ets:insert(State#state.name, T) of
        true ->
            {ok, Token};

        false ->
            ?LOG_ERROR(#{
                description => "Couldn't store token on cache",
                service_name => ServiceName
            }),
            {ok, Token}
    end.

%% @private
clear_token(ServiceName, State) ->
    Result = ets:lookup_element(
        State#state.name, ServiceName, #rpc_gateway_token.timer_ref, undefined
    ),
    case Result of
        undefined ->
            ok;
        Ref ->
            erlang:cancel_timer(Ref),
            ets:update_element(
                State#state.name, ServiceName, [
                    {#rpc_gateway_token.token, undefined},
                    {#rpc_gateway_token.expires_at, undefined},
                    {#rpc_gateway_token.timer_ref, undefined}
                ]
            ),
            ok
    end.

%% @private
cache_opt(Key, AuthConf, Default) ->
    CacheConf = maps:get(cache, AuthConf, #{}),
    maps:get(Key, CacheConf, Default).
