%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_compaction).

-include_lib("kernel/include/logger.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
-moduledoc """
Per-instance compaction.

This module is a thin orchestrator: it collects one witness (the durable
frontier each peer last reported) per peer and delegates the heavy lifting to
`bondy_oplog_instance:compact/2`, which runs the cycle atomically inside the
instance gen_server.

## Witnesses

The witnesses are `bondy_oplog_instance:compaction_witnesses/1`, which the
watermark door reads too. On a durable backend a member's frontier advances
only when it writes a checkpoint, which each compaction cycle does when its
applied frontier has moved, so a member whose cycles do not run holds
compaction for every replica; on the `ets` and `map` backends it is the live
applied frontier. With no
other member, the instance truncates on its own frontier when clustering is
disabled (`bondy_cluster:enabled/0`), and truncates nothing when it is enabled.
When the membership is unreadable or a member has no confirmed row, the
instance still runs its cycle with no witness (page collection and, on a
fused instance, retention) and the call returns the cause as an error, which
the GC scheduler reports as its trigger outcome
(`bondy_oplog_compaction_test:held_compaction_reaches_the_scheduler/0`). A
member that confirmed and then went down keeps its row, so its stale frontier
only stops the frontier advancing and the call returns `{ok, no_change}`:
telling that apart from a peer that has not synced yet needs a recency bound
this rule does not use. The reclamation scheduler reports that member (`no_frontier`).

Called by:

- `bondy_oplog_gc_scheduler`'s default trigger (one
  invocation per running instance per tick).
- Manual operator triggers via `bondy_oplog:compact/1`.
""".

-export([compact/1]).

-doc """
Runs one compaction cycle for `InstanceId`. Returns:

- `{ok, no_change}` if no progress is possible (no intersecting prefix,
  frontier ≤ current watermark).
- `{ok, {compacted, NewWatermark, EventCount}}` on success.
- `{error, {unconfirmed, Members}}` when those members have no recorded
  frontier, and `{error, no_members}` or `{error, membership_unavailable}` as
  `bondy_oplog_instance:reclamation_members/0` returns them.
  Each is returned after the instance's cycle has run with no witness, whose
  own outcome is then visible only through `[bondy_oplog, compaction, ok]`.
- `{error, Reason}` on failure.
""".
-spec compact(instance_id()) ->
    {ok, no_change}
    | {ok, {compacted, bondy_oplog_event:event_key(), non_neg_integer()}}
    | {error, term()}.

compact(InstanceId) when is_binary(InstanceId) ->
    case bondy_oplog_instance:compaction_witnesses(InstanceId) of
        {ok, Witnesses} ->
            bondy_oplog_instance:compact(InstanceId, Witnesses);
        {error, _} = Held ->
            case bondy_oplog_instance:compact(InstanceId, []) of
                {ok, _} -> Held;
                {error, _} = Error -> Error
            end
    end.
