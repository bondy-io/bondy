%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_transport_inline).
-behaviour(bondy_oplog_transport).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
In-VM transport for tests and single-node deployments.

`peer_id` is interpreted as an `instance_id()` — the request is
dispatched to the local `bondy_oplog_instance` registered
under that name. This makes it trivial to wire up two replicas of the
same logical CRDT in a single VM for unit tests.

For real distributed sync, replace with a network-aware transport
(e.g. Distributed Erlang, Partisan, gRPC) implementing the same
behaviour.
""").

-export([request/4]).
-export([self_id/1]).

-spec request(
    peer_id(),
    instance_id(),
    bondy_oplog_transport:request(),
    map()
) -> {ok, term()} | {error, term()}.

%% peer_id is treated as a local instance id.
request(PeerInstanceId, _InstanceId, Request, _Opts) when
    is_binary(PeerInstanceId)
->
    case bondy_oplog_instance:whereis(PeerInstanceId) of
        undefined ->
            {error, {peer_not_running, PeerInstanceId}};
        _Pid ->
            do_request(PeerInstanceId, Request)
    end;
request(Peer, _InstanceId, _Request, _Opts) ->
    {error, {invalid_peer_for_inline_transport, Peer}}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
do_request(PeerInstance, get_root) ->
    %% Drain the peer's applier so the returned root reflects every
    %% WAL-fsynced event. Without this, a freshly-appended event that
    %% is still in the peer's overlay would not be in the returned
    %% root, and the local sync session would conclude
    %% prematurely-equal or miss pages.
    _ = bondy_oplog_instance:await_apply(PeerInstance),
    {ok, bondy_oplog_instance:root_hash(PeerInstance)};
do_request(PeerInstance, get_frontier) ->
    %% Snapshot the applied VV FIRST, then drain, then answer the
    %% SNAPSHOT — the responder's installed-consistency order (see
    %% `bondy_oplog_responder`'s `get_frontier` clause): every event the
    %% snapshot counts is in the overlay before the drain starts, so it
    %% is installed by the time we answer and the round's later root
    %% read is same-or-newer. Draining first and reading after can
    %% count an event applied mid-call that the served tree cannot yet
    %% ship. In-VM transport ⇒ no fingerprint leg (the responder's
    %% Partisan path carries it).
    Frontier = bondy_oplog_instance:frontier(PeerInstance),
    _ = bondy_oplog_instance:await_apply(PeerInstance),
    {ok, Frontier};
do_request(PeerInstance, {confirm_root, _, _} = Request) ->
    bondy_oplog_responder:dispatch(PeerInstance, Request);
do_request(PeerInstance, get_origins) ->
    %% Node-level origin advertisement for retirement reap-by-complement;
    %% delegate so the in-VM path exercises the responder verb.
    bondy_oplog_responder:dispatch(PeerInstance, get_origins);
do_request(PeerInstance, {get_pages, _} = Request) ->
    %% Delegate to the responder so the in-VM path exercises exactly the same
    %% logic as the network transports — notably the `unavailable` reply when
    %% the peer can no longer serve the requested pages.
    bondy_oplog_responder:dispatch(PeerInstance, Request);
do_request(PeerInstance, {get_pages, _, _, _} = Request) ->
    %% Reciprocal form; the responder also schedules the reverse exchange.
    bondy_oplog_responder:dispatch(PeerInstance, Request);
do_request(PeerInstance, get_snapshot) ->
    %% Wire-protocol message name is preserved (transport ABI);
    %% internally we route to the renamed compaction_checkpoint API.
    case bondy_oplog_instance:compaction_checkpoint(PeerInstance) of
        not_found -> {ok, no_snapshot};
        {ok, W, S} -> {ok, W, S}
    end;
do_request(PeerInstance, get_catalogue_snapshot_init) ->
    %% Drain the peer's applier so the watermark and any cells already
    %% in the WAL are visible before we mint the cursor. Without this,
    %% an event appended just before `init` could land on the peer
    %% AFTER our high-water read, leaving the initiator stuck waiting
    %% for an old watermark to advance.
    _ = bondy_oplog_instance:await_apply(PeerInstance),
    case bondy_oplog_catalogue_snapshot:init(PeerInstance) of
        {ok, no_snapshot} ->
            {ok, no_snapshot};
        {ok, {Watermark, Cursor}} ->
            {ok, {init, {Watermark, Cursor}}}
    end;
do_request(PeerInstance, {get_catalogue_snapshot_next, Cursor}) ->
    case bondy_oplog_catalogue_snapshot:next(PeerInstance, Cursor) of
        {ok, {batch, _} = Batch} ->
            {ok, Batch};
        {ok, {done, _} = Done} ->
            {ok, Done};
        {error, _} = E ->
            E
    end.

-doc """
Peers are addressed by instance id on this transport, so this instance's own
id is exactly how a peer would address it.
""".
-spec self_id(instance_id()) -> peer_id().

self_id(InstanceId) ->
    InstanceId.
