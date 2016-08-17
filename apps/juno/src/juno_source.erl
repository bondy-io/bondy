%% =============================================================================
%% Copyright (C) NGINEO LIMITED 2011 - 2016. All rights reserved.
%% =============================================================================


-module(juno_source).
-include_lib("wamp/include/wamp.hrl").

-type source() :: map().

-define(INFO_KEYS, [<<"description">>]).

-export([lookup/2]).
-export([add/5]).
% -export([remove/1]).
-export([fetch/2]).
-export([list/1]).


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

% %% -----------------------------------------------------------------------------
% %% @doc
% %% @end
% %% -----------------------------------------------------------------------------
% -spec remove(list() | binary()) -> ok.
% remove(Id) when is_binary(Id) ->
%     remove(unicode:characters_to_list(Id, utf8));

% remove(Id) ->
%     case juno_security:del_user(Id) of
%         ok -> 
%             ok;
%         {error, {unknown_user, Id}} ->
%             {error, unknown_user}
%     end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(uri(), list() | binary()) -> source() | not_found.
lookup(RealmUri, Username) when is_binary(Username) ->
    lookup(RealmUri, unicode:characters_to_list(Username, utf8));

lookup(RealmUri, Username) ->
    case juno_security:lookup_user_source(RealmUri, Username) of
        not_found -> not_found;
        Obj -> to_map(Obj)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec fetch(uri(), list() | binary()) -> source() | no_return().
fetch(RealmUri, Id) when is_binary(Id) ->
    fetch(RealmUri, unicode:characters_to_list(Id, utf8));
    
fetch(RealmUri, Id) ->
    case lookup(RealmUri, Id) of
        not_found -> error(not_found);
        User -> User
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




