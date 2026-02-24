%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rpc_gateway_token_cache).

-moduledoc """
Registry and public API for the per-service token cache.

This gen_server owns a `set` ETS table that maps service names to worker
pids. Token reads go directly to a pool of workers via the ETS lookup (concurrent,
lock-free); worker creation is managed by `bondy_rpc_gateway_token_cache_sup`

## Supervision tree

```
bondy_rpc_gateway_sup (rest_for_one)
├── bondy_rpc_gateway_token_cache    ← this module (registry)
└── bondy_rpc_gateway_token_cache_sup (simple_one_for_one)
    ├── worker for <<"service_a">>
    ├── worker for <<"service_b">>
    └── ...
```

## Usage

```erlang
%% Fetch a token (creates worker on first call)
{ok, Token} = bondy_rpc_gateway_token_cache:get(
    <<"service_a">>, bondy_rpc_gateway_auth_generic, AuthConf
).

%% Invalidate after upstream 401
ok = bondy_rpc_gateway_token_cache:invalidate(<<"service_a">>).

%% Next get will fetch a fresh token
{ok, FreshToken} = bondy_rpc_gateway_token_cache:get(
    <<"service_a">>, bondy_rpc_gateway_auth_generic, AuthConf
).
```

## Hot path (cached token)

```
get(Name, ...) → ets:lookup → worker pid
                     → gen_server:call(Pid, get)
                     → state check → {ok, Token}
```
No HTTP call, no registry gen_server involved.

## Cold path (first request for a service)

```
get(Name, ...) → ets:lookup → miss
                     → gen_server:call(registry, {start_worker, ...})
                     → supervisor:start_child → new worker pid
                     → ets:insert, monitor
                     → gen_server:call(Pid, get)
                     → AuthMod:fetch_token → {ok, Token}
```
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).
-define(POOLNAME, {?MODULE, pool}).

%% Public API
-export([start_link/0]).
-export([get/3]).
-export([invalidate/1]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).


%% ===================================================================
%% Public API
%% ===================================================================

-doc """
Start the registry gen_server.

Called by `bondy_rpc_gateway_sup`. Creates the ETS table used for
service-name to worker-pid lookups.
""".
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).



-doc """
Get a cached token for the given service, creating a worker if needed.

On the hot path (worker exists, token valid) this does an ETS lookup
followed by a `gen_server:call` to the worker — no registry serialization.

On the cold path (no worker yet) the registry creates the worker under
the `simple_one_for_one` supervisor, inserts it into ETS, and then
delegates to the worker.

## Examples

```erlang
AuthConf = #{
    fetch => #{
        method => post,
        url => ~"https://idp.example.com/token",
        token_path => [~"access_token"]
    },
    apply => #{
        placement => header,
        name => ~"Authorization",
        format => ~"Bearer {{token}}"
    },
    cache => #{
        default_ttl => 1800,
        refresh_margin => 60
    }
},
{ok, Token} = bondy_rpc_gateway_token_cache:get(
    ~"service_b", bondy_rpc_gateway_auth_generic, AuthConf
).
```
""".
-spec get(binary(), module(), map()) -> {ok, binary()} | {error, term()}.
get(ServiceName, AuthMod, AuthConf) ->
    do_for_worker(
        fun
            (noproc) ->
                {error, noproc};

            (WorkerName) ->
                bondy_rpc_gateway_token_cache_worker:get_token(
                    WorkerName, ServiceName, AuthMod, AuthConf
                )
        end,
        ServiceName
    ).


-doc """
Invalidate the cached token for a service.

Sends an asynchronous `invalidate` cast to the worker. The next
`get/3` call for this service will fetch a fresh token.

Safe to call even if no worker exists for the given service name.

## Examples

```erlang
ok = bondy_rpc_gateway_token_cache:invalidate(<<"service_a">>).
```
""".
-spec invalidate(binary()) -> ok.

invalidate(ServiceName) ->
    do_for_worker(
        fun
            (noproc) ->
                ok;

            (WorkerName) ->
                _ = catch gen_server:cast(
                    WorkerName, {invalidate, ServiceName}
                ),
                ok
        end,
        ServiceName
    ).


%% ===================================================================
%% gen_server callbacks
%% ===================================================================

-doc false.
init([]) ->
    ok = init_pool(),
    {ok, undefined}.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-doc false.
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info(_Info, State) ->
    {noreply, State}.

-doc false.
terminate(_Reason, _State) ->
    ok.


%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
init_pool() ->
    DefaultSize = max(erlang:system_info(schedulers_online), 8),
    Size = bondy_rpc_gateway_config:get([token_cache_pool, size], DefaultSize),

    %% If the supervisor restarts and we call groc_pool:new it will fail with
    %% an exception, so we catch
    _ = catch gproc_pool:new(?POOLNAME, hash, [{size, Size}]),

    [
        begin
            WorkerName = worker_name(Id),
            _ = catch gproc_pool:add_worker(?POOLNAME, WorkerName),
            Result = bondy_rpc_gateway_token_cache_sup:start_worker(
                ?POOLNAME, WorkerName
            ),
            resulto:try_recover(
                Result,
                fun(Reason) ->
                    Info = bondy_stdlib_error:new(#{
                        type => noproc,
                        message =>
                            ~"An error ocurred when starting an RPC Gateway token cache worker.",
                        details => #{reason => Reason}}
                    ),
                    error(Info)
                end
            )
        end
        || Id <- lists:seq(1, Size)
    ],
    ok.

%% @private
worker_name(Id) when is_integer(Id) ->
    list_to_atom("bondy_rpc_gateway_token_cache_worker_" ++ integer_to_list(Id)).

%% @private
do_for_worker(Fun, Key) ->
    case gproc_pool:pick(?POOLNAME, Key) of
        false ->
            Fun(noproc);

        {_, _, [gproc_pool, _, _, WorkerName]} ->
            Fun(WorkerName)
    end.

