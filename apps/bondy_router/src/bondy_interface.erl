%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_interface).

-moduledoc """
The interface metadata store: descriptions and schemas for WAMP procedures,
topics and errors, published to Bondy as **documents** — versioned artifacts
a developer or CI pipeline uploads at deploy time — and read through WAMP
Interface Reflection.

## The product model

Interface metadata describes a **URI**, never a registration or a session:
it changes at release cadence, is valid whether or not any callee is
currently registered to serve its URI, and outlives every connection. Tying
its life to a session would make the catalogue flicker with connection
churn; writing it durably from a session-scoped act (a `REGISTER` option)
would leave data nobody owns and nobody cleans. So the ONLY write path is
the document:

- A document carries an `id`, an optional `version`, and `entries`, each
  entry describing one `(realm, kind, match_policy, uri)`.
- `load/1` **replaces** the previously loaded version of the same document:
  entries the new version no longer declares are removed. `delete/1`
  removes the document and every entry it declared. This is the same
  lifecycle `bondy_http_gateway` gives API Gateway specifications.
- Every projected entry records the `source` document that declared it, and
  one entry belongs to exactly ONE document: a document claiming a key
  another document currently owns is rejected whole.
- A document is validated as a whole before anything is written: one
  invalid entry rejects the entire document. (Validation is atomic; the
  writes are applied per cell on the substrate, and re-loading the same
  document converges.)

The registry never learns this store exists — the registry is the hottest
subsystem in the router and metadata must not add a byte to it.

## Storage

One durable `bondy_db` table (`bondy_interface`), two bands:

- the GLOBAL band (the empty binary, the `bondy_realm` convention) holds
  each document's **source** map keyed by its id — never a parsed form, so
  a code upgrade can always re-derive from the original text;
- each REALM's band holds the projected entries, keyed
  `term_to_binary({Kind, MatchPolicy, Uri})` (the RIB's key convention),
  which is what `describe/3` point-reads and `list/2` scans.

## Read path

The `wamp.reflection.*` procedures (`bondy_wamp_meta_api`) — which is what
makes this a Bondy capability with MCP one consumer among others.

Every schema-valued field of an entry is in the format the entry's `format`
tag names — `json_schema_2020_12`, the only member of the set today. The
tag exists so a future canonical representation (JSON-LD, lowered to JSON
Schema where a consumer requires it) arrives as a new tag plus a consumer
clause, not as a store migration.
""".

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_db_tables.hrl").

%% The global band holding document sources (the `bondy_realm` convention:
%% one shared band, keyed by id).
-define(DOC_BAND, <<>>).

-define(FORMATS, [json_schema_2020_12]).
-define(MATCH_POLICIES, [?EXACT_MATCH, ?PREFIX_MATCH, ?WILDCARD_MATCH]).

%% The keys an entry's identity — including its realm — is made of; they are
%% consumed by `load/1` and never stored inside the projected value twice.
-define(IDENTITY_KEYS, [
    kind,
    uri,
    match_policy,
    realm,
    <<"kind">>,
    <<"uri">>,
    <<"match_policy">>,
    <<"realm">>
]).

-define(VALIDATOR, #{
    <<"description">> => #{
        alias => description,
        key => description,
        required => false,
        allow_null => false,
        allow_undefined => false,
        datatype => binary
    },
    <<"format">> => #{
        alias => format,
        key => format,
        required => true,
        default => json_schema_2020_12,
        allow_null => false,
        allow_undefined => false,
        validator => fun format/1
    },
    <<"args_schema">> => #{
        alias => args_schema,
        key => args_schema,
        required => false,
        allow_null => false,
        allow_undefined => false,
        datatype => map
    },
    <<"kwargs_schema">> => #{
        alias => kwargs_schema,
        key => kwargs_schema,
        required => false,
        allow_null => false,
        allow_undefined => false,
        datatype => map
    },
    <<"result_args_schema">> => #{
        alias => result_args_schema,
        key => result_args_schema,
        required => false,
        allow_null => false,
        allow_undefined => false,
        datatype => map
    },
    <<"result_kwargs_schema">> => #{
        alias => result_kwargs_schema,
        key => result_kwargs_schema,
        required => false,
        allow_null => false,
        allow_undefined => false,
        datatype => map
    },
    <<"errors">> => #{
        alias => errors,
        key => errors,
        required => false,
        allow_null => false,
        allow_undefined => false,
        datatype => {list, binary}
    },
    <<"version">> => #{
        alias => version,
        key => version,
        required => false,
        allow_null => false,
        allow_undefined => false,
        datatype => binary
    }
}).

