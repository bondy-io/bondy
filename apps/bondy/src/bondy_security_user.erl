%% =============================================================================
%%  bondy_security_user.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
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
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_security_user).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy_security.hrl").

-type t()           ::  map().

-export_type([t/0]).

-export([add/2]).
-export([add_or_update/2]).
-export([add_source/5]).
-export([change_password/3]).
-export([change_password/4]).
-export([fetch/2]).
-export([groups/1]).
-export([has_password/1]).
-export([has_users/1]).
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

add(RealmUri, User) ->
    try
        do_add(RealmUri, maps_utils:validate(User, ?USER_SPEC))
    catch
        ?EXCEPTION(error, Reason, _) when is_map(Reason) ->
            {error, Reason}
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add_or_update(uri(), t()) -> ok.

add_or_update(RealmUri, User) ->
    try
        NewUser = maps_utils:validate(User, ?USER_SPEC),
        #{<<"username">> := Username} = NewUser,

        case do_add(RealmUri, NewUser) of
            {ok, _} = OK ->
                OK;
            {error, role_exists} ->
                Res = update(
                    RealmUri,
                    Username,
                    maps:without([<<"username">>], NewUser)
                ),
                ok_or_error(Res);
            {error, _} = Error ->
                Error
        end
    catch
        ?EXCEPTION(error, Reason, _) ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update(uri(), binary(), t()) -> {ok, t()} | {error, any()}.

update(RealmUri, Username, User0) when is_binary(Username) ->
    try
        User1 = maps_utils:validate(User0, ?USER_UPDATE_SPEC),
        Opts = maps:to_list(bondy_utils:to_binary_keys(User1)),
        case bondy_security:alter_user(RealmUri, Username, Opts) of
            {error, _} = Error ->
                Error;
            ok ->
                ok = bondy_event_manager:notify(
                    {security_user_updated, RealmUri, Username}),
                {ok, fetch(RealmUri, Username)}
        end
    catch
        ?EXCEPTION(error, Reason, _) when is_map(Reason) ->
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
has_password(#{<<"has_password">> := Val}) -> Val.


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
has_users(RealmUri) ->
    Result = plum_db:match(
        {security_users, RealmUri},
        '_',
        [{limit, 1}, {resolver, lww}, {remove_tombstones, true}]
    ),
    Result =/= '$end_of_table'.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec password(uri(), t() | id()) -> bondy_security_pw:t() | no_return().

password(RealmUri, #{<<"username">> := Username}) ->
    password(RealmUri, Username);

password(RealmUri, Username) ->
    case bondy_security:lookup_user(RealmUri, Username) of
        {error, Reason} ->
            error(Reason);
        {Username, Opts} ->
            case proplists:get_value(<<"password">>, Opts) of
                undefined ->
                    undefined;
                PW ->
                    %% In previous versions we stored a proplists,
                    %% we ensure we return a map but we do not trigger
                    %% a password version upgrade. Upgrades will be forced
                    %% during authentication or can be done by batch migration
                    %% process.
                    bondy_security_pw:to_map(PW)
            end
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
change_password(RealmUri, Username, New) when is_binary(New) ->
    case update(RealmUri, Username, #{<<"password">> => New}) of
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
        PW ->
            case bondy_security_pw:check_password(Old, PW) of
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
do_add(RealmUri, User) ->
    {L, R} = maps_utils:split([<<"username">>], User),
    #{<<"username">> := Username} = L,
    PL = maps:to_list(R),

    case bondy_security:add_user(RealmUri, Username, PL) of
        ok ->
            ok = bondy_event_manager:notify(
                {security_user_added, RealmUri, Username}),
            {ok, fetch(RealmUri, Username)};
        Error ->
            Error
    end.


%% @private
to_map(RealmUri, {Username, Opts}) ->
    Password = proplists:get_value(<<"password">>, Opts, undefined),
    HasPassword = Password =/= undefined,

    Map1 = #{
        <<"username">> => Username,
        <<"has_password">> => HasPassword,
        <<"groups">> => proplists:get_value(<<"groups">>, Opts, []),
        <<"meta">> => proplists:get_value(<<"meta">>, Opts, #{})
    },
    L = case bondy_security_source:list(RealmUri, Username) of
        {error, not_found} ->
            #{};
        Sources ->
            [maps:without([<<"username">>], S) || S <- Sources]
    end,
    Map1#{<<"sources">> => L}.


%% @private
ok_or_error({ok, _}) -> ok;
ok_or_error(Term) -> Term.


