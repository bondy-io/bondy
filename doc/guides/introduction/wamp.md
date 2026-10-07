# Web Application Messaging Protocol

## Serialisation

Erlang has a single type, the binary, for both text and bytes. Each WAMP
serialiser therefore decides how a binary goes on the wire.

### MessagePack

Bondy encodes and decodes MessagePack with its own codec, `bondy_msgpack`
(`bondy_msgpack_SUITE`):

- A binary that is valid UTF-8 is sent as `str`. Any other binary is sent as
  `bin`. Both decode to a binary.
- `nil` decodes to `undefined`, and `undefined` encodes to `nil`.
- When a map repeats a key, the first value is kept (`bondy_msgpack_SUITE:maps`).
- Extension types are refused, as are the reserved type `0xC1`, truncated
  input and trailing bytes. A message that contains one fails to decode
  (`bondy_msgpack_SUITE:published_suite_extensions_are_refused`).

### CBOR

A binary that is valid UTF-8 is sent as a CBOR text string (major type 3).
Any other binary is sent as a byte string (major type 2). A client therefore
sees the same strings it would see over JSON. `undefined` encodes to CBOR
`null`.

### bondy_connect_sdk

The Erlang client `bondy_connect_sdk` encodes and decodes through the same
`bondy_wamp_encoding` module as the router, so it applies the same rules for
each serialiser.
