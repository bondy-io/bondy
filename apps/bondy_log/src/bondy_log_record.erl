%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_log_record).

-moduledoc """
The record seam of the log core: what a frame body is made of.

The writer, reader and recovery scanner never look inside a record. They
hand a batch to `encode_body/1`, hand a frame body to `decode_body/1`,
and ask `key/1` for the integer that orders records (the sparse index
stores the first and last key of every frame) and `max_seq/1` for the
batch's sequence maximum, which the writer tracks across rotations and
returns from `open/2`. `frame_magic/0` is the 4-byte frame magic the log
is written and sniffed with, so two record kinds never decode each
other's frames.

**What the key orders.** The writer requires keys to be strictly
increasing *within* a batch (`{invalid_batch, key_not_monotonic}`) and
nothing more: the log's order is append order, and two batches appended
by two callers land in the order their calls reached the writer, whatever
their keys. The sparse index and the reader's `{key, T}` start treat the
key as monotonic across frames, so that seek is exact only for an adapter
whose keys are globally monotonic in append order. The oplog's is not
(its fast path mints a key in the caller's process and appends through a
separate call; a probe with 16 appenders lands 2–4 % of frames out of key
order), which is why nothing in the oplog resumes a disk log by key: its
consumer resumes by byte position, and retention is cut by the committed
segment ordinal. An adapter that wants an exact key seek makes its keys
monotonic by construction — one appending process assigning them — and
says so.

An adapter is passed to the log as `adapter` at open; the same module
implements `bondy_log_identity` and `bondy_log_directory`, so a log is
never opened with one kind's records and another kind's identity. The
oplog adapter encodes the bytes the oplog WAL wrote before the seam
existed; the stream adapter supplies its own body format keyed by its
own clock and reports `max_seq/1` only for the frame that seals a batch
object — its `flush_hlc`, the ordinal the log's owner seeds its clock
from — and `undefined` for every other batch.

`is_valid/1` is the writer's input validation: a batch containing a term
the adapter does not recognise is refused with
`{error, {invalid_batch, non_event}}` before anything is encoded.
""".

-type t() :: term().
-type key() :: non_neg_integer().

-export_type([t/0]).
-export_type([key/0]).

-callback frame_magic() -> bondy_log_frame:magic().

-callback is_valid(term()) -> boolean().

-callback key(t()) -> key().

-callback max_seq([t(), ...]) -> non_neg_integer() | undefined.

-callback encode_body([t(), ...]) -> binary().

-callback decode_body(binary()) ->
    {ok, [t(), ...]} | {error, term()}.
