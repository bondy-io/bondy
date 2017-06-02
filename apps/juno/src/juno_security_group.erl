%% =============================================================================
%% Copyright (C) NGINEO LIMITED 2011 - 2016. All rights reserved.
%% =============================================================================


-module(juno_security_group).
-include_lib("wamp/include/wamp.hrl").

-type group() :: map().

-define(INFO_KEYS, [<<"description">>]).

-export([add/2]).
-export([fetch/2]).
-export([list/1]).
-export([lookup/2]).
-export([remove/2]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(uri(), group()) -> ok.
add(RealmUri, Group) ->
    Info = maps:with(?INFO_KEYS, Group),
    #{
        <<"name">> := BinName
    } = Group,
    Name = unicode:characters_to_list(BinName, utf8),
    Opts = [
        {<<"info">>, Info}
    ],
    juno_security:add_group(RealmUri, Name, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(uri(), list() | binary()) -> ok.
remove(RealmUri, Id) when is_binary(Id) ->
    remove(RealmUri, unicode:characters_to_list(Id, utf8));

remove(RealmUri, Id) ->
    case juno_security:del_group(RealmUri, Id) of
        ok -> 
            ok;
        {error, {unknown_group, Id}} ->
            {error, unknown_group}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(uri(), list() | binary()) -> group() | not_found.
lookup(RealmUri, Id) when is_list(Id) ->
    lookup(RealmUri, unicode:characters_to_binary(Id, utf8, utf8));

lookup(RealmUri, Id) when is_binary(Id) ->
    case juno_security:lookup_group(RealmUri, Id) of
        not_found -> not_found;
        Obj -> to_map(Obj)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec fetch(uri(), list() | binary()) -> group() | no_return().
fetch(RealmUri, Id) when is_binary(Id) ->
    fetch(RealmUri, unicode:characters_to_list(Id, utf8));
    
fetch(RealmUri, Id) ->
    case lookup(RealmUri, Id) of
        not_found -> error(not_found);
        Obj -> Obj
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec list(uri()) -> list(group()).
list(RealmUri) ->
    [to_map(Obj) || Obj <- juno_security:list(RealmUri, group)].




%% =============================================================================
%% PRIVATE
%% =============================================================================




%% @private
to_map({Id, Opts}) ->
    Map0 = proplists:get_value(<<"info">>, Opts, #{}),
    Map0#{
        <<"name">> => Id
    }.



