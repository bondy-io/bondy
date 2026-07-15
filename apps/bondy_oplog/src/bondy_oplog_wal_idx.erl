%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_wal_idx).

-include("bondy_doc.hrl").
-include("bondy_oplog.hrl").
-include("bondy_oplog_wal.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Sparse HLC index (`.qidx`).

One `.qidx` per `.qdata` segment maps each indexed batch frame's
**HLC range** to its byte offset, at sparse intervals (default 64 KB).
The index lets `open_reader(_, {hlc, T}, _)` jump directly to the
batch that contains a target HLC in O(log N), instead of linearly
scanning a segment from offset 48.

The index is a **best-effort accelerator**, not load-bearing for
correctness. A missing or stale `.qidx` only makes HLC-seek slower:
the reader falls back to scanning from the start of the candidate
segment. Recovery rebuilds the file from a segment scan if it's
missing or shorter than expected.

This module has three concerns:

1. **Accumulator** (writer-side, in-memory): `new/1`, `note_frame/5`,
   `entries/1` build up the list of `{FirstHlc, LastHlc, ByteOffset}`
   entries to persist for a segment. The writer holds one accumulator
   at a time, for the current head segment.

2. **File I/O** (writer flush, reader load): `write_file/2` persists
   an entry list as a v2 file via tmp+datasync+rename+dir-fsync;
   `read_file/1` parses it back. The reader accepts both v1 and v2
   files: v1 entries `(Hlc, Off)` are lifted to v2 shape
   `(Hlc, Hlc, Off)` (degenerate single-HLC range). The next rebuild
   produces a v2 file.

3. **Seek** (reader-side): `open/1` loads a file and returns an
   opaque handle; `seek/2` does an O(log N) binary search for the
   entry whose range contains the target HLC, falling back to the
   largest entry whose range ends ≤ the target (mirrors v1's
   semantics for any T that misses every range). `from_entries/1`
   builds the same handle from in-memory entries (used for the head
   segment, whose `.qidx` is not yet on disk while the writer is
   alive).

### File format (v2)

Header (16 bytes) — unchanged from v1; the `Version` byte selects
the entry layout below:

```
Offset  Size  Field
   0     4    Magic           0x42444958  ("BDIX")
   4     1    Version         1 or 2
   5     3    Flags
   8     4    EntryCount
  12     4    Reserved
```

v2 entry (24 bytes):

```
Offset  Size  Field
   0     8    FirstHlc         first event's HLC in the indexed batch
   8     8    LastHlc          last event's HLC in the indexed batch
  16     8    ByteOffset       offset of the frame start within .qdata
```

v1 entry (16 bytes, read-only fallback):

```
Offset  Size  Field
   0     8    Hlc              first HLC of the indexed batch frame
   8     8    ByteOffset       offset of the frame start within .qdata
```

For a 64 MB segment with 64 KB entry spacing: 1024 entries × 24 B =
24 KB. ~0.04 % storage overhead.

### Accumulator semantics

The accumulator gates on `bytes_since_last_emit + frame_len >=
interval_bytes`. The **first frame of a segment is always indexed**
(invariant: every non-empty segment has at least one entry whose
range bounds every HLC in the segment). After each emit,
`bytes_since_last` resets to zero. Indexed entries always satisfy
`FirstHlc =< LastHlc`; a single-event batch produces an entry where
`FirstHlc == LastHlc`.
""").

-define(MAGIC, ?BONDY_OPLOG_WAL_IDX_MAGIC).
-define(HEADER_BYTES, ?BONDY_OPLOG_WAL_IDX_HEADER_BYTES).
-define(ENTRY_BYTES_V1, ?BONDY_OPLOG_WAL_IDX_ENTRY_BYTES_V1).
-define(ENTRY_BYTES_V2, ?BONDY_OPLOG_WAL_IDX_ENTRY_BYTES_V2).
-define(VERSION_V1, ?BONDY_OPLOG_WAL_IDX_VERSION_V1).
-define(VERSION_V2, ?BONDY_OPLOG_WAL_IDX_VERSION_V2).
-define(VERSION_CURRENT, ?BONDY_OPLOG_WAL_IDX_VERSION).

-type hlc() :: bondy_oplog_hlc:hlc().
-type offset() :: non_neg_integer().
-type entry() :: {hlc(), hlc(), offset()}.

%% Writer-side accumulator: a running list of entries plus the bookkeeping
%% needed to decide when to emit the next one.
-record(acc, {
    interval_bytes :: pos_integer(),
    bytes_since_last :: non_neg_integer(),
    %% Entries are stored newest-first while building so `note_frame/5`
    %% is O(1); `entries/1` reverses to ascending HLC order on emission.
    entries_rev :: [entry()],
    entry_count :: non_neg_integer()
}).

%% Reader-side index handle: a 1-based tuple of
%% `{FirstHlc, LastHlc, Offset}` entries sorted by `FirstHlc` ascending
%% (equivalently by `Offset` ascending, since the writer emits in HLC
%% order). Tuple-backed so `seek/2` is O(log N) via `element/2`
%% (constant-time random access).
-record(idx, {
    entries :: tuple()
}).

-type accumulator() :: #acc{}.
-type t() :: #idx{}.
-type entries() :: [entry()].

-export_type([entry/0]).
-export_type([accumulator/0]).
-export_type([t/0]).
-export_type([entries/0]).

%% Constants
-export([filename/1]).
-export([header_bytes/0]).
-export([entry_bytes/0]).

%% Accumulator
-export([new/0]).
-export([new/1]).
-export([note_frame/5]).
-export([would_index/2]).
-export([note_indexed_frame/4]).
-export([note_skipped_frame/2]).
-export([entries/1]).
-export([entry_count/1]).
-export([interval_bytes/1]).

%% File I/O
-export([write_file/2]).
-export([read_file/1]).

%% Reader handle
-export([open/1]).
-export([from_entries/1]).
-export([seek/2]).
-export([handle_entries/1]).

%% =============================================================================
%% CONSTANTS
%% =============================================================================

?DOC("""
Returns the canonical filename for the `.qidx` of the given segment id.
The id is rendered as a 9-digit zero-padded decimal so that
lexicographic order matches numeric order on directory listings.

Returns a binary to match the in-tree convention.
""").
-spec filename(non_neg_integer()) -> binary().

filename(Id) when is_integer(Id), Id >= 0 ->
    iolist_to_binary(io_lib:format("~9..0B.qidx", [Id])).

?DOC("Returns the `.qidx` header size in bytes (16).").
-spec header_bytes() -> pos_integer().

header_bytes() ->
    ?HEADER_BYTES.

?DOC("""
Returns the `.qidx` entry size in bytes for the **current** writer
version (v2 = 24). v1 files use 16-byte entries; the read path
handles both.
""").
-spec entry_bytes() -> pos_integer().

entry_bytes() ->
    ?ENTRY_BYTES_V2.

%% =============================================================================
%% ACCUMULATOR
%% =============================================================================

?DOC("""
Creates a fresh accumulator with the default interval
(`?BONDY_OPLOG_WAL_IDX_DEFAULT_INTERVAL_BYTES`, 64 KiB).
""").
-spec new() -> accumulator().

new() ->
    new(?BONDY_OPLOG_WAL_IDX_DEFAULT_INTERVAL_BYTES).

?DOC("""
Creates a fresh accumulator with a custom emit interval.

`IntervalBytes` controls the index density: smaller values produce more
entries (faster seek, larger `.qidx`); larger values produce fewer
entries (slower seek, smaller `.qidx`). The default is 64 KiB.
""").
-spec new(pos_integer()) -> accumulator().

new(IntervalBytes) when is_integer(IntervalBytes), IntervalBytes > 0 ->
    #acc{
        interval_bytes = IntervalBytes,
        bytes_since_last = 0,
        entries_rev = [],
        entry_count = 0
    }.

?DOC("""
Records a freshly-written frame.

`FirstHlc` and `LastHlc` are the HLCs of the first and last events in
the frame's batch (`FirstHlc =< LastHlc`; equal for a single-event
batch). `Offset` is the byte offset of the frame's start within the
segment. `FrameLen` is the total frame length on disk (header + body).

