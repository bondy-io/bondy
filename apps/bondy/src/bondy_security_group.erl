%% =============================================================================
%%  bondy_security_group.erl -
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

%% =============================================================================
%% Copyright (C) NGINEO LIMITED 2011 - 2016. All rights reserved.
%% =============================================================================


-module(bondy_security_group).
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
    bondy_security:add_group(RealmUri, Name, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(uri(), list() | binary()) -> ok.
remove(RealmUri, Id) when is_binary(Id) ->
    remove(RealmUri, unicode:characters_to_list(Id, utf8));

remove(RealmUri, Id) ->
    case bondy_security:del_group(RealmUri, Id) of
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
    case bondy_security:lookup_group(RealmUri, Id) of
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
    [to_map(Obj) || Obj <- bondy_security:list(RealmUri, group)].




%% =============================================================================
%% PRIVATE
%% =============================================================================




%% @private
to_map({Id, Opts}) ->
    Map0 = proplists:get_value(<<"info">>, Opts, #{}),
    Map0#{
        <<"name">> => Id
    }.



