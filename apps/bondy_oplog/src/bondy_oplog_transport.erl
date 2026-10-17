%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_transport).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Behaviour for the wire transport used by the sync protocol.

The library defines the protocol; the transport plugs in the actual
network. The library ships:

- `bondy_oplog_transport_inline` — for in-VM tests; routes
  requests to the local `bondy_oplog_instance` for the
  `peer_id` (treated as a local instance id).
- `bondy_oplog_transport_disterl` — Distributed Erlang
  transport; `peer_id` is a node atom.
- `bondy_oplog_transport_partisan` — the transport Bondy uses;
  `peer_id` is a node atom and replies route back over Partisan
  via `bondy_oplog_responder` (a `partisan_gen_server`).

Bondy runs with `connect_disterl => false`, so Partisan — not
Distributed Erlang — carries sync traffic, and `partisan` is a hard
dependency of this application today. This behaviour is the seam that
keeps the wire swappable: a deployment on another networking layer
implements it without touching the protocol, and Partisan could later
move behind an optional dependency.

## Request types

The library issues these requests, encoded as opaque terms; the
transport delivers them to the peer's responder which calls back into
`bondy_oplog_instance` and returns the reply.

| Request                                | Reply                                                                  |
|---|---|
| `get_root`                             | `{ok, hash() \| undefined}` \| `{ok, hash() \| undefined, fingerprint()}` |
| `get_frontier`                          | `{ok, #{origin() => seq()}}` \| `{ok, #{origin() => seq()}, fingerprint(), #{origin() => seq()}}` \| `{error, {refold_owed, instance_id()}}` |
| `get_origins`                          | `{ok, [origin()]}`                                                     |
| `get_retired`                          | `{ok, [origin()]}`                                                     |
| `{get_pages, Set}`                     | `{ok, #{hash() => page()}}`                                            |
| `get_catalogue_snapshot_init`          | `{ok, {init, {watermark(), cursor(), [bucket()]}}}` \| `{ok, no_snapshot}` \| `{error, {tables_not_registered, instance_id()}}` \| `{error, {refold_owed, instance_id()}}` |
| `{get_catalogue_snapshot_next, Cursor}`| `{ok, {batch, {cursor(), [cell()]}}}` \| `{ok, {chunked_batch, {cursor(), [cell()], [cell_chunk()]}}}` \| `{ok, {done, [cell()]}}` \| `{error, cursor_expired}` |
| `{release_catalogue_snapshot, Cursor}` | `{ok, ok}` |

A running instance refuses two requests on its own state, and both refusals
are benign: the initiator's session ends, or reads the frontier as unknown,
and the next round retries.

- `get_catalogue_snapshot_init` while its routing directory is still filling.
  `bondy_oplog_catalogue_snapshot:build_targets/2` enumerates the tables that
  have REGISTERED here, so the catalogue would miss those buckets while
  `get_frontier` answered with the whole applied vector, and the initiator
  would install the one and adopt the other.
- `get_catalogue_snapshot_init` and `get_frontier` while it is itself
  re-bootstrapping, from before its first batch request until its frontier
  claims the frontier its source reported once the stream ended
  (`bondy_oplog_instance:serving/1`): its cells may until then reflect events
  its frontier does not claim. It does not start re-bootstrapping while a
  snapshot cursor of its own is open (`bondy_oplog_instance:begin_install/3`).

`watermark()` is the peer-observed max HLC across the catalogue
projection at session start (per-shard high-water atomic from
`bondy_oplog_high_water`).

`cursor()` is an opaque binary token minted by the peer; the initiator
echoes it back unchanged on every `get_catalogue_snapshot_next` call.

`[bucket()]` names every bucket (binary) the session scans, including one
that ships no cell: the initiator deletes its cells of those buckets that the
stream does not ship (`bondy_oplog_applier:commit_stage/4`).

`cell()` is `{Bucket :: binary(), Key :: binary(), Frame :: binary()}`
where Frame is the on-disk V2 cell frame as stored by the projection
adapter (`bondy_oplog_projection_adapter`).

The catalogue-snapshot pair is used by
`bondy_oplog_sync_session:bootstrap_catalogue/3` for fresh and
recovering catalogue-mode replicas.

