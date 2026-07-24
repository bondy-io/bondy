%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_pagination).
-moduledoc """
The single end-user pagination contract shared by every paginated Bondy API.

A page is keyset (cursor) pagination: a bounded `t:result_set/0` plus an
opaque `t:cursor/0` to resume from. This module owns only the **contract** —
the cursor record, the wire codec, the staleness discipline and the
external (WAMP-facing) shape. The *walk* that assembles a page is the
source's job: `bondy_relation` walks a table's shards; `bondy_registry_meta`
walks the cluster's nodes. Both mint the same `t:cursor/0`, so a client sees
one pagination dialect regardless of what it is paging.

This is a **shared-type + codec** contract, NOT an Erlang behaviour, and
deliberately so. Resumption is intrinsic to pagination, and the sources take
the resume cursor in *incompatible* forms — `bondy_relation` takes a decoded
`t:cursor/0`, `bondy_registry_meta` takes the wire binary and decodes it
itself. There is therefore no cursor input type a single `list/3` callback
could name that both sources honour, so a `-behaviour` here would advertise a
contract one implementer would crash on. The genuine interface both comply to
is the vocabulary below: they mint `t:cursor/0`, return `t:result_set/0` built
via `result/2`, and externalise via `to_external/1`.

## The cursor

A cursor carries a `fingerprint` and a source-defined `payload`:

- `fingerprint` binds the cursor to the schema/topology that minted it. A
  cursor replayed against an incompatible source is rejected (`stale`), not
  paged wrongly. The source decides what the fingerprint covers (a table's
  shard count and key encoding for `bondy_relation`; the entry-key encoding
  and pagination schema version for `bondy_registry_meta`).
- `payload` is opaque to this module — a shard-and-key position for one
  source, a node-walk record for another.

The cursor is opaque to clients: they receive the `encode_cursor/1` binary on
one page's `next` and echo it back as the next page's `cursor`.

## External shape

WAMP payloads round-trip through JSON, CBOR and MessagePack, so `to_external/1`
renders a page as a plain map of portable scalars, with the cursor as its wire
binary. Values pass through unchanged — the paginating source externalises them
before they reach the page (e.g. `bondy_registry_meta` produces `wamp_meta`
maps on the owning node), so they are already encoder-portable here.
""".

-record(cursor, {
    fingerprint :: binary(),
    payload :: term()
}).

-opaque cursor() :: #cursor{}.

-doc """
A page. `next` is `undefined` exactly when `has_more` is `false`; the
`result/2` constructor enforces this invariant.
""".
-type result_set() :: #{
    values := [term()],
    next := cursor() | undefined,
    has_more := boolean()
}.

-doc "The WAMP-facing page: a plain map of encoder-portable scalars.".
-type ext_page() :: #{
    binary() => [term()] | binary() | boolean()
}.

-export_type([cursor/0]).
-export_type([result_set/0]).
-export_type([ext_page/0]).

%% API
-export([decode_cursor/2]).
-export([encode_cursor/1]).
-export([fingerprint/1]).
-export([new_cursor/2]).
-export([payload/1]).
-export([result/2]).
-export([to_external/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Mint a cursor for a source `Payload` under `Fingerprint`. The source decides
what `Payload` holds (a shard-and-key position, a node-walk record, ...).
""".
-spec new_cursor(Fingerprint :: binary(), Payload :: term()) -> cursor().

new_cursor(Fingerprint, Payload) when is_binary(Fingerprint) ->
    #cursor{fingerprint = Fingerprint, payload = Payload}.

-doc "The source-defined payload of `Cursor`.".
-spec payload(Cursor :: cursor()) -> term().

payload(#cursor{payload = Payload}) ->
    Payload.

-doc "The fingerprint `Cursor` was minted under.".
-spec fingerprint(Cursor :: cursor()) -> binary().

fingerprint(#cursor{fingerprint = Fingerprint}) ->
    Fingerprint.

-doc """
Build a `t:result_set/0` from `Values` and the next cursor, computing
`has_more`. Pass `undefined` as `Next` for the final page.
""".
-spec result(Values :: [term()], Next :: cursor() | undefined) ->
    result_set().

result(Values, undefined) when is_list(Values) ->
    #{values => Values, next => undefined, has_more => false};
result(Values, #cursor{} = Next) when is_list(Values) ->
    #{values => Values, next => Next, has_more => true}.

-doc """
Encode `Cursor` to an opaque wire binary. The inverse is `decode_cursor/2`.
""".
-spec encode_cursor(Cursor :: cursor()) -> binary().

encode_cursor(#cursor{} = Cursor) ->
    base64:encode(term_to_binary(Cursor)).

-doc """
Decode a wire cursor produced by `encode_cursor/1`, validating that it was
minted under `Fingerprint`.

Returns `{ok, Cursor}`, `{error, stale}` when the cursor's fingerprint does
not match (the source was re-keyed / re-sharded, or the cursor belongs to a
different source — the caller should restart from the first page), or
`{error, malformed}` when the binary is not a decodable cursor.
""".
-spec decode_cursor(Fingerprint :: binary(), Bin :: binary()) ->
    {ok, cursor()} | {error, stale | malformed}.

decode_cursor(Fingerprint, Bin) when is_binary(Fingerprint), is_binary(Bin) ->
    try binary_to_term(base64:decode(Bin), [safe]) of
        #cursor{fingerprint = Fingerprint} = Cursor ->
            {ok, Cursor};
        #cursor{} ->
            {error, stale};
        _ ->
            {error, malformed}
    catch
        _:_ ->
            {error, malformed}
    end.

-doc """
Render `ResultSet` as a WAMP-facing map of encoder-portable scalars. The
`next` cursor becomes its `encode_cursor/1` binary under `<<"cursor">>`, absent
on the final page. Values pass through unchanged — the paginating source
externalises them (e.g. `bondy_registry_meta` produces `wamp_meta` maps on the
owning node), so they are already encoder-portable here.
""".
-spec to_external(ResultSet :: result_set()) -> ext_page().

to_external(#{values := Values, next := Next, has_more := HasMore}) ->
    Base = #{
        <<"values">> => Values,
        <<"has_more">> => HasMore
    },
    case Next of
        undefined ->
            Base;
        #cursor{} ->
            Base#{<<"cursor">> => encode_cursor(Next)}
    end.
