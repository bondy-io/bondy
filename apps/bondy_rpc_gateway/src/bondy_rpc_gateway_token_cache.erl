%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rpc_gateway_token_cache).

-moduledoc """
Public API for the per-service token cache.

A pool of `bondy_rpc_gateway_token_cache_worker` processes is started
eagerly at registry init. Service names are mapped to a worker via
`gproc_pool` `hash` strategy (deterministic mapping per service name).
Each worker owns a private named ETS table holding its assigned services'
tokens, so token reads are lock-free.

## Supervision tree

```
bondy_rpc_gateway_sup (rest_for_one)
├── bondy_rpc_gateway_token_cache        ← this module (registry)
└── bondy_rpc_gateway_token_cache_sup    (one_for_one)
    ├── worker_1
    ├── worker_2
    └── ...
```

## Usage

```erlang
%% Fetch a token
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
get(Name, ...) → gproc_pool:pick → worker name (atom)
                     → ets:lookup_element on worker's table → Token
```

Two ETS lookups, no gen_server hop.

## Cold path (no cached token for service)

```
get(Name, ...) → gproc_pool:pick → worker name
                     → ets:lookup_element → undefined
                     → gen_server:call(worker, {get_token, ...})
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

    ok = ensure_pool(?POOLNAME, Size),

    [
        begin
            WorkerName = worker_name(Id),
            ok = ensure_worker_slot(?POOLNAME, WorkerName),
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
%% gproc_pool state survives restarts of this gen_server, so a re-init can
%% encounter an existing pool. `gproc_pool:new/3` raises `error:exists` in
%% that case — anything else is a real failure and should propagate.
ensure_pool(Pool, Size) ->
    try gproc_pool:new(Pool, hash, [{size, Size}]) of
        ok -> ok
    catch
        error:exists -> ok
    end.


%% @private
ensure_worker_slot(Pool, WorkerName) ->
    try gproc_pool:add_worker(Pool, WorkerName) of
        Pos when is_integer(Pos) -> ok
    catch
        error:exists -> ok
    end.

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

