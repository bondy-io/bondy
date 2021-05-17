%% =============================================================================
%%  bondy_rbac_source.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
%%  Copyright (c) 2013 Basho Technologies, Inc.
%%
%%  Licensed under the Apache License, Version 2.0 (the "License");
%%  you may not use this file except in compliance with the License.
%%  You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%  Unless required by applicable law or agreed to in writing, software
%%  distributed under the License is distributed on an "AS IS" BASIS,
%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%  See the License for the specific language governing permissions and
%%  limitations under the License.
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc
%% **Note:**
%% Usernames and group names are stored in lower case. All functions in this
%% module are case sensitice so when using the functions in this module make
%% sure the inputs you provide are in lowercase to. If you need to convert your
%% input to lowercase use {@link string:casefold/1}.
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_rbac_source).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_security.hrl").


-define(ASSIGNMENT_VALIDATOR, (?SOURCE_VALIDATOR)#{
    <<"usernames">> => #{
        alias => usernames,
		key => usernames,
        required => true,
        allow_null => false,
        allow_undefined => false,
        validator => fun bondy_data_validators:usernames/1
    }
}).

-define(SOURCE_VALIDATOR, #{
    <<"cidr">> => #{
        alias => cidr,
		key => cidr,
        allow_null => false,
        allow_undefined => false,
        required => true,
        default => [],
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
-define(PLUMDB_PREFIX(RealmUri), {security_sources, RealmUri}).
-define(FOLD_OPTS, [{resolver, lww}]).


-record(source_assignment, {
    usernames           ::  [binary() | all | anonymous],
    data                ::  t()
}).

-type assignment()      ::  #source_assignment{}.

-type user_source()     ::  #{
    type                :=  source,
    version             :=  binary(),
    username            :=  binary() | all | anonymous,
    cidr                :=  cidr(),
    authmethod          :=  binary(),
    meta                =>  #{binary() => any()}
}.

-type t()       ::  #{
    type                :=  source,
    version             :=  binary(),
    username            :=  binary() | all | anonymous,
    cidr                :=  cidr(),
    authmethod          :=  binary(),
    meta                =>  #{binary() => any()}
}.

-type external()        ::  t().
-type cidr()            ::  {inet:ip_address(), non_neg_integer()}.
-type list_opts()       ::  #{limit => pos_integer()}.

-export_type([t/0]).
-export_type([assignment/0]).
-export_type([user_source/0]).
-export_type([cidr/0]).

-export([add/2]).
-export([add/3]).
-export([authmethod/1]).
-export([cidr/1]).
-export([list/1]).
-export([list/2]).
-export([match/2]).
-export([match/3]).
-export([match_first/3]).
-export([meta/1]).
-export([new/1]).
-export([new_assignment/1]).
-export([remove/3]).
-export([remove_all/2]).
-export([to_external/1]).




%% =============================================================================
%% API
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new(Data :: map()) -> Source :: t().

new(Data) when is_map(Data) ->
    Source = maps_utils:validate(Data, ?SOURCE_VALIDATOR),
    type_and_version(Source).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec new_assignment(Data :: map()) -> Source :: assignment().

new_assignment(Data) when is_map(Data) ->
    Map = maps_utils:validate(Data, ?ASSIGNMENT_VALIDATOR),

    #source_assignment{
        usernames = maps:get(usernames, Map),
        data = type_and_version(maps:without([usernames], Map))
    }.


