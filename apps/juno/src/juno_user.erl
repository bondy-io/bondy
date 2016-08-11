%% =============================================================================
%% Copyright (C) NGINEO LIMITED 2011 - 2016. All rights reserved.
%% =============================================================================


-module(juno_user).
-include("juno.hrl").
-include_lib("wamp/include/wamp.hrl").

-type user() :: map().

-define(INFO_KEYS, [
    <<"first_name">>, 
    <<"last_name">>,
    <<"email">>, 
    <<"external_id">>
]).

-export([lookup/1]).
-export([add/1]).
-export([remove/1]).
-export([fetch/1]).
-export([list/0]).
-export([password/1]).


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
    juno_security:add_user(Username, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(list() | binary()) -> ok.
remove(Id) when is_binary(Id) ->
    remove(unicode:characters_to_binary(Id, utf8, utf8));

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
lookup(Id) when is_list(Id) ->
    lookup(unicode:characters_to_binary(Id, utf8, utf8));

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
fetch(Id) when is_list(Id) ->
    fetch(unicode:characters_to_binary(Id, utf8, utf8));
    
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


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec password(user() | id()) -> map() | no_return().
password(#{<<"username">> := Username}) ->
    password(Username);

password(Username) ->
    case juno_security:lookup_user(Username) of
        not_found -> 
            error(not_found);
        {Username, Opts} ->
            case proplists:get_value("password", Opts) of
                undefined -> undefined;
                L -> maps:from_list(L)
            end
    end.




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
    Source = case juno_source:lookup(Username) of
        not_found ->
            #{};
        Obj ->
            maps:without([<<"username">>], Obj)
    end,
    Map1#{<<"source">> => Source}.


%% @private
has_password(Opts) ->
    case proplists:get_value("password", Opts) of
        undefined -> false;
        _ -> true
    end.




