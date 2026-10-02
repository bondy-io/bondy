%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_wal).

-include("bondy_oplog.hrl").

-moduledoc """
The oplog's write-ahead log: a `bondy_log_wal` writer opened with the
oplog adapter.

The log core (writer, reader, recovery, sparse index, manifest, scrubber)
lives in the `bondy_log` library app and knows nothing about oplog events,
origins or the instance registry. This module is the oplog's view of it:
`start_link/2`, `start/2` and `open/2` take the historical oplog options
(`dir`, `origin`, the fsync / rotation / retention knobs) and open the
core with `bondy_oplog_log_adapter` as the log adapter, the adapter's
identity context built from `origin`, and `[bondy_oplog, wal]` as the
telemetry prefix, so every event keeps the name the exporter and the
dashboards know. A second adapter opens `bondy_log_wal` directly.

Every function that takes the writer pid delegates to `bondy_log_wal`;
they are here so the oplog, its tests and `bondy_oplog_wal_mem` (which
speaks the same gen_server protocol) name one module for the WAL. See
`bondy_log_wal` for the contracts.
""".

-type opts() :: #{
    dir := file:filename_all(),
    origin := bondy_oplog_origin:t(),
    max_segment_bytes => pos_integer(),
    max_batch_bytes => pos_integer(),
    retention => [{atom(), term()}],
    idx_interval_bytes => pos_integer(),
    fsync_mode => per_write | batched,
    batched_fsync_interval => pos_integer(),
    batched_fsync_bytes => pos_integer(),
    group_commit => boolean(),
    group_commit_max => pos_integer(),
    min_live_segments => pos_integer(),
    retention_sweep_interval => pos_integer(),
    max_total_wal_size => pos_integer(),
    max_live_segments => pos_integer(),
    recovery_mode => strict | rescan,
    body_compression => bondy_log_codec:algorithm(),
    body_compression_min_bytes => pos_integer(),
    body_encryption => bondy_log_codec:encryption()
}.
-type wal() :: bondy_log_wal:wal().
-type position() :: bondy_log_wal:position().
-type open_info() :: bondy_log_wal:open_info().
-type segment_id() :: bondy_log_segment:segment_id().

-export_type([opts/0]).
-export_type([wal/0]).
-export_type([position/0]).
-export_type([open_info/0]).

-export([start/2]).
-export([start_link/2]).
-export([open/2]).
-export([close/1]).
-export([append/2]).
-export([append_batch/2]).
-export([sync/1]).
-export([durable_position/1]).
-export([await_durable/3]).
-export([info/1]).
-export([reader_view/1]).
-export([advance_snapshot_watermark/2]).
-export([retention_sweep/1]).
-export([set_committed_segment/2]).
-export([mark_segment_alert/3]).
-export([clear_segment_alert/2]).

%% =============================================================================
%% API — opening
%% =============================================================================

-doc "See `bondy_log_wal:start_link/2`; opens with the oplog adapter.".
-spec start_link(instance_id(), opts()) -> {ok, pid()} | {error, term()}.

start_link(InstanceId, Opts) when
    is_binary(InstanceId), byte_size(InstanceId) > 0, is_map(Opts)
->
    bondy_log_wal:start_link(InstanceId, log_opts(InstanceId, Opts)).

-doc "See `bondy_log_wal:start/2`; opens with the oplog adapter.".
-spec start(instance_id(), opts()) -> {ok, pid()} | {error, term()}.

start(InstanceId, Opts) when
    is_binary(InstanceId), byte_size(InstanceId) > 0, is_map(Opts)
->
    bondy_log_wal:start(InstanceId, log_opts(InstanceId, Opts)).

-doc """
See `bondy_log_wal:open/2`; opens with the oplog adapter. `max_seq` in
the returned info is the largest own-origin seq the retained WAL holds,
which `bondy_oplog_instance_sup:start_wal/3` hands to the instance.
""".
-spec open(instance_id(), opts()) ->
    {ok, wal(), open_info()} | {error, term()}.

open(InstanceId, Opts) when
    is_binary(InstanceId), byte_size(InstanceId) > 0, is_map(Opts)
->
    bondy_log_wal:open(InstanceId, log_opts(InstanceId, Opts)).

%% @private
%% The `bondy_log_wal` options for the oplog's log: `origin` becomes the
%% oplog adapter's identity context `#{instance_id, origin}` (a missing
%% or invalid origin is reported by the adapter when the writer opens),
%% the adapter is `bondy_oplog_log_adapter` and the telemetry prefix is
%% `[bondy_oplog, wal]`.
-spec log_opts(instance_id(), opts()) -> bondy_log_wal:opts().

log_opts(InstanceId, Opts) ->
    Ctx = (maps:with([origin], Opts))#{instance_id => InstanceId},
    (maps:remove(origin, Opts))#{
        adapter => bondy_oplog_log_adapter,
        identity => Ctx,
        telemetry_prefix => [bondy_oplog, wal]
    }.

%% =============================================================================
%% API — the writer pid (delegated to bondy_log_wal)
%% =============================================================================

-spec close(wal()) -> ok.

close(Pid) ->
    bondy_log_wal:close(Pid).

-spec append(wal(), bondy_oplog_event:t()) ->
    {ok, bondy_hlc:hlc(), position()} | {error, term()}.

append(Pid, Event) ->
    bondy_log_wal:append(Pid, Event).

-spec append_batch(wal(), [bondy_oplog_event:t(), ...]) ->
    {ok, [{bondy_hlc:hlc(), position()}, ...]} | {error, term()}.

append_batch(Pid, Events) ->
    bondy_log_wal:append_batch(Pid, Events).

-spec sync(wal()) -> ok | {error, term()}.

sync(Pid) ->
    bondy_log_wal:sync(Pid).

-spec durable_position(wal()) -> position().

durable_position(Pid) ->
    bondy_log_wal:durable_position(Pid).

-spec await_durable(wal(), position(), timeout()) ->
    ok | {error, timeout} | {error, term()}.

await_durable(Pid, Pos, Timeout) ->
    bondy_log_wal:await_durable(Pid, Pos, Timeout).

-spec info(wal()) -> map().

info(Pid) ->
    bondy_log_wal:info(Pid).

-spec reader_view(wal()) -> map().

reader_view(Pid) ->
    bondy_log_wal:reader_view(Pid).

-spec advance_snapshot_watermark(wal(), bondy_hlc:hlc()) ->
    ok | {error, term()}.

advance_snapshot_watermark(Pid, Hlc) ->
    bondy_log_wal:advance_snapshot_watermark(Pid, Hlc).

-spec retention_sweep(wal()) ->
    {ok, [segment_id()], non_neg_integer()} | {error, term()}.

retention_sweep(Pid) ->
    bondy_log_wal:retention_sweep(Pid).

-spec set_committed_segment(wal(), segment_id()) -> ok | {error, term()}.

set_committed_segment(Pid, SegmentId) ->
    bondy_log_wal:set_committed_segment(Pid, SegmentId).

-spec mark_segment_alert(wal(), segment_id(), atom()) -> ok | {error, term()}.

mark_segment_alert(Pid, SegmentId, Reason) ->
    bondy_log_wal:mark_segment_alert(Pid, SegmentId, Reason).

-spec clear_segment_alert(wal(), segment_id()) -> ok | {error, term()}.

clear_segment_alert(Pid, SegmentId) ->
    bondy_log_wal:clear_segment_alert(Pid, SegmentId).
