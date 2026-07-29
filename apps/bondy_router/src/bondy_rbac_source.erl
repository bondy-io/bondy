%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rbac_source).
-moduledoc """
**Note:**
Usernames and group names are stored in lower case. All functions in this
module are case sensitice so when using the functions in this module make
sure the inputs you provide are in lowercase to. If you need to convert your
input to lowercase use `string:casefold/1`.

### Storage

Sources are stored in the bondy_db `security_sources` main table. The store is
realm-sharded; the compound `{Username, AMask, Authmethod}` key is encoded to a
binary with `term_to_binary/1`. That encoding is not order-preserving and the
match is on the `Username` (and optionally the `AMask`) — never the
`Authmethod` alone — so a lookup is a realm scan (`bondy_db:list/2`) that
decodes each key and filters. Storage-only (no change reactor).
""".
-include_lib("partisan/include/partisan_util.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_db_tables.hrl").
-include("bondy_security.hrl").

-define(ASSIGNMENT_VALIDATOR, #{
    % <<"roles">> => #{
    %     alias => roles,
    % 	key => roles,
    %     required => true,
    %     validator => fun bondy_data_validators:rolenames/1
    % },
    <<"usernames">> => #{
        alias => usernames,
        key => usernames,
        required => true,
        allow_null => false,
        allow_undefined => false,
        validator => fun bondy_data_validators:usernames/1
    },
    <<"cidr">> => #{
        alias => cidr,
        key => cidr,
        allow_null => false,
        allow_undefined => false,
        required => true,
        default => {{0, 0, 0, 0}, 0},
        datatype => [binary, tuple],
        validator => fun bondy_data_validators:cidr/1
    },
    <<"authmethod">> => #{
        alias => authmethod,
        key => authmethod,
        required => true,
        allow_null => false,
        datatype => {in, ?BONDY_AUTH_METHOD_NAMES}
    },
    <<"meta">> => #{
        alias => meta,
        key => meta,
        allow_null => false,
        allow_undefined => false,
        required => true,
        datatype => map,
        default => #{}
    }
}).

-define(VERSION, <<"1.1">>).

-record(source_assignment, {
    usernames :: [binary() | all | anonymous],
    data :: t()
}).

-type assignment() :: #source_assignment{}.

-type user_source() :: #{
    type := source,
    version := binary(),
    username := binary() | all | anonymous,
    cidr := bondy_cidr:t(),
    authmethod := binary(),
    meta => #{binary() => any()}
}.

-type t() :: #{
    type := source,
    version := binary(),
    username := binary() | all | anonymous,
    cidr := bondy_cidr:t(),
    authmethod := binary(),
    meta => #{binary() => any()}
}.

-type add_opts() :: #{
    %% `true` when applying declarative config (idempotent write, no runtime
    %% side-effects) — see `bondy_realm:apply_config/0`.
    declarative => boolean(),
    actor_id => term()
}.

-type external() :: t().
-type list_opts() :: #{limit => pos_integer()}.

-export_type([t/0]).
-export_type([assignment/0]).
-export_type([user_source/0]).

-export([add/2]).
-export([add/3]).
-export([authmethod/1]).
%% Exported for the legacy-backup import translator (bondy_export): the source
%% key must be encoded byte-identically to the live write path.
-export([encode_key/1]).
-export([cidr/1]).
-export([list/1]).
-export([list/2]).
-export([match/2]).
-export([match/3]).
-export([match_first/3]).
-export([meta/1]).
-export([new_assignment/1]).
-export([remove/3]).
-export([remove_all/1]).
-export([remove_all/2]).
-export([to_external/1]).

%% =============================================================================
%% API
%% =============================================================================

-spec new_assignment(Data :: map()) -> Source :: assignment().

new_assignment(Data) when is_map(Data) ->
    Map = maps_utils:validate(Data, ?ASSIGNMENT_VALIDATOR),

    #source_assignment{
        usernames = maps:get(usernames, Map),
        data = type_and_version(maps:without([usernames], Map))
    }.

