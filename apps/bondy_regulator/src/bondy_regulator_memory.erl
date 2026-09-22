%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_regulator_memory).
-moduledoc """
Node memory monitor: a periodic sampler of the node's memory use against its
limit, exposing a binary high/normal status through a lock-free read
(`high/0`) — the memory counterpart of `bondy_regulator_load`.

## What is measured

The limit that kills a node is the one the kernel enforces, so inside a
cgroup the monitor reads the cgroup: usage is the cgroup's anonymous memory
(`anon` in `memory.stat` under cgroup v2, `total_rss` under v1) and the limit
is `memory.max` (`memory.limit_in_bytes` under v1). Anonymous memory is where
the BEAM's heaps, binaries and ETS tables live and what the kernel cannot
reclaim; page cache is left out because the kernel reclaims it under pressure
before it kills anything. `erlang:memory(total)` is not used there: it does
not include the allocators' carrier overhead, so it reads below what the
kernel bills.

When `memory_monitor_limit` is configured it wins: usage is then
`erlang:memory(total)` against that limit, which is the only reading
available outside a cgroup (a developer's machine, a bare VM). With neither a
limit configured nor a bounded cgroup there is nothing to compare against;
the monitor says so once at start and never reports high.

## Status

`high` is entered when the sampled usage reaches `high_watermark` percent of
the limit and left when it falls to `low_watermark` percent, each crossing
held for three consecutive samples before it is committed — the same
hysteresis and dwell as the load monitor, for the same reason: one sample is
not a state. The transitions raise and clear the `bondy_memory_high` alarm,
whose details carry the usage and limit; `usage/0` reads the last sample.

`high/0` never blocks and never raises: one `atomics` read through a
`persistent_term`-cached ref, failing open (`false`) when the monitor is not
running — availability outranks regulation. Consumers refuse NEW work while
it holds; they do not shed work already admitted.

Pinned by `bondy_regulator_memory_test`: the hysteresis and dwell through
`step/3`, the cgroup readers against fixture directories, and the whole
sampler driven from a fixture through both transitions, alarm included.

Configuration (`bondy_regulator` application environment, set via the
`load_regulation.memory_monitor.*` cuttlefish mappings):

- `memory_monitor_high_watermark` — percent of the limit at which the node
  becomes high (default 85).
- `memory_monitor_low_watermark` — percent at which it returns to normal
  (default 75).
- `memory_monitor_sample_interval_ms` — sampling period (default 1000).
- `memory_monitor_limit` — bytes; when set, overrides the cgroup.
- `memory_monitor_cgroup_root` — where the cgroup files are read from
  (default `"/sys/fs/cgroup"`); the seam the tests use.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-define(PT_KEY, {?MODULE, status}).
-define(STATUS_SLOT, 1).
-define(USAGE_SLOT, 2).
-define(LIMIT_SLOT, 3).
-define(SOURCE_SLOT, 4).
-define(DEFAULT_HIGH_WATERMARK, 85).
-define(DEFAULT_LOW_WATERMARK, 75).
-define(DEFAULT_SAMPLE_INTERVAL_MS, 1000).
-define(DEFAULT_CGROUP_ROOT, "/sys/fs/cgroup").
%% Same dwell as the load monitor; see its `?DWELL_SAMPLES`.
-define(DWELL_SAMPLES, 3).
-define(ALARM_ID, bondy_memory_high).
%% cgroup v1 reports "no limit" as the largest page-aligned signed 64-bit
%% value; anything in that range is unlimited.
-define(V1_UNLIMITED_FLOOR, 1 bsl 62).

-type source() :: none | explicit | cgroup_v2 | cgroup_v1.
-type reading() :: {ok, {Usage :: non_neg_integer(), Limit :: pos_integer()}}.

-record(state, {
    ref :: atomics:atomics_ref(),
    source :: source(),
    root :: string(),
    %% The configured limit; only meaningful for `explicit`.
    limit :: pos_integer() | undefined,
    high :: pos_integer(),
    low :: non_neg_integer(),
    interval_ms :: pos_integer(),
    %% Consecutive samples the pending (not yet committed) status has held.
    dwell = 0 :: non_neg_integer()
}).

%% API
-export([high/0]).
-export([start_link/0]).
-export([status/0]).
-export([usage/0]).

-ifdef(TEST).
%% `step/3' for the dwell window (see the load monitor); `read_cgroup/2' so
%% the readers can be driven against fixture directories.
-export([read_cgroup/2]).
-export([step/3]).
-endif.

%% GEN_SERVER CALLBACKS
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([init/1]).
-export([terminate/2]).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link() -> {ok, pid()} | ignore | {error, any()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Returns `true` when the node is in the high state. Lock-free (one atomics
read); fails open (`false`) when the monitor is not running.
""".
-spec high() -> boolean().

