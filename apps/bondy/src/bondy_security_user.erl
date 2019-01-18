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
-include("bondy_security.hrl").

-define(VALIDATE_USERNAME, fun
        (<<"all">>) ->
            false;
        ("all") ->
            false;
        (all) ->
            false;
        (_) ->
            true
    end
).

-define(SPEC, #{
    <<"username">> => #{
        alias => username,
        key => <<"username">>,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => binary,
        validator => ?VALIDATE_USERNAME
    },
    <<"password">> => #{
        alias => password,
        key => <<"password">>,
        required => true,
        allow_null => false,
        datatype => binary
    },
    <<"groups">> => #{
        alias => groups,
        key => <<"groups">>, %% bondy_security requirement
        allow_null => false,
        allow_undefined => false,
        required => true,
        default => [],
        datatype => {list, binary}
    },
    <<"meta">> => #{
        alias => meta,
        key => <<"meta">>,
        allow_null => false,
        allow_undefined => false,
        required => true,
        datatype => map,
        default => #{}
    }
}).

-define(UPDATE_SPEC, #{
    <<"password">> => #{
        alias => password,
        key => <<"password">>,
        required => false,
        allow_null => false,
        allow_undefined => false,
        datatype => binary
    },
    <<"groups">> => #{
        alias => groups,
        key => <<"groups">>, %% bondy_security requirement
        required => false,
        allow_null => false,
        allow_undefined => false,
        datatype => {list, binary}
    },
    <<"meta">> => #{
        alias => meta,
        key => <<"meta">>,
        allow_null => false,
        allow_undefined => false,
        required => false,
        datatype => map
    }
}).


-type t() :: map().

-export_type([t/0]).

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



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(uri(), t()) -> ok | {error, map()}.

add(RealmUri, User0) ->
    try
        User1 = maps_utils:validate(User0, ?SPEC),
        {L, R} = maps_utils:split([<<"username">>], User1),
        #{<<"username">> := Username} = L,
        PL = maps:to_list(R),

        case bondy_security:add_user(RealmUri, Username, PL) of
            ok ->
                ok = bondy_event_manager:notify(
                    {security_user_added, RealmUri, Username}),
                {ok, fetch(RealmUri, Username)};
            Error ->
                Error
        end
    catch
        error:Reason when is_map(Reason) ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update(uri(), binary(), t()) -> {ok, t()} | {error, any()}.

update(RealmUri, Username, User0) when is_binary(Username) ->
    try
        User1 = maps_utils:validate(User0, ?UPDATE_SPEC),
        Opts = maps:to_list(User1),
        case bondy_security:alter_user(RealmUri, Username, Opts) of
            {error, _} = Error ->
                Error;
            ok ->
                ok = bondy_event_manager:notify(
                    {security_user_updated, RealmUri, Username}),
                {ok, fetch(RealmUri, Username)}
        end
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
    bondy_security_source:remove(RealmUri, [Username], CIDR).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(uri(), binary() | map()) -> ok | {error, {unknown_user, binary()}}.

remove(RealmUri, #{<<"username">> := Username}) ->
    remove(RealmUri, Username);

remove(RealmUri, Username) ->
    case bondy_security:del_user(RealmUri, Username) of
        ok ->
            ok = bondy_event_manager:notify(
                    {security_user_deleted, RealmUri, Username}),
            ok;
        {error, _} = Error ->
            Error
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(uri(), binary()) -> t() | {error, not_found}.

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
-spec fetch(uri(), binary()) -> t() | no_return().

fetch(RealmUri, Id) ->
    case lookup(RealmUri, Id) of
        {error, _} = Error -> Error;
        User -> User
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec list(uri()) -> list(t()).

list(RealmUri) ->
    [to_map(RealmUri, User) || User <- bondy_security:list(RealmUri, user)].


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec password(uri(), t() | id()) -> map() | no_return().

password(RealmUri, #{<<"username">> := Username}) ->
    password(RealmUri, Username);

password(RealmUri, Username) ->
    case bondy_security:lookup_user(RealmUri, Username) of
        {error, Reason} ->
            error(Reason);
        {Username, Opts} ->
            case proplists:get_value(<<"password">>, Opts) of
                undefined -> undefined;
                L -> maps:from_list(L)
            end
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
change_password(RealmUri, Username, New) when is_binary(New) ->
    case update(RealmUri, Username, #{password => New}) of
        {ok, _} ->
            bondy_event_manager:notify(
                {security_password_changed, RealmUri, Username});
        Error ->
            Error
    end.




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
change_password(RealmUri, Username, New, Old) ->
    case catch password(RealmUri, Username) of
        {'EXIT', {Reason, _}} ->
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
        <<"groups">> => proplists:get_value(<<"groups">>, PL, []),
        <<"meta">> => proplists:get_value(<<"meta">>, PL, #{})
    },
    L = case bondy_security_source:list(RealmUri, Username) of
        {error, not_found} ->
            #{};
        Sources ->
            [maps:without([username], S) || S <- Sources]
    end,
    Map1#{<<"sources">> => L}.


%% @private
has_password(Opts) ->
    case proplists:get_value(<<"password">>, Opts) of
        undefined -> false;
        _ -> true
    end.




