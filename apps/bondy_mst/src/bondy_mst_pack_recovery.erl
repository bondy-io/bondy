%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_pack_recovery).

-include_lib("kernel/include/logger.hrl").
-include("bondy_mst.hrl").
-include("bondy_mst_pack.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Recovery pass for the pack-store's `incoming.pack` file and its
manifest reconciliation. See the pack-store design notes
§10 for the high-level design.

Invoked by `bondy_mst_pack_store:open/2` when
`bondy_mst_pack_writer:open/2` returns `{error, needs_recovery}` —
one of four conditions:

| Trigger | Action |
|---|---|
| Manifest `incoming_pack = absent`, file present (orphan) | Delete the orphan |
| Manifest `incoming_pack = present`, file missing | Flip manifest to absent |
| `incoming.pack` header missing / short / unparseable | Delete file + flip manifest to absent |
| Trailing record(s) torn or fail CRC / hash verify | Truncate file to last valid record's end-offset |

After `recover/3` returns `{ok, _}`, the caller re-invokes
`bondy_mst_pack_writer:open/2` once and expects it to succeed —
the reconciliation has restored the (manifest, file) pair to a
shape `open_incoming/5` accepts.

Only the `incoming.pack` file and the manifest's `incoming_pack`
flag are mutated. Sealed packs and `*.tmp` rename artefacts are
left to `bondy_mst_pack_writer:cleanup_orphan_packs/2`, which
runs on every open.

The pack store sits beneath a WAL that is the authoritative
source of truth — recovering bytes that the WAL applier will
re-derive is unnecessary, so the truncation path discards
trailing torn records rather than attempting to repair them.

## Outcome map

```erlang
#{
    actions :: [orphan_incoming_deleted
              | manifest_flipped_to_absent
              | header_reset
              | trailing_records_truncated],
    bytes_truncated       :: non_neg_integer(),
    records_recovered     :: non_neg_integer(),
    incoming_state_before :: present | absent,
    incoming_state_after  :: present | absent
}
```

`records_recovered` is the count of records that survived the
forward scan (i.e. were verified). It is 0 in the header-reset,
orphan-deleted, and manifest-flip cases.
""").

-export([recover/3]).

-type recover_outcome() :: #{
    actions := [recover_action()],
    bytes_truncated := non_neg_integer(),
    records_recovered := non_neg_integer(),
    incoming_state_before := present | absent,
    incoming_state_after := present | absent
}.

-type recover_action() ::
    orphan_incoming_deleted
    | manifest_flipped_to_absent
    | header_reset
    | trailing_records_truncated.

-type recover_error() ::
    {manifest, term()}
    | {orphan_delete, term()}
    | {incoming, term()}.

-export_type([recover_outcome/0]).
-export_type([recover_action/0]).
-export_type([recover_error/0]).

%% =============================================================================
%% API
%% =============================================================================

-spec recover(
    Dir :: file:filename_all(),
    InstanceId :: binary(),
    HashAlgo :: atom()
) -> {ok, recover_outcome()} | {error, recover_error()}.

recover(Dir, InstanceId, HashAlgo) when
    is_binary(InstanceId), is_atom(HashAlgo)
->
    case bondy_mst_pack_manifest:read(Dir) of
        {ok, M} ->
            Declared = bondy_mst_pack_manifest:incoming_pack(M),
            Path = bondy_mst_pack_paths:incoming_pack_path(Dir),
            Exists = filelib:is_regular(Path),
            do_recover(Dir, InstanceId, HashAlgo, M, Declared, Path, Exists);
        {error, R} ->
            {error, {manifest, R}}
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% Case A: manifest says no, file exists → delete the orphan.
do_recover(_Dir, _InstanceId, _HashAlgo, _M, absent, Path, true) ->
    case prim_file:delete(Path) of
        ok ->
            log_action(orphan_incoming_deleted, #{path => Path}),
            outcome([orphan_incoming_deleted], 0, 0, absent, absent);
        {error, enoent} ->
            outcome([orphan_incoming_deleted], 0, 0, absent, absent);
        {error, R} ->
            {error, {orphan_delete, R}}
    end;
%% Case B: manifest says yes, file missing → flip manifest to absent.
do_recover(Dir, _InstanceId, _HashAlgo, M, present, _Path, false) ->
    case flip_manifest_to_absent(Dir, M) of
        ok ->
            log_action(manifest_flipped_to_absent, #{dir => Dir}),
            outcome([manifest_flipped_to_absent], 0, 0, present, absent);
        {error, R} ->
            {error, {manifest, R}}
    end;
%% Case C/D: manifest says yes, file exists → scan and repair in place.
do_recover(Dir, InstanceId, HashAlgo, M, present, Path, true) ->
    scan_and_repair(Dir, InstanceId, HashAlgo, M, Path);
%% Fully consistent: nothing to do. The writer never returns
%% `needs_recovery` for this shape, but be defensive.
do_recover(_Dir, _InstanceId, _HashAlgo, _M, absent, _Path, false) ->
    outcome([], 0, 0, absent, absent).

%% --- scan and repair (Case C/D) --------------------------------------------

scan_and_repair(Dir, InstanceId, HashAlgo, M, Path) ->
    InstanceHash = erlang:phash2(InstanceId, 1 bsl 32),
    case prim_file:open(Path, [read, write, raw, binary]) of
        {ok, Fd} ->
            try
                run_scan(Dir, M, Path, Fd, InstanceHash, HashAlgo)
            after
                _ = prim_file:close(Fd)
            end;
        {error, R} ->
            {error, {incoming, R}}
    end.

run_scan(Dir, M, Path, Fd, InstanceHash, HashAlgo) ->
    case prim_file:position(Fd, eof) of
        {ok, OrigSize} ->
            HeaderBytes = bondy_mst_pack_codec:header_bytes(),
            case check_header(Fd, InstanceHash, HashAlgo, HeaderBytes) of
                ok ->
                    scan_records_loop(
                        Fd,
                        HeaderBytes,
                        HeaderBytes,
                        0,
                        OrigSize,
                        Path,
                        Dir
                    );
                header_bad ->
                    reset_incoming(Dir, Path, OrigSize, M)
            end;
        {error, R} ->
            {error, {incoming, R}}
    end.

check_header(Fd, ExpectedInstanceHash, ExpectedAlgo, HeaderBytes) ->
    case prim_file:pread(Fd, 0, HeaderBytes) of
        {ok, HBin} when byte_size(HBin) =:= HeaderBytes ->
            case bondy_mst_pack_codec:decode_pack_header(HBin) of
                {ok, #{instance_hash := IH, hash_algo := A}} when
                    IH =:= ExpectedInstanceHash, A =:= ExpectedAlgo
                ->
                    ok;
                _ ->
                    header_bad
            end;
        _ ->
            header_bad
    end.

scan_records_loop(Fd, Offset, LastValidEnd, RecCount, OrigSize, Path, Dir) ->
    HdrBytes = bondy_mst_pack_codec:record_header_bytes(),
    case prim_file:pread(Fd, Offset, HdrBytes) of
        eof ->
            finish_scan(Fd, Dir, Path, LastValidEnd, OrigSize, RecCount);
        {ok, <<>>} ->
            finish_scan(Fd, Dir, Path, LastValidEnd, OrigSize, RecCount);
        {ok, Bin} when byte_size(Bin) < HdrBytes ->
            truncate_to(Fd, Dir, Path, LastValidEnd, OrigSize, RecCount);
        {ok, Bin} ->
            case bondy_mst_pack_codec:decode_record_header(Bin) of
                {ok, #{hash := H, page_len := L} = Header} ->
                    BodyOffset = Offset + HdrBytes,
                    case verify_body(Fd, BodyOffset, L, Header, H) of
                        ok ->
                            scan_records_loop(
                                Fd,
                                BodyOffset + L,
                                BodyOffset + L,
                                RecCount + 1,
                                OrigSize,
                                Path,
                                Dir
                            );
                        torn ->
                            truncate_to(
                                Fd,
                                Dir,
                                Path,
                                LastValidEnd,
                                OrigSize,
                                RecCount
                            )
                    end;
                {error, _} ->
                    truncate_to(
                        Fd,
                        Dir,
                        Path,
                        LastValidEnd,
                        OrigSize,
                        RecCount
                    )
            end;
        {error, _} ->
            truncate_to(Fd, Dir, Path, LastValidEnd, OrigSize, RecCount)
    end.

verify_body(_Fd, _BodyOffset, 0, Header, Hash) ->
    case bondy_mst_pack_codec:verify_record(Header, <<>>) of
        ok ->
            case crypto:hash(sha256, <<>>) of
                Hash -> ok;
                _ -> torn
            end;
        {error, _} ->
            torn
    end;
verify_body(Fd, BodyOffset, L, Header, Hash) ->
    case prim_file:pread(Fd, BodyOffset, L) of
        {ok, Body} when byte_size(Body) =:= L ->
            case bondy_mst_pack_codec:verify_record(Header, Body) of
                ok ->
                    case crypto:hash(sha256, Body) of
                        Hash -> ok;
                        _ -> torn
                    end;
                {error, _} ->
                    torn
            end;
        _ ->
            torn
    end.

%% Scan reached a clean EOF.
%%
%% If `LastValidEnd =:= OrigSize` the file is byte-perfect and we
%% shouldn't have been called — the writer's scan would have
%% accepted it. Treat as a no-op rather than crashing.
%%
%% If `LastValidEnd < OrigSize` there are trailing bytes that don't
%% form a record (e.g. zero-pad from a torn write that ended on
%% nothing parseable). Truncate.
finish_scan(_Fd, _Dir, _Path, LastValidEnd, OrigSize, RecCount) when
    LastValidEnd =:= OrigSize
->
    outcome([], 0, RecCount, present, present);
finish_scan(Fd, Dir, Path, LastValidEnd, OrigSize, RecCount) ->
    truncate_to(Fd, Dir, Path, LastValidEnd, OrigSize, RecCount).

truncate_to(_Fd, _Dir, _Path, NewSize, OrigSize, RecCount) when
    NewSize =:= OrigSize
->
    outcome([], 0, RecCount, present, present);
truncate_to(Fd, Dir, Path, NewSize, OrigSize, RecCount) ->
    case do_truncate(Fd, Dir, NewSize) of
        ok ->
            log_action(
                trailing_records_truncated,
                #{path => Path, from => OrigSize, to => NewSize}
            ),
            outcome(
                [trailing_records_truncated],
                OrigSize - NewSize,
                RecCount,
                present,
                present
            );
        {error, R} ->
            {error, {incoming, R}}
    end.

reset_incoming(Dir, Path, OrigSize, M) ->
    case prim_file:delete(Path) of
        ok ->
            finalise_reset(Dir, Path, OrigSize, M, [header_reset]);
        {error, enoent} ->
            finalise_reset(Dir, Path, OrigSize, M, []);
        {error, R} ->
            {error, {incoming, R}}
    end.

finalise_reset(Dir, Path, OrigSize, M, Pre) ->
    case flip_manifest_to_absent(Dir, M) of
        ok ->
            case Pre of
                [header_reset] ->
                    log_action(
                        header_reset,
                        #{path => Path, from => OrigSize}
                    );
                _ ->
                    ok
            end,
            Actions = Pre ++ [manifest_flipped_to_absent],
            outcome(Actions, OrigSize, 0, present, absent);
        {error, R} ->
            {error, {manifest, R}}
    end.

do_truncate(Fd, Dir, NewSize) ->
    case prim_file:position(Fd, NewSize) of
        {ok, NewSize} ->
            case prim_file:truncate(Fd) of
                ok ->
                    case bondy_mst_io:datasync(Fd) of
                        ok ->
                            _ = bondy_mst_io:fsync_dir(Dir),
                            ok;
                        {error, _} = E ->
                            E
                    end;
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

flip_manifest_to_absent(Dir, M) ->
    M1 = bondy_mst_pack_manifest:with_incoming_pack(M, absent),
    bondy_mst_pack_manifest:write(Dir, M1).

outcome(Actions, BytesTruncated, RecCount, Before, After) ->
    {ok, #{
        actions => Actions,
        bytes_truncated => BytesTruncated,
        records_recovered => RecCount,
        incoming_state_before => Before,
        incoming_state_after => After
    }}.

log_action(Action, Ctx) ->
    ?LOG_NOTICE(Ctx#{
        event => mst_pack_recovery_action,
        action => Action
    }).
