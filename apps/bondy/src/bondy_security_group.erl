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

-module(bondy_security_group).
-include("bondy.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy_security.hrl").

-define(SPEC, ?UPDATE_SPEC#{
    <<"name">> => #{
        alias => name,
        key => <<"name">>,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => binary,
        validator => fun(X) ->
            {ok, ?CHARS2LIST(X)}
        end
    },
    <<"groups">> => #{
        alias => groups,
        key => <<"groups">>, %% bondy_security requirement
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

-define(UPDATE_SPEC, #{
    <<"groups">> => #{
        alias => groups,
        key => <<"groups">>, %% bondy_security requirement
        allow_null => false,
        allow_undefined => false,
        required => false,
        datatype => {list, binary}
    },
    <<"meta">> => #{
        alias => meta,
        allow_null => false,
        allow_undefined => false,
        required => false,
        datatype => map
    }
}).

-type group() :: map().


-export([add/2]).
-export([update/3]).
-export([fetch/2]).
-export([list/1]).
-export([lookup/2]).
-export([remove/2]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec add(uri(), group()) -> ok.

add(RealmUri, Group0) ->
    try
        Group1 = maps_utils:validate(Group0, ?SPEC),
        {#{<<"name">> := Name}, Opts} = maps_utils:split([<<"name">>], Group1),
        bondy_security:add_group(RealmUri, Name, maps:to_list(Opts)),
        _ = bondy:publish(
            #{}, ?GROUP_ADDED, [RealmUri, Name], #{},
            ?BONDY_PRIV_REALM_URI
        ),
        ok
    catch
        error:Reason ->
            {error, Reason}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update(uri(), binary(), group()) -> ok.

update(RealmUri, Name, Group0) when is_binary(Name) ->
    try
        Group1 = maps_utils:validate(Group0, ?UPDATE_SPEC),
        bondy_security:alter_group(RealmUri, Name, maps:to_list(Group1)),
        _ = bondy:publish(
            #{}, ?GROUP_UPDATED, [RealmUri, Name], #{},
            ?BONDY_PRIV_REALM_URI
        ),
        ok
    catch
        error:Reason ->
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
            _ = bondy:publish(
                #{}, ?GROUP_DELETED, [RealmUri, Name], #{},
                ?BONDY_PRIV_REALM_URI
            ),
            ok;
        {error, {unknown_group, Name}} ->
            {error, unknown_group}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec lookup(uri(), list() | binary()) -> group() | {error, not_found}.

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
-spec fetch(uri(), list() | binary()) -> group() | no_return().

fetch(RealmUri, Name) ->
    case lookup(RealmUri, Name) of
        {error, Reason} -> error(Reason);
        Group -> Group
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec list(uri()) -> list(group()).

list(RealmUri) when is_binary(RealmUri) ->
    [to_map(Obj) || Obj <- bondy_security:list(RealmUri, group)].




%% =============================================================================
%% PRIVATE
%% =============================================================================




%% @private
to_map({Name, PL}) ->
    #{
        <<"name">> => Name,
        <<"groups">> => proplists:get_value(<<"groups">>, PL, []),
        <<"meta">> => proplists:get_value(<<"meta">>, PL, #{})
    }.



