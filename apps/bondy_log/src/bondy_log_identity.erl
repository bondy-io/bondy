%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_log_identity).

-moduledoc """
The identity seam of the log core: what fills the two identity fields of
the 48-byte segment header.

The header carries an 8-byte field at offset 16 and a 16-byte field at
offset 32 (`bondy_log_segment`). The core writes whatever the adapter
encodes into them when it creates a segment, and asks the adapter to
verify them whenever it opens one, so a segment restored into the wrong
log is refused before a single frame is read. The core never interprets
the bytes.

`Ctx` is the `identity` option the log was opened with; the core hands it
to both callbacks unchanged. The oplog adapter takes
`#{instance_id, origin}` and encodes `sha256(InstanceId)` truncated
to 8 bytes plus the 16-byte origin, the bytes the WAL wrote before the
seam existed. `encode_identity/1` is also where the adapter validates its
context: its `{error, Reason}` becomes the writer's open error.

`verify_identity/2` returns the adapter's own mismatch reason; the core
reports it as `{orphan_segment, Reason}`.
""".

-type identity() :: #{hash8 := <<_:64>>, id16 := <<_:128>>}.
-type ctx() :: map().

-export_type([identity/0]).
-export_type([ctx/0]).

-callback encode_identity(ctx()) -> {ok, identity()} | {error, term()}.

-callback verify_identity(identity(), ctx()) -> ok | {error, term()}.
