%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_compaction).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Per-instance compaction.

This module is a thin orchestrator: it collects one witness (recorded root
and applied frontier) per peer and delegates the heavy lifting to
`bondy_oplog_instance:compact/2`, which runs the cycle (stability frontier →
interpret_cog → snapshot → MST truncate → watermark advance) atomically inside
the instance gen_server.

## Witnesses

Every peer that is a cluster member witnesses, reachable or not. The members
are the full Partisan membership (`bondy_oplog_instance:reclamation_members/0`)
and each must have a confirmed row
(`bondy_oplog_peer_state:confirmed_peer_states/2`) however long it has been
silent; a member drops out only through a Partisan `leave`. Until then, a
member that is down or partitioned holds compaction: truncating what it has
not received loses for good the writes each side accepted alone, once both
sides have truncated (`proofs/tla/ConfirmedCompaction_RootVV3_Fresh_Partition.cfg`
violates `NoLoss` under a recency filter; the `_Members_` configs hold it).
When the membership is unreadable, solo, or has an unconfirmed member, no
witness is passed: nothing is peer-confirmed, and only the watermark catch-up
truncates.

A fused instance (`bondy_oplog_registry:fused/1`; ephemeral, which
`bondy_db:assert_fused_requires_ephemeral/2` enforces) is the exception: its witnesses are the peers heard from within
`peer_timeout_ms` (`bondy_oplog_peer_state:get_instance_peer_states/1`). Its
history lives in memory, so a down member must not hold it, and it may lose
what a silent peer alone holds, as its retention policy already may
(`bondy_oplog_instance` admits retention only on a fused instance).

Called by:

- `bondy_oplog_gc_scheduler`'s default trigger (one
  invocation per running instance per tick).
- Manual operator triggers via `bondy_oplog:compact/1`.
""").

-export([compact/1]).

?DOC("""
Runs one compaction cycle for `InstanceId`. Returns:

- `{ok, no_change}` if no progress is possible (no confirmed members, no
  intersecting prefix, frontier ≤ current watermark).
- `{ok, {compacted, NewWatermark, EventCount}}` on success.
- `{error, Reason}` on failure.
""").
-spec compact(instance_id()) ->
    {ok, no_change}
    | {ok, {compacted, bondy_oplog_event:event_key(), non_neg_integer()}}
    | {error, term()}.

compact(InstanceId) when is_binary(InstanceId) ->
    bondy_oplog_instance:compact(InstanceId, witnesses(InstanceId)).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
witnesses(InstanceId) ->
    case bondy_oplog_registry:fused(InstanceId) of
        true -> bondy_oplog_peer_state:get_instance_peer_states(InstanceId);
        false -> member_witnesses(InstanceId)
    end.

%% @private
member_witnesses(InstanceId) ->
    case bondy_oplog_instance:reclamation_members() of
        {ok, Members} ->
            case
                bondy_oplog_peer_state:confirmed_peer_states(
                    InstanceId, Members
                )
            of
                {ok, States} -> States;
                {unconfirmed, _} -> []
            end;
        error ->
            []
    end.
