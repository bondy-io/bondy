%% =============================================================================
%%  bondy_api_client.erl -
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

-module(bondy_api_client).
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


-define(CLIENT_UPDATE_SPEC, #{
    <<"client_secret">> => #{
        alias => client_secret,
        required => false,
        allow_null => false,
        allow_undefined => false,
        datatype => binary
    },
    <<"groups">> => #{
        alias => groups,
        required => false,
        allow_null => true,
        allow_undefined => true,
        datatype => {list, binary}
    },
    <<"meta">> => #{
        alias => meta,
        required => false,
        allow_null => true,
        allow_undefined => true,
        datatype => map
    }
}).

-define(CLIENT_SPEC, #{
    <<"client_id">> => #{
        alias => client_id,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => binary,
        validator => ?VALIDATE_USERNAME,
        default => fun() -> bondy_oauth2:generate_fragment(32) end
    },
    <<"client_secret">> => #{
        alias => client_secret,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => binary,
        default => fun() -> bondy_oauth2:generate_fragment(32) end
    },
    <<"groups">> => #{
        alias => groups,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => {list, binary},
        default => []
    },
    <<"meta">> => #{
        alias => meta,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => map,
        default => #{}
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
%% Adds an API client to realm RealmUri.
%% Creates a new user adding it to the `api_clients` group.
%% @end
%% -----------------------------------------------------------------------------
-spec add(uri(), map()) -> {ok, map()} | {error, atom() | map()}.

add(RealmUri, Info0) ->
    try
        ok = maybe_init_security(RealmUri),
        {Id, Opts, Info1} = validate(Info0, ?CLIENT_SPEC),
        case bondy_security:add_user(RealmUri, Id, Opts) of
            {error, _} = Error ->
                Error;
            ok ->
                {ok, Info1}
        end
    catch
        %% @TODO change for throw when maps_validate is upgraded
        error:Reason when is_map(Reason) ->
            {error, Reason}
    end.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update(uri(), binary(), map()) ->
    {ok, map()} | {error, term()} | no_return().

update(RealmUri, ClientId, Info0) ->
    ok = maybe_init_security(RealmUri),
    {undefined, Opts, Info1} = validate(Info0, ?CLIENT_UPDATE_SPEC),
    case bondy_security:alter_user(RealmUri, ClientId, Opts) of
        {error, _} = Error ->
            Error;
        ok ->
            {ok, Info1}
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(uri(), list() | binary()) -> ok | {error, unknown_user}.

remove(RealmUri, Id) ->
    bondy_security_user:remove(RealmUri, Id).




%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
validate(Info0, Spec) ->
    Info1 = maps_utils:validate(Info0, Spec),
    Groups = ["api_clients" | maps:get(<<"groups">>, Info1, [])],
    Opts = [
        {"password", maps:get(<<"client_secret">>, Info1)},
        {"groups", Groups} |
        maps:to_list(maps:with([<<"meta">>], Info1))
    ],
    Id = maps:get(<<"client_id">>, Info1, undefined),
    {Id, Opts, Info1}.


%% @private
maybe_init_security(RealmUri) ->
    G = #{
        <<"name">> => <<"api_clients">>,
        <<"meta">> => #{<<"description">> => <<"A group of applications making protected resource requests through Bondy API Gateway on behalf of the resource owner and with its authorisation.">>}
    },
    case bondy_security_group:lookup(RealmUri, <<"api_clients">>) of
        {error, not_found} ->
            bondy_security_group:add(RealmUri, G);
        _ ->
            ok
    end.