%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_wal_scrubber).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").
-include("bondy_oplog_wal.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Per-instance integrity scrubber.

Walks every sealed segment's frames on a configurable cadence and
verifies each frame's CRC against the same primitive the reader uses
(`bondy_oplog_wal_frame:decode/1`). On the first bad frame in a
segment it records an alert in the manifest via
`bondy_oplog_wal:mark_segment_alert/3` so the segment surfaces in
`bondy_oplog_wal:info/1` and through the
`[bondy_oplog, wal, scrub, segment]` telemetry event.

## What it does

- Sealed segments only. The head segment is appended to by the writer
  concurrently; CRC-walking it under append would race the writer. Head
  integrity is the writer's own responsibility (frames CRC'd on encode,
  recovery scans them on next open).
- Once-per-segment alerting. If a segment is already in the manifest's
  `scrubber_alerts`, the scrubber skips re-walking it. An operator
  clears the alert via `bondy_oplog_wal:clear_segment_alert/2` after
  re-deriving the segment (anti-entropy from peers / snapshot restore).
- Does not auto-repair. The scrubber's sole job is detection; the
  recovery path is operator-driven.
- Read-only file access. Opens each segment with `[read, raw, binary]`
  and closes immediately after the walk; never holds a fd across a
  segment boundary.

## Configuration

| Key | Default | Meaning |
|---|---|---|
| `interval_ms` | `0` (disabled) | Cadence between scrub runs. `0` keeps the gen_server idle; manual triggering via `scrub_now/1` still works (handy for tests and operator-initiated checks). |

The interval is jittered by ±10% per tick so a fleet of instances does
not synchronize its scrub I/O.

## Telemetry

Per segment walked, one event:

```
[bondy_oplog, wal, scrub, segment]
  measurements: frames_checked, bad_crc, bad_magic, truncated_segment,
                duration_us, bytes_checked
  metadata:     instance_id, segment_id, outcome
```

`outcome` is one of:

- `ok` — segment walked clean.
- `alert` — at least one frame was bad; the segment is marked in the
  manifest. `bad_crc`, `bad_magic`, `truncated_segment` carry the
  frame-class counts.
- `skipped` — segment already alerted; not re-walked.
- `gone` — segment file disappeared between manifest read and open
  (concurrent retention sweep); treated as a soft no-op.

Per scrub run, one roll-up event:

```
[bondy_oplog, wal, scrub, run]
  measurements: segments_walked, segments_skipped, alerts_raised,
                frames_checked, bytes_checked, bad_crc, bad_magic,
                truncated_segment, duration_us
  metadata:     instance_id, trigger
```

`trigger` is `manual` (`scrub_now/1`) or `tick` (periodic).
`segments_skipped` counts already-alerted segments observed during
the run; `segments_walked` counts the ones actually re-CRC'd.

## Crash semantics

The scrubber is a passive observer with no state across restarts. It
runs as a peer child of `bondy_oplog_instance_sup`, whose `one_for_all`
strategy means a scrubber crash also restarts the writer and applier.
That cost is acceptable because the scrubber's hot path is read-only
file I/O on sealed segments — crash-prone code surface is small —
and operators wanting an extra safety net simply leave `interval_ms`
at its default of `0` (no automatic walks).
""").

-record(state, {
    instance_id :: binary(),
    interval_ms :: non_neg_integer(),
    timer_ref :: undefined | reference(),
    last_run_at_us :: undefined | integer()
}).

-type opts() :: #{
    instance_id := binary(),
    interval_ms => non_neg_integer()
}.

-export_type([opts/0]).

-export([start_link/1]).
-export([child_spec/1]).
-export([stop/1]).
-export([scrub_now/1]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

-define(SEG_HEADER_BYTES, ?BONDY_OPLOG_WAL_SEGMENT_HEADER_BYTES).
-define(FRAME_HEADER_BYTES, ?BONDY_OPLOG_WAL_FRAME_HEADER_BYTES).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link(opts()) -> {ok, pid()} | {error, term()}.

start_link(#{instance_id := InstanceId} = Opts) when is_binary(InstanceId) ->
    gen_server:start_link(?MODULE, Opts, []).

-spec child_spec(opts()) -> supervisor:child_spec().

child_spec(#{instance_id := InstanceId} = Opts) ->
    #{
        id => {?MODULE, InstanceId},
        start => {?MODULE, start_link, [Opts]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

-spec stop(pid()) -> ok.

stop(Pid) when is_pid(Pid) ->
    try gen_server:stop(Pid, normal, 5000) of
        ok -> ok
    catch
        exit:noproc -> ok;
        exit:{noproc, _} -> ok
    end.

?DOC("""
Triggers an immediate scrub run, synchronously.

