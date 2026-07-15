%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_wal_segment).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").
-include("bondy_oplog_wal.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Segment header read/write and segment file lifecycle primitives.

A WAL segment file (`.qdata`) starts with a fixed 48-byte header
followed by a stream of frames written by `bondy_oplog_wal_frame`.
The header is written once on segment creation, fsynced, and never
updated afterwards.

```
Offset  Size  Field           Description
------  ----  -----           -----------
   0     4    Magic           0x42445347  ("BDSG")
   4     1    Version
   5     3    Flags
   8     8    SegmentId       monotonic per-instance
  16     8    InstanceIdHash  first 8 bytes of sha256(InstanceId)
  24     8    CreatedAt       wall-clock millis since epoch
  32    16    Origin          16-byte binary from bondy_oplog_origin
```

`create/4` writes a new segment file with its header, fsyncs both file
and enclosing directory, and returns the open RW file descriptor.
`read_header/1` parses the header from an already-open file. `verify/3`
checks that an in-memory header belongs to the expected instance and
origin (rejecting orphan tarballs / wrong-instance files).
""").

-define(MAGIC, ?BONDY_OPLOG_WAL_SEGMENT_MAGIC).
-define(HEADER_BYTES, ?BONDY_OPLOG_WAL_SEGMENT_HEADER_BYTES).
-define(VERSION, ?BONDY_OPLOG_WAL_SEGMENT_VERSION).
-define(INSTANCE_HASH_BYTES, ?BONDY_OPLOG_WAL_INSTANCE_ID_HASH_BYTES).

-record(?MODULE, {
    segment_id :: non_neg_integer(),
    version :: non_neg_integer(),
    flags :: non_neg_integer(),
    instance_id_hash :: binary(),
    created_at :: non_neg_integer(),
    origin :: binary()
}).

-type segment_id() :: non_neg_integer().
-type t() :: #?MODULE{}.

-export_type([segment_id/0]).
-export_type([t/0]).

-export([create/4]).
-export([open/1]).
-export([read_header/1]).
-export([verify/3]).
-export([header_bytes/0]).
-export([instance_id_hash/1]).
-export([filename/1]).
-export([segment_id/1]).
-export([origin/1]).
-export([created_at/1]).
-export([encode_header/1]).

%% =============================================================================
%% API
%% =============================================================================

?DOC("Returns the segment header size in bytes (48).").
-spec header_bytes() -> pos_integer().

header_bytes() ->
    ?HEADER_BYTES.

?DOC("""
Returns the canonical filename for the `.qdata` of the given segment id.
The id is rendered as a 9-digit zero-padded decimal so that
lexicographic order matches numeric order on directory listings.

Returns a binary to match the in-tree convention; `filename:join/2`
accepts both binaries and charlists transparently.
""").
-spec filename(segment_id()) -> binary().

filename(Id) when is_integer(Id), Id >= 0 ->
    iolist_to_binary(io_lib:format("~9..0B.qdata", [Id])).

?DOC("""
Returns the 8-byte instance id hash used in segment headers.

It is the leading 8 bytes of `crypto:hash(sha256, InstanceId)`. The hash
makes the segment header self-describing — a segment file restored onto
the wrong instance directory is detected via header mismatch.
""").
-spec instance_id_hash(instance_id()) -> binary().

instance_id_hash(InstanceId) when
    is_binary(InstanceId), byte_size(InstanceId) > 0
->
    Full = crypto:hash(sha256, InstanceId),
    binary:part(Full, 0, ?INSTANCE_HASH_BYTES).

?DOC("""
Creates a new segment file at `Path` with the given header fields.

Steps:
1. Open the file with `[write, raw, binary, exclusive]` so we error if
   the file already exists.
2. Write the 48-byte header.
3. `datasync` the file descriptor.
4. `datasync` the enclosing directory so the new dirent is durable.
5. Close the write fd and re-open it for read/write so the caller can
   append frames.

Returns `{ok, Fd, Header}` on success or `{error, Reason}` on failure.
""").
-spec create(
    Path :: file:filename_all(),
    SegmentId :: segment_id(),
    InstanceId :: instance_id(),
    Origin :: bondy_oplog_origin:t()
) ->
    {ok, file:fd(), t()} | {error, term()}.

create(Path, SegmentId, InstanceId, Origin) when
    is_integer(SegmentId),
    SegmentId >= 0,
    is_binary(InstanceId),
    byte_size(InstanceId) > 0,
    is_binary(Origin),
    byte_size(Origin) =:= ?BONDY_OPLOG_ORIGIN_BYTES
->
    InstanceHash = instance_id_hash(InstanceId),
    CreatedAt = erlang:system_time(millisecond),
    Header = #?MODULE{
        segment_id = SegmentId,
        version = ?VERSION,
        flags = 0,
        instance_id_hash = InstanceHash,
        created_at = CreatedAt,
        origin = Origin
    },
    HeaderBin = encode_header(Header),
    case prim_file:open(Path, [read, write, raw, binary, exclusive]) of
        {ok, Fd} ->
            case write_and_sync(Fd, HeaderBin, Path) of
                ok ->
                    {ok, Fd, Header};
                {error, _} = E ->
                    ok = prim_file:close(Fd),
                    E
            end;
        {error, _} = E ->
            E
    end.

?DOC("""
Opens an existing segment file for read/write and parses its header.

Returns `{ok, Fd, Header}` if the segment header parses cleanly, or
`{error, Reason}`. Caller-side identity verification should use
`verify/3` against the parsed header.
""").
-spec open(file:filename_all()) ->
    {ok, file:fd(), t()} | {error, term()}.

open(Path) ->
    case prim_file:open(Path, [read, write, raw, binary]) of
        {ok, Fd} ->
            case read_header(Fd) of
                {ok, Header} ->
                    {ok, Fd, Header};
                {error, _} = E ->
                    ok = prim_file:close(Fd),
                    E
            end;
        {error, _} = E ->
            E
    end.

?DOC("""
Reads and parses the 48-byte segment header from the start of `Fd`.

Leaves the file position at offset 48 (the start of the first frame),
so the caller can immediately begin streaming frame I/O.

Errors:
- `bad_magic` — header magic does not match `BDSG`.
- `unsupported_version` — header version is not v1.
- `truncated_header` — fewer than 48 bytes available.
""").
-spec read_header(file:fd()) ->
    {ok, t()}
    | {error, bad_magic | unsupported_version | truncated_header | term()}.

read_header(Fd) ->
    case prim_file:pread(Fd, 0, ?HEADER_BYTES) of
        {ok, Bin} when is_binary(Bin), byte_size(Bin) < ?HEADER_BYTES ->
            %% Size check first so a too-small file is always reported
            %% as truncated regardless of its contents.
            {error, truncated_header};
        {ok,
            <<?MAGIC:32/big-unsigned, Version:8/unsigned, Flags:24/big-unsigned,
                SegmentId:64/big-unsigned,
                InstanceHash:?INSTANCE_HASH_BYTES/binary,
                CreatedAt:64/big-unsigned,
                Origin:?BONDY_OPLOG_ORIGIN_BYTES/binary>>} ->
            case Version of
                ?VERSION ->
                    %% Position fd past the header so subsequent
                    %% sequential reads/writes land on frame 0.
                    {ok, _} = prim_file:position(Fd, ?HEADER_BYTES),
                    {ok, #?MODULE{
                        segment_id = SegmentId,
                        version = Version,
                        flags = Flags,
                        instance_id_hash = InstanceHash,
                        created_at = CreatedAt,
                        origin = Origin
                    }};
                _ ->
                    {error, unsupported_version}
            end;
        {ok, <<Magic:32/big-unsigned, _/binary>>} when Magic =/= ?MAGIC ->
            {error, bad_magic};
        eof ->
            {error, truncated_header};
        {error, _} = E ->
            E
    end.

?DOC("""
Verifies a parsed header belongs to the expected instance/origin.

Returns `ok` if every identity field matches the caller's expectation,
or `{error, {orphan_segment, Reason}}` where `Reason` describes the
first mismatched field. The recovery procedure uses this to refuse
orphan segments (e.g., a backup tarball restored onto the wrong
instance or replica).

Identity check fields:
- `InstanceIdHash` — first 8 bytes of `sha256(InstanceId)`.
- `Origin` — the 16-byte replica id.

The `SegmentId` is **not** checked here: the caller chooses which file
to open and pairs it with its expected segment id separately.
""").
-spec verify(t(), instance_id(), bondy_oplog_origin:t()) ->
    ok
    | {error, {orphan_segment, instance_id_hash_mismatch | origin_mismatch}}.

verify(#?MODULE{instance_id_hash = Hash, origin = Origin}, InstanceId, Origin) ->
    Expected = instance_id_hash(InstanceId),
    case Hash of
        Expected -> ok;
        _ -> {error, {orphan_segment, instance_id_hash_mismatch}}
    end;
verify(#?MODULE{}, _InstanceId, _Origin) ->
    {error, {orphan_segment, origin_mismatch}}.

?DOC("Returns the SegmentId field of a parsed header.").
-spec segment_id(t()) -> segment_id().

segment_id(#?MODULE{segment_id = Id}) -> Id.

?DOC("Returns the Origin field of a parsed header.").
-spec origin(t()) -> bondy_oplog_origin:t().

origin(#?MODULE{origin = O}) -> O.

?DOC("Returns the CreatedAt millisecond timestamp of a parsed header.").
-spec created_at(t()) -> non_neg_integer().

created_at(#?MODULE{created_at = C}) -> C.

%% =============================================================================
%% PRIVATE
%% =============================================================================

?DOC("""
Encodes a segment header record back into its 48-byte on-disk form.

Used by `bondy_oplog_wal_recovery` to rewrite a head segment during
`rescan` recovery: the new (compacted) segment carries the original
header unchanged so the file's identity (`segment_id`,
`instance_id_hash`, `origin`, `created_at`) is preserved across the
rewrite.
""").
-spec encode_header(t()) -> binary().

encode_header(#?MODULE{
    segment_id = SegmentId,
    version = Version,
    flags = Flags,
    instance_id_hash = InstanceHash,
    created_at = CreatedAt,
    origin = Origin
}) ->
    ?INSTANCE_HASH_BYTES = byte_size(InstanceHash),
    ?BONDY_OPLOG_ORIGIN_BYTES = byte_size(Origin),
    <<?MAGIC:32/big-unsigned, Version:8/unsigned, Flags:24/big-unsigned,
        SegmentId:64/big-unsigned, InstanceHash/binary,
        CreatedAt:64/big-unsigned, Origin/binary>>.

%% @private
%% Writes the header bytes, fsyncs the file descriptor, and fsyncs the
%% enclosing directory. The directory fsync is required on POSIX so the
%% new dirent survives a power loss.
write_and_sync(Fd, HeaderBin, Path) ->
    case prim_file:write(Fd, HeaderBin) of
        ok ->
            case bondy_mst_io:datasync(Fd) of
                ok ->
                    bondy_mst_io:fsync_dir(filename:dirname(Path));
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.
