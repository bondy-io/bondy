%% =============================================================================
%%  bondy_security_user.erl -
%%
%%  Copyright (c) 2016-2017 Ngineo Limited t/a Leapsight. All rights reserved.
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

-module(bondy_security_user).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").

-type user() :: map().

-define(UPDATE_SPEC, #{
    <<"password">> => #{
        alias => password,
        key => "password",
        required => false,
        datatype => binary,
        validator => fun(X) ->
            {ok, ?CHARS2LIST(X)}
        end
    },
    <<"groups">> => #{
        alias => groups,
        key => "groups", %% bondy_security requirement
        allow_null => false,
        allow_undefined => false,
        required => true,
        datatype => {list, binary},
        default => []
    },
    <<"meta">> => #{
        alias => meta,
        allow_null => false,
        allow_undefined => false,
        required => true,
        datatype => map,
        default => #{}
    }
}).

-define(SPEC, ?UPDATE_SPEC#{
    <<"username">> => #{
        alias => username,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => binary,
        validator => fun(X) ->
            {ok, ?CHARS2LIST(X)}
        end
    }
}).

-export([add/2]).
-export([add_source/5]).
-export([change_password/3]).
-export([change_password/4]).
-export([fetch/2]).
-export([groups/1]).
-export([list/1]).
-export([lookup/2]).
-export([password/2]).
-export([remove/2]).
-export([remove_source/3]).
-export([update/3]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(uri(), user()) -> ok | {error, map()}.

add(RealmUri, User0) ->
    try
        User1 = maps_utils:validate(User0, ?SPEC),
        {#{<<"username">> := Username}, Opts} = maps_utils:split(
            [<<"username">>], User1),
        bondy_security:add_user(RealmUri, Username, maps:to_list(Opts))
    catch
        error:Reason when is_map(Reason) ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update(uri(), binary(), user()) -> ok.

update(RealmUri, Username, User0) when is_binary(Username) ->
    update(RealmUri, ?CHARS2LIST(Username), User0);

update(RealmUri, Username, User0) ->
    try
        User1 = maps_utils:validate(User0, ?UPDATE_SPEC),
        bondy_security:alter_user(RealmUri, Username, maps:to_list(User1))
    catch
        %% Todo change to throw when upgrade to new utils
        error:Reason when is_map(Reason) ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
groups(#{<<"groups">> := Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add_source(
    RealmUri :: uri(),
    Username :: binary(),
    CIDR :: bondy_security:cidr(),
    Source :: atom(),
    Options :: list()) -> ok.
add_source(RealmUri, Username, CIDR, Source, Opts) ->
    bondy_security_source:add(RealmUri, [Username], CIDR, Source, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove_source(
    RealmUri :: uri(),
    Usernames :: [binary()] | all,
    CIDR :: bondy_security:cidr()) -> ok.

remove_source(RealmUri, Username, CIDR) ->
    bondy_security:del_source(RealmUri, [Username], CIDR).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(uri(), list() | binary()) -> ok | {error, unknown_user}.

remove(RealmUri, Id) when is_list(Id) ->
    remove(RealmUri, unicode:characters_to_binary(Id, utf8, utf8));

remove(RealmUri, Id) ->
    case bondy_security:del_user(RealmUri, Id) of
        ok ->
            ok;
        {error, {unknown_user, Id}} ->
            {error, unknown_user}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(uri(), list() | binary()) -> user() | {error, not_found}.

lookup(RealmUri, Id) when is_list(Id) ->
    lookup(RealmUri, unicode:characters_to_binary(Id, utf8, utf8));

lookup(RealmUri, Id) ->
    case bondy_security:lookup_user(RealmUri, Id) of
        {error, _} = Error ->
            Error;
        User ->
            to_map(RealmUri, User)
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
        {error, _} = Error -> Error;
        User -> User
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec list(uri()) -> list(user()).
list(RealmUri) ->
    [to_map(RealmUri, User) || User <- bondy_security:list(RealmUri, user)].


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec password(uri(), user() | id()) -> map() | no_return().
password(RealmUri, #{username := Username}) ->
    password(RealmUri, Username);

password(RealmUri, Username) ->
    case bondy_security:lookup_user(RealmUri, Username) of
        {error, Reason} ->
            error(Reason);
        {Username, Opts} ->
            case proplists:get_value("password", Opts) of
                undefined -> undefined;
                L -> maps:from_list(L)
            end
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
change_password(RealmUri, Username, New) when is_binary(New) ->
    update(RealmUri, Username, #{password => New}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
change_password(RealmUri, Username, New, Old) ->
    case catch password(RealmUri, Username) of
        {'EXIT',{Reason, _}} ->
            {error, Reason};
        Password ->
            case bondy_security_pw:check_password(Old, Password) of
                true ->
                    change_password(RealmUri, Username, New);
                false ->
                    {error, bad_password}
            end
    end.




%% =============================================================================
%% PRIVATE
%% =============================================================================




%% @private
to_map(RealmUri, {Username, PL}) ->
    Map1 = #{
        <<"username">> => Username,
        <<"has_password">> => has_password(PL),
        <<"groups">> => proplists:get_value("groups", PL, []),
        <<"meta">> => proplists:get_value(<<"meta">>, PL, #{})
    },
    L = case bondy_security_source:list(RealmUri, Username) of
        {error, not_found} ->
            #{};
        Sources ->
            [maps:without([username], S) || S <- Sources]
    end,
    Map1#{sources => L}.


%% @private
has_password(Opts) ->
    case proplists:get_value("password", Opts) of
        undefined -> false;
        _ -> true
    end.




