%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_session_id).
-moduledoc """
This module implements the Bondy session identifier. They consist of a 56-bit
WAMP Session Identifier and a 104-bit randomly generated payload.

The WAMP Session Identifier is an integer drawn randomly from a uniform
distribution over the complete range `[1, 2^53]` i.e. (between `1` and
`9007199254740992`).

The string representation is fixed at 27-characters encoded using base62 to be
URL friendly.

The uniqueness property does not depend on any host-identifiable information or
the wall clock. Instead it depends on the improbability of random collisions in
such a large number space.
""".

-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-define(MAX_EXT_ID, ?MAX_ID).
-define(ENCODED_LEN, 27).
-define(LEN, 160).
-define(EXT_LEN, 56).

-type t() :: binary().

-export([new/0]).
-export([new/1]).
-export([node_hash/0]).
-export([node_hash/1]).
-export([to_external/1]).
-export([is_type/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Returns a new globally unique session id based on a new random external
identifier.
""".
-spec new() -> t().

new() ->
    %% IDs in the _global scope_ MUST be drawn _randomly_ from a _uniform
    %% distribution_ over the complete range [0, 2^53]
    new(rand:uniform(?MAX_EXT_ID)).

-doc """
Returns a new globally unique session id based on the external identifier
`ExternalId`.
""".
-spec new(ExternalId :: id()) -> t().

new(ExternalId) when
    is_integer(ExternalId) andalso
        ExternalId >= 1 andalso
        ExternalId =< ?MAX_EXT_ID
->
    %% First segment is the external id as a 56-bit binary
    ExternalIdBin = <<ExternalId:?EXT_LEN/integer>>,

    %% Second part is 104-bit of random data
    PayloadSize = trunc((?LEN - ?EXT_LEN) / 8),
    Payload = crypto:strong_rand_bytes(PayloadSize),

    %% We append first and second part
    <<Id:?LEN/integer>> = <<ExternalIdBin/binary, Payload/binary>>,

    %% We encode using base62
    Base62 = base62:encode(Id),

    %% We pad to 27 chars
    Existing = iolist_to_binary(string:pad(Base62, ?ENCODED_LEN, leading, $0)),

    %% We prepend the OWNING NODE's hash as a distinct, dot-separated segment.
    %% This keeps the existing 27-char id whole (it still encodes the WAMP integer
    %% id + the random payload) and makes the id SELF-LOCATING: because the `.`
    %% aligns with WAMP URI segments, `wamp.session.{NodeHash}.{Existing}.get`
    %% composes by plain concatenation, and one per-node wildcard registration
    %% `wamp.session.{NodeHash}..get` routes the RPC to the owning node WITHOUT a
    %% per-session registration.
    <<(node_hash())/binary, $., Existing/binary>>.

-doc """
Returns a stable hash of the local node, used as the self-locating segment of a
session id. Collisions merely degrade routing to a retry (the target node's
handler finds the session isn't local), never to a wrong answer.
""".
-spec node_hash() -> binary().

node_hash() ->
    integer_to_binary(erlang:phash2(bondy_config:nodestring(), 4294967296)).

-doc "Returns the owning-node hash segment of a session id, or `undefined`.".
-spec node_hash(t()) -> binary() | undefined.

node_hash(Id) when is_binary(Id) ->
    case binary:split(Id, <<$.>>) of
        [NodeHash, _Existing] -> NodeHash;
        [_] -> undefined
    end.

-doc """
Returns the external session identifier i.e. the WAMP Session ID.
""".
-spec to_external(Base62 :: binary()) -> WAMPSessionId :: id().

to_external(Id) when is_binary(Id) ->
    %% Decode the existing (dot-suffix) segment, which still encodes the WAMP id
    %% in its first 56 bits — the node-hash prefix is not part of the WAMP id.
    Bin = base62:decode(existing_part(Id)),

    %% We extract the first segment (56-bits) as an integer
    <<ExternalId:?EXT_LEN/integer, _/binary>> = <<Bin:?LEN/integer>>,

    ExternalId.

is_type(Id) when is_binary(Id) ->
    byte_size(existing_part(Id)) =:= ?ENCODED_LEN;
is_type(_) ->
    false.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% The original 27-char base62 id (the segment after the node-hash prefix). Falls
%% back to the whole binary for a legacy (prefix-less) id.
existing_part(Id) ->
    case binary:split(Id, <<$.>>) of
        [_NodeHash, Existing] -> Existing;
        [Existing] -> Existing
    end.

%% =============================================================================
%% TESTS
%% =============================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

%% @private A valid 27-char base62 "existing" id (no node-hash prefix), built
%% deterministically so tests need neither bondy_config nor randomness.
mk_existing(Ext) ->
    <<Id160:?LEN/integer>> = <<Ext:?EXT_LEN/integer, 0:(?LEN - ?EXT_LEN)/integer>>,
    iolist_to_binary(string:pad(base62:encode(Id160), ?ENCODED_LEN, leading, $0)).

composite_parse_test() ->
    Existing = mk_existing(123456789),
    Id = <<"777.", Existing/binary>>,
    ?assertEqual(<<"777">>, node_hash(Id)),
    ?assertEqual(Existing, existing_part(Id)),
    ?assert(is_type(Id)).

to_external_skips_prefix_test() ->
    Ext = 123456789,
    Existing = mk_existing(Ext),
    Id = <<"777.", Existing/binary>>,
    %% The WAMP id must survive the node-hash prefix (and the legacy form).
    ?assertEqual(Ext, to_external(Id)),
    ?assertEqual(Ext, to_external(Existing)).

legacy_id_test() ->
    Existing = mk_existing(42),
    ?assert(is_type(Existing)),
    ?assertEqual(undefined, node_hash(Existing)).

-endif.