%% -----------------------------------------------------------------------------
%% @doc Returns the authmethod associated withe the source
%% @end
%% -----------------------------------------------------------------------------
authmethod(#{type := source, authmethod := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the source's CIDR.
%% @end
%% -----------------------------------------------------------------------------
cidr(#{type := source, cidr := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the metadata associated with the source
%% @end
%% -----------------------------------------------------------------------------
meta(#{type := source, meta := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(
    RealmUri :: uri(), Assignment :: map() | assignment()) ->
    ok | {error, any()}.

add(RealmUri, Data) when is_map(Data) ->
    try
        Assignment = new_assignment(Data),
        add(RealmUri, Assignment)
    catch
        throw:Reason ->
            {error, Reason}
    end;

add(RealmUri, #source_assignment{} = A) ->
    do_add(RealmUri, A#source_assignment.usernames, A#source_assignment.data).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(
    Realmuri :: uri(),
    Usernames :: [binary()] | all | anonymous,
    Assignment :: map() | assignment()) -> ok | {error, any()}.

add(RealmUri, Usernames, #{type := source} = Source) ->
    try
        do_add(RealmUri, Usernames, Source)
    catch
        throw:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(
    RealmUri :: uri(),
    Usernames :: [binary() | anonymous] | binary() | anonymous | all,
    CIDR :: bondy_rbac_source:cidr()) -> ok.

remove(RealmUri, Keyword, CIDR)
when (Keyword == all orelse Keyword == anonymous) ->
    remove(RealmUri, [Keyword], CIDR);

remove(RealmUri, Usernames, CIDR) when is_list(Usernames) ->
    Prefix  = ?PLUMDB_PREFIX(RealmUri),
    _ = [
        plum_db:delete(Prefix, {Username, anchor_mask(CIDR)})
        || Username <- Usernames
    ],
    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove_all(RealmUri :: uri(), Username :: binary()) -> ok.

remove_all(RealmUri, Username) ->
    Prefix  = ?PLUMDB_PREFIX(RealmUri),
    plum_db:fold(fun
        ({{Id, _CIDR} = Key, _}, Acc) when Id == Username ->
            plum_db:delete(Prefix, Key),
            Acc;
        ({{_, _}, _}, Acc) ->
            Acc
        end,
        ok,
        Prefix
    ).



%% -----------------------------------------------------------------------------
%% @doc Returns all the sources for user including the ones for speacial
%% use 'all'.
%% @end
%% -----------------------------------------------------------------------------
-spec match(uri(), binary() | all | anonymous) -> [t()].

match(RealmUri, all) ->
    [from_term(Term) || Term <- do_match(RealmUri, all)];

match(RealmUri, Username) ->
    lists:append(
        [from_term(Term) || Term <- do_match(RealmUri, Username)],
        match(RealmUri, all)
    ).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match(
    RealmUri :: uri(),
    Username :: binary() | all | anonymous,
    ConnIP :: inet:ip_address()) -> [t()].

match(RealmUri, Username, ConnIP) ->
    %% We need to use the internal match function (do_match) as it returns Keys
    %% and Values, we need the keys to be able to sort

    Sources = sort_sources(
        lists:append(
            do_match(RealmUri, Username),
            do_match(RealmUri, all)
        )
    ),

    Pred = fun({{_, {IP, Mask}}, _}) ->
        mask_address(IP, Mask) == mask_address(ConnIP, Mask)
    end,
    [from_term(Term) || Term <- lists:filter(Pred, Sources)].


%% -----------------------------------------------------------------------------
%% @doc Returns the first matching source of all the sources available for
%% username `Username'.
%% @end
%% -----------------------------------------------------------------------------
-spec match_first(
    RealmUri :: uri(),
    Username :: binary() | all | anonymous,
    ConnIP :: inet:ip_address()) -> {ok, t()} | {error, nomatch}.

match_first(RealmUri, Username, ConnIP) ->
    %% We need to use the internal match function (do_match) as it returns Keys
    %% and Values, we need the keys to be able to sort
    Sources = sort_sources(do_match(RealmUri, Username)),
    Fun = fun({{_, {IP, Mask}}, _} = Term) ->
        mask_address(IP, Mask) == mask_address(ConnIP, Mask)
            andalso throw({result, from_term(Term)})
    end,
    try
        ok = lists:foreach(Fun, Sources),
        {error, nomatch}
    catch
        throw:{result, Source} ->
            Source
    end.




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec list(uri()) -> list(t()).

list(RealmUri) ->
    list(RealmUri, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec list(RealmUri :: uri(), Opts :: list_opts()) -> list(t()).

list(RealmUri, Opts) ->
    Prefix = ?PLUMDB_PREFIX(RealmUri),

    FoldOpts = case maps_utils:get_any([limit, <<"limit">>], Opts, undefined) of
        undefined ->
            ?FOLD_OPTS;
        Limit ->
            [{limit, Limit} | ?FOLD_OPTS]
    end,

    plum_db:fold(
        fun
            ({_, ?TOMBSTONE}, Acc) ->
                Acc;
            ({_, _} = Term, Acc) ->
                [from_term(Term)|Acc]
        end,
        [],
        Prefix,
        FoldOpts
    ).


%% -----------------------------------------------------------------------------
%% @doc Returns the external representation of the user `User'.
%% @end
%% -----------------------------------------------------------------------------
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


do_add(RealmUri, Keyword, #{type := source} = Source)
when Keyword == all orelse Keyword == anonymous ->
    Prefix = ?PLUMDB_PREFIX(RealmUri),
    Masked = anchor_mask(maps:get(cidr, Source)),
    %% TODO check if there are already 'user' sources for this CIDR
    %% with the same source
    ok = plum_db:put(Prefix, {Keyword, Masked}, Source),
    ok;

do_add(RealmUri, Usernames, #{type := source} = Source) ->
    Prefix = ?PLUMDB_PREFIX(RealmUri),

    %% We validate all usernames exist
    Unknown = bondy_rbac_user:unknown(RealmUri, Usernames),
    [] =:= Unknown orelse throw({unknown_users, Unknown}),

    Masked = anchor_mask(maps:get(cidr, Source)),

    _ = lists:foreach(
        fun(Username) ->
            %% prev we added {Authmethod, Meta} instead of Source
            plum_db:put(Prefix, {Username, Masked}, Source)
        end,
        Usernames
    ),
    ok.

%% @private
%% Returns the Key Value
%% Example:
%% [
%%     {{anonymous, {{0,0,0,0},0}},
%%     #{authmethod => <<"anonymous">>,...,version => <<"1.1">>}}]
%% }
do_match(RealmUri, Username) ->
    Prefix = ?PLUMDB_PREFIX(RealmUri),
    Opts = [{remove_tombstones, true} | ?FOLD_OPTS],
    plum_db:match(Prefix, {Username, '_'}, Opts).

%% @private
from_term({{Username, CIDR}, [{Authmethod, Options}]}) ->
    Meta = maps:from_list(Options),
    Source = #{
        username => Username,
        authmethod => Authmethod,
        meta => Meta,
        cidr => CIDR
    },
    {Username, type_and_version(Source)};

from_term(
    {{Username, CIDR}, #{type := source, version := ?VERSION} = Source}) ->
    Source#{
        username => Username,
        cidr => CIDR
    }.



%% @private
type_and_version(Map) ->
    Map#{
        version => ?VERSION,
        type => source
    }.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
mask_address({_, _, _, _} = Addr, Maskbits) ->
    B = list_to_binary(tuple_to_list(Addr)),
    <<Subnet:Maskbits, _Host/bitstring>> = B,
    Subnet;

mask_address({A, B, C, D, E, F, G, H}, Maskbits) ->
    <<Subnet:Maskbits, _Host/bitstring>> = <<
        A:16, B:16, C:16, D:16, E:16,F:16, G:16, H:16
    >>,
    Subnet.

%% -----------------------------------------------------------------------------
%% @private
%% @doc returns the real bottom of a netmask. Eg if 192.168.1.1/16 is
%% provided, return 192.168.0.0/16
%% @end
%% -----------------------------------------------------------------------------
anchor_mask({_, _, _, _} = Addr, Maskbits) ->
    M = mask_address(Addr, Maskbits),
    Rem = 32 - Maskbits,
    <<A:8, B:8, C:8, D:8>> = <<M:Maskbits, 0:Rem>>,
    {{A, B, C, D}, Maskbits};

anchor_mask({_, _, _, _, _, _, _, _} = Addr, Maskbits) ->
    M = mask_address(Addr, Maskbits),
    Rem = 128 - Maskbits,
    <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>> = <<M:Maskbits, 0:Rem>>,
    {{A, B, C, D, E, F, G, H}, Maskbits}.

anchor_mask({Addr, Mask}) ->
    anchor_mask(Addr, Mask).


sort_sources(Sources) ->
    %% sort sources first by userlist, so that 'all' matches come last
    %% and then by CIDR, so that most specific masks come first
    Sources1 = lists:sort(
        fun
            ({{all, _}, _}, {{all, _}, _}) ->
                true;
            ({{all, _}, _}, _) ->
                %% anything is greater than 'all'
                true;
            (_, {{all, _}, _}) ->
                false;
            (_, _) ->
                true
        end,
        Sources
    ),

    lists:sort(
        fun({{_, {_, MaskA}}, _}, {{_, {_, MaskB}}, _}) ->
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