%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_responder).

-behaviour(partisan_gen_server).

-include_lib("kernel/include/logger.hrl").
-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Node-level sync responder for distributed transports.

A single `partisan_gen_server` per node, registered locally under the
atom `?MODULE`. Distributed transport implementations
(`bondy_oplog_transport_partisan`, `bondy_oplog_transport_disterl`,
gRPC-based, ...) deliver incoming sync requests *here*, and the
responder dispatches them to the right local `bondy_oplog_instance`.

It is a `partisan_gen_server` (not a plain `gen_server`) so that the
reply to a remote caller routes back over Partisan: a deployment with
`connect_disterl => false` has no Erlang-distribution link to carry an
OTP `gen_server:reply/2`, so the responder must speak Partisan on both
the receive and reply legs. A plain disterl `gen_server:call` still
reaches it (a `partisan_gen_server` handles the `'$gen_call'` protocol),
so `bondy_oplog_transport_disterl` keeps working when Erlang
distribution *is* connected.

## Why a single responder

Instance ids are arbitrary binaries chosen by the consumer, and we
support millions of instances per node. We can't register each
instance's gen_server under a distinct atom name (atom-table growth
is unbounded). A single fixed-atom responder per node is the
addressing primitive distributed transports can rely on.

## Concurrency model

Every incoming `{sync_protocol, InstanceId, Request}` call is handled
by a *short-lived worker process* — the responder's `handle_call`
spawns the worker, defers the reply (`{noreply, State}`) and the
worker calls `partisan_gen_server:reply/2` once the dispatch completes. The
responder's mailbox is therefore freed almost immediately and many
peers can drive sync requests in parallel.

This matters because all sync traffic from all peers across all
instances funnels through this one process. A serial design would
serialise the entire node's incoming sync rate.

## Wire shape

A Partisan transport issues (a disterl transport uses the OTP
`gen_server:call` equivalent):

```erlang
partisan_gen_server:call(
    {bondy_oplog_responder, Peer},
    {sync_protocol, InstanceId, Request},
    [{timeout, Timeout}, {channel, Channel}]
).
```

| Request                                  | Reply                                                                  |
|---|---|
| `get_root`                               | `{ok, hash() \| undefined, fingerprint()}`                             |
| `get_frontier`                           | `{ok, #{origin() => seq()}, fingerprint()}`                            |
| `get_origins`                            | `{ok, [origin()]}`                                                     |
| `get_retired`                            | `{ok, [origin()]}`                                                     |
| `{get_pages, Set}`                       | `{ok, #{hash() => page()}}`                                            |
| `get_snapshot`                           | `{ok, no_snapshot}` \| `{ok, event_key(), term()}`                     |
| `get_catalogue_snapshot_init`            | `{ok, no_snapshot}` \| `{ok, {init, {watermark(), cursor()}}}`         |
| `{get_catalogue_snapshot_next, Cursor}`  | `{ok, {batch, {cursor(), [cell()]}}}` \| `{ok, {done, []}}` \| `{error, cursor_expired}` |

