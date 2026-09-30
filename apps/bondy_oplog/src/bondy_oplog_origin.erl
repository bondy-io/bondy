%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_origin).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Origin identity for the MST event-store replication layer.

An *Origin* identifies a replica — the node-instance that creates events.
The replication layer treats `t/0` as an opaque binary; the only invariant
is that two distinct replicas must never share the same Origin.

## Default behaviour

`default/0` returns a stable, per-VM 128-bit random identifier. It is
generated on first call and cached in `persistent_term`, so subsequent
calls within the same VM lifetime return the same value. **It is NOT
persisted across VM restarts** — for VM-restart-safe identity, either
(a) configure `storage_path` on the instance so
`bondy_oplog_instance_sup` resolves the origin via
[`load_or_create/1`](#load_or_create-1), or (b) generate the id
externally and pass it via the `origin` start_instance option.

## Disk persistence

`load_or_create/1` reads a previously persisted origin from a file, or
generates and persists a fresh one when there is no file. The on-disk layout is a single
`?BONDY_OPLOG_ORIGIN_BYTES`-byte file written with
`bondy_mst_io:write_file_atomic/2`. The supervisor calls it automatically when
the caller configured `storage_path` but did not provide an explicit
`origin`, so a default-configured durable instance survives kill -9 +
restart without WAL recovery rejecting its own segments as
`{orphan_segment, origin_mismatch}`.

## Validation

`validate/1` enforces the only structural invariant: Origin is a
non-empty binary. Uniqueness is the operator's responsibility.
""").

-type t() :: binary().

-define(DEFAULT_KEY, {?MODULE, default}).

-export_type([t/0]).

-export([default/0]).
-export([new/0]).
-export([load_or_create/1]).
-export([validate/1]).

%% =============================================================================
%% API
%% =============================================================================

?DOC("""
Returns the per-VM default Origin, generating it lazily on first call.

The value is cached in `persistent_term` under the key `{?MODULE, default}`.
It is intentionally **not persisted across VM restarts**: each restart is
treated as a new replica identity, which is conservative — peers that have
seen events from the previous identity will treat the restarted node as a
new participant. Production deployments that need identity continuity should
generate the id externally and pass it via the `origin` start_instance
option.

Concurrent first calls all return the one value that is cached: the value
is generated under a node-local lock, after checking the cache again
(`bondy_oplog_origin_test:concurrent_first_calls_agree_test/0`).
""").
-spec default() -> t().

default() ->
    case persistent_term:get(?DEFAULT_KEY, undefined) of
        undefined ->
            global:trans(
                {?DEFAULT_KEY, self()}, fun create_default/0, [node()]
            );
        Id when is_binary(Id) ->
            Id
    end.

?DOC("""
Generates a fresh 128-bit random Origin identifier.
""").
-spec new() -> t().

new() ->
    crypto:strong_rand_bytes(?BONDY_OPLOG_ORIGIN_BYTES).

?DOC("""
Returns the origin persisted at `Path`, generating and persisting one only
when `Path` does not exist (`enoent`).

Any other outcome is an error, and an existing file is never rewritten:
a read error, a file that is not `?BONDY_OPLOG_ORIGIN_BYTES` long
(`{corrupted, unexpected_size}`), or a fresh origin that could not be
persisted. An origin that differs from the one the instance's WAL segments
were written with makes WAL recovery reject them as
`{orphan_segment, origin_mismatch}`, so a start that fails here is retried
with the persisted origin intact (`bondy_oplog_origin_test`,
`bondy_oplog_instance_keeper_test:unreadable_origin_heals/0`).

The on-disk layout is a single `?BONDY_OPLOG_ORIGIN_BYTES`-byte file written
with `bondy_mst_io:write_file_atomic/2`. A persisted origin is returned only
after its directory has been fsynced, so an origin written by a start whose
directory fsync failed is durable before a retried start uses it
(`bondy_oplog_origin_test`).
""").
-spec load_or_create(Path :: file:filename_all()) ->
    {ok, t()} | {error, term()}.

load_or_create(Path) ->
    PathBin = unicode:characters_to_binary(Path),
    case read_persisted(PathBin) of
        {ok, _} = Ok ->
            Dir = filename:dirname(PathBin),
            case bondy_mst_io:fsync_dir(Dir) of
                ok -> Ok;
                {error, Reason} -> {error, {dir_fsync_failed, Dir, Reason}}
            end;
        {error, enoent} ->
            create_and_persist(PathBin);
        {error, _} = Error ->
            Error
    end.

?DOC("""
Validates an origin value. Returns `ok` if valid, `{error, Reason}` otherwise.
""").
-spec validate(term()) -> ok | {error, term()}.

validate(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    ok;
validate(_) ->
    {error, invalid_origin}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
read_persisted(Path) ->
    case prim_file:read_file(Path) of
        {ok, <<Origin:?BONDY_OPLOG_ORIGIN_BYTES/binary>>} ->
            {ok, Origin};
        {ok, _Garbage} ->
            {error, {corrupted, unexpected_size}};
        {error, _} = E ->
            E
    end.

%% @private
create_and_persist(Path) ->
    Origin = new(),
    case persist(Path, Origin) of
        ok -> {ok, Origin};
        {error, _} = Error -> Error
    end.

%% @private
%% It runs in the process starting the instance, which on first boot is the
%% catalogue opening its tables, so a failed directory fsync is returned.
persist(Path, Origin) ->
    case filelib:ensure_dir(Path) of
        ok ->
            try
                bondy_mst_io:write_file_atomic(Path, Origin)
            catch
                error:{dir_fsync_failed, _, _} = Reason -> {error, Reason}
            end;
        {error, _} = E ->
            E
    end.

%% @private
%% `?MODULE:new()` so a test can widen the window between the check and the
%% put (`bondy_oplog_origin_test:concurrent_first_calls_agree_test/0`).
create_default() ->
    case persistent_term:get(?DEFAULT_KEY, undefined) of
        undefined ->
            Id = ?MODULE:new(),
            ok = persistent_term:put(?DEFAULT_KEY, Id),
            Id;
        Id ->
            Id
    end.