-doc "Returns the authmethod associated with the source".
authmethod(#{type := source, authmethod := Val}) -> Val.

-doc "Returns the source's CIDR.".
cidr(#{type := source, cidr := Val}) -> Val.

-doc "Returns the metadata associated with the source".
meta(#{type := source, meta := Val}) -> Val.

-doc """
Adds a source to the realm identified by `RealmUri` using assignment or map
`Assignment`.
""".
-spec add(
    RealmUri :: uri(), Assignment :: map() | assignment()
) ->
    {ok, t()} | {error, any()}.

add(RealmUri, Assignment) ->
    add(RealmUri, Assignment, #{}).

-doc """
Adds a source to the realm identified by `RealmUri` using assignment or map
`Assignment`.
""".
-spec add(
    RealmUri :: uri(),
    Assignment :: map() | assignment(),
    Opts :: add_opts()
) ->
    {ok, t()} | {error, any()}.

add(RealmUri, Data, Opts) when is_map(Data) ->
    try
        Assignment = new_assignment(Data),
        add(RealmUri, Assignment, Opts)
    catch
        throw:Reason ->
            {error, Reason}
    end;
add(RealmUri, #source_assignment{} = A, Opts) ->
    do_add(
        RealmUri,
        A#source_assignment.usernames,
        A#source_assignment.data,
        Opts
    ).

-spec remove(
    RealmUri :: uri(),
    Usernames :: [binary() | anonymous] | binary() | anonymous | all,
    CIDR :: bondy_cidr:t() | binary()
) -> ok.

remove(RealmUri, Keyword, CIDR) when
    (Keyword == all orelse Keyword == anonymous)
->
    remove(RealmUri, [atom_to_binary(Keyword)], CIDR);
remove(RealmUri, Usernames0, CIDR0) when is_list(Usernames0) ->
    Usernames =
        case bondy_data_validators:usernames(Usernames0) of
            {ok, Valid} ->
                Valid;
            true ->
                Usernames0;
            false ->
                ?ERROR(badarg, [RealmUri, Usernames0, CIDR0], usernames)
        end,

    AMask =
        case bondy_data_validators:cidr(CIDR0) of
            {ok, CIDR} ->
                bondy_cidr:anchor_mask(CIDR);
            true ->
                bondy_cidr:anchor_mask(CIDR0);
            false ->
                ?ERROR(badarg, [RealmUri, Usernames, CIDR0], invalid_cidr)
        end,

    Table = table(),

    UserSources = lists:flatten([
        do_match(RealmUri, Username, AMask)
     || Username <- Usernames
    ]),
    _ = [
        bondy_db:apply(Table, RealmUri, encode_key(Key), clear)
     || {Key, _} <- UserSources
    ],
    ok;
remove(RealmUri, Username, CIDR) when is_binary(Username) ->
    remove(RealmUri, [Username], CIDR).

-doc """
Removes all sources from all users in realm identifier by uri `RealmUri`.
""".
-spec remove_all(RealmUri :: uri()) -> ok.

remove_all(RealmUri) ->
    Table = table(),
    {ok, Rows} = bondy_db:list(Table, RealmUri),
    _ = [
        bondy_db:apply(Table, RealmUri, EncKey, clear)
     || {EncKey, _V, _Hlc} <- Rows
    ],
    ok.

-spec remove_all(RealmUri :: uri(), Username :: binary()) -> ok.

remove_all(RealmUri, Username) ->
    Table = table(),
    {Lo, Hi} = bondy_oplog_index_key:col_bounds(Username),
    {ok, Rows} = bondy_db:range_all(Table, RealmUri, Lo, Hi, #{}),
    _ = [
        bondy_db:apply(Table, RealmUri, EncKey, clear)
     || {EncKey, _V, _Hlc} <- Rows
    ],
    ok.

-doc """
Returns all the sources for user including the ones for special use 'all'.
""".
-spec match(uri(), binary() | all | anonymous) -> [t()].

match(RealmUri, all) ->
    [from_term(Term) || Term <- do_match(RealmUri, all)];
match(RealmUri, Username) ->
    lists:append(
        [from_term(Term) || Term <- do_match(RealmUri, Username)],
        match(RealmUri, all)
    ).

-spec match(
    RealmUri :: uri(),
    Username :: binary() | all | anonymous,
    ConnIP :: inet:ip_address()
) -> [t()].

match(RealmUri, Username, ConnIP) when ?IS_IP(ConnIP) ->
    %% We need to use the internal match function (do_match) as it returns Keys
    %% and Values, we need the keys to be able to sort

    Sources = sort_sources(
        lists:append(
            do_match(RealmUri, Username),
            do_match(RealmUri, all)
        )
    ),

    Pred = fun({{_, {_, Mask} = CIDR, _}, _}) ->
        bondy_cidr:match(CIDR, {ConnIP, Mask})
    end,
    [from_term(Term) || Term <- lists:filter(Pred, Sources)].

-doc """
Returns the first matching source of all the sources available for username
`Username`.
""".
-spec match_first(
    RealmUri :: uri(),
    Username :: binary() | all | anonymous,
    ConnIP :: inet:ip_address()
) -> {ok, t()} | {error, nomatch}.

match_first(RealmUri, Username, ConnIP) ->
    %% We need to use the internal match function (do_match) as it returns Keys
    %% and Values, we need the keys to be able to sort the result
    Sources = sort_sources(do_match(RealmUri, Username)),
    Fun = fun({{_, {_, Mask} = CIDR, _}, _} = Term) ->
        bondy_cidr:match(CIDR, {ConnIP, Mask}) andalso
            throw({result, from_term(Term)})
    end,
    try
        ok = lists:foreach(Fun, Sources),
        {error, nomatch}
    catch
        throw:{result, Source} ->
            Source
    end.

-spec list(uri()) -> list(t()).

list(RealmUri) ->
    list(RealmUri, #{}).

-spec list(RealmUri :: uri(), Opts :: list_opts()) -> list(t()).

list(RealmUri, Opts) ->
    Sources = [from_term(Term) || Term <- scan(RealmUri)],

    case maps_utils:get_any([limit, <<"limit">>], Opts, undefined) of
        undefined ->
            Sources;
        Limit ->
            lists:sublist(Sources, Limit)
    end.

-doc "Returns the external representation of the source `Source`.".
-spec to_external(Source :: t()) -> external().

to_external(#{type := source, version := ?VERSION} = Source) ->
    {Addr, Mask} = maps:get(cidr, Source),
    String = iolist_to_binary(
        io_lib:format("~s/~B", [inet_parse:ntoa(Addr), Mask])
    ),
    maps:put(cidr, String, Source).

%% =============================================================================
%% PRIVATE
%% =============================================================================

do_add(RealmUri, Keyword, #{type := source} = Source, Opts) when
    Keyword == all orelse Keyword == anonymous
->
    Masked = bondy_cidr:anchor_mask(maps:get(cidr, Source)),
    %% TODO check if there are already 'user' sources for this CIDR
    %% with the same source
    Authmethod = maps:get(authmethod, Source),
    Key = {Keyword, Masked, Authmethod},
    store(RealmUri, Key, Source, Opts);
do_add(RealmUri, Usernames, #{type := source} = Source, Opts) ->
    %% We validate all usernames exist
    Unknown = bondy_rbac_user:unknown(RealmUri, Usernames),
    [] =:= Unknown orelse throw({no_such_users, Unknown}),

    Masked = bondy_cidr:anchor_mask(maps:get(cidr, Source)),

    _ = lists:foreach(
        fun(Username) ->
            %% prev we added {Authmethod, Meta} instead of Source
            Authmethod = maps:get(authmethod, Source),
            Key = {Username, Masked, Authmethod},
            _ = store(RealmUri, Key, Source, Opts),
            ok
        end,
        Usernames
    ),
    {ok, Source}.

%% Sources carry no lifecycle side-effects. A runtime write is a plain lww set
%% (dominates by HLC); a declarative config apply (`declarative`) is IDEMPOTENT
%% via `bondy_db:reconcile`, so re-reading the same config file on every boot emits
%% no operation and never re-stamps the cell with a fresh HLC (which would
%% diverge cross-node convergence). The op-based CRDT + anti-entropy
%% handle convergence; plum_db's deterministic-version rebase is obsolete.
store(RealmUri, Key, Source, Opts) ->
    EncKey = encode_key(Key),
    %% `Opts` may be a map (`#{declarative => true}` from config apply) or a
    %% plain list, so guard with `is_map/1`.
    Result =
        case is_map(Opts) andalso maps:get(declarative, Opts, false) =:= true of
            true -> bondy_db:reconcile(table(), RealmUri, EncKey, Source);
            false -> bondy_db:apply(table(), RealmUri, EncKey, {set, Source})
        end,
    case Result of
        ok ->
            {ok, Source};
        Error ->
            Error
    end.

%% @private
-doc """
Returns the Key Value
Example:

```erlang
[
    {{anonymous, {{0,0,0,0},0}},
    #{authmethod => <<"anonymous">>,...,version => <<"1.1">>}}]
}
```
""".
do_match(RealmUri, Username) ->
    lists:append(scan_user(RealmUri, Username), proto_all_sources(RealmUri)).

%% @private
do_match(RealmUri, Username, AMask) ->
    Sources = [
        KV
     || {{_U, Mask, _Method}, _} = KV <- scan_user(RealmUri, Username),
        Mask == AMask
    ],
    lists:append(Sources, proto_all_sources(RealmUri)).

%% @private
%% The prototype realm's `all` sources, unioned into a realm's match results.
%% TODO when we enable assigned to groups here we need to also union the
%% sources assigned to the group in the proto.
proto_all_sources(RealmUri) ->
    case bondy_realm:prototype_uri(RealmUri) of
        undefined ->
            [];
        ProtoUri ->
            scan_user(ProtoUri, all)
    end.

%% @private
from_term(
    {{Username, CIDR, _M}, #{type := source, version := ?VERSION} = Source}
) ->
    Source#{
        username => Username,
        cidr => CIDR
    };
from_term({{Username, CIDR}, [{Authmethod, Options}]}) ->
    from_term({{Username, CIDR}, {Authmethod, Options}});
from_term({{Username, CIDR}, {Authmethod, Options}}) ->
    %% Legacy version format
    Meta = maps:from_list(Options),
    Source = #{
        username => Username,
        authmethod => Authmethod,
        meta => Meta,
        cidr => CIDR
    },
    {Username, type_and_version(Source)}.

%% @private
type_and_version(Map) ->
    Map#{
        version => ?VERSION,
        type => source
    }.

%% @private
%% The open bondy_db `security_sources` table handle. Raises if the catalogue
%% has not provisioned it yet.
table() ->
    case bondy_namespace_catalog:table(?BONDY_DB_SOURCE_TAB) of
        undefined ->
            error(security_sources_table_unavailable);
        Table ->
            Table
    end.

%% @private
%% All live sources in a realm as decoded `{Key, Value}` pairs (the same shape
%% the old `plum_db:match` returned), where `Key` is the 3-tuple
%% `{Username, AMask, Authmethod}`. Cleared cells (non-map values) are dropped.
scan(RealmUri) ->
    {ok, Rows} = bondy_db:list(table(), RealmUri),
    [{decode_key(EncKey), V} || {EncKey, V, _Hlc} <- Rows, is_map(V)].

%% @private
%% All live sources for one username in a realm — a bounded username-band range
%% scan (`O(sources-for-user)`), used by the auth-path match instead of the
%% full-realm `scan/1`. Same decoded `{Key, Value}` shape; cleared (non-map)
%% cells are dropped.
scan_user(RealmUri, Username) ->
    {Lo, Hi} = bondy_oplog_index_key:col_bounds(Username),
    {ok, Rows} = bondy_db:range_all(table(), RealmUri, Lo, Hi, #{}),
    [{decode_key(EncKey), V} || {EncKey, V, _Hlc} <- Rows, is_map(V)].

%% @private
%% The source store key is the 3-tuple `{Username, AMask, Authmethod}`, encoded
%% as an **order-preserving composite**: the username as a type-tagged leading
%% column (`encode_col/1`, covering binary usernames and the reserved atoms
%% `all`/`anonymous`), a `0x00` separator, then the canonical `term_to_binary`
%% of `{AMask, Authmethod}`. The username column is `0x00`-free, so all of a
%% user's sources are a contiguous band (`col_bounds(Username)`) — the auth-path
%% match (`do_match/2,3`) is a bounded range scan, not a full-realm filter.
encode_key({Username, AMask, Authmethod}) ->
    <<
        (bondy_oplog_index_key:encode_col(Username))/binary,
        0,
        (term_to_binary({AMask, Authmethod}, [deterministic]))/binary
    >>.

%% @private
%% Inverse of `encode_key/1`: split at the single `0x00` separator (the username
%% column is `0x00`-free), decode the username column, then `[safe]`-decode
%% `{AMask, Authmethod}` (their atoms already exist).
decode_key(Bin) when is_binary(Bin) ->
    {ColBin, Rest} = split_key(Bin),
    {AMask, Authmethod} = binary_to_term(Rest, [safe]),
    {bondy_oplog_index_key:decode_col(ColBin), AMask, Authmethod}.

%% @private
split_key(Bin) ->
    case binary:match(Bin, <<0>>) of
        {Pos, 1} ->
            Col = binary:part(Bin, 0, Pos),
            Suffix = binary:part(Bin, Pos + 1, byte_size(Bin) - Pos - 1),
            {Col, Suffix};
        nomatch ->
            error({badarg, Bin})
    end.

sort_sources(Sources) ->
    %% sort sources first by userlist, so that 'all' matches come last
    %% and then by CIDR, so that most specific masks come first
    Sources1 = lists:sort(
        fun
            ({{all, _, _}, _}, {{all, _, _}, _}) ->
                true;
            ({{all, _, _}, _}, _) ->
                %% anything is greater than 'all'
                true;
            (_, {{all, _, _}, _}) ->
                false;
            (_, _) ->
                true
        end,
        Sources
    ),

    lists:sort(
        fun({{_, {_, MaskA}, _}, _}, {{_, {_, MaskB}, _}, _}) ->
            MaskA > MaskB
        end,
        Sources1
    ).

%% group users sharing the same CIDR/Source/Options
% group_sources(Sources) ->
%     D = lists:foldl(fun({User, CIDR, Source, Options}, Acc) ->
%                 dict:append({CIDR, Source, Options}, User, Acc)
%         end, dict:new(), Sources),
%     R1 = [{Users, CIDR, Source, Options} || {{CIDR, Source, Options}, Users} <-
%                                        dict:to_list(D)],
%     %% Split any entries where the user list contains (but is not
%     %% exclusively) 'all' so that 'all' has its own entry. We could
%     %% actually elide any user sources that overlap with an 'all'
%     %% source, but that may be more confusing because deleting the all
%     %% source would then 'resurrect' the user sources.
%     R2 = lists:foldl(fun({Users, CIDR, Source, Options}=E, Acc) ->
%                     case Users =/= [all] andalso lists:member(all, Users) of
%                         true ->
%                             [{[all], CIDR, Source, Options},
%                              {Users -- [all], CIDR, Source, Options}|Acc];
%                         false ->
%                             [E|Acc]
%                     end
%             end, [], R1),
%     %% sort the result by the same criteria that sort_sources uses
%     R3 = lists:sort(fun({UserA, _, _, _}, {UserB, _, _, _}) ->
%                     case {UserA, UserB} of
%                         {[all], [all]} ->
%                             true;
%                         {[all], _} ->
%                             %% anything is greater than 'all'
%                             true;
%                         {_, [all]} ->
%                             false;
%                         {_, _} ->
%                             true
%                     end
%             end, R2),
%     lists:sort(fun({_, {_, MaskA}, _, _}, {_, {_, MaskB}, _, _}) ->
%                 MaskA > MaskB
%         end, R3).
