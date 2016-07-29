%% =============================================================================
%% Copyright (C) NGINEO LIMITED 2011 - 2016. All rights reserved.
%% =============================================================================


-module(juno_group).

-type group() :: map().

-define(INFO_KEYS, [<<"description">>]).

-export([lookup/1]).
-export([add/1]).
-export([remove/1]).
-export([fetch/1]).
-export([list/0]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(group()) -> ok.
add(Group) ->
    Info = maps:with(?INFO_KEYS, Group),
    #{
        <<"name">> := BinName
    } = Group,
    Name = unicode:characters_to_list(BinName, utf8),
    Opts = [
        {<<"info">>, Info}
    ],
    juno_security:add_group(Name, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(list() | binary()) -> ok.
remove(Id) when is_binary(Id) ->
    remove(unicode:characters_to_list(Id, utf8));

remove(Id) ->
    case juno_security:del_group(Id) of
        ok -> 
            ok;
        {error, {unknown_group, Id}} ->
            {error, unknown_group}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(list() | binary()) -> group() | not_found.
lookup(Id) when is_binary(Id) ->
    lookup(unicode:characters_to_list(Id, utf8));

lookup(Id) ->
    case juno_security:lookup_group(Id) of
        not_found -> not_found;
        Obj -> to_map(Obj)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec fetch(list() | binary()) -> group() | no_return().
fetch(Id) when is_binary(Id) ->
    fetch(unicode:characters_to_list(Id, utf8));
    
fetch(Id) ->
    case lookup(Id) of
        not_found -> error(not_found);
        Obj -> Obj
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec list() -> list(group()).
list() ->
    [to_map(Obj) || Obj <- juno_security:list(group)].




%% =============================================================================
%% PRIVATE
%% =============================================================================




%% @private
to_map({Id, Opts}) ->
    Map0 = proplists:get_value(<<"info">>, Opts, #{}),
    Map0#{
        <<"name">> => Id
    }.