high() ->
    case persistent_term:get(?PT_KEY, undefined) of
        undefined ->
            false;
        Ref ->
            atomics:get(Ref, ?STATUS_SLOT) == 1
    end.

-doc "Returns the current status. Fails open (`normal`).".
-spec status() -> normal | high.

status() ->
    case high() of
        true -> high;
        false -> normal
    end.

-doc """
The last sample: usage and limit in bytes and where they were read from.
Zeros and `none` when the monitor is not running or has no source.
""".
-spec usage() ->
    #{
        status := normal | high,
        usage_bytes := non_neg_integer(),
        limit_bytes := non_neg_integer(),
        source := source()
    }.

usage() ->
    case persistent_term:get(?PT_KEY, undefined) of
        undefined ->
            #{
                status => normal,
                usage_bytes => 0,
                limit_bytes => 0,
                source => none
            };
        Ref ->
            #{
                status => status(),
                usage_bytes => atomics:get(Ref, ?USAGE_SLOT),
                limit_bytes => atomics:get(Ref, ?LIMIT_SLOT),
                source => decode_source(atomics:get(Ref, ?SOURCE_SLOT))
            }
    end.

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

init([]) ->
    High = get_env(memory_monitor_high_watermark, ?DEFAULT_HIGH_WATERMARK),
    Low = get_env(memory_monitor_low_watermark, ?DEFAULT_LOW_WATERMARK),
    IntervalMs = get_env(
        memory_monitor_sample_interval_ms, ?DEFAULT_SAMPLE_INTERVAL_MS
    ),
    Root = get_root(),
    {Source, Limit} = resolve_source(Root),

    Ref =
        case persistent_term:get(?PT_KEY, undefined) of
            undefined ->
                New = atomics:new(4, []),
                ok = persistent_term:put(?PT_KEY, New),
                New;
            Existing ->
                %% A restart reuses the published ref (readers hold no
                %% subscription to invalidate); reset to normal. A previous
                %% incarnation killed without `terminate/2' may have left
                %% its alarm up: nothing but a high-to-normal transition
                %% clears it, and a fresh monitor starts at normal.
                atomics:get(Existing, ?STATUS_SLOT) =:= 1 andalso
                    alarm_handler:clear_alarm(?ALARM_ID),
                ok = atomics:put(Existing, ?STATUS_SLOT, 0),
                Existing
        end,
    ok = atomics:put(Ref, ?SOURCE_SLOT, encode_source(Source)),

    State = #state{
        ref = Ref,
        source = Source,
        root = Root,
        limit = Limit,
        high = max(1, High),
        low = max(0, Low),
        interval_ms = IntervalMs
    },

    case Source of
        none ->
            ?LOG_NOTICE(#{
                description =>
                    "Memory monitor has no limit to compare against: no "
                    "memory_monitor_limit is configured and the node is not "
                    "in a bounded cgroup. The node will never report memory "
                    "high.",
                cgroup_root => Root
            }),
            {ok, State};
        _ ->
            ?LOG_INFO(#{
                description => "Memory monitor started.",
                source => Source,
                high_watermark_pct => High,
                low_watermark_pct => Low,
                sample_interval_ms => IntervalMs
            }),
            {ok, schedule_sample(State)}
    end.

handle_call(Event, From, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event,
        from => From
    }),
    {reply, {error, {unsupported_call, Event}}, State}.

handle_cast(Event, State) ->
    ?LOG_WARNING(#{
        reason => unsupported_event,
        event => Event
    }),
    {noreply, State}.

handle_info(sample, State0) ->
    #state{ref = Ref, high = High, low = Low, dwell = Dwell0} = State0,
    {Usage, Limit} = sample(State0),
    ok = atomics:put(Ref, ?USAGE_SLOT, Usage),
    ok = atomics:put(Ref, ?LIMIT_SLOT, Limit),

    Pct = percent(Usage, Limit),
    Status = atomics:get(Ref, ?STATUS_SLOT),
    Pending = transition(Status, Pct, High, Low),

    State =
        case step(Status, Pending, Dwell0) of
            {hold, Dwell} ->
                State0#state{dwell = Dwell};
            {commit, 1} ->
                ok = atomics:put(Ref, ?STATUS_SLOT, 1),
                Source = State0#state.source,
                Desc = <<
                    "Node memory use is above the high watermark: admission "
                    "gates refuse new work until it falls below the low "
                    "watermark."
                >>,
                ?LOG_NOTICE(#{
                    description => Desc,
                    usage_bytes => Usage,
                    limit_bytes => Limit,
                    usage_pct => Pct,
                    high_watermark_pct => High,
                    low_watermark_pct => Low,
                    source => Source,
                    dwell_samples => ?DWELL_SAMPLES
                }),
                %% The 3-tuple is how an app outside `bondy_router` reaches
                %% the alarm's `details`; see `bondy_alarm_handler:set_alarm/2`.
                alarm_handler:set_alarm(
                    {
                        ?ALARM_ID,
                        Desc,
                        #{
                            details => #{
                                usage_bytes => Usage,
                                limit_bytes => Limit,
                                source => Source
                            }
                        }
                    }
                ),
                State0#state{dwell = 0};
            {commit, 0} ->
                ok = atomics:put(Ref, ?STATUS_SLOT, 0),
                ?LOG_NOTICE(#{
                    description => "Node memory use returned to normal.",
                    usage_bytes => Usage,
                    limit_bytes => Limit,
                    usage_pct => Pct,
                    low_watermark_pct => Low,
                    dwell_samples => ?DWELL_SAMPLES
                }),
                alarm_handler:clear_alarm(?ALARM_ID),
                State0#state{dwell = 0}
        end,

    {noreply, schedule_sample(State)};
handle_info(Info, State) ->
    ?LOG_DEBUG(#{
        reason => unsupported_event,
        event => Info
    }),
    {noreply, State}.

terminate(_Reason, #state{ref = Ref}) ->
    %% Fail open while we are down: the gates read normal, and the alarm
    %% goes with it -- an alarm with no monitor behind it would outlive the
    %% condition, since only a sample can clear it.
    case atomics:exchange(Ref, ?STATUS_SLOT, 0) of
        1 -> alarm_handler:clear_alarm(?ALARM_ID);
        0 -> ok
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% The dwell step, as in `bondy_regulator_load'. A crossing is committed only
%% once it has held for `?DWELL_SAMPLES` consecutive samples; a return to the
%% committed side voids any partial dwell.
step(Status, Status, _Dwell) ->
    {hold, 0};
