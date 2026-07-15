%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_origin).

-include_lib("kernel/include/logger.hrl").
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

`load_or_create/1` reads a previously persisted origin from a file or
generates and persists a fresh one. The on-disk layout is a single
`?BONDY_OPLOG_ORIGIN_BYTES`-byte file written via the standard
durability sequence (tmp + datasync + rename + fsync_dir, mirroring
`bondy_mst_pack_manifest`). The supervisor calls it automatically when
the caller configured `storage_path` but did not provide an explicit
`origin`, so a default-configured durable instance survives kill -9 +
restart without WAL recovery rejecting its own segments as
`{orphan_segment, origin_mismatch}`.

## Validation

`validate/1` enforces the only structural invariant: Origin is a
non-empty binary. Uniqueness is the operator's responsibility.
""").

-type t() :: binary().

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
""").
-spec default() -> t().

default() ->
    Key = {?MODULE, default},
    case persistent_term:get(Key, undefined) of
        undefined ->
            Id = new(),
            ok = persistent_term:put(Key, Id),
            Id;
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
Reads a previously persisted origin from `Path`, or generates a fresh
one and writes it there. Returns the origin in either case.

Failure to read a non-`enoent` error or to persist a freshly minted
origin is logged at warning and falls through to an in-memory origin
— the caller still gets a usable id, but it is ephemeral until
persistence succeeds.

The on-disk layout is a single `?BONDY_OPLOG_ORIGIN_BYTES`-byte file
written via the standard durability sequence: temp file, `datasync`
the fd, atomic `rename`, `fsync_dir` on the containing directory.
""").
-spec load_or_create(Path :: file:filename_all()) -> t().

load_or_create(Path) ->
    PathBin = unicode:characters_to_binary(Path),
    case read_persisted(PathBin) of
        {ok, Origin} ->
            Origin;
        {error, enoent} ->
            create_and_persist(PathBin);
        {error, Reason} ->
            ?LOG_WARNING(#{
                description =>
                    "Failed to read persisted origin; regenerating "
                    "(prior identity will be lost)",
                path => PathBin,
                reason => Reason
            }),
            create_and_persist(PathBin)
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
        ok ->
            Origin;
        {error, Reason} ->
            ?LOG_WARNING(#{
                description =>
                    "Failed to persist origin; identity will be "
                    "ephemeral until persistence succeeds (kill -9 + "
                    "restart will be rejected by WAL recovery)",
                path => Path,
                reason => Reason
            }),
            Origin
    end.

%% @private
%% tmp + datasync + rename + fsync_dir — mirrors the durability
%% sequence used by `bondy_mst_pack_manifest:write/2`.
persist(Path, Origin) ->
    Dir = filename:dirname(Path),
    Tmp = <<Path/binary, ".tmp">>,
    case filelib:ensure_dir(Path) of
        ok ->
            case write_and_sync(Tmp, Origin) of
                ok ->
                    case bondy_mst_io:rename(Tmp, Path) of
                        ok ->
                            bondy_mst_io:fsync_dir(Dir);
                        {error, _} = E ->
                            _ = prim_file:delete(Tmp),
                            E
                    end;
                {error, _} = E ->
                    _ = prim_file:delete(Tmp),
                    E
            end;
        {error, _} = E ->
            E
    end.

%% @private
write_and_sync(Tmp, Bin) ->
    case prim_file:open(Tmp, [write, raw, binary]) of
        {ok, Fd} ->
            try
                case prim_file:write(Fd, Bin) of
                    ok -> bondy_mst_io:datasync(Fd);
                    {error, _} = E -> E
                end
            after
                _ = prim_file:close(Fd)
            end;
        {error, _} = E ->
            E
    end.
