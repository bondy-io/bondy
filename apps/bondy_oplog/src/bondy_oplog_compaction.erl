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

This module is a thin orchestrator: it asks
`bondy_oplog_peer_state` for the current per-peer root
hashes and delegates the heavy lifting to
`bondy_oplog_instance:compact/2`, which runs the cycle
(stability frontier → interpret_cog → snapshot → MST truncate →
watermark advance) atomically inside the instance gen_server.

Called by:

- `bondy_oplog_gc_scheduler`'s default trigger (one
  invocation per running instance per tick).
- Manual operator triggers via `bondy_oplog:compact/1`.
""").

-export([compact/1]).

?DOC("""
Runs one compaction cycle for `InstanceId`. Returns:

- `{ok, no_change}` if no progress is possible (no peers, no
  intersecting prefix, frontier ≤ current watermark).
- `{ok, {compacted, NewWatermark, EventCount}}` on success.
- `{error, Reason}` on failure — typically `no_crdt_module` if the
  instance was started without `crdt_module` configured.
""").
-spec compact(instance_id()) ->
    {ok, no_change}
    | {ok, {compacted, bondy_oplog_event:event_key(), non_neg_integer()}}
    | {error, term()}.

compact(InstanceId) when is_binary(InstanceId) ->
    PeerStates =
        bondy_oplog_peer_state:get_instance_peer_states(InstanceId),
    %% A rootless entry (rounds only ever completed against an empty peer
    %% tree) constrains nothing: same treatment as a peer this table has
    %% never seen — compaction may proceed and that peer, if it ever needs
    %% the truncated prefix, takes the bootstrap path.
    PeerRoots = [
        R
     || #{root_hash := R} <- PeerStates, is_binary(R)
    ],
    bondy_oplog_instance:compact(InstanceId, PeerRoots).
