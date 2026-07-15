%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_session).

-moduledoc """
The client's view of an established WAMP session, built from the router's
`WELCOME` message (its `session_id` and `details`).

This is a pure data module: a session value is created once the protocol layer
(`bondy_connect_protocol`) transitions to `established`, and is read by the
connection process and the public API. The `details` map is the verbatim
`WELCOME.Details`; the accessors extract the commonly-needed fields, reading
either atom or binary keys so the value is robust to how the codec decoded it.
""".

-record(bondy_connect_session, {
    id :: non_neg_integer(),
    realm_uri :: binary() | undefined,
    authid :: binary() | undefined,
    authrole :: binary() | undefined,
    authmethod :: binary() | undefined,
    authprovider :: binary() | undefined,
    roles :: map(),
    details :: map()
}).

-opaque t() :: #bondy_connect_session{}.

-export_type([t/0]).

-export([new/2]).
-export([id/1]).
-export([realm_uri/1]).
-export([authid/1]).
-export([authrole/1]).
-export([authmethod/1]).
-export([authprovider/1]).
-export([roles/1]).
-export([details/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc "Build a session from a `WELCOME` message's session id and details.".
-spec new(SessionId :: non_neg_integer(), Details :: map()) -> t().

new(SessionId, Details) when is_integer(SessionId), is_map(Details) ->
    #bondy_connect_session{
        id = SessionId,
        realm_uri = field(realm, Details, undefined),
        authid = field(authid, Details, undefined),
        authrole = field(authrole, Details, undefined),
        authmethod = field(authmethod, Details, undefined),
        authprovider = field(authprovider, Details, undefined),
        roles = field(roles, Details, #{}),
        details = Details
    }.

-spec id(t()) -> non_neg_integer().
id(#bondy_connect_session{id = Val}) -> Val.

-spec realm_uri(t()) -> binary() | undefined.
realm_uri(#bondy_connect_session{realm_uri = Val}) -> Val.

-spec authid(t()) -> binary() | undefined.
authid(#bondy_connect_session{authid = Val}) -> Val.

-spec authrole(t()) -> binary() | undefined.
authrole(#bondy_connect_session{authrole = Val}) -> Val.

-spec authmethod(t()) -> binary() | undefined.
authmethod(#bondy_connect_session{authmethod = Val}) -> Val.

-spec authprovider(t()) -> binary() | undefined.
authprovider(#bondy_connect_session{authprovider = Val}) -> Val.

-spec roles(t()) -> map().
roles(#bondy_connect_session{roles = Val}) -> Val.

-spec details(t()) -> map().
details(#bondy_connect_session{details = Val}) -> Val.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private Read `Key' from `Map', accepting either the atom or its binary form.
field(Key, Map, Default) when is_atom(Key) ->
    case maps:find(Key, Map) of
        {ok, Value} ->
            Value;
        error ->
            maps:get(atom_to_binary(Key, utf8), Map, Default)
    end.
