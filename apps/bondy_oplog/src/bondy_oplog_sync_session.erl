%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_sync_session).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
A single anti-entropy sync session.

Implements the **pull-direction** of the MST reconciliation protocol:
the *initiator* (this side) repeatedly
asks the *peer* for pages it is missing until its local copy of the
peer's tree is complete. Two such sessions — A pulling from B *and* B
pulling from A — converge both replicas to the same root.

## Algorithm

```
1. PeerRoot ← transport:request(Peer, Instance, get_root)
2. if PeerRoot == LocalRoot, done
3. loop:
     Missing ← instance:missing_set(Instance, PeerRoot)
     if Missing is empty, break
     Batch ← take(Missing, aae_pages_per_round)   %% BOUNDED per round
     Pages ← transport:request(Peer, Instance, {get_pages, Batch})
     if Pages unavailable:                        %% peer truncated+GC'd
         PeerRoot ← get_root again; continue if it moved
         %% (chase_refreshed_root/7); if it did NOT move, the peer's
         %% applied-frontier VV decides: no deficit ⇒ end benign
         %% (record nothing), deficit ⇒ {peer_pages_unavailable, _}
     instance:merge_pages(Instance, Pages)
     %% the round pulls only a bounded slice; the next missing_set picks
     %% up the rest (and any deeper pages a merged page now references)
4. record_sync_complete(Peer, Instance, PeerRoot)
   %% PeerRoot = the root the session actually COMPLETED against
```

Step 4 checkpoints the **peer's** root — the one it advertised in step 1, every
page of which we hold by the time we reach step 4. That is what makes
`bondy_oplog_instance:compute_frontier_for/2` a statement about what peers
hold. Recording our own root would instead measure our sync recency: sync is
pull-only, so a peer receives our data only when it pulls from us, in a
different session.

Each round pulls at most `bondy_oplog_config:aae_pages_per_round/0` pages, so a
session's peak memory is bounded regardless of how divergent the trees are — a
small divergence still converges in a round or two; a bulk initial sync simply
takes more rounds rather than materialising the whole tree at once.

## API shapes

- `run/3` — synchronous; returns `{ok, FinalRoot}` or `{error, Reason}`.
  Used by tests and consumers that want to await completion.
- `start/3` — asynchronous spawn; the session reports completion via
  `bondy_oplog_peer_state:record_sync_complete/3` and exits.
  Used by the default sync scheduler.

## Bounded iterations

The round ceiling is **adaptive**: it scales with the initial missing-set size
(bounded batches mean a bulk sync legitimately needs many rounds), and only
backstops a non-converging loop. A peer that returns nothing for a non-empty
request is caught immediately by the empty-pages guard. `max_iterations` may
still be set explicitly in `opts()` to pin a fixed cap (tests, special cases);
the default (`undefined`) selects the adaptive budget.
""").

-type opts() :: #{
    transport => module(),
    transport_opts => map(),
    max_iterations => pos_integer(),
    record_in_peer_state => boolean()
}.

-export_type([opts/0]).

-export([run/3]).
-export([run/4]).
-export([maybe_bump_ae_isolated/1]).
-export([start/3]).
-export([start/4]).
-export([bootstrap/3]).
-export([bootstrap_catalogue/3]).
-export([start_bootstrap/3]).
-export([start_bootstrap_catalogue/3]).

%% Bounded-batch pull needs many rounds for a bulk sync, so the round ceiling
%% scales with the initial missing set (`(missing / per_round) * SLACK + FLOOR`).
%% SLACK covers deeper pages revealed while descending the tree; FLOOR keeps a
%% small/quiescent sync from a degenerate ceiling. This is only a non-progress
%% backstop — a stuck peer is caught immediately by the empty-pages guard.
-define(AAE_ROUND_BUDGET_SLACK, 8).
-define(AAE_ROUND_BUDGET_FLOOR, 64).

%% =============================================================================
%% API
%% =============================================================================

?DOC("""
Synchronously runs a pull-direction sync session. Returns `{ok, Root}`
on success, where `Root` is the local root hash after merging.
""").
-spec run(instance_id(), peer_id(), opts()) ->
    {ok, bondy_mst:hash() | undefined} | {error, term()}.

run(Instance, Peer, Opts) ->
    run(Instance, Peer, Opts, default_max_iterations(Opts)).

-spec run(instance_id(), peer_id(), opts(), non_neg_integer() | undefined) ->
    {ok, bondy_mst:hash() | undefined} | {error, term()}.

run(Instance, Peer, Opts, Iterations) when is_binary(Instance) ->
    Transport = maps:get(
        transport,
        Opts,
        bondy_oplog_transport_inline
    ),
    TransportOpts = maps:get(transport_opts, Opts, #{}),
    Record = maps:get(record_in_peer_state, Opts, true),
    Start = erlang:monotonic_time(),
    %% Capture the peer's applied-frontier BEFORE the round. `get_root` inside
    %% `do_run` is same-or-newer, so this is a LOWER BOUND for what a converged
    %% round leaves us holding — merging it after a successful round can never
    %% over-claim. This is the ONLY convergence path for a shard the peer has
    %% fully compacted: its MST is a snapshot with no `cell_apply` keys, so the
    %% roots are already equal (nothing to page-sync) and `frontier_from_mst`
    %% folds nothing — without this the oracle stays DIVERGED forever despite
    %% byte-identical data. Best-effort (`#{}` on transport error).
    PeerFrontier = request_peer_frontier(
        Instance, Peer, Transport, TransportOpts
    ),
    %% `do_run/5` yields the peer root alongside the local one; only the local
    %% root is part of this function's contract, so split them here.
    {Result0, PeerRoot} =
        case do_run(Instance, Peer, Transport, TransportOpts, Iterations) of
            {ok, LocalRoot, PR} -> {{ok, LocalRoot}, PR};
            {error, _} = Error -> {Error, undefined}
        end,
    %% The adoption below is gated behind a frontier-GAP check. The
    %% adoption's "can never over-claim" argument holds only when a peer
    %% having compacted an event IMPLIES this node already held it — and
    %% BOTH compaction flavours can break that implication by design:
    %% `mst_retention` truncates by local policy with no confirmation at
    %% all, and the durable peer-confirmed frontier is RECENCY-FILTERED
    %% (`bondy_oplog_peer_state:get_instance_peer_states/1`) — a replica
    %% silent past `peer_timeout_ms` is dropped so compaction can
    %% proceed without it. In either case, if the peer's pre-round
    %% frontier is still strictly ahead of ours after a complete round,
    %% the missing events were compacted away at the peer and can never
    %% arrive by page-sync — adopting would flip the convergence oracle
    %% to CONVERGED over silently missing data. Fail the session with
    %% `{frontier_gap, Origins}` instead; the sync scheduler flags a
    %% catalogue rebootstrap, whose install + finalize supply BOTH the
    %% data and the frontier. This check IS the recovery half of the
    %% recency filter's liveness trade — without it a stale-peer rejoin
    %% silently loses whatever was truncated past it (found by
    %% `bondy_oplog_compaction_cluster_SUITE`'s stale-peer rejoin case,
    %% which previously timed out here with zero rebootstraps flagged).
    %% Both the gap check and the adoption require a COMPLETE round
    %% (`PeerRoot =/= skip`): a benign-incomplete round (budget/byte caps,
    %% mid-session root refresh) has not pulled everything the peer's
    %% pre-round frontier covers, so a deficit there is expected lag (not
    %% a gap — flagging it rebootstraps healthy instances on every capped
    %% round under load), and adopting there would over-claim maxima the
    %% round never delivered.
    Result = maybe_frontier_gap(Result0, Instance, Peer, PeerFrontier, PeerRoot),
    ok = maybe_adopt_peer_frontier(Result, Instance, PeerFrontier, PeerRoot),
    maybe_record(Result, Instance, Peer, Record, PeerRoot),
    ok = maybe_confirm_root(
        Result, Instance, Peer, Transport, TransportOpts, Record, PeerRoot
    ),
    Duration = erlang:monotonic_time() - Start,
    Outcome =
        case Result of
            {ok, _} -> ok;
            {error, _} -> error
        end,
    telemetry:execute(
        [bondy_oplog, sync, Outcome],
        #{duration => Duration},
        #{instance_id => Instance, peer => Peer}
    ),
    Result.

?DOC("""
Spawns the session in a separate process and returns immediately.
Completion is reported via `peer_state` and via telemetry. The spawned
process exits normally on success and with an error reason on failure.
""").
-spec start(instance_id(), peer_id(), opts()) -> {ok, pid()}.

start(Instance, Peer, Opts) ->
    start(Instance, Peer, Opts, default_max_iterations(Opts)).

-spec start(instance_id(), peer_id(), opts(), non_neg_integer() | undefined) ->
    {ok, pid()}.

start(Instance, Peer, Opts, Iterations) ->
    Pid = spawn(fun() ->
        case run(Instance, Peer, Opts, Iterations) of
            {ok, _} ->
                ok;
            {error, Reason} ->
                ?LOG_WARNING(#{
                    description => "sync session failed",
                    instance => Instance,
                    peer => Peer,
                    reason => Reason
                }),
                exit({sync_failed, Reason})
        end
    end),
    {ok, Pid}.

?DOC("""
Bootstrap session: fetch the peer's snapshot first, install it
locally, then run the regular pull-direction sync for events past the
new watermark.

