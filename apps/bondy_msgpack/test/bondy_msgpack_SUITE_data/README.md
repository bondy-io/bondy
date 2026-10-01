# MessagePack cross-implementation test suite

`msgpack-test-suite.json` is the published MessagePack test suite by Yusuke
Kawasaki, vendored unmodified under its MIT licence (`LICENSE`).

- Source: <https://github.com/kawanet/msgpack-test-suite>, file
  `dist/msgpack-test-suite.json`
- Commit: `e04f6edeaae5` (2018-10-18), package version 1.0.0
- SHA-256: `8ea4d7aea19f7cf4…` (first 16 hex digits)

Each case gives a value and every encoding of it a conforming implementation
may write. `bondy_msgpack_SUITE` checks that every listed encoding decodes
to the value and that `bondy_msgpack:encode/1` produces one of the listed
encodings, with two exceptions:

- `timestamp` and `ext`: extension types have no Erlang mapping in this codec,
  so the decoder must reject every one of these encodings.
- `binary`: Erlang has one binary type for text and bytes, so a binary that is
  valid UTF-8 is encoded as str. Only the binaries that are not valid UTF-8 are
  held to the listed bin encodings; the others must encode as str.
