%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rate_limiter).
-moduledoc """
Keyed, garbage-collected token-bucket rate limiting over
`bondy_regulator_rate_limit`.

`bondy_regulator_rate_limit` provides a single token bucket per explicit key and
leaves lifecycle to the caller — ideal for a long-lived per-connection bucket,
but not for limits keyed on an UNBOUNDED, transient dimension such as a source
IP address (pre-auth connection / auth-attempt throttles). This module adds that
missing layer:

- **get-or-create** — the first `allow/2` for a key mints its bucket; subsequent
  calls reuse it. The hit path is a single lockless `ets:lookup/2` +
  `ets:update_element/3` (last-access touch) + the atomics-based bucket check,
  so it adds no process hop and no lock on the hot path.
- **GC** — a `gen_server` owns the registry ETS table and periodically sweeps
  buckets idle for longer than a TTL, deleting the registry row AND the
  underlying `bondy_regulator_rate_limit` bucket, so keyspace can't grow without
  bound under a churning-IP flood.

`allow/2` never blocks and never raises: an out-of-tokens result is `false`; if
the limiter subsystem is somehow unavailable it FAILS OPEN (`true`) rather than
wedging the inbound path — availability of the router outranks the rate limit.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-define(TAB, ?MODULE).
-define(DEFAULT_TTL_MS, 600000).
-define(DEFAULT_SWEEP_MS, 60000).

-record(state, {
    ttl_ms :: pos_integer(),
    sweep_ms :: pos_integer()
}).

-type rate_opts() :: #{rate => number(), capacity => pos_integer(), _ => _}.

-export_type([rate_opts/0]).

%% API
-export([allow/2]).
-export([allow/3]).
-export([forget/1]).

%% gen_server
-export([start_link/0]).
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%% =============================================================================
%% API
%% =============================================================================

-doc "Equivalent to `allow(Key, RateOpts, 1)`.".
-spec allow(Key :: term(), RateOpts :: rate_opts()) -> boolean().

allow(Key, RateOpts) ->
    allow(Key, RateOpts, 1).

-doc """
Consumes `Increment` tokens from the bucket identified by `Key`, creating the
bucket (from `RateOpts`) on first use. Returns `true` if allowed, `false` when
the bucket is exhausted. Fails open (`true`) if the registry table is
unavailable.
""".
-spec allow(Key :: term(), RateOpts :: rate_opts(), Increment :: pos_integer()) ->
    boolean().

allow(Key, RateOpts, Increment) when is_map(RateOpts), is_integer(Increment) ->
    try ets:lookup(?TAB, Key) of
        [{Key, Bucket, _Last}] ->
            _ = ets:update_element(?TAB, Key, {3, now_ms()}),
            consume(Bucket, Increment);
        [] ->
            allow_new(Key, RateOpts, Increment)
    catch
        error:badarg ->
            %% Registry table not started (e.g. app not fully up) — fail open.
            true
    end.

-doc "Deletes the bucket for `Key` (registry row + regulator bucket).".
-spec forget(Key :: term()) -> ok.

forget(Key) ->
    case ets:lookup(?TAB, Key) of
        [{Key, Bucket, _}] ->
            catch bondy_regulator_rate_limit:delete(Bucket),
            true = ets:delete(?TAB, Key),
            ok;
        [] ->
            ok
    end.

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    %% Public so the hot path reads/writes without a process hop; the gen_server
    %% owns it so a limiter crash does not lose it silently.
    _ = ets:new(?TAB, [
        named_table,
        public,
        set,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    SweepMs = cfg(sweep_interval_ms, ?DEFAULT_SWEEP_MS),
    State = #state{
        ttl_ms = cfg(idle_ttl_ms, ?DEFAULT_TTL_MS),
        sweep_ms = SweepMs
    },
    _ = erlang:send_after(SweepMs, self(), sweep),
    {ok, State}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(sweep, #state{ttl_ms = Ttl, sweep_ms = SweepMs} = State) ->
    _ = sweep(Ttl),
    _ = erlang:send_after(SweepMs, self(), sweep),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
consume(Bucket, Increment) ->
    case bondy_regulator_rate_limit:allow(Bucket, Increment) of
        {true, _} -> true;
        {false, _} -> false
    end.

%% @private
%% Create the bucket for a new key. `ets:insert_new/2` makes create race-safe:
%% if a concurrent caller won, delete our just-made regulator bucket and reuse
%% the winner's.
allow_new(Key, RateOpts, Increment) ->
    RegKey = {?MODULE, Key},
    case bondy_regulator_rate_limit:new(token_bucket, RegKey, RateOpts) of
        {ok, Bucket} ->
            case ets:insert_new(?TAB, {Key, Bucket, now_ms()}) of
                true ->
                    consume(Bucket, Increment);
                false ->
                    catch bondy_regulator_rate_limit:delete(Bucket),
                    allow(Key, RateOpts, Increment)
            end;
        {error, Reason} ->
            ?LOG_WARNING(#{
                description =>
                    "Could not create rate-limit bucket; failing open",
                key => Key,
                reason => Reason
            }),
            true
    end.

%% @private
sweep(Ttl) ->
    Cutoff = now_ms() - Ttl,
    %% Collect idle keys, then delete each (registry row + regulator bucket).
    MS = [{{'$1', '$2', '$3'}, [{'<', '$3', Cutoff}], [{{'$1', '$2'}}]}],
    Idle = ets:select(?TAB, MS),
    lists:foreach(
        fun({Key, Bucket}) ->
            catch bondy_regulator_rate_limit:delete(Bucket),
            ets:delete(?TAB, Key)
        end,
        Idle
    ),
    length(Idle).

%% @private
now_ms() ->
    erlang:system_time(millisecond).

%% @private
cfg(Key, Default) ->
    application:get_env(bondy_regulator, Key, Default).