step(_Status, Pending, Dwell) when Dwell + 1 >= ?DWELL_SAMPLES ->
    {commit, Pending};
step(_Status, _Pending, Dwell) ->
    {hold, Dwell + 1}.

%% @private
%% The hysteresis step: `1` (high) at or above the high watermark, `0`
%% (normal) at or below the low watermark, unchanged in between.
transition(0, Pct, High, _Low) when Pct >= High ->
    1;
transition(1, Pct, _High, Low) when Pct =< Low ->
    0;
transition(Status, _Pct, _High, _Low) ->
    Status.

%% @private
percent(_Usage, 0) ->
    0;
percent(Usage, Limit) ->
    Usage * 100 div Limit.

%% @private
%% One reading. A cgroup whose limit went away (`max`, or a file the kernel
%% no longer exposes) reads as `{0, 0}`, which the hysteresis turns into a
%% return to normal after the dwell — no limit, nothing to be high against.
-spec sample(#state{}) -> {non_neg_integer(), non_neg_integer()}.

sample(#state{source = explicit, limit = Limit}) ->
    {erlang:memory(total), Limit};
sample(#state{source = Source, root = Root}) ->
    case read_cgroup(Source, Root) of
        {ok, {Usage, Limit}} -> {Usage, Limit};
        _ -> {0, 0}
    end.

%% @private
%% An explicit limit wins; otherwise the first cgroup layout that reads with
%% a finite limit; otherwise `none`.
-spec resolve_source(string()) -> {source(), pos_integer() | undefined}.

resolve_source(Root) ->
    case application:get_env(bondy_regulator, memory_monitor_limit) of
        {ok, Limit} when is_integer(Limit), Limit > 0 ->
            {explicit, Limit};
        _ ->
            case read_cgroup(cgroup_v2, Root) of
                {ok, _} ->
                    {cgroup_v2, undefined};
                _ ->
                    case read_cgroup(cgroup_v1, Root) of
                        {ok, _} -> {cgroup_v1, undefined};
                        _ -> {none, undefined}
                    end
            end
    end.

%% @private
%% Reads usage and limit from a cgroup rooted at `Root'. `unlimited' when the
%% cgroup exists but sets no limit; `{error, _}' when the files are absent or
%% unreadable.
-spec read_cgroup(cgroup_v2 | cgroup_v1, string()) ->
    reading() | unlimited | {error, term()}.

read_cgroup(cgroup_v2, Root) ->
    case read_integer_or(filename:join(Root, "memory.max"), <<"max">>) of
        {ok, unlimited} ->
            unlimited;
        {ok, Limit} ->
            with_stat(filename:join(Root, "memory.stat"), [<<"anon">>], Limit);
        {error, _} = Err ->
            Err
    end;
read_cgroup(cgroup_v1, Root) ->
    Dir = filename:join(Root, "memory"),
    case read_integer_or(filename:join(Dir, "memory.limit_in_bytes"), none) of
        {ok, Limit} when Limit >= ?V1_UNLIMITED_FLOOR ->
            unlimited;
        {ok, Limit} ->
            with_stat(
                filename:join(Dir, "memory.stat"),
                [<<"total_rss">>, <<"rss">>],
                Limit
            );
        {error, _} = Err ->
            Err
    end.

%% @private
with_stat(StatFile, Keys, Limit) ->
    case stat_value(StatFile, Keys) of
        {ok, Usage} -> {ok, {Usage, Limit}};
        {error, _} = Err -> Err
    end.

%% @private
%% The integer in a one-value cgroup file, or `unlimited' when the file holds
%% `Sentinel' (`max' under v2).
read_integer_or(File, Sentinel) ->
    case file:read_file(File) of
        {ok, Bin} ->
            case string:trim(Bin) of
                Sentinel -> {ok, unlimited};
                Trimmed -> to_integer(Trimmed, File)
            end;
        {error, Reason} ->
            {error, {Reason, File}}
    end.

%% @private
%% The value of the first of `Keys' present in a `memory.stat' file
%% (`key value' lines).
stat_value(File, Keys) ->
    case file:read_file(File) of
        {ok, Bin} ->
            Lines = binary:split(Bin, <<"\n">>, [global, trim_all]),
            Stat = maps:from_list([
                {K, V}
             || Line <- Lines,
                [K, V] <- [binary:split(Line, <<" ">>)]
            ]),
            first_key(Keys, Stat, File);
        {error, Reason} ->
            {error, {Reason, File}}
    end.

%% @private
first_key([], _Stat, File) ->
    {error, {missing_stat_key, File}};
first_key([Key | Rest], Stat, File) ->
    case Stat of
        #{Key := V} -> to_integer(V, File);
        _ -> first_key(Rest, Stat, File)
    end.

%% @private
to_integer(Bin, File) ->
    try
        {ok, binary_to_integer(Bin)}
    catch
        error:badarg -> {error, {not_an_integer, File}}
    end.

%% @private
schedule_sample(#state{interval_ms = IntervalMs} = State) ->
    _ = erlang:send_after(IntervalMs, self(), sample),
    State.

%% @private
get_root() ->
    case application:get_env(bondy_regulator, memory_monitor_cgroup_root) of
        {ok, Root} when is_list(Root) -> Root;
        _ -> ?DEFAULT_CGROUP_ROOT
    end.

%% @private
get_env(Key, Default) ->
    case application:get_env(bondy_regulator, Key) of
        {ok, Value} when is_integer(Value), Value >= 0 ->
            Value;
        _ ->
            Default
    end.

%% @private
encode_source(none) -> 0;
encode_source(explicit) -> 1;
encode_source(cgroup_v2) -> 2;
encode_source(cgroup_v1) -> 3.

%% @private
decode_source(0) -> none;
decode_source(1) -> explicit;
decode_source(2) -> cgroup_v2;
decode_source(3) -> cgroup_v1.
