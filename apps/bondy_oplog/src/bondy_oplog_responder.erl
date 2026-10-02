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
| `get_catalogue_snapshot_init`            | `{ok, no_snapshot}` \| `{ok, {init, {watermark(), cursor()}}}`         |
| `{get_catalogue_snapshot_next, Cursor}`  | `{ok, {batch, {cursor(), [cell()]}}}` \| `{ok, {done, []}}` \| `{error, cursor_expired}` |

Errors propagate as `{error, Reason}` (e.g. `{instance_not_running, Id}`).
## Read semantics

`get_root` and `{get_pages, Set}` do not await the local applier's drain.
Both read the same in-memory MST, so the advertised root and the pages served
are mutually consistent even while a just-appended local event is still
draining, and the next round picks that event up. Awaiting the
drain would put `get_root` over the sync timeout whenever the applier is busy
under AAE load, leaving a peer that had lost a shard unable to heal from this
node. Both replies also carry this node's keying-topology fingerprint, so the
initiator can confirm the two nodes key data the same way before pulling.

`get_root` answers `bondy_oplog_instance:aae_root/1`, which applies the
integrity guard, rather than the raw root. The two `undefined` cases stay
distinct on the wire: a genuinely empty tree — fully compacted or never
written — answers `undefined`, which the joiner and the fully-compacted-shard
convergence path depend on, while a live root the guard refuses answers an
error, failing the session benignly for a retry. Collapsing them lets the
initiator read a dangling window as "the peer's tree is empty", a complete
round with nothing to pull, and the frontier-gap check then returns a false
standing-gap verdict on every round of that window.

`get_frontier` answers the applied-frontier version vector, `#{Origin => max
Seq}`, read lock-free from the registry. Equal frontiers across nodes mean
the same op-set has been applied, because causal delivery makes a per-origin
max sequence identify the applied prefix, and the vector is
compaction-invariant. Unlike `get_root` it is an
installed-consistency barrier, since the answered vector is the initiator's
evidence base for the gap check and must therefore count only what the tree
can already ship. On drain timeout the reply is an error and the initiator
degrades to `#{}`, skipping both adoption and the gap check for that round.

`get_origins` and `get_retired` are node-level: this node's view of the
replicated grow-only retirement set. A peer unions the answer in, which is the
whole of the replication — the set only grows, so there is nothing to order
and nothing to reconcile. `get_retired` is also the reap's precondition. A
replica drops a retired origin's frontier entry only once every member's
answer contains that origin, so a peer that cannot answer blocks the reap
rather than licensing it.

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
`InstanceId`. Read-only requests do not await the applier's drain, except
`get_frontier`, which is an installed-consistency barrier.
""").
-spec dispatch(instance_id(), bondy_oplog_transport:request()) ->
    {ok, term()} | {error, term()}.

dispatch(InstanceId, get_root) when is_binary(InstanceId) ->
    case bondy_oplog_instance:whereis(InstanceId) of
        undefined ->
            {error, {instance_not_running, InstanceId}};
        _Pid ->
            %% No drain await here, and `aae_root/1` rather than the raw
            %% root, so the integrity guard applies. A root the guard refuses
            %% answers an ERROR — `undefined` is reserved for a genuinely
            %% empty tree, and collapsing the two manufactures a standing gap.
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
            %% The order is the mechanism: snapshot the vector FIRST, then
            %% drain, then answer the SNAPSHOT. Everything the snapshot
            %% counts had its projection write done at snapshot time, so it
            %% is installed by the time we answer. Reading after the drain
            %% instead counts events applied mid-call that the round's root
            %% cannot yet carry — an off-by-one gap on nearly every round
            %% under sustained writes.
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
    {ok, bondy_oplog_origin_bans:retired()};
dispatch(InstanceId, {get_pages, Hashes}) when is_binary(InstanceId) ->
    do_get_pages(InstanceId, Hashes);
dispatch(InstanceId, {get_pages, _Peer, _PeerRoot, Hashes}) when
    is_binary(InstanceId)
->
    %% The requester's peer id and root ride along, so a responder learns for
    %% free what the requester holds. Nothing acts on it: root inequality is
    %% not "I am behind" — during a bulk pull the roots differ on every round,
    %% so a reciprocal trigger becomes a storm of reverse sessions that
    %% starves the node-wide `aae_max_concurrency` cap and slows convergence
    %% (`bondy_oplog_reciprocal_sync_test`). Acting on it needs a real
    %% is-behind predicate and a budget of its own.
    do_get_pages(InstanceId, Hashes);
dispatch(InstanceId, get_catalogue_snapshot_init) when
    is_binary(InstanceId)
->
    case bondy_oplog_instance:whereis(InstanceId) of
        undefined ->
            {error, {instance_not_running, InstanceId}};
        _Pid ->
            %% `bondy_oplog_catalogue_snapshot:build_targets/2` enumerates the
            %% tables that have REGISTERED, so an instance still filling its
            %% routing directory ships a catalogue missing those buckets while
            %% `get_frontier` still reports the whole applied vector. The
            %% initiator would install the one and adopt the other. Refuse
            %% until the directory is complete: the session ends benignly and
            %% the next round retries, as for `root_unservable`.
            case bondy_oplog_registry:tables_registered(InstanceId) of
                false ->
                    {error, {tables_not_registered, InstanceId}};
                true ->
                    %% No await_apply: serve the current MST snapshot (AAE
                    %% eventual); blocking here caused the 5s sync timeouts —
                    %% see `get_root`.
                    case bondy_oplog_catalogue_snapshot:init(InstanceId) of
                        {ok, no_snapshot} ->
                            {ok, no_snapshot};
                        {ok, {Watermark, Cursor}} ->
                            {ok, {init, {Watermark, Cursor}}}
                    end
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
                {ok, {chunked_batch, _} = Chunked} -> {ok, Chunked};
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
%% Packs pages into a reply no larger than the sync byte ceiling (derived from
%% Partisan's frame cap), so a reply never trips `max_message_size` and drops
%% the peer. What does not fit costs one more round: the requester merges what
%% it gets and re-derives its `missing_set`. At least one fitting page is
%% always included, so an empty map keeps its error meaning. A page larger
%% than the ceiling on its own is skipped and reported rather than allowed to
%% poison the peer connection; it cannot replicate until the cap is raised
%% above it.
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
        "AAE sync is handling items too large for the inter-node frame cap "
        "(cluster.max_message_size). Catalogue CELLS are shipped in parts and "
        "still converge, at the cost of extra bootstrap rounds; MST PAGES are "
        "left out, so those sync rounds complete nothing and the instance "
        "makes no AAE progress until the cap is raised. See "
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
