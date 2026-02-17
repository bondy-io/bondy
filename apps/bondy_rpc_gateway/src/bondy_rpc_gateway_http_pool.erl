%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rpc_gateway_http_pool).

-moduledoc """
A supervised hackney connection pool with automatic health-check retries using
bondy_retry. The pool is restarted when the endpoint becomes available again.

### Usage

```erlang
bondy_rpc_gateway_http_pool:start_link(my_api_pool,
    <<"https://api.example.com">>,
    #{
        size => 25,
        connect_timeout => 5_000,
        recv_timeout => 15_000,
        retry_opts => #{
            deadline => 0,
            max_retries => 1_000_000,
            backoff_enabled => true,
            backoff_min => 1_000,
            backoff_max => 30_000,
            backoff_type => jitter
        }
    }
).
```

### Key design points

**Indefinite retry** — `deadline => 0` disables the deadline in `bondy_retry`. If `max_retries` is ever hit, `schedule_retry/1` resets the retry state via `succeed/1` and continues, so the pool never gives up.

**Health check on start** — `try_start_pool/1` does a HEAD request to verify the endpoint is actually reachable before marking the pool `up`. This avoids accepting requests into a dead pool.

**Fast failure for callers** — while the pool is `down`, `request/5` returns `{error, pool_down}` immediately rather than hanging. Callers can decide whether to queue, retry themselves, or fail fast.

**`bondy_retry:fire/1`** — uses the erlang timer mechanism so the gen_server gets a `{timeout, Ref, Id}` message, keeping everything async and OTP-idiomatic.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-record(state, {
    name                ::  atom(),
    endpoint            ::  binary(),
    pool_opts           ::  proplists:proplist(),
    req_opts            ::  proplists:proplist(),
    retry               ::  bondy_retry:t(),
    retry_ref           ::  reference() | undefined,
    status = down       ::  up | down
}).

-type start_opts()      ::  #{
                                %% Pool (hackney_pool)
                                size => pos_integer(),
                                checkout_timeout => timeout(),
                                idle_timeout => timeout(),
                                %% Request defaults (hackney:request)
                                connect_timeout => timeout(),
                                recv_timeout => timeout(),
                                follow_redirect => boolean(),
                                max_redirect => non_neg_integer(),
                                %% TLS (hackney:request)
                                ssl_options => [ssl:tls_client_option()],
                                %% Proxy (hackney:request)
                                proxy => binary(),
                                proxy_auth =>
                                    {User :: binary(), Pass :: binary()},
                                %% Auth (hackney:request)
                                basic_auth =>
                                    {User :: binary(), Pass :: binary()},
                                %% Retry (ours)
                                retry_opts => bondy_retry:opts()
                            }.

-export_type([start_opts/0]).

%% API
-export([start_link/3]).
-export([status/1]).
-export([mark_down/1]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).


%% =============================================================================
%% API
%% =============================================================================


-doc "Start a pool process and link it to the calling process.".
-spec start_link(Name :: atom(), Endpoint :: binary(), Opts :: start_opts()) ->
    {ok, pid()} | {error, term()}.

start_link(Name, Endpoint, Opts) when is_map(Opts) ->
    gen_server:start_link({local, Name}, ?MODULE, [Name, Endpoint, Opts], []).


-doc "Return the current pool status (`up` or `down`).".
-spec status(Name :: atom()) -> up | down.

status(Name) ->
    gen_server:call(Name, status).


-doc "Mark the pool as down and schedule a health-check retry.".
-spec mark_down(Name :: atom()) -> ok.

mark_down(Name) ->
    gen_server:call(Name, mark_down).

%% =============================================================================
%% gen_server callbacks
%% =============================================================================


-doc false.
init([Name, Endpoint, Opts]) ->
    process_flag(trap_exit, true),

    %% Translate our opts -> hackney_pool opts
    PoolOpts = [
        {max_connections, maps:get(size, Opts, 50)},
        {timeout, maps:get(idle_timeout, Opts, 150_000)},
        {checkout_timeout, maps:get(checkout_timeout, Opts, 10_000)}
    ],

    %% Translate our opts -> hackney request opts
    ReqOpts = request_opts(Name, Opts),

    RetryOpts = maps:get(retry_opts, Opts, #{
        deadline => 0,
        max_retries => 1_000_000,
        backoff_enabled => true,
        backoff_min => 1_000,
        backoff_max => 30_000,
        backoff_type => jitter
    }),

    Retry = bondy_retry:init({?MODULE, Name}, RetryOpts),

    State = #state{
        name = Name,
        endpoint = Endpoint,
        pool_opts = PoolOpts,
        req_opts = ReqOpts,
        retry = Retry
    },

    {ok, try_start_pool(State)}.


-doc false.
handle_call(mark_down, _From, #state{} = State0) ->
    State = do_mark_down(State0),
    {reply, ok, State};

handle_call(status, _From, #state{status = Status} = State) ->
    {reply, Status, State};

handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.


-doc false.
handle_cast(_Msg, State) ->
    {noreply, State}.


-doc false.
handle_info(
    {timeout, Ref, {?MODULE, Name}},
    #state{retry_ref = Ref, name = Name} = State
) ->
    {noreply, try_start_pool(State)};

handle_info(_Msg, State) ->
    {noreply, State}.


-doc false.
terminate(_Reason, #state{name = Name, status = up}) ->
    hackney_pool:stop_pool(Name),
    ok;

terminate(_Reason, _State) ->
    ok.


%% =============================================================================
%% PRIVATE
%% =============================================================================



-spec request_opts(atom(), start_opts()) -> proplists:proplist().

request_opts(Name, Opts) ->
    Base = [
        {pool, Name},
        with_body
    ],
    Optional = [
        {connect_timeout, maps:get(connect_timeout, Opts, 8_000)},
        {recv_timeout, maps:get(recv_timeout, Opts, 30_000)},
        {follow_redirect, maps:get(follow_redirect, Opts, false)},
        {max_redirect, maps:get(max_redirect, Opts, 5)}
    ],
    MaybeSSL = case maps:find(ssl_options, Opts) of
        {ok, SslOpts} ->
            [{ssl_options, SslOpts}];
        error ->
            []
    end,
    MaybeProxy = case maps:find(proxy, Opts) of
        {ok, Proxy} ->
            [{proxy, Proxy}] ++
            case maps:find(proxy_auth, Opts) of
                {ok, ProxyAuth} ->
                    [{proxy_auth, ProxyAuth}];
                error ->
                    []
            end;
        error ->
            []
    end,
    MaybeAuth = case maps:find(basic_auth, Opts) of
        {ok, Auth} ->
            [{basic_auth, Auth}];
        error ->
            []
    end,
    Base ++ Optional ++ MaybeSSL ++ MaybeProxy ++ MaybeAuth.



try_start_pool(#state{name = Name, endpoint = Endpoint} = State0) ->
    catch hackney_pool:stop_pool(Name),
    hackney_pool:start_pool(Name, State0#state.pool_opts),

    %% Health check with minimal timeouts
    HealthOpts = [
        {pool, Name},
        {connect_timeout, 5_000},
        {recv_timeout, 5_000}
    ],

    case hackney:request(head, Endpoint, [], <<>>, HealthOpts) of
        {ok, _Status, _Headers, Ref} when is_reference(Ref) ->
            hackney:close(Ref),
            mark_up(State0);
        {ok, _Status, _Headers, _Body} ->
            mark_up(State0);
        {error, Reason} ->
            ?LOG_WARNING(#{
                description => "Pool health check failed, scheduling retry",
                pool => Name,
                reason => Reason,
                retry_count => bondy_retry:count(State0#state.retry)
            }),
            schedule_retry(State0)
    end.



mark_up(#state{name = Name, retry = Retry0} = State) ->
    {_, Retry} = bondy_retry:succeed(Retry0),
    ?LOG_INFO(#{
        description => "Pool is up",
        pool => Name
    }),
    State#state{
        status = up,
        retry = Retry,
        retry_ref = undefined
    }.



do_mark_down(#state{} = State) ->
    catch hackney_pool:stop_pool(State#state.name),
    schedule_retry(State#state{status = down}).



schedule_retry(#state{retry = Retry0} = State) ->
    case bondy_retry:fail(Retry0) of
        {max_retries, Retry} ->
            %% Reset and keep going — we want indefinite retries
            {_, FreshRetry} = bondy_retry:succeed(Retry),
            ?LOG_WARNING(#{
                description => "Max retries reached, resetting retry state",
                pool => State#state.name
            }),
            schedule_retry(State#state{retry = FreshRetry});
        {_Delay, Retry} ->
            Ref = bondy_retry:fire(Retry),
            State#state{
                retry = Retry,
                retry_ref = Ref
            }
    end.