The transport itself is stateless. Per-call options are passed through
the `Opts` argument.
""").

-type cell() ::
    {Bucket :: binary(), Key :: binary(), Frame :: binary()}.

%% One numbered part of a cell whose serialized size alone exceeds the sync
%% byte ceiling, so it cannot be framed whole
%% (`bondy_oplog_catalogue_snapshot:emit_parts/6`). Parts of a given
%% `{Bucket, Key}` arrive in ascending `Idx` order across consecutive
%% batches; the initiator reassembles `Frame` by concatenating parts 1..Total
%% and MUST fail the bootstrap if the stream ends with an incomplete
%% reassembly.
-type cell_chunk() ::
    {
        Bucket :: binary(),
        Key :: binary(),
        Idx :: pos_integer(),
        Total :: pos_integer(),
        Part :: binary()
    }.

-type request() ::
    get_root
    | get_frontier
    %% Node-level, not instance-level: the instance id only routes them.
    %% `get_origins` is the origins the peer currently claims (the
    %% reap-by-complement input); `get_retired` is the peer's view of the
    %% replicated grow-only retirement set, which peers union in and which
    %% gates frontier reaping.
    | get_origins
    | get_retired
    | {get_pages, [bondy_mst:hash()] | sets:set(bondy_mst:hash())}
    %% Reciprocal form: carries the requester's peer id and root so the
    %% responder learns, for free, that it is behind and can schedule its own
    %% exchange in the opposite direction. A transport that does not export
    %% `self_id/1` sends the 2-tuple form above.
    | {get_pages, Peer :: peer_id(), Root :: bondy_mst:hash(), [
        bondy_mst:hash()
    ]}
    %% Swap-completion notice: the initiator of a completed round reports its
    %% durable frontier, which the responder records against it.
    | {confirm_frontier, Peer :: peer_id(),
        Frontier :: #{binary() => non_neg_integer()}}
    | get_catalogue_snapshot_init
    | {get_catalogue_snapshot_next, bondy_oplog_catalogue_cursor:cursor()}
    | {release_catalogue_snapshot, bondy_oplog_catalogue_cursor:cursor()}.

-type response() ::
    {ok, bondy_mst:hash() | undefined}
    | {ok, #{binary() => non_neg_integer()}}
    %% `get_frontier`: applied frontier, topology fingerprint, durable frontier
    | {ok, #{binary() => non_neg_integer()}, binary() | undefined, #{
        binary() => non_neg_integer()
    }}
    %% `get_origins` / `get_retired`
    | {ok, [binary()]}
    | {ok, #{bondy_mst:hash() => bondy_mst_page:t()}}
    %% The peer cannot serve the requested pages — typically because they have
    %% been reclaimed by compaction. Distinct from an empty page map, which is
    %% a protocol violation. The caller should fall back to bootstrap rather
    %% than retry.
    | {ok, {unavailable, [bondy_mst:hash()]}}
    | {ok, no_snapshot}
    | {ok, bondy_oplog_event:event_key(), term()}
    | {ok,
        {init,
            {non_neg_integer(), bondy_oplog_catalogue_cursor:cursor(), [
                binary()
            ]}}}
    | {ok, {batch, {bondy_oplog_catalogue_cursor:cursor(), [cell()]}}}
    %% Emitted only when a cell is too large to frame whole; the initiator
    %% reassembles the parts before it installs the cell.
    | {ok,
        {chunked_batch,
            {
                bondy_oplog_catalogue_cursor:cursor(), [cell()], [cell_chunk()]
            }}}
    | {ok, {done, []}}
    | {error, cursor_expired}.

-export_type([cell/0]).
-export_type([cell_chunk/0]).

-export_type([request/0]).
-export_type([response/0]).

-export([response/1]).

-callback request(
    Peer :: peer_id(),
    InstanceId :: instance_id(),
    Request :: request(),
    Opts :: map()
) -> response() | {error, term()}.

-doc """
Returns this node's own `peer_id()` — the value a remote peer would use to
address it over this transport.

Transport-specific: the inline transport addresses peers by instance id, so
self is `InstanceId`; network transports address by node.
""".
-callback self_id(InstanceId :: instance_id()) -> peer_id().

-doc """
Admits a reply a network transport received from a peer's responder: every
shape `response()` allows passes unchanged, and anything else becomes
`{error, {unexpected_response, Reply}}`. One home for the shapes, so a new
reply cannot be admitted by one transport and dropped by another.
""".
-spec response(term()) -> response() | {error, term()}.

response({ok, _} = Reply) -> Reply;
response({ok, _, _} = Reply) -> Reply;
response({ok, _, _, _} = Reply) -> Reply;
response({error, _} = Error) -> Error;
response(Other) -> {error, {unexpected_response, Other}}.
