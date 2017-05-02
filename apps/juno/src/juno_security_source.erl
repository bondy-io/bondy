%% =============================================================================
%% Copyright (C) NGINEO LIMITED 2011 - 2016. All rights reserved.
%% =============================================================================


-module(juno_security_source).
-include_lib("wamp/include/wamp.hrl").

-type source() :: map().

-define(INFO_KEYS, [<<"description">>]).

-export([add/5]).
-export([list/1]).
-export([list/2]).
-export([remove/3]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(
    RealmUri :: uri(), 
    Usernames :: [binary()] | all, 
    CIDR :: juno_security:cidr(), 
    Source :: atom(),
    Options :: list()) -> ok.
add(RealmUri, Usernames, CIDR, Source, Opts ) ->
    juno_security:add_source(RealmUri, Usernames, CIDR, Source, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(
    RealmUri :: uri(),
    Usernames :: [binary()] | all,
    CIDR :: juno_security:cidr()) -> ok.
remove(RealmUri, Usernames, CIDR) ->
    juno_security:del_source(RealmUri, Usernames, CIDR).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec list(uri(), list() | binary()) -> source() | not_found.
list(RealmUri, Username) when is_binary(Username) ->
    list(RealmUri, unicode:characters_to_list(Username, utf8));

list(RealmUri, Username) ->
    case juno_security:lookup_user_sources(RealmUri, Username) of
        not_found -> not_found;
        Sources -> [to_map(S) || S <- Sources]
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec list(uri()) -> list(source()).
list(RealmUri) ->
    [to_map(Obj) || Obj <- juno_security:list(RealmUri, source)].




%% =============================================================================
%% PRIVATE
%% =============================================================================




%% @private
to_map({Username, CIDR, Source, Opts} = _Obj) ->
    Map0 = proplists:get_value(<<"info">>, Opts, #{}),
    {Addr, Mask} = CIDR,
    CIDRStr = list_to_binary(
        io_lib:format("~s/~B", [inet_parse:ntoa(Addr), Mask])),
    Map0#{
        <<"username">> => Username,
        <<"cidr">> => CIDRStr,
        <<"source">> => list_to_binary(atom_to_list(Source)),
        <<"options">> => <<"TBD">> %%TODO
    }.