-type kind() :: procedure | topic | error.
-type t() :: #{
    kind := kind(),
    uri := uri(),
    match_policy := binary(),
    format := json_schema_2020_12,
    source := binary(),
    description => binary(),
    args_schema => map(),
    kwargs_schema => map(),
    result_args_schema => map(),
    result_kwargs_schema => map(),
    errors => [uri()],
    version => binary()
}.

-export_type([kind/0]).
-export_type([t/0]).

-export([delete/1]).
-export([describe/3]).
-export([get/1]).
-export([list/0]).
-export([list/2]).
-export([load/1]).
-export([to_external/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Loads (or REPLACES) an interface document:
`#{<<"id">> := binary(), <<"entries">> := [map()]}`, each entry carrying its
own `realm`, `kind` and `uri` (and optionally `match_policy` and the
descriptive fields).

The whole document is validated first — every entry, that each realm
exists, that no two of its entries claim one key, and that no key is owned
by a DIFFERENT document — and the first failure rejects the document with
nothing written. Entries the previously loaded version declared and this
one does not are removed.
""".
-spec load(Document :: map()) -> ok | {error, Reason :: any()}.

load(#{<<"id">> := Id, <<"entries">> := Entries} = Document) when
    is_binary(Id), Id =/= <<>>, is_list(Entries), Entries =/= []
->
    try
        Validated = [
            {realm_of(Data), new(Id, Data)}
         || Data <- Entries
        ],
        Keys = [projection_key(R, E) || {R, E} <- Validated],
        ok = assert_no_duplicates(Keys),
        ok = assert_ownership(Id, Keys),

        %% Remove what the previous version declared and this one does not
        %% (still owned by this document — an entry another load has since
        %% taken over is not this document's to remove).
        Stale = [K || K <- stored_keys(Id), not lists:member(K, Keys)],
        ok = lists:foreach(
            fun({RealmUri, Key}) -> clear_owned(Id, RealmUri, Key) end,
            Stale
        ),

        ok = lists:foreach(
            fun({{RealmUri, Key}, {_, Entry}}) ->
                ok = bondy_db:apply(table(), RealmUri, Key, {set, Entry})
            end,
            lists:zip(Keys, Validated)
        ),
        bondy_db:apply(table(), ?DOC_BAND, Id, {set, Document})
    catch
        throw:Reason ->
            {error, Reason};
        error:Reason ->
            {error, Reason}
    end;
load(#{<<"id">> := Id}) when not is_binary(Id) orelse Id == <<>> ->
    {error, {invalid_value, <<"id">>}};
load(#{<<"id">> := _, <<"entries">> := Entries}) when
    not is_list(Entries) orelse Entries == []
->
    %% A document declaring nothing is not a load; removal is `delete/1`.
    {error, {invalid_value, <<"entries">>}};
load(Document) when is_map(Document) ->
    Missing =
        case maps:is_key(<<"id">>, Document) of
            true -> <<"entries">>;
            false -> <<"id">>
        end,
    {error, {missing_required_value, Missing}};
load(_) ->
    {error, invalid_document}.

-doc """
Deletes the document `Id` and every projected entry it still owns.
""".
-spec delete(Id :: binary()) -> ok | {error, not_found}.

delete(Id) when is_binary(Id) ->
    case bondy_db:read(table(), ?DOC_BAND, Id) of
        {ok, {Document, _}} when is_map(Document) ->
            ok = lists:foreach(
                fun({RealmUri, Key}) -> clear_owned(Id, RealmUri, Key) end,
                doc_keys(Document)
            ),
            bondy_db:apply(table(), ?DOC_BAND, Id, clear);
        _ ->
            {error, not_found}
    end.

-doc "The SOURCE of document `Id`, as originally loaded.".
-spec get(Id :: binary()) -> {ok, map()} | {error, not_found}.

get(Id) when is_binary(Id) ->
    case bondy_db:read(table(), ?DOC_BAND, Id) of
        {ok, {Document, _}} when is_map(Document) -> {ok, Document};
        _ -> {error, not_found}
    end.

-doc "The sources of every loaded document.".
-spec list() -> [map()].

list() ->
    {ok, Cells} = bondy_db:list(table(), ?DOC_BAND),
    [Document || {_Id, Document, _Hlc} <- Cells, is_map(Document)].

-doc """
The entry describing `Uri` in `RealmUri`, trying the three match policies in
specificity order (`exact`, `prefix`, `wildcard`) — three point reads, no
scan. `Uri` is the URI the entry was declared under, not a URI to
pattern-match against stored patterns.
""".
-spec describe(RealmUri :: uri(), Kind :: kind(), Uri :: uri()) ->
    {ok, t()} | {error, not_found}.

describe(RealmUri, Kind, Uri) when is_binary(Uri) ->
    describe(RealmUri, Kind, Uri, ?MATCH_POLICIES).

-doc "Every entry of `Kind` declared for `RealmUri`.".
-spec list(RealmUri :: uri(), Kind :: kind()) -> [t()].

list(RealmUri, Kind) ->
    {ok, Cells} = bondy_db:list(table(), RealmUri),
    [
        Entry
     || {_Key, Entry, _Hlc} <- Cells,
        %% A cleared cell surfaces its tombstone in a listing.
        is_map(Entry),
        maps:get(kind, Entry, undefined) =:= Kind
    ].

-doc "The entry as a JSON-friendly, binary-keyed map.".
-spec to_external(t()) -> map().

to_external(#{kind := Kind, format := Format} = Entry) ->
    maps:fold(
        fun(K, V, Acc) -> maps:put(atom_to_binary(K), V, Acc) end,
        #{},
        Entry#{kind => atom_to_binary(Kind), format => atom_to_binary(Format)}
    ).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Validates one document entry. Identity (kind, uri, match_policy) comes
%% from the entry itself; the owning document rides in `source`.
new(Id, Data) when is_map(Data) ->
    Kind = kind(maps_utils:get_any([kind, <<"kind">>], Data, undefined)),
    Uri = maps_utils:get_any([uri, <<"uri">>], Data, undefined),
    Policy = maps_utils:get_any(
        [match_policy, <<"match_policy">>], Data, ?EXACT_MATCH
    ),
    lists:member(Policy, ?MATCH_POLICIES) orelse
        throw({invalid_match_policy, Policy}),
    (is_binary(Uri) andalso bondy_wamp_uri:is_valid(Uri, Policy)) orelse
        throw({invalid_uri, Uri}),
    Entry = maps_utils:validate(maps:without(?IDENTITY_KEYS, Data), ?VALIDATOR),
    Entry#{kind => Kind, uri => Uri, match_policy => Policy, source => Id}.

%% @private
describe(_, _, _, []) ->
    {error, not_found};
describe(RealmUri, Kind, Uri, [Policy | Rest]) ->
    case bondy_db:read(table(), RealmUri, key(Kind, Policy, Uri)) of
        {ok, {Entry, _Hlc}} when is_map(Entry) ->
            {ok, Entry};
        _ ->
            describe(RealmUri, Kind, Uri, Rest)
    end.

%% @private
%% The projection cell key: the RIB's own convention for a composite key on
%% a binary-keyed substrate. No range scan needs it order-preserving —
%% `list/2` scans the band and filters on the value.
key(Kind, Policy, Uri) ->
    term_to_binary({Kind, Policy, Uri}).

%% @private
projection_key(RealmUri, #{kind := Kind, match_policy := Policy, uri := Uri}) ->
    {RealmUri, key(Kind, Policy, Uri)}.

%% @private
assert_no_duplicates(Keys) ->
    length(Keys) =:= length(lists:usort(Keys)) orelse
        throw(duplicate_entries),
    ok.

%% @private
%% One entry belongs to exactly one document: a key currently owned by a
%% DIFFERENT document rejects this whole load.
assert_ownership(Id, Keys) ->
    lists:foreach(
        fun({RealmUri, Key}) ->
            case bondy_db:read(table(), RealmUri, Key) of
                {ok, {#{source := Owner, kind := Kind, uri := Uri}, _}} when
                    Owner =/= Id
                ->
                    throw(
                        {conflict, #{
                            realm => RealmUri,
                            kind => Kind,
                            uri => Uri,
                            owner => Owner
                        }}
                    );
                _ ->
                    ok
            end
        end,
        Keys
    ).

%% @private
%% The projection keys the STORED version of document `Id` declared.
stored_keys(Id) ->
    case bondy_db:read(table(), ?DOC_BAND, Id) of
        {ok, {Document, _}} when is_map(Document) -> doc_keys(Document);
        _ -> []
    end.

%% @private
%% Key derivation from a STORED source, deliberately LENIENT: the document
%% was validated when it loaded, and cleanup (a replacing load, a delete)
%% must not fail because the world changed since — a realm deleted after
%% the load, say. An entry whose identity no longer derives is skipped;
%% `clear_owned/3` makes a wrong derivation harmless.
doc_keys(#{<<"entries">> := Entries}) when is_list(Entries) ->
    lists:filtermap(
        fun(Data) ->
            try
                Realm = maps_utils:get_any(
                    [realm, <<"realm">>], Data, undefined
                ),
                Kind = kind(
                    maps_utils:get_any([kind, <<"kind">>], Data, undefined)
                ),
                Uri = maps_utils:get_any([uri, <<"uri">>], Data, undefined),
                Policy = maps_utils:get_any(
                    [match_policy, <<"match_policy">>], Data, ?EXACT_MATCH
                ),
                is_binary(Realm) andalso is_binary(Uri) andalso
                    {true, {Realm, key(Kind, Policy, Uri)}}
            catch
                _:_ -> false
            end
        end,
        Entries
    );
doc_keys(_) ->
    [].

%% @private
%% Clears a projection cell only while `Id` still owns it: an entry another
%% document's load has since taken over is not this document's to remove.
clear_owned(Id, RealmUri, Key) ->
    case bondy_db:read(table(), RealmUri, Key) of
        {ok, {#{source := Id}, _}} ->
            ok = bondy_db:apply(table(), RealmUri, Key, clear);
        _ ->
            ok
    end.

%% @private
kind(<<"procedure">>) -> procedure;
kind(<<"topic">>) -> topic;
kind(<<"error">>) -> error;
kind(Kind) when Kind == procedure; Kind == topic; Kind == error -> Kind;
kind(Kind) -> throw({invalid_kind, Kind}).

%% @private
%% A `maps_utils` validator: coerce the wire spelling and close the set —
%% anything outside `?FORMATS` fails validation.
format(<<"json_schema_2020_12">>) -> {ok, json_schema_2020_12};
format(Format) -> lists:member(Format, ?FORMATS).

%% @private
realm_of(Data) ->
    case maps_utils:get_any([realm, <<"realm">>], Data, undefined) of
        Uri when is_binary(Uri), Uri =/= <<>> ->
            bondy_realm:exists(Uri) orelse throw({no_such_realm, Uri}),
            Uri;
        Other ->
            throw({invalid_realm, Other})
    end.

%% @private
%% The published `bondy_interface` table handle, or an error when the
%% catalogue has not provisioned it yet.
table() ->
    case bondy_namespace_catalog:table(?BONDY_DB_INTERFACE_TAB) of
        undefined -> error(bondy_interface_table_unavailable);
        Table -> Table
    end.