The accumulator emits a new entry when:

1. The accumulator is empty (i.e., this is the first frame of the
   segment). The first frame is **always** indexed so every non-empty
   segment has at least one entry usable for seek.
2. The accumulator has emitted at least one entry **and** the running
   `bytes_since_last_emit + FrameLen >= interval_bytes`. The new entry
   is `(FirstHlc, LastHlc, Offset)` and `bytes_since_last` resets to
   zero.

Otherwise `bytes_since_last` is incremented by `FrameLen` and the
entry list is unchanged.
""").
-spec note_frame(accumulator(), hlc(), hlc(), offset(), pos_integer()) ->
    accumulator().

note_frame(Acc, FirstHlc, LastHlc, Offset, FrameLen) ->
    case would_index(Acc, FrameLen) of
        true -> note_indexed_frame(Acc, FirstHlc, LastHlc, Offset);
        false -> note_skipped_frame(Acc, FrameLen)
    end.

?DOC("""
Returns `true` when a frame of size `FrameLen` should be indexed
according to the accumulator's interval. Used by the sealed-segment
`.qidx` rebuild path in recovery to avoid body-decoding frames that
will not produce an index entry.
""").
-spec would_index(accumulator(), pos_integer()) -> boolean().

would_index(#acc{entries_rev = []}, _FrameLen) ->
    %% First frame of segment is always indexed.
    true;
would_index(#acc{bytes_since_last = B, interval_bytes = I}, FrameLen) when
    is_integer(FrameLen), FrameLen > 0
->
    B + FrameLen >= I.

?DOC("""
Records a frame that the caller has decided to index. Appends an
entry, bumps `entry_count`, and resets `bytes_since_last` to zero.

