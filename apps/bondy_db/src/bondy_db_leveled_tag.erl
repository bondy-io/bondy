%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_db_leveled_tag).

-include("bondy_doc.hrl").
-include_lib("bondy_oplog/include/bondy_oplog.hrl").

-moduledoc #{format => "text/markdown"}.
?MODULEDOC("""
Leveled custom-tag hooks for the projection cell tag `?BONDY_FOLD_TAG`.

Leveled exposes two application-env hooks per tag:

- `extract_metadata/3` — runs on every `book_put` for our tag; takes the
  object bytes (a V2 frame produced by `bondy_oplog_cell_frame:encode/4`)
  and projects them to the **HEAD wire format**
  (`<<HlcLen:16, Hlc/binary, ValueBytes/binary>>`). The HEAD bytes land
  in the ledger; the journal still carries the full frame for full-object
  reads.
- `build_head/2` — runs on every `book_head` and reconstructs the HEAD
  bytes from the ledger-stored metadata. Since we store the HEAD bytes
  in the metadata's third tuple element, this is a one-element extract.

## Why metadata is `{Hash, Size, HeadBin}` rather than just `HeadBin`

Leveled's non-overridable helpers (`leveled_head:get_size/2`,
`leveled_head:get_hash/2`) assume `object_metadata()` is a 3-tuple
`{Hash, Size, ExtraOrLastMods}` for any tag that isn't `?RIAK_TAG` or
`?HEAD_TAG`. Returning a flat binary from `extract_metadata/3` would
crash those helpers on the size/hash extraction path. We keep the
3-tuple convention and stash the HEAD bytes in the third slot.

## Registration

Registration is a one-shot env-var write done in
`bondy_mst_app:start/2`:

```erlang
application:set_env(leveled, extract_metadata,
    fun bondy_db_leveled_tag:extract_metadata/3),
application:set_env(leveled, build_head,
    fun bondy_db_leveled_tag:build_head/2),
```

Leveled's `get_appdefined_function/3` only delegates to these for
**non-builtin** tags (anything other than `?STD_TAG`, `?RIAK_TAG`,
`?HEAD_TAG`). Built-in tags continue to use their hardcoded paths, so
our override is invisible to any leveled bucket that still uses
`?STD_TAG`. The functions still pattern-match on `?BONDY_FOLD_TAG`
defensively and call the default for unknown tags.
""").

-export([extract_metadata/3]).
-export([build_head/2]).
-export([install/0]).

%% =============================================================================
%% LEVELED HOOKS
%% =============================================================================

-doc """
Project a V2 cell frame to its HEAD wire format and pack it into the
3-tuple metadata layout that `leveled_head:get_size/2` and
`leveled_head:get_hash/2` expect (`{Hash, Size, ExtraOrLastMods}`).

The HEAD bytes are stashed in the third slot; `build_head/2` extracts
them on `book_head`.
""".
-spec extract_metadata(
    Tag :: atom(),
    Size :: non_neg_integer(),
    Frame :: binary()
) -> {{non_neg_integer(), non_neg_integer(), binary()}, []}.

extract_metadata(?BONDY_FOLD_TAG, Size, Frame) when is_binary(Frame) ->
    HeadBin = bondy_oplog_cell_frame:extract_head(Frame),
    Hash = erlang:phash2(Frame),
    {{Hash, Size, HeadBin}, []};
extract_metadata(_Tag, Size, Obj) ->
    %% Defensive fallback for any non-fold tag that somehow routes
    %% through our hook. Mirrors `leveled_head:default_extract_metadata/3`.
    {{standard_hash(Obj), Size, undefined}, []}.

-doc """
Reconstruct the HEAD wire format from the ledger-stored metadata.

`book_head/4` returns whatever `build_head/2` produces, so this is the
final shape `bondy_db_projection_leveled:head/3` hands back to the
substrate.
""".
-spec build_head(
    Tag :: atom(),
    Metadata :: {non_neg_integer(), non_neg_integer(), binary()}
) -> binary().

build_head(?BONDY_FOLD_TAG, {_Hash, _Size, HeadBin}) when is_binary(HeadBin) ->
    HeadBin;
build_head(_Tag, Metadata) ->
    %% Defensive fallback — return metadata unchanged. Mirrors
    %% `leveled_head:default_build_head/2`.
    Metadata.

-doc """
Register the `extract_metadata/3` and `build_head/2` hooks with leveled's
`app_defined_functions` env vars. Idempotent. Called from
`bondy_mst_app:start/2` in normal use; tests that bring up a Bookie
without starting the bondy_mst application can call this directly.

Loads the leveled application first (loading is required before
`set_env` succeeds; leveled does not need to be **started** for the
hooks to be effective — `get_appdefined_function/3` just reads the
env at extraction/build time).
""".
-spec install() -> ok.

install() ->
    _ = application:load(leveled),
    ok = application:set_env(
        leveled, extract_metadata, fun ?MODULE:extract_metadata/3
    ),
    ok = application:set_env(
        leveled, build_head, fun ?MODULE:build_head/2
    ),
    ok.

%% =============================================================================
%% INTERNAL
%% =============================================================================

%% @private
standard_hash(Obj) ->
    erlang:phash2(term_to_binary(Obj)).
