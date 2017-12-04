%% =============================================================================
%%  bondy_api.erl -
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

-module(bondy_api_resource_owner).
-include_lib("wamp/include/wamp.hrl").


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

-define(USER_SPEC,#{
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
        datatype => binary,
        default => fun() -> bondy_oauth2:generate_fragment(48) end
    },
    <<"groups">> => #{
        alias => groups,
        key => <<"groups">>,
        required => true,
        allow_null => false,
        datatype => {list, binary},
        default => []
    },
    <<"meta">> => #{
        alias => meta,
        key => <<"meta">>,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => map,
        default => #{}
    }
}).

-define(USER_UPDATE_SPEC,#{
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
        key => <<"groups">>,
        required => false,
        allow_null => true,
        allow_undefined => true,
        datatype => {list, binary}
    },
    <<"meta">> => #{
        alias => meta,
        key => <<"meta">>,
        required => false,
        allow_null => false,
        allow_undefined => false,
        datatype => map
    }
}).

-export([add/2]).
-export([remove/2]).
-export([update/3]).




%% =============================================================================
%% API
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @doc
%% Adds a resource owner (end-user or system) to realm RealmUri.
%% Creates a new user adding it to the `resource_owners' group.
%% @end
%% -----------------------------------------------------------------------------
-spec add(uri(), map()) ->
    {ok, map()} | {error, term()} | no_return().

add(RealmUri, Info0) ->
    {Username, Opts, Info1} = validate(Info0, ?USER_SPEC),
    case bondy_security:add_user(RealmUri, Username, Opts) of
        {error, _} = Error ->
            Error;
        ok ->
            {ok, Info1}
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update(uri(), binary(), map()) ->
    {ok, map()} | {error, term()} | no_return().

update(RealmUri, Username, Info0) ->
    {undefined, Opts, Info1} = validate(Info0, ?USER_UPDATE_SPEC),
    case bondy_security:alter_user(RealmUri, Username, Opts) of
        {error, _} = Error ->
            Error;
        ok ->
            {ok, Info1}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(uri(), list() | binary()) -> ok.

remove(RealmUri, Id) ->
    bondy_security_user:remove(RealmUri, Id).




%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
validate(Info0, Spec) ->
    Info1 = maps_utils:validate(Info0, Spec),
    Groups = [<<"resource_owners">> | maps:get(<<"groups">>, Info1, [])],
    Opts = [
        {<<"password">>, maps:get(<<"password">>, Info1)},
        {<<"groups">>, Groups} |
        maps:to_list(maps:with([<<"meta">>], Info1))
    ],
    Username = maps:get(<<"username">>, Info1, undefined),
    {Username, Opts, Info1}.