Errors propagate as `{error, Reason}` (e.g. `{instance_not_running, Id}`).
""").

-export([start_link/0]).
-export([dispatch/2]).
-export([child_spec/0]).

%% partisan_gen_server
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

-ifdef(TEST).
-export([cap_pages/2]).
-export([check_oversized_alarm/1]).
-endif.

%% Oversized-item alarm: raised while AAE sync is skipping items too large to
%% replicate over the transport frame. Driven off the sync_metrics counter, so
%% it covers pages AND cells uniformly and needs no back-edge from the detection
%% sites. The condition self-heals when the operator raises the frame cap.
-define(OVERSIZED_ALARM_ID, bondy_oplog_sync_oversized_items).
%% Poll cadence and the quiet window after which the alarm clears.
-define(OVERSIZED_POLL_MS, 30000).
-define(OVERSIZED_CLEAR_MS, 300000).

%% =============================================================================
%% LIFECYCLE
%% =============================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.

start_link() ->
    partisan_gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec child_spec() -> supervisor:child_spec().

child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

%% =============================================================================
%% API
%% =============================================================================

?DOC("""
Locally dispatches a sync `Request` to the instance identified by
`InstanceId`. Read-only requests use the lock-free instance API and
do not round-trip the instance gen_server.
""").
-spec dispatch(instance_id(), bondy_oplog_transport:request()) ->
    {ok, term()} | {error, term()}.

dispatch(InstanceId, get_root) when is_binary(InstanceId) ->
    case bondy_oplog_instance:whereis(InstanceId) of
        undefined ->
            {error, {instance_not_running, InstanceId}};
        _Pid ->
            %% We do NOT await the local applier's drain before reading the
            %% root. AAE is eventually consistent, and `root_hash/1` and
            %% `get_pages/2` both read the same in-memory MST, so the root we
            %% advertise and the pages we serve are mutually consistent even if
            %% a just-appended local event is still draining — the next sync
            %% round picks it up. Blocking on `await_apply/1` here is what made
            %% `get_root` (and `get_pages`) exceed the 5s sync timeout whenever
            %% the applier was busy under AAE load, so a peer that had lost a
            %% shard could never heal from us. Reply with the current root,
            %% plus this node's keying-topology fingerprint so the initiator can
            %% verify both nodes key data the same way before pulling pages.
            %%
            %% `aae_root/1` (not `root_hash/1`) applies the integrity guard:
            %% if our root is dangling (a page it references is missing —
            %% transiently normal under the truncate+page-GC churn) it
            %% answers `undefined`, so the peer pulls nothing unservable
            %% from us and we heal via our own pull / replay.
            %%
            %% A guard-tripped `undefined` MUST NOT be advertised as the
            %% root, because the initiator rightly treats an `undefined`
            %% peer root as "peer's tree is genuinely empty" — a COMPLETE
            %% round with nothing to pull, which the frontier-gap check
            %% then judges against our honest applied frontier. During a
            %% dangling window that manufactured a false standing-gap
            %% verdict on every such round. Distinguish the two: a live
            %% root that the
            %% guard refuses is answered as an ERROR — the session fails
            %% benignly and retries next round — while a genuinely empty
            %% tree (`root_hash/1` = `undefined`: fully compacted or never
            %% written) keeps the `undefined` answer that the joiner /
            %% fully-compacted-shard convergence path depends on. The two
            %% reads race harmlessly: a tree that empties in between
            %% answers an error once and empty on the retry.
            case bondy_oplog_instance:aae_root(InstanceId) of
                undefined ->
                    case bondy_oplog_instance:root_hash(InstanceId) of
                        undefined ->
                            {ok, undefined,
                                bondy_oplog:topology_fingerprint(
                                    bondy_oplog:db_of(InstanceId)
                                )};
                        _Live ->
                            {error, {root_unservable, InstanceId}}
                    end;
                Root ->
                    {ok, Root,
                        bondy_oplog:topology_fingerprint(
                            bondy_oplog:db_of(InstanceId)
                        )}
            end
    end;
dispatch(InstanceId, get_frontier) when is_binary(InstanceId) ->
    case bondy_oplog_instance:whereis(InstanceId) of
        undefined ->
            {error, {instance_not_running, InstanceId}};
        _Pid ->
            %% The applied-frontier version vector convergence oracle:
            %% `#{Origin => max Seq}`. Equal frontiers across nodes ⇒ the same
            %% op-set has been applied ⇒ converged (causal delivery makes a
            %% per-origin max Seq identify the applied prefix), and it is
            %% compaction-invariant.
            %%
            %% INSTALLED-CONSISTENCY BARRIER (unlike `get_root', which stays
            %% lock-free): the answered frontier is the initiator's evidence
            %% base for the frontier-GAP check, so everything it counts must
            %% already be in the tree the round completes against. The VV
            %% advances at the projection write, which the drain performs
            %% BEFORE the MST install, so a lock-free read counts events the
            %% tree cannot yet ship — ordinary install lag read as a gap.
            %%
            %% THE ORDER IS LOAD-BEARING: snapshot the VV FIRST, then drain,
            %% then answer the SNAPSHOT. Every event the snapshot counts had
            %% its projection write done at snapshot time, so it is already
            %% in the overlay when the drain starts and installed by the time
            %% we answer. Draining first and reading after leaves a window in
            %% which events applied mid-call are counted but not yet
            %% installed when the round grabs its root — a standing
            %% off-by-one gap on nearly every round under sustained writes.
            %%
            %% On drain timeout answer an error: the initiator degrades to
            %% `#{}', skipping both adoption and the gap check for the round.
            Frontier = bondy_oplog_instance:frontier(InstanceId),
            case bondy_oplog_instance:await_apply(InstanceId) of
                ok ->
                    {ok, Frontier,
                        bondy_oplog:topology_fingerprint(
                            bondy_oplog:db_of(InstanceId)
                        )};
                {error, timeout} ->
                    {error, {frontier_unavailable, InstanceId}}
            end
    end;
dispatch(InstanceId, {confirm_root, Peer, Root}) when
    is_binary(InstanceId), is_binary(Root)
->
    %% The peer completed a pull against the root we advertised, so it now
    %% holds every page reachable from it. Checkpoint that root against the
    %% peer: both replicas now hold the SAME root for each other, which is
    %% Canteen's common sub-graph and what makes the stability frontier
    %% symmetric. Without it each side records only what it unilaterally
    %% observed, at its own times, and compaction diverges.
    case bondy_oplog_instance:whereis(InstanceId) of
        undefined ->
            {error, {instance_not_running, InstanceId}};
        _Pid ->
            ok = bondy_oplog_peer_state:record_sync_complete(
                Peer, InstanceId, Root
            ),
            {ok, ok}
    end;
dispatch(InstanceId, get_origins) when is_binary(InstanceId) ->
    %% NODE-level, deliberately: the origins this node currently claims,
    %% for the retirement reap-by-complement
    %% (`bondy_oplog_origin_retirement`). The instance id only routes the
    %% request; every instance answers identically. A mixed-version peer
    %% that lacks this verb answers `{error, {dispatch_failed, _}}`, which
    %% the retirement pass treats as member-unreachable — fail-closed.
    {ok, bondy_oplog_origin_retirement:local_origins()};
dispatch(InstanceId, get_retired) when is_binary(InstanceId) ->
    %% NODE-level, like `get_origins`: this node's view of the replicated
    %% grow-only retirement set. Peers pull it and union it in, which is the
    %% whole of the replication — the set only grows, so there is nothing to
    %% order and nothing to reconcile.
    %%
    %% It is also the reap's precondition: a replica drops a retired
    %% origin's frontier entry only once EVERY member's answer contains that
    %% origin, so a mixed-version peer answering `{error, {dispatch_failed,
    %% _}}` blocks the reap rather than licensing it.
    {ok, bondy_oplog_origin_bans:retired()};
dispatch(InstanceId, {get_pages, Hashes}) when is_binary(InstanceId) ->
    do_get_pages(InstanceId, Hashes);
dispatch(InstanceId, {get_pages, _Peer, _PeerRoot, Hashes}) when
    is_binary(InstanceId)
->
    %% Reciprocal form. The requester's peer id and root ride along so that a
    %% responder learns, for free, what the requester holds — the input a
    %% stability oracle needs (see BONDY_DB_DELETE_DESIGN.md §4.6).
    %%
    %% We do NOT act on it here. Two hazards, both measured:
    %%
    %%  1. Root inequality is not "I am behind". While A bulk-pulls from B the
    %%     roots differ on *every* round, so triggering on inequality turns one
    %%     bulk pull into a storm of reverse sessions.
    %%  2. Those sessions consume slots from the node-wide `aae_max_concurrency`
    %%     cap (default 3), starving the sessions that were making progress.
    %%     Reciprocity then *slows* convergence — `bondy_frontier_cluster_SUITE`
    %%     fails on `asymmetric_compaction_keeps_oracle_in_sync` with a
    %%     convergence timeout.
    %%
    %% Serving pages must also stay cheap: an `is-behind` test via `missing_set`
    %% is O(diff) and this is the hot path.
    %%
    %% Wiring the trigger therefore needs a genuine is-behind predicate and a
    %% budget that does not compete with scheduled sync. Until then the wire
    %% carries the information and nothing acts on it.
    do_get_pages(InstanceId, Hashes);
dispatch(InstanceId, get_snapshot) when is_binary(InstanceId) ->
    case bondy_oplog_instance:whereis(InstanceId) of
        undefined ->
            {error, {instance_not_running, InstanceId}};
        _Pid ->
            %% No await_apply: serve the current MST snapshot (AAE eventual);
            %% blocking here caused the 5s sync timeouts — see `get_root`.
            %% Wire-protocol message `get_snapshot` is preserved
            %% (transport ABI). Internally it routes to the renamed
            %% compaction_checkpoint API.
            case bondy_oplog_instance:compaction_checkpoint(InstanceId) of
                not_found -> {ok, no_snapshot};
                {ok, W, S} -> {ok, W, S}
            end
    end;
dispatch(InstanceId, get_catalogue_snapshot_init) when
    is_binary(InstanceId)
->
    case bondy_oplog_instance:whereis(InstanceId) of
        undefined ->
            {error, {instance_not_running, InstanceId}};
        _Pid ->
            %% No await_apply: serve the current MST snapshot (AAE eventual);
            %% blocking here caused the 5s sync timeouts — see `get_root`.
            case bondy_oplog_catalogue_snapshot:init(InstanceId) of
                {ok, no_snapshot} ->
                    {ok, no_snapshot};
                {ok, {Watermark, Cursor}} ->
                    {ok, {init, {Watermark, Cursor}}}
            end
    end;
dispatch(InstanceId, {get_catalogue_snapshot_next, Cursor}) when
    is_binary(InstanceId), is_binary(Cursor)
->
    case bondy_oplog_instance:whereis(InstanceId) of
        undefined ->
            {error, {instance_not_running, InstanceId}};
        _Pid ->
            case bondy_oplog_catalogue_snapshot:next(InstanceId, Cursor) of
                {ok, {batch, _} = Batch} -> {ok, Batch};
                {ok, {done, _} = Done} -> {ok, Done};
                {error, _} = E -> E
            end
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
do_get_pages(InstanceId, Hashes) ->
    case bondy_oplog_instance:whereis(InstanceId) of
        undefined ->
            {error, {instance_not_running, InstanceId}};
        _Pid ->
            %% No await_apply: serve the current MST snapshot (AAE eventual);
            %% blocking here caused the 5s sync timeouts — see `get_root`.
            HashList =
                case is_list(Hashes) of
                    true -> Hashes;
                    false -> sets:to_list(Hashes)
                end,
            Pages = bondy_oplog_instance:get_pages(InstanceId, HashList),
            case map_size(Pages) of
                0 when HashList =/= [] ->
                    %% We hold none of the requested pages. The usual cause is
                    %% that compaction reclaimed them, in which case no amount
                    %% of retrying will help and the caller must bootstrap.
                    %% Say so explicitly rather than returning an empty map,
                    %% which the caller cannot distinguish from a bug.
                    {ok, {unavailable, HashList}};
                _ ->
                    {ok, cap_pages(InstanceId, Pages)}
            end
    end.

%% @private
%% Pack pages into a response no larger than the sync byte ceiling (derived from
%% Partisan's frame cap), so the reply never trips `max_message_size` and drops
%% the peer. Pages beyond the ceiling are left out; the requester merges what it
%% gets and re-derives its `missing_set` next round, so a capped response just
%% costs one more round. At least one fitting page is always included, so the
%% caller never sees an (error-signalling) empty map while progress is possible.
%% A single page whose serialized size alone exceeds the ceiling cannot be
%% delivered within the frame cap at all: it is skipped and reported, so it never
%% poisons the peer connection — it simply cannot replicate until the cap is
%% raised above it.
cap_pages(InstanceId, Pages) ->
    MaxBytes = bondy_oplog_config:sync_max_response_bytes(),
    {Capped, _Used} = maps:fold(
        fun(Hash, Page, {Acc, Used} = Keep) ->
            %% Measure the wire footprint of the whole map entry — the hash
            %% KEY plus the page value — not just the value, so the packed
            %% response matches what actually serializes into the frame.
            Size = erlang:external_size(Hash) + erlang:external_size(Page),
            if
                Size > MaxBytes ->
                    ok = bondy_oplog_sync_metrics:report_oversized(
                        page, {InstanceId, Hash}, Size, MaxBytes
                    ),
                    Keep;
                Acc =:= #{} ->
                    %% Always ship at least one fitting page so the stream makes
                    %% progress even when the remaining budget is small.
                    {Acc#{Hash => Page}, Size};
                Used + Size =< MaxBytes ->
                    {Acc#{Hash => Page}, Used + Size};
                true ->
                    %% Ceiling reached; leave the rest for the next round.
                    Keep
            end
        end,
        {#{}, 0},
        Pages
    ),
    Capped.

%% =============================================================================
%% partisan_gen_server CALLBACKS
%% =============================================================================

init([]) ->
    process_flag(trap_exit, true),
    %% Serves sync/catalogue-snapshot requests in bursts; off_heap mailbox
    %% so a request burst backlog isn't re-scanned by the GC.
    process_flag(message_queue_data, off_heap),
    ok = bondy_oplog_sync_metrics:declare(),
    ok = schedule_oversized_poll(),
    {ok, #{
        oversized_alarm => false,
        oversized_total => 0,
        oversized_last_increase => 0
    }}.

handle_call({sync_protocol, InstanceId, Request}, From, State) ->
    %% Spawn-and-go: free the responder's mailbox immediately. The
    %% worker dispatches and uses gen_server:reply/2 to answer.
    _ = spawn(fun() ->
        Reply =
            try
                dispatch(InstanceId, Request)
            catch
                C:R:S ->
                    ?LOG_WARNING(#{
                        description => "responder dispatch raised",
                        instance_id => InstanceId,
                        request => Request,
                        class => C,
                        reason => R,
                        stacktrace => S
                    }),
                    {error, {dispatch_failed, R}}
            end,
        partisan_gen_server:reply(From, Reply)
    end),
    {noreply, State};
handle_call(_Req, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(check_oversized_alarm, State0) ->
    State = check_oversized_alarm(State0),
    ok = schedule_oversized_poll(),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    %% Best-effort: don't leave a stale alarm across a responder restart. The
    %% new incarnation re-asserts within one poll if the condition persists.
    ok = clear_oversized_alarm(),
    ok.

%% =============================================================================
%% PRIVATE — oversized-item alarm
%% =============================================================================

%% @private
schedule_oversized_poll() ->
    _ = erlang:send_after(?OVERSIZED_POLL_MS, self(), check_oversized_alarm),
    ok.

%% @private
%% Drive the SASL alarm off the sync_metrics oversized counter: assert while it
%% is still climbing, clear after `?OVERSIZED_CLEAR_MS` with no further skips
%% (the operator raised the frame cap). The `oversized_alarm` flag makes set and
%% clear happen once per episode, so a prepending alarm handler never
%% accumulates duplicate entries.
check_oversized_alarm(State) ->
    #{
        oversized_alarm := Alarmed,
        oversized_total := PrevTotal,
        oversized_last_increase := LastIncrease
    } = State,
    Total = bondy_oplog_sync_metrics:oversized_total(),
    Now = erlang:monotonic_time(millisecond),
    if
        Total > PrevTotal ->
            Alarmed orelse set_oversized_alarm(),
            State#{
                oversized_alarm => true,
                oversized_total => Total,
                oversized_last_increase => Now
            };
        Alarmed andalso Now - LastIncrease >= ?OVERSIZED_CLEAR_MS ->
            ok = clear_oversized_alarm(),
            State#{oversized_alarm => false};
        true ->
            State
    end.

%% @private
set_oversized_alarm() ->
    Desc = <<
        "AAE sync is skipping items too large to replicate: a stored value "
        "exceeds the inter-node frame cap (cluster.max_message_size). The "
        "affected data cannot converge until the cap is raised above it. See "
        "the bondy_oplog_sync_oversized_item_last_bytes metric and the WARNING "
        "logs for the size and identity."
    >>,
    _ =
        try
            alarm_handler:set_alarm({?OVERSIZED_ALARM_ID, Desc})
        catch
            _:_ -> ok
        end,
    ok.

%% @private
clear_oversized_alarm() ->
    _ =
        try
            alarm_handler:clear_alarm(?OVERSIZED_ALARM_ID)
        catch
            _:_ -> ok
        end,
    ok.