This is the lower-level companion of `note_frame/5`. Use this when
the caller has already determined the frame should be indexed (e.g.,
via `would_index/2` followed by a body decode to extract the first
and last HLCs).
""").
-spec note_indexed_frame(accumulator(), hlc(), hlc(), offset()) ->
    accumulator().

note_indexed_frame(
    #acc{entries_rev = Rev, entry_count = N} = Acc,
    FirstHlc,
    LastHlc,
    Offset
) when
    is_integer(FirstHlc),
    FirstHlc >= 0,
    is_integer(LastHlc),
    LastHlc >= FirstHlc,
    is_integer(Offset),
    Offset >= 0
->
    Acc#acc{
        entries_rev = [{FirstHlc, LastHlc, Offset} | Rev],
        entry_count = N + 1,
        bytes_since_last = 0
    }.

?DOC("""
Records a frame the caller is **not** indexing. Just adds `FrameLen`
bytes to `bytes_since_last`; no entry is appended.

Used by the sealed-segment `.qidx` rebuild path to advance the
accumulator's interval bookkeeping without paying for a body decode.
""").
-spec note_skipped_frame(accumulator(), pos_integer()) -> accumulator().

note_skipped_frame(#acc{bytes_since_last = B} = Acc, FrameLen) when
    is_integer(FrameLen), FrameLen > 0
->
    Acc#acc{bytes_since_last = B + FrameLen}.

?DOC("""
Returns the accumulator's entries in HLC-ascending order, suitable for
passing to `write_file/2` or `from_entries/1`.
""").
-spec entries(accumulator()) -> entries().

entries(#acc{entries_rev = Rev}) ->
    lists:reverse(Rev).

?DOC("Returns the number of entries currently in the accumulator.").
-spec entry_count(accumulator()) -> non_neg_integer().

entry_count(#acc{entry_count = N}) -> N.

?DOC("Returns the accumulator's configured emit interval in bytes.").
-spec interval_bytes(accumulator()) -> pos_integer().

interval_bytes(#acc{interval_bytes = I}) -> I.

%% =============================================================================
%% FILE I/O
%% =============================================================================

?DOC("""
Atomically writes `Entries` to a `.qidx` file at `Path`.

Steps:

1. Write `Path.tmp` with the header + entry stream.
2. `datasync` the tmp fd.
3. `rename(Path.tmp, Path)` — atomic on POSIX same-filesystem.
4. `fsync_dir(dirname(Path))` — required on ext4/xfs.

Returns `ok` or `{error, Reason}`. On any failure the tmp file is
removed and the original `.qidx` (if any) is left untouched. An empty
entry list is valid — it writes a header with `EntryCount = 0`.

Caller is responsible for choosing the path; typically:
`filename:join(Dir, bondy_oplog_wal_idx:filename(SegId))`.
""").
-spec write_file(file:filename_all(), entries()) -> ok | {error, term()}.

write_file(Path, Entries) when is_list(Entries) ->
    EntryCount = length(Entries),
    Header = encode_header(EntryCount),
    Body = encode_entries(Entries),
    TmpPath = tmp_path(Path),
    case prim_file:open(TmpPath, [write, raw, binary]) of
        {ok, Fd} ->
            Res = write_and_sync(Fd, [Header | Body]),
            ok = prim_file:close(Fd),
            commit_or_cleanup(Res, TmpPath, Path);
        {error, _} = E ->
            E
    end.

?DOC("""
Reads and parses a `.qidx` file at `Path`.

