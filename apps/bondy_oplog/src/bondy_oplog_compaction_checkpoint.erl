%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_compaction_checkpoint).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Behaviour for the per-instance compaction checkpoint store.

A compaction checkpoint is the output of one compaction cycle: the
consolidated CRDT state at a particular compaction watermark.
Compaction reads the current checkpoint, folds the stable event
prefix through `interpret_cog/2`, writes the new checkpoint, and
truncates the MST.

The checkpoint is **not** a durability layer for the projection — it
is a cache for the compaction algorithm so a restart does not have
to replay every event since instance birth. The durable triplet is
WAL + MST + Projection; the checkpoint is rebuildable from those
three at higher cost. Single-node durability is backups; multi-node
durability is peer catalogue-snapshot bootstrap.

The "snapshot" overload — `bondy_oplog_catalogue_snapshot` is the
streaming peer-bootstrap protocol, an unrelated mechanism — is
deliberately resolved by the `compaction_checkpoint` naming here.

The library defines the storage interface; implementations choose
durability and serialisation:

- `bondy_oplog_compaction_checkpoint_ets` — in-memory; useful for
  tests and ephemeral instances where rebuild cost on restart is
  acceptable.
- `bondy_oplog_compaction_checkpoint_file` — file-backed (atomic
  rename); durable single-checkpoint persistence. Default implementation.

Consumers that need different durability characteristics (RocksDB,
S3, etc.) implement this behaviour themselves.

## Single-checkpoint policy

The library keeps exactly one checkpoint per instance: the
most-recent one. Older checkpoints are not retained. This matches
the architecture's "checkpoint is a baseline, not history" framing
— the MST plus the latest checkpoint fully reconstruct the live
state.

Consumers that want versioned checkpoints build them on top of the
behaviour (e.g. by writing each checkpoint with a separate id and
keeping a roll-up).
""").

-type state() :: term().

-export_type([state/0]).

-callback init(InstanceId :: instance_id(), Opts :: map()) ->
    {ok, state()} | {error, Reason :: term()}.

-callback put_checkpoint(
    State :: state(),
    Watermark :: bondy_oplog_event:event_key(),
    Checkpoint :: term()
) -> ok | {error, term()}.

-callback get_checkpoint(State :: state()) ->
    {ok, Watermark :: bondy_oplog_event:event_key(), Checkpoint :: term()}
    | not_found
    | {error, term()}.

-callback current_watermark(State :: state()) ->
    bondy_oplog_event:event_key() | undefined | {error, term()}.

-callback close(State :: state()) -> ok.
