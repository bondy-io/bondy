%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_connector_http_pool).

-moduledoc """
A supervised hackney connection pool with automatic health-check retries using
bondy_retry. The pool is restarted when the endpoint becomes available again.

### Usage

```erlang
bondy_http_connector_http_pool:start_link(my_api_pool,
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

**Periodic liveness probe while up** — the health check above only runs at startup and while `down`, so on its own it leaves a service degrading mid-flight invisible until a live call happens to hit it. `liveness.*` config (`schema/bondy_http_connector.schema`) arms a self-rearming timer that re-probes on an interval while `up`, and after `failure_threshold` consecutive failures calls `do_mark_down/1`. Pool state flips back to `up` fail-open on the first successful recovery probe; the service-down alarm (`alarm_handler:set_alarm/1`, id `{http_connector_service_down, ServiceName}`) is gated separately by `success_threshold` consecutive successes so a flapping upstream doesn't flap the page while traffic still resumes as soon as it's reachable. See `bondy_http_connector_telemetry` for the emitted events and metric families.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-record(state, {
    name :: atom(),
    %% Human-readable service name (the label used for telemetry/alarms —
    %% `name` above is the mangled pool atom, not fit for a Prometheus label
    %% or an operator-facing alarm description).
    service_name :: binary(),
    endpoint :: binary(),
    pool_opts :: proplists:proplist(),
    req_opts :: proplists:proplist(),
    retry :: bondy_retry:t(),
    retry_ref :: reference() | undefined,
    status = down :: up | down,
    %% Periodic up-state health check (distinct from `retry`, which only
    %% runs while `down`). See `liveness_opts()`.
    liveness_opts :: liveness_opts(),
    liveness_timer :: reference() | undefined,
    consec_failures = 0 :: non_neg_integer(),
    consec_successes = 0 :: non_neg_integer(),
    last_error :: term()
}).

-type liveness_opts() :: #{
    enabled => boolean(),
    path => binary(),
    method => get | head,
    interval => timeout(),
    timeout => timeout(),
    failure_threshold => pos_integer(),
    success_threshold => pos_integer()
}.

-type start_opts() :: #{
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
    retry_opts => bondy_retry:opts(),
    %% Telemetry/alarm label (ours)
    service_name => binary(),
    %% Periodic up-state health check (ours)
    liveness => liveness_opts()
}.

-export_type([start_opts/0]).

%% API
-export([start_link/3]).
-export([status/1]).
-export([mark_down/1]).
-export([request/5]).
-export([request/6]).

%% Exported for testing
-export([liveness_url/2]).

%% gen_server callbacks
-export([init/1]).
-export([handle_continue/2]).
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

-doc """
Issue a request through the pool using its preconfigured request options
(`ssl_options`, timeouts, `with_body`, etc.). Returns `{error, pool_down}`
immediately while the pool is down so callers fail fast.
""".
-spec request(
    Pool :: atom(),
    Method :: atom(),
    Url :: binary(),
    Headers :: list(),
    Body :: iodata()
) ->
    {ok, non_neg_integer(), list(), binary()}
    | {error, pool_down | term()}.

request(Pool, Method, Url, Headers, Body) ->
    request(Pool, Method, Url, Headers, Body, []).

-doc """
Same as `request/5` but allows per-call overrides (e.g. `connect_timeout`,
`recv_timeout`) to be merged on top of the pool's stored options.
""".
-spec request(
    Pool :: atom(),
    Method :: atom(),
    Url :: binary(),
    Headers :: list(),
    Body :: iodata(),
    Overrides :: proplists:proplist()
) ->
    {ok, non_neg_integer(), list(), binary()}
    | {error, pool_down | term()}.

request(Pool, Method, Url, Headers, Body, Overrides) ->
    case persistent_term:get({?MODULE, Pool}, undefined) of
        {up, ReqOpts} ->
            Opts = merge_opts(Overrides, ReqOpts),
            hackney:request(Method, Url, Headers, Body, Opts);
        {down, _} ->
            {error, pool_down};
        undefined ->
            {error, pool_down}
    end.

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
        service_name = maps:get(service_name, Opts, atom_to_binary(Name)),
        endpoint = Endpoint,
        pool_opts = PoolOpts,
        req_opts = ReqOpts,
        retry = Retry,
        liveness_opts = maps:get(liveness, Opts, #{})
    },

    %% Publish in `down` state synchronously so callers see `pool_down`
    %% rather than `undefined` between supervisor return and the first
    %% health check completing. Defer the actual health probe to a
    %% continuation so init/1 returns immediately — otherwise N services
    %% with unreachable endpoints would block the manager's start_pools
    %% continuation for N × ~10s serially.
    ok = publish_status(State),
    {ok, State, {continue, init_pool}}.

-doc false.
handle_continue(init_pool, #state{} = State) ->
    {noreply, try_start_pool(State)}.

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
handle_info(
    {liveness_check, Name},
    #state{name = Name, status = up} = State
) ->
    {noreply, do_liveness_check(State)};
handle_info({liveness_check, _Name}, State) ->
    %% Pool is down (or this is a stale timer message racing a down
    %% transition that already cancelled it) — the down-state
    %% `bondy_retry` health check owns recovery; don't run a second,
    %% redundant probe cadence.
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

-doc false.
terminate(_Reason, #state{name = Name, status = up} = State) ->
    _ = cancel_liveness_timer(State),
    _ = persistent_term:erase({?MODULE, Name}),
    hackney_pool:stop_pool(Name),
    ok;
terminate(_Reason, #state{name = Name} = State) ->
    _ = cancel_liveness_timer(State),
    _ = persistent_term:erase({?MODULE, Name}),
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
    MaybeSSL =
        case maps:find(ssl_options, Opts) of
            {ok, SslOpts} ->
                [{ssl_options, SslOpts}];
            error ->
                [{ssl_options, default_ssl_options()}]
        end,
    MaybeProxy =
        case maps:find(proxy, Opts) of
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
    MaybeAuth =
        case maps:find(basic_auth, Opts) of
            {ok, Auth} ->
                [{basic_auth, Auth}];
            error ->
                []
        end,
    Base ++ Optional ++ MaybeSSL ++ MaybeProxy ++ MaybeAuth.

try_start_pool(#state{name = Name} = State0) ->
    %% Idempotent: hackney_pool:start_pool returns ok on first call and
    %% (silently / harmlessly) on subsequent calls when the pool already
    %% exists, so we don't tear down in-flight connections on every health
    %% retry. The pool itself is only destroyed in `do_mark_down/1` and on
    %% `terminate/2` — i.e. when state actually demands it.
    _ = hackney_pool:start_pool(Name, State0#state.pool_opts),

    case probe_endpoint(State0) of
        ok ->
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

%% Pool state flips to `up` fail-open, on the very first successful
%% probe — a service that is merely flaky shouldn't stay unreachable to
%% callers a moment longer than necessary. `liveness.success_threshold`
%% instead gates ALARM clearing (`maybe_clear_alarm/1`, also consulted
%% by every subsequent up-state probe in `handle_probe_success/1`): with
%% the default of 1 it clears immediately here, matching a plain
%% recover-on-first-success expectation; a higher threshold keeps the
%% alarm active — deliberately decoupled from traffic — until the
%% recovery looks stable, so a flapping upstream doesn't flap the page.
mark_up(
    #state{name = Name, service_name = ServiceName, retry = Retry0} = State0
) ->
    {_, Retry} = bondy_retry:succeed(Retry0),
    ?LOG_INFO(#{
        description => "Pool is up",
        pool => Name
    }),
    State1 = State0#state{
        status = up,
        retry = Retry,
        retry_ref = undefined,
        consec_failures = 0,
        consec_successes = 1,
        last_error = undefined
    },
    ok = publish_status(State1),
    ok = bondy_http_connector_telemetry:pool_status(ServiceName, up),
    ok = maybe_clear_alarm(State1),
    arm_liveness_timer(State1).

do_mark_down(#state{name = Name, service_name = ServiceName} = State0) ->
    catch hackney_pool:stop_pool(Name),
    _ = cancel_liveness_timer(State0),
    State1 = State0#state{status = down, liveness_timer = undefined},
    ok = publish_status(State1),
    ok = bondy_http_connector_telemetry:pool_status(ServiceName, down),
    ok = set_service_down_alarm(State1),
    schedule_retry(State1).

%% =============================================================================
%% LIVENESS PROBE
%% =============================================================================

%% @private
%% Issues the configured probe (method + path, default HEAD to the
%% service's bare endpoint) and normalises the outcome to `ok |
%% {error, Reason}`. Shared by the startup/down-state health check
%% (`try_start_pool/1`) and the periodic up-state liveness check
%% (`do_liveness_check/1`) so the two can't drift apart.
probe_endpoint(
    #state{name = Name, endpoint = Endpoint, liveness_opts = LOpts} = State
) ->
    Method = maps:get(method, LOpts, head),
    Timeout = maps:get(timeout, LOpts, 5_000),
    Url = liveness_url(Endpoint, LOpts),
    ReqOpts0 = [
        {pool, Name},
        {connect_timeout, Timeout},
        {recv_timeout, Timeout}
    ],
    ReqOpts =
        case proplists:get_value(ssl_options, State#state.req_opts) of
            undefined -> ReqOpts0;
            SslOpts -> [{ssl_options, SslOpts} | ReqOpts0]
        end,
    case hackney:request(Method, Url, [], <<>>, ReqOpts) of
        {ok, _Status, _Headers} ->
            ok;
        {ok, _Status, _Headers, Ref} when is_reference(Ref) ->
            hackney:close(Ref),
            ok;
        {ok, _Status, _Headers, _Body} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

-doc """
The default `liveness.path` (`/`) probes the bare endpoint — exactly
the pre-existing health-check behaviour. A configured path is appended,
normalising the slash between `Endpoint` and `Path` so callers can supply
either with or without a leading/trailing `/`.
""".
-spec liveness_url(Endpoint :: binary(), LivenessOpts :: liveness_opts()) ->
    binary().

liveness_url(Endpoint, LOpts) ->
    case maps:get(path, LOpts, <<"/">>) of
        <<"/">> ->
            Endpoint;
        Path ->
            Base =
                case binary:last(Endpoint) of
                    $/ -> binary:part(Endpoint, 0, byte_size(Endpoint) - 1);
                    _ -> Endpoint
                end,
            Path1 =
                case Path of
                    <<"/", _/binary>> -> Path;
                    _ -> <<"/", Path/binary>>
                end,
            <<Base/binary, Path1/binary>>
    end.

%% @private
%% Only ever scheduled while `up` (see the `handle_info/2` guard) — a
%% self-rearming periodic check independent of the down-state
%% `bondy_retry` cadence, so a service that degrades without a live WAMP
%% call happening to hit it is still detected.
do_liveness_check(#state{service_name = ServiceName} = State0) ->
    StartTs = erlang:monotonic_time(millisecond),
    Result = probe_endpoint(State0),
    DurationMs = erlang:monotonic_time(millisecond) - StartTs,
    case Result of
        ok ->
            ok = bondy_http_connector_telemetry:liveness_probe(
                ServiceName, ok, DurationMs
            ),
            handle_probe_success(State0);
        {error, Reason} ->
            ok = bondy_http_connector_telemetry:liveness_probe(
                ServiceName, error, DurationMs
            ),
            handle_probe_failure(State0, Reason)
    end.

%% @private
handle_probe_success(#state{consec_successes = Successes} = State0) ->
    State1 = State0#state{
        consec_failures = 0, consec_successes = Successes + 1
    },
    ok = maybe_clear_alarm(State1),
    arm_liveness_timer(State1).

%% @private
handle_probe_failure(#state{consec_failures = Failures0} = State0, Reason) ->
    LOpts = State0#state.liveness_opts,
    FailureThreshold = maps:get(failure_threshold, LOpts, 3),
    Failures = Failures0 + 1,
    State1 = State0#state{
        consec_failures = Failures,
        consec_successes = 0,
        last_error = Reason
    },
    case Failures >= FailureThreshold of
        true ->
            ?LOG_WARNING(#{
                description =>
                    "Liveness probe failure threshold reached, marking pool down",
                pool => State1#state.name,
                service => State1#state.service_name,
                consecutive_failures => Failures,
                reason => Reason
            }),
            %% Recovery is now owned by the down-state `bondy_retry` loop
            %% (`try_start_pool/1`, via `schedule_retry/1` inside
            %% `do_mark_down/1`), which re-arms the liveness timer through
            %% `mark_up/1` once it succeeds again — don't re-arm here.
            do_mark_down(State1);
        false ->
            arm_liveness_timer(State1)
    end.

%% @private
arm_liveness_timer(#state{name = Name, liveness_opts = LOpts} = State) ->
    case maps:get(enabled, LOpts, true) of
        false ->
            State;
        true ->
            Interval = maps:get(interval, LOpts, 30_000),
            Timer = erlang:send_after(Interval, self(), {liveness_check, Name}),
            State#state{liveness_timer = Timer}
    end.

%% @private
cancel_liveness_timer(#state{liveness_timer = undefined}) ->
    ok;
cancel_liveness_timer(#state{liveness_timer = Timer}) ->
    _ = erlang:cancel_timer(Timer),
    ok.

%% @private
%% Alarm id is a `{Tag, ServiceName}` pair (consistent with the existing
%% `bondy_alarm_handler` id convention — see e.g. the reclamation/AAE
%% alarms) so `bondy_alarm_active{alarm_id}` (bondy_prometheus_db) carries
%% the service in its label without a second dimension.
set_service_down_alarm(#state{
    service_name = ServiceName, endpoint = Endpoint, last_error = LastError
}) ->
    Desc = #{service => ServiceName, endpoint => Endpoint, reason => LastError},
    alarm_handler:set_alarm({{http_connector_service_down, ServiceName}, Desc}).

%% @private
%% Clears the alarm once `liveness.success_threshold` consecutive
%% probes have succeeded (default 1 — clears on the spot). Idempotent:
%% `bondy_alarm_handler:clear_alarm/1` on an id that isn't currently
%% set is a harmless no-op, so calling this on every post-recovery
%% probe until the threshold is reached is safe.
maybe_clear_alarm(#state{
    service_name = ServiceName,
    consec_successes = Successes,
    liveness_opts = LOpts
}) ->
    SuccessThreshold = maps:get(success_threshold, LOpts, 1),
    case Successes >= SuccessThreshold of
        true ->
            alarm_handler:clear_alarm(
                {http_connector_service_down, ServiceName}
            );
        false ->
            ok
    end.

%% @private
default_ssl_options() ->
    bondy_cert_manager:ssl_opts().

%% @private
%% Persistent_term writes trigger a major GC of all persistent_term
%% consumers, so skip when the value isn't actually changing. ReqOpts is
%% set once at init and never mutates, so the only thing that flips after
%% startup is Status — ignoring no-op transitions there is what matters.
publish_status(#state{name = Name, status = Status, req_opts = ReqOpts}) ->
    Key = {?MODULE, Name},
    Value = {Status, ReqOpts},
    case persistent_term:get(Key, undefined) of
        Value ->
            ok;
        _ ->
            persistent_term:put(Key, Value),
            ok
    end.

%% @private
%% Merge per-call overrides on top of pool defaults. lists:keymerge would
%% require sorting; this preserves the pool's option order which matters for
%% hackney (later proplist entries win, so we put overrides last).
merge_opts([], ReqOpts) ->
    ReqOpts;
merge_opts(Overrides, ReqOpts) ->
    Filtered = [
        Opt
     || Opt <- ReqOpts,
        not lists:keymember(opt_key(Opt), 1, Overrides)
    ],
    Filtered ++ Overrides.

%% @private
opt_key({K, _}) -> K;
opt_key(K) when is_atom(K) -> K.

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