Returns `{ok, Entries}` where `Entries` is in HLC-ascending order
(each `{FirstHlc, LastHlc, Offset}`), or `{error, Reason}` for:

- `enoent` — file missing.
- `truncated_header` — file shorter than 16 bytes.
- `bad_magic` — header magic is not `BDIX`.
- `unsupported_version` — header version is neither v1 nor v2.
- `truncated_entries` — `EntryCount` declares more bytes than the file
  contains.
- `trailing_bytes` — file contains bytes past the declared entry count.

A file with `EntryCount = 0` is valid and returns `{ok, []}`.

v1 files are read transparently: each 16-byte v1 entry `(Hlc, Offset)`
is lifted to the v2 shape `(Hlc, Hlc, Offset)` so callers always see a
single representation. The seek semantics on a lifted v1 file reduce
to the original v1 behaviour (single-point ranges).
""").
-spec read_file(file:filename_all()) ->
    {ok, entries()} | {error, term()}.

read_file(Path) ->
    case prim_file:read_file(Path) of
        {ok, Bin} ->
            decode_file(Bin);
        {error, _} = E ->
            E
    end.

%% =============================================================================
%% READER HANDLE
%% =============================================================================

?DOC("""
Opens a `.qidx` file and returns a seek-ready handle.

Equivalent to `read_file/1` followed by `from_entries/1`, but combined
so callers don't have to handle two error sites.

Returns `{ok, t()}` or `{error, Reason}` with the same error space as
`read_file/1`.
""").
-spec open(file:filename_all()) -> {ok, t()} | {error, term()}.

open(Path) ->
    case read_file(Path) of
        {ok, Entries} ->
            {ok, from_entries(Entries)};
        {error, _} = E ->
            E
    end.

?DOC("""
Builds a seek-ready handle directly from an in-memory entry list.

Used for the head segment whose `.qidx` is not yet on disk while the
writer is alive: the writer hands the reader its current accumulator
entries via `bondy_oplog_wal:reader_view/1`, and the reader wraps them
with this function to seek without a file round-trip.

`Entries` must be sorted by HLC ascending — the writer always appends
in HLC-ascending order, so the accumulator's `entries/1` already
satisfies this. An empty list is valid; the resulting handle returns
`none` for every `seek/2`.
""").
-spec from_entries(entries()) -> t().

from_entries(Entries) when is_list(Entries) ->
    #idx{entries = list_to_tuple(Entries)}.

?DOC("""
Returns the byte offset of the indexed batch frame the reader should
start at to find `TargetHlc`. `none` if every entry's range is strictly
> `TargetHlc` (or the handle is empty).

Search rules:

1. If some entry's range contains `TargetHlc`
   (`FirstHlc =< TargetHlc =< LastHlc`), return that entry's offset —
   the target is inside the indexed batch.
2. Otherwise, return the offset of the largest entry whose `LastHlc`
   is `=< TargetHlc` — the v1-style fallback. The reader scans
   forward from there into the un-indexed gap.

