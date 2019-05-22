%% =============================================================================
%%  bondy_security_group.erl -
%%
%%  Copyright (c) 2016-2018 Ngineo Limited t/a Leapsight. All rights reserved.
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
-module(bondy_security_group).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy_security.hrl").


-type t() :: map().


-export([add/2]).
-export([add_or_update/2]).
-export([update/3]).
-export([fetch/2]).
-export([list/1]).
-export([lookup/2]).
-export([remove/2]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(uri(), t()) -> ok | {error, any()}.

add(RealmUri, Group) ->
    try
        do_add(RealmUri, maps_utils:validate(Group, ?GROUP_SPEC))
    catch
        ?EXCEPTION(error, Reason, _) ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add_or_update(uri(), t()) -> ok.

add_or_update(RealmUri, Group) ->
    try
    #{<<"name">> := Name} = NewGroup = maps_utils:validate(Group, ?GROUP_SPEC),
        case do_add(RealmUri, NewGroup) of
            ok ->
                ok;
            {error, role_exists} ->
                Res = update(
                    RealmUri, Name, maps:without([<<"name">>], NewGroup)),
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
-spec update(uri(), binary(), t()) -> ok.

update(RealmUri, Name, Group0) when is_binary(Name) ->
    try
        Group1 = maps_utils:validate(Group0, ?GROUP_UPDATE_SPEC),
        bondy_security:alter_group(RealmUri, Name, maps:to_list(Group1)),
        bondy_event_manager:notify({security_group_updated, RealmUri, Name})
    catch
        ?EXCEPTION(error, Reason, _) ->
            {error, Reason}
    end.

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(uri(), binary()) -> ok | {error, any()}.

remove(RealmUri, Name) when is_binary(Name) ->
    case bondy_security:del_group(RealmUri, Name) of
        ok ->
            bondy_event_manager:notify(
                {security_group_deleted, RealmUri, Name});
        {error, {unknown_group, Name}} ->
            {error, unknown_group}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(uri(), list() | binary()) -> t() | {error, not_found}.

lookup(RealmUri, Name) when is_binary(Name) ->
    case bondy_security:lookup_group(RealmUri, Name) of
        {error, _} = Error ->
            Error;
        Group ->
            to_map(Group)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec fetch(uri(), list() | binary()) -> t() | no_return().

fetch(RealmUri, Name) ->
    case lookup(RealmUri, Name) of
        {error, Reason} -> error(Reason);
        Group -> Group
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec list(uri()) -> list(t()).

list(RealmUri) when is_binary(RealmUri) ->
    [to_map(Obj) || Obj <- bondy_security:list(RealmUri, group)].




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
do_add(RealmUri, Group) ->
    {#{<<"name">> := Name}, NewGroup} = maps_utils:split([<<"name">>], Group),
    Opts = maps:to_list(bondy_utils:to_binary_keys(NewGroup)),
    bondy_security:add_group(RealmUri, Name, Opts),
    bondy_event_manager:notify({security_group_added, RealmUri, Name}).


%% @private
to_map({Name, PL}) ->
    #{
        <<"name">> => Name,
        <<"groups">> => proplists:get_value(<<"groups">>, PL, []),
        <<"meta">> => proplists:get_value(<<"meta">>, PL, #{})
    }.

%% @private
ok_or_error({ok, _}) -> ok;
ok_or_error(Term) -> Term.