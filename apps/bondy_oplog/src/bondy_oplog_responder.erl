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
            %% if our root is dangling (a page it references is missing) it
            %% advertises `undefined` instead, so the peer pulls nothing
            %% unservable from us (avoiding `peer_returned_empty_pages`) and we
            %% heal our own root via our pull / replay rather than poisoning a
            %% healthy peer. Local logic keeps using the real `root_hash/1`.
            {ok, bondy_oplog_instance:aae_root(InstanceId),
                bondy_oplog:topology_fingerprint(
                    bondy_oplog:db_of(InstanceId)
                )}
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
            %% compaction-invariant. Lock-free registry read; like `get_root` we
            %% do NOT await the applier drain (eventually consistent). The
            %% topology fingerprint lets the initiator compare frontiers only when
            %% both nodes key data the same way.
            {ok, bondy_oplog_instance:frontier(InstanceId),
                bondy_oplog:topology_fingerprint(
                    bondy_oplog:db_of(InstanceId)
                )}
    end;
dispatch(InstanceId, {get_pages, Hashes}) when is_binary(InstanceId) ->
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
            {ok, bondy_oplog_instance:get_pages(InstanceId, HashList)}
    end;
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
%% partisan_gen_server CALLBACKS
%% =============================================================================

init([]) ->
    process_flag(trap_exit, true),
    %% Serves sync/catalogue-snapshot requests in bursts; off_heap mailbox
    %% so a request burst backlog isn't re-scanned by the GC.
    process_flag(message_queue_data, off_heap),
    {ok, #{}}.

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

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