Binary search over the entry tuple; O(log N) time, no allocations.
Entries are sorted ascending by `FirstHlc`, which (together with the
writer's monotonic HLC sequence) means the entries are also sorted by
`LastHlc` — a single bsearch tracks both range-hit and fallback.

The returned offset is **a frame boundary** — the first byte of a
frame header inside the indexed segment.
""").
-spec seek(t(), hlc()) -> {ok, offset()} | none.

seek(#idx{entries = E}, TargetHlc) when
    is_integer(TargetHlc), TargetHlc >= 0
->
    N = tuple_size(E),
    case N of
        0 ->
            none;
        _ ->
            {FirstHlc1, _, _} = element(1, E),
            case FirstHlc1 > TargetHlc of
                true -> none;
                false -> bsearch(E, TargetHlc, 1, N, undefined)
            end
    end.

?DOC("Returns the entries embedded in a handle, in HLC-ascending order.").
-spec handle_entries(t()) -> entries().

handle_entries(#idx{entries = E}) ->
    tuple_to_list(E).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
encode_header(EntryCount) when
    is_integer(EntryCount), EntryCount >= 0, EntryCount =< 16#FFFFFFFF
->
    <<?MAGIC:32/big-unsigned, ?VERSION_CURRENT:8/unsigned, 0:24/big-unsigned,
        EntryCount:32/big-unsigned, 0:32/big-unsigned>>.

%% @private
%% v2-only encode. v1 files exist on-disk from prior writers; the
%% reader handles them via the decode path, but writers never produce
%% v1 again.
encode_entries(Entries) ->
    [
        <<F:64/big-unsigned, L:64/big-unsigned, O:64/big-unsigned>>
     || {F, L, O} <- Entries
    ].

%% @private
decode_file(Bin) when is_binary(Bin), byte_size(Bin) < ?HEADER_BYTES ->
    {error, truncated_header};
decode_file(
    <<?MAGIC:32/big-unsigned, Version:8/unsigned, _Flags:24/big-unsigned,
        EntryCount:32/big-unsigned, _Reserved:32/big-unsigned,
        EntriesBin/binary>>
) ->
    case Version of
        ?VERSION_V1 ->
            decode_entries_bin(?ENTRY_BYTES_V1, EntriesBin, EntryCount);
        ?VERSION_V2 ->
            decode_entries_bin(?ENTRY_BYTES_V2, EntriesBin, EntryCount);
        _ ->
            {error, unsupported_version}
    end;
decode_file(<<Magic:32/big-unsigned, _/binary>>) when Magic =/= ?MAGIC ->
    {error, bad_magic}.

%% @private
decode_entries_bin(EntryBytes, Bin, EntryCount) ->
    Expected = EntryCount * EntryBytes,
    Have = byte_size(Bin),
    if
        Have < Expected -> {error, truncated_entries};
        Have > Expected -> {error, trailing_bytes};
        true -> {ok, decode_entries_loop(EntryBytes, Bin, [])}
    end.

%% @private
decode_entries_loop(_EntryBytes, <<>>, Acc) ->
    lists:reverse(Acc);
decode_entries_loop(
    ?ENTRY_BYTES_V1,
    <<H:64/big-unsigned, O:64/big-unsigned, Rest/binary>>,
    Acc
) ->
    %% v1 fallback: lift the single HLC to a degenerate single-point
    %% range so callers see a uniform 3-tuple shape.
    decode_entries_loop(?ENTRY_BYTES_V1, Rest, [{H, H, O} | Acc]);
decode_entries_loop(
    ?ENTRY_BYTES_V2,
    <<F:64/big-unsigned, L:64/big-unsigned, O:64/big-unsigned, Rest/binary>>,
    Acc
) ->
    decode_entries_loop(?ENTRY_BYTES_V2, Rest, [{F, L, O} | Acc]).

%% @private
%% Writes the header+body to the open tmp fd then datasyncs. The close
%% is the caller's responsibility so we can keep `commit_or_cleanup/3`
%% out of the fd-life path.
write_and_sync(Fd, Iolist) ->
    case prim_file:write(Fd, Iolist) of
        ok ->
            case bondy_mst_io:datasync(Fd) of
                ok -> ok;
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

%% @private
commit_or_cleanup(ok, TmpPath, Path) ->
    case bondy_mst_io:rename(TmpPath, Path) of
        ok ->
            bondy_mst_io:fsync_dir(filename:dirname(Path));
        {error, _} = E ->
            _ = prim_file:delete(TmpPath),
            E
    end;
commit_or_cleanup({error, _} = E, TmpPath, _Path) ->
    _ = prim_file:delete(TmpPath),
    E.

%% @private
tmp_path(Path) ->
    iolist_to_binary([Path, ".tmp"]).

%% @private
%% Binary search for the entry whose range contains `T`, falling back
%% to the largest entry whose `LastHlc =< T`. Invariant: entries are
%% sorted ascending by `FirstHlc` (and, by writer monotonicity, by
%% `LastHlc` too). Walking towards higher indices while
%% `LastHlc =< T` tracks the fallback "best so far"; a hit on an
%% entry's range short-circuits with that entry's offset.
bsearch(_E, _T, Lo, Hi, Best) when Lo > Hi ->
    case Best of
        undefined -> none;
        _ -> {ok, Best}
    end;
bsearch(E, T, Lo, Hi, Best) ->
    Mid = (Lo + Hi) div 2,
    {F, L, O} = element(Mid, E),
    if
        T < F ->
            %% Target is before this entry's range — fallback (if any)
            %% lives to the left.
            bsearch(E, T, Lo, Mid - 1, Best);
        T =< L ->
            %% In-range hit — return immediately, this is the best
            %% possible answer.
            {ok, O};
        true ->
            %% Past this entry's range — update fallback and look right
            %% in case a later entry's range still contains T.
            bsearch(E, T, Mid + 1, Hi, O)
    end.
