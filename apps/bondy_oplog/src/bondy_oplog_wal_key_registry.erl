%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_wal_key_registry).

-include("bondy_doc.hrl").
-include("bondy_oplog_wal.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Behaviour for the per-instance encryption key registry consulted by
`bondy_oplog_wal_codec` when body encryption is enabled.

The WAL writer asks for the *current* key (the one to encrypt new
frames with); the reader and recovery scanner ask for *historic*
keys by `KeyId` (the value baked into older ciphertext envelopes).
The behaviour deliberately exposes two narrow callbacks rather than a
single "key store" map — operators can back it with whatever they
already manage (a Vault client, an in-memory module, an Erlang
application env entry, an external KMS).

## Callbacks

```
current_key/0 -> {KeyId, Key}
```

Returns the writer's *current* key. Called once per encrypted frame on
the write hot path; implementations should cache rather than do
fresh network I/O. `KeyId` is the 16-bit identifier baked into the
envelope so the reader can resolve the key later; `Key` is a 32-byte
binary suitable for AES-256-GCM.

```
lookup_key(KeyId) -> {ok, Key} | {error, missing}
```

Returns a key by id. Called on the read path for every encrypted
frame. `{error, missing}` is the *only* valid failure surface — any
other failure mode must be hidden from the caller (callers treat
`missing` as a non-recoverable but well-typed error and surface
`{error, {missing_key, KeyId}}`; crashing in this callback turns
the read into an exit signal, which is much worse).

## Key rotation

Rotation is a write-side decision: the writer's view of "current key"
changes the moment its registry's `current_key/0` returns a new
`{KeyId', Key'}` pair. Frames written after rotation carry `KeyId'`
in their envelope; frames written before rotation still carry the
older `KeyId`.

**Never retire a key while frames written with it are still live.**
A key is "live" as long as any unread frame (live segment or
unsnapshotted history) was written with it. Removing such a key from
the registry makes the WAL unreadable from that point: the codec
returns `{error, {missing_key, KeyId}}` rather than guessing. The
operator runbook should pair every retirement with either a forced
compaction past the last frame using that key, or a snapshot
sufficient to bypass it.

## Why a behaviour and not a fixed implementation

Operator environments differ: in development a static key in
application env is fine; in production the keys live in a KMS that
needs auth tokens, lease renewal, or local caching. By keeping the
key store behind a behaviour, the WAL does not need to ship a Vault
client, an AWS SDK, or any other transport. Implementations are
also easier to unit-test in isolation.
""").

-type key_id() :: 0..16#FFFF.
-type cipher_key() :: <<_:256>>.

-export_type([key_id/0]).
-export_type([cipher_key/0]).

?DOC("""
Returns the writer's current encryption key. Called once per frame on
the write hot path; implementations should cache rather than do
network I/O per call.
""").
-callback current_key() -> {key_id(), cipher_key()}.

?DOC("""
Looks up a key by id. Called on the read path; `{error, missing}` is
the only valid failure response.
""").
-callback lookup_key(key_id()) -> {ok, cipher_key()} | {error, missing}.
