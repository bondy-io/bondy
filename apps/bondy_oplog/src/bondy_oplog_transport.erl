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
| `get_frontier`                          | `{ok, #{origin() => seq()}}` \| `{ok, #{origin() => seq()}, fingerprint()}` |
| `{get_pages, Set}`                     | `{ok, #{hash() => page()}}`                                            |
| `get_snapshot`                         | `{ok, event_key(), term()}` \| `{ok, no_snapshot}`                     |
| `get_catalogue_snapshot_init`          | `{ok, {init, {watermark(), cursor()}}}` \| `{ok, no_snapshot}`         |
| `{get_catalogue_snapshot_next, Cursor}`| `{ok, {batch, {cursor(), [cell()]}}}` \| `{ok, {done, []}}` \| `{error, cursor_expired}` |

`watermark()` is the peer-observed max HLC across the catalogue
projection at session start (per-shard high-water atomic from
`bondy_oplog_high_water`).

`cursor()` is an opaque binary token minted by the peer; the initiator
echoes it back unchanged on every `get_catalogue_snapshot_next` call.

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

-type request() ::
    get_root
    | get_frontier
    | {get_pages, [bondy_mst:hash()] | sets:set(bondy_mst:hash())}
    | get_snapshot
    | get_catalogue_snapshot_init
    | {get_catalogue_snapshot_next, bondy_oplog_catalogue_cursor:cursor()}.

-type response() ::
    {ok, bondy_mst:hash() | undefined}
    | {ok, #{binary() => non_neg_integer()}}
    | {ok, #{bondy_mst:hash() => bondy_mst_page:t()}}
    | {ok, no_snapshot}
    | {ok, bondy_oplog_event:event_key(), term()}
    | {ok, {init, {non_neg_integer(), bondy_oplog_catalogue_cursor:cursor()}}}
    | {ok, {batch, {bondy_oplog_catalogue_cursor:cursor(), [cell()]}}}
    | {ok, {done, []}}
    | {error, cursor_expired}.

-export_type([cell/0]).

-export_type([request/0]).
-export_type([response/0]).

-callback request(
    Peer :: peer_id(),
    InstanceId :: instance_id(),
    Request :: request(),
    Opts :: map()
) -> {ok, term()} | {error, term()}.
