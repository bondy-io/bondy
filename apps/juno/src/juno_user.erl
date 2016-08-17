%% =============================================================================
%% Copyright (C) NGINEO LIMITED 2011 - 2016. All rights reserved.
%% =============================================================================


-module(juno_user).
-include("juno.hrl").
-include_lib("wamp/include/wamp.hrl").

-type user() :: map().

-define(INFO_KEYS, [
    first_name, 
    last_name,
    email, 
    enternal_id
]).

-export([add/2]).
-export([fetch/2]).
-export([list/1]).
-export([lookup/2]).
-export([password/2]).
-export([remove/2]).
-export([remove_source/3]).
-export([set_source/5]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(uri(), user()) -> ok.
add(RealmUri, User) ->
    Info = maps:with(?INFO_KEYS, User),
    #{username := BinName, password := Pass} = User,
    Username = unicode:characters_to_list(BinName, utf8),
    Opts = [
        {info, Info},
        {"password", binary_to_list(Pass)}
    ],
    juno_security:add_user(RealmUri, Username, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec set_source(
    RealmUri :: uri(), 
    Username :: binary(), 
    CIDR :: juno_security:cidr(), 
    Source :: atom(),
    Options :: list()) -> ok.
set_source(RealmUri, Username, CIDR, Source, Opts) ->
    juno_source:add(RealmUri, [Username], CIDR, Source, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove_source(
    RealmUri :: uri(),
    Usernames :: [binary()] | all,
    CIDR :: juno_security:cidr()) -> ok.
remove_source(RealmUri, Username, CIDR) ->
    juno_security:del_source(RealmUri, [Username], CIDR).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(uri(), list() | binary()) -> ok.
remove(RealmUri, Id) when is_binary(Id) ->
    remove(RealmUri, unicode:characters_to_binary(Id, utf8, utf8));

remove(RealmUri, Id) ->
    case juno_security:del_user(RealmUri, Id) of
        ok -> 
            ok;
        {error, {unknown_user, Id}} ->
            {error, unknown_user}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(uri(), list() | binary()) -> user() | not_found.
lookup(RealmUri, Id) when is_list(Id) ->
    lookup(RealmUri, unicode:characters_to_binary(Id, utf8, utf8));

lookup(RealmUri, Id) ->
    case juno_security:lookup_user(RealmUri, Id) of
        not_found -> not_found;
        User -> to_map(RealmUri, User)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec fetch(uri(), list() | binary()) -> user() | no_return().
fetch(RealmUri, Id) when is_list(Id) ->
    fetch(RealmUri, unicode:characters_to_binary(Id, utf8, utf8));
    
fetch(RealmUri, Id) ->
    case lookup(RealmUri, Id) of
        not_found -> error(not_found);
        User -> User
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec list(uri()) -> list(user()).
list(RealmUri) ->
    [to_map(RealmUri, User) || User <- juno_security:list(RealmUri, user)].


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec password(uri(), user() | id()) -> map() | no_return().
password(RealmUri, #{username := Username}) ->
    password(RealmUri, Username);

password(RealmUri, Username) ->
    case juno_security:lookup_user(RealmUri, Username) of
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
to_map(RealmUri, {Username, Opts} = User) ->
    Map0 = proplists:get_value(info, Opts, #{}),
    Map1 = Map0#{
        username => Username,
        <<"has_password">> => has_password(Opts),
        <<"groups">> => juno_security:user_groups(RealmUri, User)
    },
    Source = case juno_source:lookup(RealmUri, Username) of
        not_found ->
            #{};
        Obj ->
            maps:without([username], Obj)
    end,
    Map1#{<<"source">> => Source}.


%% @private
has_password(Opts) ->
    case proplists:get_value("password", Opts) of
        undefined -> false;
        _ -> true
    end.