Suitable for a *fresh* replica joining a long-running cluster, or a
*recovering* replica whose watermark is far behind. Falls back to
plain sync if the peer reports `no_snapshot`.

Returns `{ok, FinalRoot}` on success, `{error, Reason}` otherwise.
""").
-spec bootstrap(instance_id(), peer_id(), opts()) ->
    {ok, bondy_mst:hash() | undefined} | {error, term()}.

bootstrap(Instance, Peer, Opts) when is_binary(Instance) ->
    Transport = maps:get(
        transport,
        Opts,
        bondy_oplog_transport_inline
    ),
    TransportOpts = maps:get(transport_opts, Opts, #{}),
    case Transport:request(Peer, Instance, get_snapshot, TransportOpts) of
        {ok, no_snapshot} ->
            %% Peer has nothing to bootstrap from. The local instance
            %% has no path to a `live` projection state through this
            %% peer — but a *fresh* peer with empty state and no events
            %% behind the watermark is still safe to flip live (there
            %% is nothing to apply incorrectly). Skip the snapshot
            %% install and proceed with plain sync; the lifecycle stays
            %% as it was (caller is expected to have seeded a genesis
            %% peer separately, or to try a peer with a snapshot).
            run(Instance, Peer, Opts);
        {ok, Watermark, Snapshot} ->
            case
                bondy_oplog_instance:load_snapshot(
                    Instance, Watermark, Snapshot
                )
            of
                {ok, _} ->
                    %% Bootstrap completion ordering:
                    %%   1. load_snapshot (done above) installs the
                    %%      snapshot and advances the watermark to
                    %%      H_boot.
                    %%   2. `mark_live/1` writes the durable flag
                    %%      file — the marker that "everything
                    %%      before me succeeded." MUST be last:
                    %%      a crash between (1) and (2) leaves no
                    %%      flag, so restart re-runs bootstrap
                    %%      idempotently; a crash after (2)
                    %%      durably leaves the instance live.
                    %%   3. Run anti-entropy for events past the new
                    %%      watermark. Safe to interleave because
                    %%      the applier is already gated and the WAL
                    %%      is the buffer.
                    ok = bondy_oplog_instance:mark_live(Instance),
                    run(Instance, Peer, Opts);
                {error, watermark_not_advancing} ->
                    %% Local watermark is already ≥ peer's. The local
                    %% instance is either already live (flag exists)
                    %% or was a genesis seed (lifecycle was already
                    %% live). Either way mark_live is idempotent;
                    %% calling it here makes the path uniformly leave
                    %% the lifecycle in `live` regardless of which
                    %% branch was taken.
                    ok = bondy_oplog_instance:mark_live(Instance),
                    run(Instance, Peer, Opts);
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

?DOC("""
Catalogue-mode bootstrap session. The peer streams its projection
cells in chunks (`get_catalogue_snapshot_init` +
`{get_catalogue_snapshot_next, Cursor}`); the initiator installs each
batch into its own projection. After the stream ends, the lifecycle is
marked `live` (for a fresh caller) and the regular pull-direction sync
runs to catch up on any events newer than the peer's session-start
watermark.

The local instance MUST be catalogue-mode (`crdt_module = undefined`).
Single-CRDT-mode callers must use `bootstrap/3` instead. A
`{error, not_a_catalogue_instance}` is returned otherwise.

If the peer reports `no_snapshot` (it is itself single-CRDT mode, or
has not yet wired a `cell_apply_target`) the call falls through to
plain `run/3`. This handles the new-cluster genesis case cleanly: an
empty peer + empty local replica produces an immediate `done`.

