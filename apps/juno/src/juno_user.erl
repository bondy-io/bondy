%% =============================================================================
%% Copyright (C) NGINEO LIMITED 2011 - 2016. All rights reserved.
%% =============================================================================


-module(juno_user).

-type user() :: map().

-define(INFO_KEYS, [<<"first_name">>, <<"last_name">>, <<"email">>]).

-export([lookup/1]).
-export([add/1]).
-export([remove/1]).
-export([fetch/1]).
-export([list/0]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(user()) -> ok.
add(User) ->
    Info = maps:with(?INFO_KEYS, User),
    #{
        <<"username">> := BinName
    } = User,
    Username = unicode:characters_to_list(BinName, utf8),
    Opts = [
        {<<"info">>, Info}
    ],
    case juno_security:add_user(Username, Opts) of
        ok ->
            ok;
        {error, role_exists} ->
            {error, user_exists}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(list() | binary()) -> ok.
remove(Id) when is_binary(Id) ->
    remove(unicode:characters_to_list(Id, utf8));

remove(Id) ->
    case juno_security:del_user(Id) of
        ok -> 
            ok;
        {error, {unknown_user, Id}} ->
            {error, unknown_user}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(list() | binary()) -> user() | not_found.
lookup(Id) when is_binary(Id) ->
    lookup(unicode:characters_to_list(Id, utf8));

lookup(Id) ->
    case juno_security:lookup_user(Id) of
        not_found -> not_found;
        User -> to_map(User)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec fetch(list() | binary()) -> user() | no_return().
fetch(Id) when is_binary(Id) ->
    fetch(unicode:characters_to_list(Id, utf8));
    
fetch(Id) ->
    case lookup(Id) of
        not_found -> error(not_found);
        User -> User
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec list() -> list(user()).
list() ->
    [to_map(User) || User <- juno_security:list(user)].




%% =============================================================================
%% PRIVATE
%% =============================================================================




%% @private
to_map({Username, Opts} = User) ->
    Map0 = proplists:get_value(<<"info">>, Opts, #{}),
    Map1 = Map0#{
        <<"username">> => Username,
        <<"has_password">> => has_password(Opts),
        <<"groups">> => juno_security:user_groups(User)
    },
    case juno_source:lookup(Username) of
        not_found ->
            Map1;
        Source ->
            Map1#{<<"source">> => Source}
    end.


%% @private
has_password(Opts) ->
    case proplists:get_value("password", Opts) of
        undefined -> false;
        _ -> true
    end.



