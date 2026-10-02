%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_log_directory).

-moduledoc """
The discovery seam of the log core: where a log's writer pid is
published and looked up.

The writer calls `register/2` from its `init/1`, after recovery has
completed and before it serves any request; the scrubber calls
`lookup_pid/1` at the start of every run because the writer it walks may
have been restarted since the last one. The core knows nothing else about
the directory: no handle, no unregistration (a writer's death is observed
by whoever monitors the pid).

The oplog adapter wires both calls to the oplog's per-instance registry
row, which the rest of the oplog shares; a stream log supplies its own
registry.
""".

-callback register(InstanceId :: binary(), pid()) -> ok.

-callback lookup_pid(InstanceId :: binary()) -> pid() | undefined.
