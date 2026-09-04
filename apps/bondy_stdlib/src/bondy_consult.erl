%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_consult).
-moduledoc """
The one encoder for files read back with `file:consult/1`.

Every on-disk manifest in Bondy (`bondy_mst_pack_manifest`,
`bondy_oplog_wal_manifest`, `bondy_oplog_wal_state`, `bondy_db_manifest`) is
a sequence of Erlang terms that `file:consult/1` parses. Producing those bytes
has two steps, and both are load-bearing:

1. `io_lib:format/2` renders the term to a list of *characters* — code points,
   not bytes. `~tw` is used for a single-line, deterministic rendering in
   which a binary is always written as a byte list (`<<1,2>>`), an atom or
   string containing non-ASCII characters is written as those characters, and
   nothing is escaped.
2. `unicode:characters_to_binary/1` encodes those characters as UTF-8, which
   is the encoding `file:consult/1` decodes.

Using `iolist_to_binary/1` for step 2 instead is the defect this module
exists to make unrepeatable: it writes each code point as one byte, so a
character in the range 160..255 lands in the file as a byte that is not valid
UTF-8 and `file:consult/1` rejects the whole file with
`{Line, file_io_server, invalid_unicode}`; a code point above 255 makes it
raise `badarg`. Which terms reach that range depends on the directive — `~p`
renders a binary of printable latin-1 bytes as `<<"...">>`, so a raw sha256
root did it about once in 2400 (measured: 21/50000, and it crash-looped a
production shard); `~tw` never string-renders a binary but still emits an atom
such as `'café'` verbatim — so changing the directive alone closed the binary
case and left the atom case open (measured against OTP `io_lib` and
`file:consult/1` on 2026-09-03).

The directive is therefore a layout choice; the byte encoding is the
invariant. Both are pinned by `prop_bondy_consult`, whose generator covers
binaries of arbitrary bytes, atoms and strings with latin-1 and wide
characters, integers, floats, and nested lists, tuples and maps, and reads
every case back through the real `file:consult/1`.

Terms with no external representation (pids, ports, references, funs) are
not consultable and are not this module's concern: the caller's schema
excludes them.
""".

-export([encode/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Encodes `Terms` as the UTF-8 bytes of a `file:consult/1` file: one term per
line, each terminated by `.` and a newline.

`file:consult/1` of a file holding the result returns `{ok, Terms}` for every
term `file:consult/1` can represent (see the module doc for the evidence).
""".
-spec encode(Terms :: [term()]) -> binary().

encode(Terms) when is_list(Terms) ->
    unicode:characters_to_binary([io_lib:format("~tw.~n", [T]) || T <- Terms]).
