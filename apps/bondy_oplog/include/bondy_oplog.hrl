%% =============================================================================
%%  bondy_oplog.hrl -
%%
%%  Copyright (c) 2023-2025 Leapsight. All rights reserved.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%% =============================================================================

%% -----------------------------------------------------------------------------
%% Records and constants for the MST-based event-store replication layer.
%% Architecture references:
%%   _design/0_architecture.md
%%   _design/3_mst_append_only.md
%% -----------------------------------------------------------------------------

-ifndef(BONDY_OPLOG_HRL).
-define(BONDY_OPLOG_HRL, true).

%% Rows a range read returns when the caller passes no `limit`. THE single
%% definition of that default: the substrate's `range/5` and `range_all/5`,
%% both projection adapters' `range/5`, and `bondy_db`'s stale-index
%% fallback all resolve to it. It was previously a literal repeated at each
%% of those five sites, with only a comment recording that they were meant
%% to agree. A default, not a bound — every range API takes an explicit
%% `limit`, and a caller that passes one is unaffected.
-define(DEFAULT_RANGE_LIMIT, 1000).

%% Origin identifier: opaque binary. 16 bytes is the recommended default
%% (random per-replica id). Larger values are accepted (e.g. SHA-256 of a
%% public key) — the replication layer treats it as opaque.
-define(BONDY_OPLOG_ORIGIN_BYTES, 16).

%% An *instance id* is the unit of independence. One MST per instance.
%% Instance ids are opaque binaries chosen by the consumer; the library
%% does not interpret them. Consumers that need atom-friendly ids can
%% encode them as binaries (e.g. `atom_to_binary/1`) at their boundary.
-type instance_id() :: binary().

%% A *peer id* identifies a remote replica to the library. The library
%% treats it as opaque — it is the consumer's choice (a node atom, a
%% binary URL, a `{ip, port}` tuple, etc.). The transport behaviour
%% (Stage 4) interprets peer ids; the peer-state ETS keys on them.
-type peer_id() :: term().

%% HLC pack layout: 48 bits of physical millisecond timestamp +
%% 16 bits of logical counter. Compares as a plain integer.
-define(BONDY_OPLOG_HLC_LOGICAL_BITS, 16).
-define(BONDY_OPLOG_HLC_LOGICAL_MASK, 16#FFFF).
-define(BONDY_OPLOG_HLC_LOGICAL_MAX, 16#FFFF).

%% A globally unique event identity and total order key. Tuple element order
%% is significant because ETS ordered_set sorts tuples lexicographically:
%% by HLC first (time), then Origin (deterministic tie-break across replicas),
%% then Seq (per-origin monotonic). This is the "dot" referenced by Tier 1
%% causal metadata.
-record(bondy_oplog_event_key, {
    hlc :: non_neg_integer(),
    origin :: binary(),
    seq :: non_neg_integer()
}).

%% Event payload stored in the write log. The replication layer never
%% interprets `op` or `meta`. The CRDT's COG-Interpreter does.
%%
%% `prev_hash` and `signature` are populated by the configured event
%% validator (`bondy_oplog_validator`). Trust validator
%% leaves both `undefined`; crypto validator fills them with the
%% per-origin chain hash and the Ed25519 signature respectively.
-record(bondy_oplog_event, {
    key :: #bondy_oplog_event_key{},
    op :: term(),
    meta :: undefined | term(),
    prev_hash :: undefined | binary(),
    signature :: undefined | binary()
}).

%% Overlay row shape (`ordered_set`, public, per-instance). Keyed by
%% the event key; carries the encoded value (so reads can return
%% without going back to the WAL), the event's HLC for CAS-eviction,
%% and an origin tag for future eager-push support. Tuple positions
%% are stable; they appear in match-specs.
-define(OVERLAY_KEY_POS, 1).
-define(OVERLAY_VALUE_POS, 2).
-define(OVERLAY_HLC_POS, 3).
-define(OVERLAY_ORIGIN_POS, 4).

-endif.