`WasLive` is captured at session start so `finalize_catalogue_bootstrap`
can decide whether to mark live (fresh) or skip the lifecycle update
(recovering).
""").
-spec bootstrap_catalogue(instance_id(), peer_id(), opts()) ->
    {ok, bondy_mst:hash() | undefined}
    | {error, not_a_catalogue_instance}
    | {error, cursor_expired}
    | {error, term()}.

bootstrap_catalogue(Instance, Peer, Opts) when is_binary(Instance) ->
    case bondy_oplog_instance:crdt_module(Instance) of
        Mod when is_atom(Mod), Mod =/= undefined ->
            {error, not_a_catalogue_instance};
        undefined ->
            do_bootstrap_catalogue(Instance, Peer, Opts)
    end.

%% @private
do_bootstrap_catalogue(Instance, Peer, Opts) ->
    Transport = maps:get(
        transport,
        Opts,
        bondy_oplog_transport_inline
    ),
    TransportOpts = maps:get(transport_opts, Opts, #{}),
    WasLive = is_live(Instance),
    Start = erlang:monotonic_time(),
    Result = do_bootstrap_snapshot(
        Instance, Peer, Opts, Transport, TransportOpts, WasLive
    ),
    Duration = erlang:monotonic_time() - Start,
    Outcome =
        case Result of
            {ok, _} -> ok;
            {error, _} -> error
        end,
    telemetry:execute(
        [bondy_oplog, sync, catalogue_bootstrap, Outcome],
        #{duration => Duration},
        #{instance_id => Instance, peer => Peer, was_live => WasLive}
    ),
    Result.

%% @private
%% Catalogue-snapshot bootstrap: bulk-seed the local projection from the
%% peer snapshot in `replace` mode (skip-if-older by HLC), mark live (a
%% `pre_bootstrap` caller), then anti-entropy + op-replay using the
%% checkpoint-replace + op-replay approach (CvRDT `merge_states` merge-mode
%% is not used).
do_bootstrap_snapshot(Instance, Peer, Opts, Transport, TransportOpts, WasLive) ->
    case
        Transport:request(
            Peer, Instance, get_catalogue_snapshot_init, TransportOpts
        )
    of
        {ok, no_snapshot} ->
            %% Peer has nothing to ship. Run the regular pull and let the
            %% lifecycle stay where it was — the caller seeded the replica
            %% as `live` (genesis) or expects a future bootstrap against a
            %% non-empty peer.
            run(Instance, Peer, Opts);
        {ok, {init, {Watermark, Cursor}}} ->
            %% Capture the peer's applied-frontier version vector BEFORE
            %% streaming. The shipped projection cells carry only HLC + value,
            %% NOT the per-origin `{Origin, Seq}` the frontier is built from, so
            %% a fresh replica cannot reconstruct the frontier from the install
            %% — it adopts the peer's. Captured at init (a lower bound for what
            %% the live scan ships), so the merged frontier never claims more
            %% than was installed. Best-effort (`#{}` on error): the convergence
            %% oracle then heals via the normal sync path rather than falsely
            %% reporting converged.
            PeerFrontier = request_peer_frontier(
                Instance, Peer, Transport, TransportOpts
            ),
            case
                pull_install_loop(
                    Instance, Peer, Transport, TransportOpts, Cursor, 0, 0, 0
                )
            of
                {ok, Installed, Skipped, MaxInstalledHlc} ->
                    %% A3 — `MaxInstalledHlc` is absorbed into the local clock
                    %% at finalize, BEFORE the instance can be marked live.
                    %% The session-start `Watermark` alone would under-absorb:
                    %% it is a lower bound for what the live scan ships.
                    ok = bondy_oplog_instance:finalize_catalogue_bootstrap(
                        Instance,
                        Watermark,
                        PeerFrontier,
                        MaxInstalledHlc,
                        WasLive
                    ),
                    telemetry:execute(
                        [bondy_oplog, sync, catalogue_bootstrap, complete],
                        #{
                            installed => Installed,
                            skipped => Skipped,
                            watermark => Watermark
                        },
                        #{
                            instance_id => Instance,
                            peer => Peer,
                            was_live => WasLive
                        }
                    ),
                    finish_bootstrap(Instance, Peer, Opts, WasLive);
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%% @private
%% Run anti-entropy (MST page union + diff-replay), then, for a LIVE
%% re-bootstrap, op-replay: re-derive the projection from the now-merged
%% local+peer event set. The snapshot install is `replace` (skip-if-older
%% by HLC), which is correct for a register but can CLOBBER a CRDT that
%% accumulates per-Origin (a counter, a grow-set) when the peer's
%% higher-HLC cell omits a local Origin's contribution. A full re-fold
%% (`interpret_cog` over the complete event set) restores it — the op-based
%% replacement for the removed CvRDT `merge_states`. On a fresh
%% (`pre_bootstrap`) replica it is unnecessary (the local projection was
%% empty, so `replace` could not clobber, and the cold-start replay already
%% re-folds), so it is skipped to avoid a redundant full fold.
finish_bootstrap(Instance, Peer, Opts, WasLive) ->
    case run(Instance, Peer, Opts) of
        {ok, _} = Ok ->
            case WasLive of
                true -> ok = rederive_projection(Instance);
                false -> ok
            end,
            Ok;
        {error, _} = E ->
            E
    end.

%% @private
%% A fused instance has no applier — its rederive runs in the instance
%% gen_server over its own cell-apply source. Resolving via `applier_pid`
%% alone silently NO-OPed for fused instances, leaving the very cells
%% this call exists to restore (a `replace`-mode install that clobbered a
%% per-Origin-accumulating CRDT) permanently diverged: the clobbered ops
%% are covered by the applied-frontier VV, so no oracle ever flags them.
rederive_projection(Instance) ->
    case bondy_oplog_registry:fused(Instance) of
        true ->
            case bondy_oplog_instance:rederive_projection(Instance) of
                ok ->
                    ok;
                {error, Reason} ->
                    ?LOG_WARNING(#{
                        description =>
                            "post-bootstrap projection rederive failed; "
                            "cells clobbered by the catalogue install may "
                            "stay diverged until the next re-bootstrap",
                        instance => Instance,
                        reason => Reason
                    }),
                    ok
            end;
        _ ->
            case bondy_oplog_registry:applier_pid(Instance) of
                undefined ->
                    ok;
                Pid when is_pid(Pid) ->
                    bondy_oplog_applier:rederive_projection_sync(Pid)
            end
    end.

%% @private
%% The peer's applied-frontier VV (`#{Origin => Seq}`), used to seed a fresh
%% replica's frontier on catalogue bootstrap. The catalogue install writes the
%% projection cells, but those cells carry only HLC + value — not the per-origin
%% `{Origin, Seq}` the frontier needs — so the frontier cannot be derived from
%% the install and must be adopted from the peer. Best-effort: `#{}` on any
%% transport error (the convergence oracle then heals on the normal sync path).
%% Reuses the existing `get_frontier` request; tolerates both the Partisan
%% 3-tuple (`{ok, Frontier, Fp}`) and the inline 2-tuple (`{ok, Frontier}`).
request_peer_frontier(Instance, Peer, Transport, TransportOpts) ->
    case catch Transport:request(Peer, Instance, get_frontier, TransportOpts) of
        {ok, Frontier, _Fp} when is_map(Frontier) -> Frontier;
        {ok, Frontier} when is_map(Frontier) -> Frontier;
        _ -> #{}
    end.

%% @private
pull_install_loop(
    Instance,
    Peer,
    Transport,
    TransportOpts,
    Cursor,
    Installed,
    Skipped,
    MaxHlc
) ->
    %% The install is always `replace` (skip-if-older by HLC); CvRDT
    %% `merge_states` merge-mode is not used. On a fresh
    %% replica the local projection is empty so every cell installs; on a
    %% live re-bootstrap a higher-HLC peer cell can clobber a per-Origin-
    %% accumulating CRDT, which the post-bootstrap op-replay then restores.
    Req = {get_catalogue_snapshot_next, Cursor},
    case Transport:request(Peer, Instance, Req, TransportOpts) of
        {ok, {done, []}} ->
            {ok, Installed, Skipped, MaxHlc};
        {ok, {batch, {NextCursor, Cells}}} ->
            case
                bondy_oplog_instance:install_catalogue_batch(
                    Instance, {replace, Cells}
                )
            of
                {ok, #{installed := I, skipped := S} = Counts} ->
                    pull_install_loop(
                        Instance,
                        Peer,
                        Transport,
                        TransportOpts,
                        NextCursor,
                        Installed + I,
                        Skipped + S,
                        max(MaxHlc, maps:get(max_hlc, Counts, 0))
                    );
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

?DOC("""
Spawns a `bootstrap/3` (single-CRDT) session in a separate process and
returns immediately. Failures are logged and the process exits with
`{bootstrap_failed, Reason}`. Used by the sync scheduler for
auto-bootstrap of single-CRDT pre_bootstrap instances.
""").
-spec start_bootstrap(instance_id(), peer_id(), opts()) -> {ok, pid()}.

start_bootstrap(Instance, Peer, Opts) ->
    Pid = spawn(fun() ->
        case bootstrap(Instance, Peer, Opts) of
            {ok, _} ->
                ok;
            {error, Reason} ->
                ?LOG_WARNING(#{
                    description => "bootstrap session failed",
                    instance => Instance,
                    peer => Peer,
                    reason => Reason
                }),
                exit({bootstrap_failed, Reason})
        end
    end),
    {ok, Pid}.

?DOC("""
Spawns a `bootstrap_catalogue/3` session in a separate process and
returns immediately. Failures are logged and the process exits with
`{bootstrap_catalogue_failed, Reason}`. Used by the sync scheduler for
auto-bootstrap of catalogue-mode pre_bootstrap instances.
""").
-spec start_bootstrap_catalogue(instance_id(), peer_id(), opts()) ->
    {ok, pid()}.

start_bootstrap_catalogue(Instance, Peer, Opts) ->
    Pid = spawn(fun() ->
        case bootstrap_catalogue(Instance, Peer, Opts) of
            {ok, _} ->
                ok;
            {error, Reason} ->
                ?LOG_WARNING(#{
                    description => "bootstrap_catalogue session failed",
                    instance => Instance,
                    peer => Peer,
                    reason => Reason
                }),
                exit({bootstrap_catalogue_failed, Reason})
        end
    end),
    {ok, Pid}.

%% @private
is_live(Instance) ->
    case bondy_oplog_instance:lifecycle_state(Instance) of
        live -> true;
        _ -> false
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
do_run(Instance, Peer, Transport, TransportOpts, MaxIterations) ->
    case Transport:request(Peer, Instance, get_root, TransportOpts) of
        {ok, PeerRoot, PeerFp} ->
            pull_if_compatible(
                Instance,
                Peer,
                Transport,
                TransportOpts,
                MaxIterations,
                PeerRoot,
                PeerFp
            );
        {ok, PeerRoot} ->
            %% Legacy peer (pre-fingerprint reply): no topology check.
            pull_if_compatible(
                Instance,
                Peer,
                Transport,
                TransportOpts,
                MaxIterations,
                PeerRoot,
                undefined
            );
        {error, _} = E ->
            E
    end.

%% @private
%% Per-shard MST roots are only comparable when both nodes key data the same
%% way, so we verify the peer's keying-topology fingerprint matches ours before
%% pulling. A mismatch is refused loudly rather than diverging silently;
%% `undefined` on either side (an ephemeral DB, or a peer that predates the
%% fingerprint) skips the check.
pull_if_compatible(
    Instance, Peer, Transport, TransportOpts, MaxIterations, PeerRoot, PeerFp
) ->
    LocalFp = bondy_oplog:topology_fingerprint(bondy_oplog:db_of(Instance)),
    case topology_compatible(LocalFp, PeerFp) of
        true ->
            %% The pull carries out the peer root the session actually
            %% COMPLETED against — which, after a mid-session root refresh
            %% (`chase_refreshed_root/7`), is not necessarily the one this
            %% function was handed. Only that root may be checkpointed as
            %% held-in-full (`maybe_record/5`); `skip` marks a benign
            %% incomplete round that must checkpoint nothing.
            pull_from_root(
                Instance,
                Peer,
                Transport,
                TransportOpts,
                MaxIterations,
                PeerRoot
            );
        false ->
            ?LOG_ERROR(#{
                description =>
                    "Refusing AAE sync: the peer's bondy_db keying topology "
                    "differs from ours, so per-shard MST roots are not "
                    "comparable. The nodes must agree on partition_strategy, "
                    "shard_count and per-table routing (compare the topology "
                    "MANIFEST on each node).",
                instance => Instance,
                peer => Peer,
                local_fingerprint => hexfp(LocalFp),
                peer_fingerprint => hexfp(PeerFp)
            }),
            {error, {topology_mismatch, LocalFp, PeerFp}}
    end.

%% @private
pull_from_root(
    Instance, _Peer, _Transport, _TransportOpts, _MaxIterations, undefined
) ->
    %% Peer has nothing; nothing to pull.
    {ok, bondy_oplog_instance:root_hash(Instance), undefined};
pull_from_root(
    Instance, Peer, Transport, TransportOpts, MaxIterations, PeerRoot
) ->
    LocalRoot = bondy_oplog_instance:root_hash(Instance),
    case PeerRoot =:= LocalRoot of
        true ->
            {ok, LocalRoot, PeerRoot};
        false ->
            pull_until_complete(
                Instance,
                Peer,
                Transport,
                TransportOpts,
                PeerRoot,
                MaxIterations
            )
    end.

%% @private
topology_compatible(undefined, _) -> true;
topology_compatible(_, undefined) -> true;
topology_compatible(Fp, Fp) -> true;
topology_compatible(_, _) -> false.

%% @private
hexfp(undefined) -> undefined;
hexfp(Fp) when is_binary(Fp) -> binary:encode_hex(Fp).

%% @private
%% Backstop: the adaptive round budget is exhausted. With bounded page batches a
%% legitimate bulk sync needs many rounds, so the budget scales with the initial
%% missing set; reaching `0` means the missing set is not converging (e.g. a
%% peer that keeps returning pages which do not reduce it). Surface and let the
%% scheduler retry on the next tick.
pull_until_complete(
    Instance,
    Peer,
    _Transport,
    _TransportOpts,
    _PeerRoot,
    0
) ->
    ?LOG_WARNING(#{
        description => "sync session exhausted its adaptive round budget",
        instance => Instance,
        peer => Peer
    }),
    {error, sync_round_budget_exhausted};
pull_until_complete(
    Instance,
    Peer,
    Transport,
    TransportOpts,
    PeerRoot,
    Budget0
) ->
    %% Pin the root we are about to pull so the instance's page GC does
    %% not sweep pulled-but-not-yet-merged pages between our rounds —
    %% during a multi-round pull the earlier rounds' pages are
    %% unreachable from the LOCAL root until the final integrate, and
    %% every concurrent compaction cycle used to collect them (the
    %% merge then silently treated the missing subtrees as empty). The
    %% pin is consumed by a successful integrate and TTL-expires if
    %% this session dies. First entry only; chase re-pins its refreshed
    %% root.
    _ =
        Budget0 =:= undefined andalso
            (catch bondy_oplog_instance:pin_peer_root(Instance, PeerRoot)),
    case bondy_oplog_instance:missing_set(Instance, PeerRoot) of
        [] ->
            %% Every page reachable from PeerRoot is now in our store.
            %% Integrate at the item level — this walks PeerRoot's tree
            %% using the local store and folds its items into ours,
            %% producing a new merged root. `PeerRoot` rides along as the
            %% root this session demonstrably completed against — the ONLY
            %% root `maybe_record/5` may checkpoint (a mid-session root
            %% refresh means the session-start root was never fully held).
            %% The integrate re-checks the missing set ATOMICALLY with
            %% the merge (its instance serializes with the page GC) and
            %% refuses a partial merge — on `peer_pages_missing` the
            %% pages were swept between our check and the call, so loop
            %% back and re-pull them (budget-bounded).
            case bondy_oplog_instance:integrate_peer_root(Instance, PeerRoot) of
                ok ->
                    {ok, bondy_oplog_instance:root_hash(Instance), PeerRoot};
                {error, {peer_pages_missing, _}} ->
                    NextBudget =
                        case Budget0 of
                            undefined -> 4;
                            _ -> Budget0 - 1
                        end,
                    pull_until_complete(
                        Instance,
                        Peer,
                        Transport,
                        TransportOpts,
                        PeerRoot,
                        NextBudget
                    )
            end;
        Missing ->
            PerRound = bondy_oplog_config:aae_pages_per_round(),
            %% On the first round (`Budget0 == undefined`) size the round
            %% ceiling to the work; thereafter count it down.
            Budget =
                case Budget0 of
                    undefined ->
                        initial_round_budget(length(Missing), PerRound);
                    _ ->
                        Budget0
                end,
            %% Bounded page batch: pull at most `PerRound` of the missing pages
            %% this round, NOT the whole set. `PerRound` is the node-wide page
            %% budget (`aae_max_pages_in_flight`) divided by the concurrency cap
            %% (`aae_max_concurrency`), so AAE's peak memory is bounded
            %% independent of dataset size AND of how many sessions run — more
            %% concurrency means smaller batches, not more RAM. The next round's
            %% `missing_set` recomputes the remainder, including any deeper pages
            %% a just-merged page now references.
            Batch = lists:sublist(Missing, PerRound),
            %% Reciprocal form: announce our own root while asking for pages,
            %% so the peer learns for free whether it is behind us and can
            %% schedule an exchange in the other direction. Without this a
            %% pair converges mutually only when both schedulers happen to
            %% tick toward each other.
            Req = get_pages_request(Instance, Transport, Batch),
            case Transport:request(Peer, Instance, Req, TransportOpts) of
                {ok, {unavailable, _}} ->
                    %% The peer cannot serve these pages — its compaction +
                    %% page GC reclaimed them mid-session, i.e. the root we
                    %% pinned at session start went stale under us. The
                    %% normal remedy is to CHASE the refreshed root (its
                    %% pages are the peer's live tree, always servable),
                    %% not to abort: treating every miss as terminal caused
                    %% a re-bootstrap storm on every truncation round, and
                    %% each live re-bootstrap is a clobber-and-rederive
                    %% cycle not to be entered gratuitously.
                    chase_refreshed_root(
                        Instance,
                        Peer,
                        Transport,
                        TransportOpts,
                        PeerRoot,
                        Budget,
                        Batch
                    );
                {ok, Pages} when map_size(Pages) =:= 0 ->
                    {error, {peer_returned_empty_pages, Batch}};
                {ok, Pages} ->
                    ok = merge_pages(Instance, Pages),
                    pull_until_complete(
                        Instance,
                        Peer,
                        Transport,
                        TransportOpts,
                        PeerRoot,
                        Budget - 1
                    );
                {error, _} = E ->
                    E
            end
    end.

%% @private
%% The peer could not serve pages of `OldRoot` — re-request its current
%% root and continue the round against that (budget-decremented, so a
%% peer truncating faster than we can chase ends in
%% `sync_round_budget_exhausted` and retries next round). Only when the
%% peer has NOT moved (or the refresh fails) does the applied-frontier
%% deficit decide: no deficit ⇒ the unpullable pages cover only events
%% this replica already applied — end the round benign, recording
%% nothing (`skip`: the session-start root was never fully held, so
%% neither recency nor root may be checkpointed); a strict deficit ⇒ the
%% terminal error, and the scheduler flags the catalogue re-bootstrap.
chase_refreshed_root(
    Instance, Peer, Transport, TransportOpts, OldRoot, Budget, Batch
) ->
    %% A failed root re-request (transport error, or the peer's
    %% dangling-root guard answering `{error, {root_unservable, _}}`
    %% mid-GC) ends the round as a plain session error — retried on the
    %% next tick. Falling back to the old root here would read as "root
    %% unmoved" below and, with a fresh-events deficit, manufacture a
    %% false `peer_pages_unavailable` verdict (an immediate rebootstrap
    %% flag) out of a transient serving hiccup.
    NewRoot =
        case Transport:request(Peer, Instance, get_root, TransportOpts) of
            {ok, R, _Fp} -> R;
            {ok, R} -> R;
            {error, _} = RootErr -> RootErr
        end,
    case NewRoot of
        {error, _} = E ->
            E;
        OldRoot ->
            PeerFrontier = request_peer_frontier(
                Instance, Peer, Transport, TransportOpts
            ),
            case frontier_deficit(Instance, PeerFrontier) of
                [] ->
                    telemetry:execute(
                        [bondy_oplog, sync, pages_unavailable_benign],
                        #{count => 1},
                        #{instance_id => Instance, peer => Peer}
                    ),
                    {ok, bondy_oplog_instance:root_hash(Instance), skip};
                _Origins ->
                    {error, {peer_pages_unavailable, Batch}}
            end;
        undefined ->
            %% The peer compacted to an empty tree: nothing left to pull.
            %% `undefined` keeps the existing empty-peer record semantics
            %% (recency only).
            {ok, bondy_oplog_instance:root_hash(Instance), undefined};
        _ ->
            %% Chasing a refreshed root: pin it like the session-start
            %% root (the stale pin expires by TTL).
            _ = (catch bondy_oplog_instance:pin_peer_root(Instance, NewRoot)),
            pull_until_complete(
                Instance,
                Peer,
                Transport,
                TransportOpts,
                NewRoot,
                Budget - 1
            )
    end.

%% @private
%% Builds the page request, preferring the reciprocal 4-tuple form. Falls back
%% to the legacy 2-tuple when the transport cannot name us — a peer running an
%% older version answers the 2-tuple and simply does not reciprocate, so a
%% mixed-version cluster degrades to the previous behaviour rather than
%% failing.
get_pages_request(Instance, Transport, Batch) ->
    try Transport:self_id(Instance) of
        SelfId ->
            {get_pages, SelfId, bondy_oplog_instance:root_hash(Instance), Batch}
    catch
        error:undef ->
            {get_pages, Batch}
    end.

%% @private
initial_round_budget(MissingCount, PerRound) ->
    (MissingCount div PerRound + 1) * ?AAE_ROUND_BUDGET_SLACK +
        ?AAE_ROUND_BUDGET_FLOOR.

%% @private
%% A successful round (`{ok, Root}`, `Record =:= true`) freshens this
%% instance's AE targets — INCLUDING when `Root =:= undefined` (an empty
%% instance verified caught-up with the peer). The empty case is exactly the
%% idle low-churn shard the auth freshness fence depends on, so it MUST bump.
%% The peer-state record also always lands: with an empty peer tree it
%% advances recency only (no root to confirm — see
%% `bondy_oplog_peer_state:record_sync_complete/3`).
maybe_record({ok, _LocalRoot}, _Instance, _Peer, _Record, skip) ->
    %% Benign incomplete round (`chase_refreshed_root/7`): the peer's
    %% advertised root was never fully held, so checkpointing it — or even
    %% bumping recency against it — would overstate this session.
    ok;
maybe_record({ok, _LocalRoot}, Instance, Peer, true, PeerRoot) ->
    %% Checkpoint the PEER's root, not ours.
    %%
    %% `peer_state` feeds `compute_frontier_for/2`, whose contract is "the
    %% largest local key present in EVERY peer's confirmed root" — a statement
    %% about what peers hold. Recording our own root instead makes it a
    %% statement about our own sync recency: because sync is pull-only, a peer
    %% receives our data only when *it* pulls from *us*, in a session this one
    %% knows nothing about. The frontier would then cover events no peer has,
    %% which is unsound for anything that reclaims on stability.
    %%
    %% `PeerRoot` is the root the peer advertised at the start of this session,
    %% and reaching here means we pulled every page reachable from it. So both
    %% replicas demonstrably hold it. Using the session-start root (rather than
    %% re-reading the peer's current one) is deliberately conservative: the peer
    %% may have advanced since, which only delays the frontier, never
    %% over-claims it.
    ok = maybe_checkpoint_root(PeerRoot, Instance, Peer),
    ok = bump_ae_on_sync(Instance, Peer);
maybe_record(_, _, _, _, _) ->
    ok.

%% @private
%% Completes the swap: tell the peer we now hold every page reachable from the
%% root it advertised, so it checkpoints that same root against us.
%%
%% This is what makes the stability frontier a *shared* object. A pull alone
%% leaves each side holding only what it unilaterally observed of the other, at
%% its own times; stability then advances at different rates per node and
%% compaction diverges. With the confirmation both replicas hold the same root
%% for each other — Canteen's common sub-graph (§3.3), reached without a push
%% path or a reverse session.
%%
%% Best-effort: a failure costs the peer a stale checkpoint, which only delays
%% its frontier. Never fails the session.
maybe_confirm_root(
    {ok, _}, Instance, Peer, Transport, TransportOpts, true, PeerRoot
) when is_binary(PeerRoot) ->
    SelfId =
        try
            Transport:self_id(Instance)
        catch
            error:undef -> undefined
        end,
    case SelfId of
        undefined ->
            %% Transport cannot name us, so the peer could not attribute the
            %% confirmation. Degrade to the unilateral behaviour.
            ok;
        _ ->
            Req = {confirm_root, SelfId, PeerRoot},
            case Transport:request(Peer, Instance, Req, TransportOpts) of
                {ok, _} ->
                    ok;
                {error, Reason} ->
                    ?LOG_DEBUG(#{
                        description => "swap confirmation not delivered",
                        instance => Instance,
                        peer => Peer,
                        reason => Reason
                    }),
                    ok
            end
    end;
maybe_confirm_root(_, _, _, _, _, _, _) ->
    ok.

%% @private
%% Every completed round records — `undefined` (an empty peer tree, e.g. a
%% fully-compacted quiescent shard) advances the peer's sync recency
%% without confirming a root, so the last-sync age stays truthful on
%% converged idle shards instead of climbing forever.
maybe_checkpoint_root(Root, Instance, Peer) when
    is_binary(Root) orelse Root =:= undefined
->
    bondy_oplog_peer_state:record_sync_complete(Peer, Instance, Root).

%% @private
%% Adopt the peer's applied-frontier after a CONVERGED round (`{ok, _}`).
%% `PeerFrontier` was captured before the round (a lower bound), so this only
%% ever raises the local frontier to maxima we provably hold — never a false
%% "in sync". Only merges + persists when the peer actually carries a HIGHER
%% seq for some origin: the steady state (already converged) is a pure map
%% comparison with no ETS write and no `fsync`. The persist makes an adopted
%% maximum durable so an isolated restart (peer then unreachable) keeps the
%% converged oracle rather than re-diverging until the peer returns.
maybe_adopt_peer_frontier({ok, _}, _Instance, _PeerFrontier, skip) ->
    %% Benign incomplete round: the pre-round frontier's maxima were not
    %% necessarily delivered, so adopting would over-claim. The next
    %% complete round adopts.
    ok;
maybe_adopt_peer_frontier({ok, _}, Instance, PeerFrontier, _PeerRoot) when
    is_map(PeerFrontier), map_size(PeerFrontier) > 0
->
    Local = bondy_oplog_registry:frontier(Instance),
    Adds = maps:filter(
        fun(Origin, Seq) ->
            case Local of
                #{Origin := Cur} -> Seq > Cur;
                _ -> true
            end
        end,
        PeerFrontier
    ),
    case map_size(Adds) > 0 of
        true ->
            ok = bondy_oplog_registry:merge_frontier(Instance, Adds),
            _ = catch bondy_oplog_instance:persist_frontier(Instance),
            ok;
        false ->
            ok
    end;
maybe_adopt_peer_frontier(_Result, _Instance, _PeerFrontier, _PeerRoot) ->
    ok.

%% @private
%% Frontier-GAP check (see the call site in `run/4` for the full
%% rationale). Fires on a SUCCESSFUL round when the peer's PRE-round
%% applied frontier is still strictly ahead of ours after the round: the
%% missing events were compacted away at the peer — whether by
%% `mst_retention` policy or by the durable recency-filtered frontier
%% advancing past this then-silent replica — and can never arrive by
%% page-sync, so the only convergence path is a catalogue rebootstrap.
%%
%% On an applier-backed instance the pulled events reach the projection
%% (and the applied-frontier VV its max-merge advances) ASYNCHRONOUSLY —
%% the `integrate_peer_root` handler casts `replay_cell_events` to the
%% APPLIER — so a first-pass deficit may be nothing but replay lag:
%% settle the whole local pipeline and re-check before declaring a gap.
%% The settle is two barriers: the instance's overlay drain
%% (`await_apply/1` — local WAL-appended events projected + installed)
%% and the APPLIER barrier (`bondy_oplog_applier:barrier/1` — served
%% after the integrate-time replay cast already in its queue, and
%% running the I1 fence so even a LOST cast is replayed). On a fused
%% instance there is no applier and replay was inline at integrate, so
%% only the overlay drain applies. With the peer's answer
%% installed-consistent (the responder's barrier) and the round complete,
%% a residual deficit after this settle is deterministic evidence the
%% missing events were compacted away at the peer. The exit reason's
%% origins list is bounded to keep it log-safe; the full per-origin
%% deficit (peer vs local sequence) goes out on the
%% `[bondy_oplog, sync_session, frontier_gap]` telemetry event and the
%% log line here, so a standing gap is diagnosable from either.
maybe_frontier_gap({ok, _} = Result, _Instance, _Peer, _PeerFrontier, skip) ->
    %% Benign incomplete round: a deficit here is expected transfer lag,
    %% not evidence of compacted-away history. The next complete round
    %% judges.
    Result;
maybe_frontier_gap({ok, _} = Result, Instance, Peer, PeerFrontier, PeerRoot) when
    is_map(PeerFrontier), map_size(PeerFrontier) > 0
->
    case frontier_deficit(Instance, PeerFrontier) of
        Deficit0 when map_size(Deficit0) =:= 0 ->
            Result;
        Deficit0 ->
            ok = settle_local(Instance),
            case frontier_deficit(Instance, PeerFrontier) of
                Deficit when map_size(Deficit) =:= 0 ->
                    ?LOG_DEBUG(#{
                        description =>
                            "Frontier deficit settled by the local "
                            "apply-pipeline barriers (replay lag, not "
                            "a gap)",
                        instance => Instance,
                        peer => Peer,
                        deficit => Deficit0
                    }),
                    Result;
                Deficit ->
                    Presence = deficit_presence(Instance, Deficit),
                    LocalRoot =
                        catch bondy_oplog_instance:root_hash(Instance),
                    telemetry:execute(
                        [bondy_oplog, sync_session, frontier_gap],
                        #{count => 1, origins => map_size(Deficit)},
                        #{
                            instance_id => Instance,
                            peer => Peer,
                            deficit => Deficit,
                            present_locally => Presence,
                            completed_peer_root => PeerRoot,
                            local_root => LocalRoot
                        }
                    ),
                    ?LOG_INFO(#{
                        description =>
                            "Frontier gap: peer's applied frontier is "
                            "still ahead after a complete round and a "
                            "local settle (per-origin peer vs local "
                            "sequences in `deficit`; `present_locally` "
                            "discriminates apply-side lag from a "
                            "peer-side over-claim)",
                        instance => Instance,
                        peer => Peer,
                        deficit => Deficit,
                        present_locally => Presence
                    }),
                    Origins = lists:sublist(maps:keys(Deficit), 5),
                    {error, {frontier_gap, Origins}}
            end
    end;
maybe_frontier_gap(Result, _Instance, _Peer, _PeerFrontier, _PeerRoot) ->
    Result.

%% @private
%% Forensic probe on a residual deficit: is each behind `{Origin, Seq}`
%% event present in the LOCAL log (MST + overlay — `fold_range/5`
%% captures both in one instance callback)? `true` ⇒ the round delivered
%% the event and the deficit is local apply-side lag the settle barriers
%% did not cover; `false` ⇒ the peer's answered frontier counted an
%% event its served tree never shipped (peer-side over-claim). Bounded:
%% probes at most 10 missing seqs per behind origin. Diagnostic only —
%% total, `#{}` on any failure.
deficit_presence(Instance, Deficit) ->
    try
        First = bondy_oplog_instance:first_key(Instance),
        Last = bondy_oplog_instance:latest_key(Instance),
        case First =:= undefined orelse Last =:= undefined of
            true ->
                #{};
            false ->
                Want = maps:fold(
                    fun(Origin, #{peer := S, local := L}, Acc) ->
                        Lo = max(L + 1, S - 9),
                        lists:foldl(
                            fun(Seq, Acc1) -> Acc1#{{Origin, Seq} => false} end,
                            Acc,
                            lists:seq(Lo, S)
                        )
                    end,
                    #{},
                    Deficit
                ),
                bondy_oplog_instance:fold_range(
                    Instance,
                    First,
                    Last,
                    fun(E, Acc) ->
                        K = bondy_oplog_event:key(E),
                        OS = {
                            bondy_oplog_event:key_origin(K),
                            bondy_oplog_event:key_seq(K)
                        },
                        case maps:is_key(OS, Acc) of
                            true -> Acc#{OS => true};
                            false -> Acc
                        end
                    end,
                    Want
                )
        end
    catch
        _:_ ->
            #{}
    end.

%% @private
%% Settle the local apply pipeline: overlay drained (local events
%% projected + installed) and, when the instance is applier-backed, the
%% applier caught up (queued replay casts served + the I1 fence run).
settle_local(Instance) ->
    _ = catch bondy_oplog_instance:await_apply(Instance),
    case bondy_oplog_registry:applier_pid(Instance) of
        Pid when is_pid(Pid) ->
            _ = catch bondy_oplog_applier:barrier(Pid),
            ok;
        _ ->
            ok
    end.

%% @private
%% Per-origin deficit map (`Origin => #{peer => Seq, local => Cur}`) for
%% which the peer's applied-frontier VV is strictly ahead of the local
%% one — the convergence oracle's definition of "this replica is missing
%% something". Empty map = no deficit. Origins are node-scoped so the
%% map is bounded by cluster size.
frontier_deficit(Instance, PeerFrontier) ->
    Local =
        case bondy_oplog_registry:frontier(Instance) of
            M when is_map(M) -> M;
            _ -> #{}
        end,
    maps:fold(
        fun(Origin, Seq, Acc) ->
            case maps:get(Origin, Local, 0) of
                Cur when Seq > Cur ->
                    Acc#{Origin => #{peer => Seq, local => Cur}};
                _ ->
                    Acc
            end
        end,
        #{},
        PeerFrontier
    ).

%% @private
%% Substrate read-side freshness wiring. After a successful AE round,
%% bump every shard the consumer registered for this instance so
%% long-quiet shards (no writer activity) do not trip `{stale, _}` purely
%% on inactivity.
%%
%% Uses `bondy_oplog_core_registry:bump_ae_targets/2` so the AE-side bump
%% shares a primitive — and timing semantics — with the applier-side
%% bump in `bondy_oplog_applier:bump_ae_targets/1`. Empty target list
%% is a strict no-op.
%%
%% This is the `synced` site (we reached a peer this round). Under the
%% `quorum` isolation policy the bump is additionally gated on a connected
%% majority, so a minority partition that can still sync internally does
%% not self-certify fresh. `refuse` / `proceed` always bump here.
bump_ae_on_sync(Instance, Peer) ->
    case should_certify_freshness(synced) of
        true -> do_bump_ae_targets(Instance, #{peer => Peer, site => synced});
        false -> ok
    end.

-doc """
Freshen this instance's AE targets for a node whose peer list is empty
this round (no peer reachable). Certification follows
`should_certify_freshness/1`: a genuine single-node deployment
(`is_solo/0`) always certifies, since it has no peer to lag. Otherwise the
`db.aae.fence.on_isolation` policy decides — `proceed` always bumps
(treat isolation as vacuously fresh), `refuse` never bumps (fail closed —
the fence will refuse), `quorum` bumps only while connected to a majority.
Called by the sync scheduler at its no-peer seam.
""".
-spec maybe_bump_ae_isolated(instance_id()) -> ok.

maybe_bump_ae_isolated(Instance) when is_binary(Instance) ->
    case should_certify_freshness(isolated) of
        true ->
            do_bump_ae_targets(Instance, #{peer => undefined, site => isolated});
        false ->
            ok
    end.

%% @private
do_bump_ae_targets(Instance, Meta) ->
    case bondy_oplog_registry:ae_targets(Instance) of
        Targets when is_list(Targets), Targets =/= [] ->
            Now = erlang:monotonic_time(millisecond),
            {Bumped, NotFound} =
                bondy_oplog_core_registry:bump_ae_targets(Targets, Now),
            telemetry:execute(
                [bondy_oplog, sync, ae_bumped],
                #{count => Bumped, not_found => NotFound},
                Meta#{instance_id => Instance, now_ms => Now}
            ),
            ok;
        _ ->
            ok
    end.

%% @private
%% The configured no-peer fence policy (`db.aae.fence.on_isolation`).
isolation_policy() ->
    bondy_oplog_config:aae_fence_on_isolation().

%% @private
%% Whether a freshness certification is permitted now under the isolation
%% policy, for a bump arising from `Site` (`synced` = a successful round
%% that reached a peer; `isolated` = a tick with no peers in membership).
%%
%% A genuine single-node deployment (`is_solo/0`) certifies unconditionally: it
%% IS the whole cluster, so its local view cannot lag a peer that does not
%% exist. This is what lets a single-node deployment authenticate with the AAE
%% fence on, and a cold-started node serve auth before its first peer round —
%% without weakening `refuse` for a real isolated minority, whose membership
%% still lists the unreachable peers (so `is_solo/0` is false).
should_certify_freshness(Site) ->
    case is_solo() of
        true ->
            true;
        false ->
            case isolation_policy() of
                proceed -> true;
                refuse -> Site =:= synced;
                quorum -> connected_majority()
            end
    end.

%% @private
%% True iff this node is the sole member of its Partisan membership — a genuine
%% single-node deployment. `partisan_peer_service:members/0` returns the full
%% known membership (every peer ever joined, INCLUDING currently-unreachable
%% ones — the same set `connected_majority/0` reads as `Expected`), so a node
%% that was clustered and is now partitioned still lists its peers and is NOT
%% solo. Only a deployment that never had a peer is.
is_solo() ->
    case partisan_peer_service:members() of
        {ok, Members} when is_list(Members) -> length(Members) =< 1;
        _ -> false
    end.

%% @private
%% True iff this node is connected to a strict majority of its expected
%% Partisan membership (self counts). Solo membership is trivially a
%% majority; a minority partition is not.
connected_majority() ->
    Expected =
        case partisan_peer_service:members() of
            {ok, Members} when is_list(Members) -> length(Members);
            _ -> 1
        end,
    Connected = length(partisan:nodes()) + 1,
    Connected * 2 > Expected.

%% @private
%% Inserts pages into the local store. When the backend supports
%% concurrent writes (e.g. ETS), runs in this process — no gen_server
%% round-trip. Otherwise falls back to the gen_server merge_pages
%% call, which is required for backends whose store *is* the
%% gen_server's state (e.g. map_store).
merge_pages(Instance, Pages) when is_map(Pages) ->
    merge_pages(Instance, maps:values(Pages));
merge_pages(Instance, Pages) when is_list(Pages) ->
    case bondy_oplog_registry:mst(Instance) of
        undefined ->
            bondy_oplog_instance:merge_pages(Instance, Pages);
        MST ->
            Store = bondy_mst:store(MST),
            Caps = bondy_mst_store:capabilities(Store),
            case maps:get(concurrent_writes, Caps, false) of
                true ->
                    %% Direct insert in this process. The store
                    %% mutates in place (e.g. ETS); the gen_server's
                    %% MST handle wraps the same store and sees the
                    %% new pages on the next read.
                    lists:foreach(
                        fun(Page) ->
                            {_Hash, _MST1} = bondy_mst:put_page(MST, Page)
                        end,
                        Pages
                    ),
                    ok;
                false ->
                    bondy_oplog_instance:merge_pages(Instance, Pages)
            end
    end.

%% @private
%% `undefined` selects the adaptive round budget (scaled to the initial missing
%% set, see `pull_until_complete/6`) — the right default now that each round
%% pulls a bounded page batch and a bulk sync needs many rounds. A caller may
%% still pass an explicit integer cap (tests, special cases).
default_max_iterations(Opts) ->
    maps:get(max_iterations, Opts, undefined).