Returns `{ok, #{segments_walked => N, alerts_raised => M,
duration_us => D}}` once the run completes. Used by tests and by
operators for ad-hoc verification.
""").
-spec scrub_now(pid()) -> {ok, map()} | {error, term()}.

scrub_now(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, scrub_now, infinity).

%% =============================================================================
%% gen_server CALLBACKS
%% =============================================================================

init(#{instance_id := InstanceId} = Opts) ->
    Interval = maps:get(interval_ms, Opts, 0),
    State = #state{
        instance_id = InstanceId,
        interval_ms = Interval
    },
    {ok, arm_timer(State)}.

handle_call(scrub_now, _From, State0) ->
    {Reply, State1} = do_scrub(State0, manual),
    {reply, {ok, Reply}, State1};
handle_call(_Req, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(scrub_tick, State0) ->
    State1 = State0#state{timer_ref = undefined},
    {_Summary, State2} = do_scrub(State1, tick),
    {noreply, arm_timer(State2)};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #state{timer_ref = Ref}) when is_reference(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok;
terminate(_Reason, _State) ->
    ok.

%% =============================================================================
%% PRIVATE — scheduling
%% =============================================================================

%% @private
%% Arm the next tick. Jittered by ±10% so a fleet of instances spreads
%% its scrub I/O across the interval. `Interval = 0` keeps the
%% gen_server idle (no tick scheduled); manual `scrub_now/1` still
%% works.
arm_timer(#state{interval_ms = 0} = State) ->
    State#state{timer_ref = undefined};
arm_timer(#state{interval_ms = Interval} = State) when Interval > 0 ->
    Jitter =
        erlang:phash2(make_ref(), Interval div 5 + 1) -
            (Interval div 10),
    Delay = max(1, Interval + Jitter),
    Ref = erlang:send_after(Delay, self(), scrub_tick),
    State#state{timer_ref = Ref}.

%% =============================================================================
%% PRIVATE — scrub run
%% =============================================================================

%% @private
%% Resolve the WAL writer via the registry, fetch its info, walk each
%% sealed segment, and return a summary. Returns `{Summary, NewState}`
%% so the caller can choose between returning the summary (manual
%% trigger) and discarding it (periodic tick). Emits one
%% `[bondy_oplog, wal, scrub, run]` event per call carrying the
%% aggregated counters.
do_scrub(#state{instance_id = InstanceId} = State, Trigger) ->
    T0 = erlang:monotonic_time(microsecond),
    Outcome =
        case bondy_oplog_registry:wal_pid(InstanceId) of
            undefined ->
                empty_summary(#{error => wal_pid_not_registered});
            WalPid ->
                walk_all_segments(InstanceId, WalPid)
        end,
    Duration = erlang:monotonic_time(microsecond) - T0,
    Summary = Outcome#{duration_us => Duration},
    emit_run_event(InstanceId, Trigger, Summary),
    {Summary, State#state{last_run_at_us = T0}}.

%% @private
%% Zero summary template; reused for early-exit paths (no wal pid in
%% registry, info call failed). Includes the same keys the happy path
%% reports so downstream dashboards never see missing measurements.
empty_summary(Extra) ->
    maps:merge(
        #{
            segments_walked => 0,
            segments_skipped => 0,
            alerts_raised => 0,
            frames_checked => 0,
            bytes_checked => 0,
            bad_crc => 0,
            bad_magic => 0,
            truncated_segment => 0
        },
        Extra
    ).

%% @private
%% Snapshot the WAL's info, derive the sealed-segment list (live minus
%% head minus already-alerted), and walk each in order.
walk_all_segments(InstanceId, WalPid) ->
    try bondy_oplog_wal:info(WalPid) of
        Info ->
            Dir = maps:get(dir, Info),
            Live = maps:get(live_segments, Info),
            Head = maps:get(current_segment, Info),
            Alerted = [Id || {Id, _} <- maps:get(scrubber_alerts, Info, [])],
            Sealed = [Id || Id <- Live, Id =/= Head],
            ToWalk = [Id || Id <- Sealed, not lists:member(Id, Alerted)],
            walk_each(InstanceId, WalPid, Dir, Sealed, Alerted, ToWalk)
    catch
        exit:{noproc, _} ->
            empty_summary(#{error => wal_no_longer_running});
        exit:{timeout, _} ->
            empty_summary(#{error => wal_info_timeout})
    end.

%% @private
walk_each(InstanceId, WalPid, Dir, Sealed, Alerted, ToWalk) ->
    SkippedIds = [Id || Id <- Sealed, lists:member(Id, Alerted)],
    %% Emit a skipped event per already-alerted segment so dashboards
    %% see that the scrubber observed but chose not to re-walk it. Keeps
    %% the per-segment event-count steady across runs.
    lists:foreach(
        fun(SegId) ->
            emit_segment_event(
                InstanceId, SegId, skipped, zero_segment_measurements()
            )
        end,
        SkippedIds
    ),
    %% Walked segments. Each returns `{Outcome, Counts}` so per-run
    %% aggregation does not require re-parsing telemetry events.
    Walks = [
        walk_one(InstanceId, WalPid, Dir, SegId)
     || SegId <- ToWalk
    ],
    Alerts = length([Outcome || {Outcome, _} <- Walks, Outcome =:= alert]),
    Agg = aggregate_counts([Counts || {_, Counts} <- Walks]),
    Agg#{
        segments_walked => length(Walks),
        segments_skipped => length(SkippedIds),
        alerts_raised => Alerts
    }.

%% @private
%% Sums the per-segment counter maps into a single map keyed by the
%% counter names. Keeps `duration_us` out of the aggregate — the
%% caller stamps the run's own `duration_us` after aggregation.
aggregate_counts(Maps) ->
    Init = zero_segment_measurements(),
    Init1 = maps:remove(duration_us, Init),
    lists:foldl(
        fun(M, Acc) ->
            maps:fold(
                fun
                    (duration_us, _, A) -> A;
                    (K, V, A) -> A#{K := maps:get(K, A, 0) + V}
                end,
                Acc,
                M
            )
        end,
        Init1,
        Maps
    ).

%% @private
zero_segment_measurements() ->
    #{
        frames_checked => 0,
        bad_crc => 0,
        bad_magic => 0,
        truncated_segment => 0,
        bytes_checked => 0,
        duration_us => 0
    }.

%% @private
%% Walk a single sealed segment. Opens read-only, scans frame-by-frame,
%% emits one telemetry event with the outcome, and (on the first bad
%% frame) marks the segment in the manifest. Returns
%% `{ok | alert, Counts}` so the caller can aggregate without re-
%% parsing telemetry.
walk_one(InstanceId, WalPid, Dir, SegId) ->
    Path = filename:join(Dir, bondy_oplog_wal_segment:filename(SegId)),
    T0 = erlang:monotonic_time(microsecond),
    case prim_file:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            try walk_frames(Fd) of
                {Outcome, Counts} ->
                    Duration = erlang:monotonic_time(microsecond) - T0,
                    M = Counts#{duration_us => Duration},
                    case Outcome of
                        ok ->
                            emit_segment_event(InstanceId, SegId, ok, M),
                            {ok, M};
                        {alert, Reason} ->
                            _ = bondy_oplog_wal:mark_segment_alert(
                                WalPid, SegId, Reason
                            ),
                            emit_segment_event(InstanceId, SegId, alert, M),
                            {alert, M}
                    end
            after
                _ = prim_file:close(Fd)
            end;
        {error, enoent} ->
            %% Concurrent retention sweep raced us; not an error.
            Z = zero_segment_measurements(),
            emit_segment_event(InstanceId, SegId, gone, Z),
            {ok, Z};
        {error, Reason} ->
            ?LOG_WARNING(#{
                description => "scrubber failed to open segment",
                instance_id => InstanceId,
                segment_id => SegId,
                reason => Reason
            }),
            {ok, zero_segment_measurements()}
    end.

%% @private
%% Frame-walk loop. Starts past the 48-byte segment header. Maintains
%% counts of bad-frame classes so the caller can attach them to the
%% emitted telemetry event. Stops on EOF (clean exit) or on the first
%% bad frame (alert).
walk_frames(Fd) ->
    walk_frames_loop(
        Fd,
        ?SEG_HEADER_BYTES,
        #{
            frames_checked => 0,
            bad_crc => 0,
            bad_magic => 0,
            truncated_segment => 0,
            bytes_checked => 0
        }
    ).

%% @private
walk_frames_loop(Fd, Off, Counts) ->
    case prim_file:pread(Fd, Off, ?FRAME_HEADER_BYTES) of
        {ok, HBin} when byte_size(HBin) =:= ?FRAME_HEADER_BYTES ->
            case bondy_oplog_wal_frame:decode_header(HBin) of
                {ok, #{frame_len := FrameLen}} ->
                    case verify_frame(Fd, Off, FrameLen) of
                        ok ->
                            Counts1 = Counts#{
                                frames_checked :=
                                    maps:get(frames_checked, Counts) + 1,
                                bytes_checked :=
                                    maps:get(bytes_checked, Counts) + FrameLen
                            },
                            walk_frames_loop(Fd, Off + FrameLen, Counts1);
                        {bad, Class} ->
                            {{alert, Class}, bump(Counts, class_to_key(Class))}
                    end;
                {error, bad_magic} ->
                    {{alert, bad_magic}, bump(Counts, bad_magic)};
                {error, _} ->
                    {{alert, truncated}, bump(Counts, truncated_segment)}
            end;
        {ok, _Short} ->
            %% Sealed segment should not have a short tail. Treat as
            %% truncation alert.
            {{alert, truncated}, bump(Counts, truncated_segment)};
        eof ->
            {ok, Counts};
        {error, Reason} ->
            {{alert, Reason}, bump(Counts, truncated_segment)}
    end.

%% @private
verify_frame(Fd, Off, FrameLen) ->
    case prim_file:pread(Fd, Off, FrameLen) of
        {ok, Bin} when byte_size(Bin) =:= FrameLen ->
            case bondy_oplog_wal_frame:decode(Bin) of
                {ok, _Body, _Meta} -> ok;
                {error, crc_mismatch} -> {bad, bad_crc};
                {error, bad_magic} -> {bad, bad_magic};
                {error, _} -> {bad, sealed_body_decode}
            end;
        {ok, _Short} ->
            {bad, truncated};
        eof ->
            {bad, truncated};
        {error, _} ->
            {bad, truncated}
    end.

%% @private
class_to_key(bad_crc) -> bad_crc;
class_to_key(bad_magic) -> bad_magic;
class_to_key(truncated) -> truncated_segment;
class_to_key(_) -> truncated_segment.

%% @private
bump(Counts, Key) ->
    Counts#{Key := maps:get(Key, Counts) + 1}.

%% =============================================================================
%% PRIVATE — telemetry
%% =============================================================================

%% @private
emit_segment_event(InstanceId, SegId, Outcome, Measurements) ->
    telemetry:execute(
        [bondy_oplog, wal, scrub, segment],
        Measurements,
        #{
            instance_id => InstanceId,
            segment_id => SegId,
            outcome => Outcome
        }
    ).

%% @private
%% Roll-up event for an entire scrub run. Lets operators see "how
%% much did one run cost / find" without summing across per-segment
%% events. `trigger` discriminates `scrub_now/1` calls from periodic
%% ticks so dashboards can break the two apart.
emit_run_event(InstanceId, Trigger, Summary) ->
    Keys = [
        segments_walked,
        segments_skipped,
        alerts_raised,
        frames_checked,
        bytes_checked,
        bad_crc,
        bad_magic,
        truncated_segment,
        duration_us
    ],
    Measurements = maps:with(Keys, Summary),
    telemetry:execute(
        [bondy_oplog, wal, scrub, run],
        Measurements,
        #{instance_id => InstanceId, trigger => Trigger}
    ).
