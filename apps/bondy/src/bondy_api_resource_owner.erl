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

-define(ADD_SPEC, #{
    <<"groups">> => #{
        alias => groups,
        key => <<"groups">>, %% bondy_security requirement
        allow_null => false,
        allow_undefined => false,
        required => true,
        default => [],
        datatype => {list, binary}
    }
}).

-define(UPDATE_SPEC, #{
    <<"groups">> => #{
        alias => groups,
        key => <<"groups">>, %% bondy_security requirement
        required => false,
        allow_null => false,
        allow_undefined => false,
        datatype => {list, binary}
    }
}).

-export([add/2]).
-export([remove/2]).
-export([update/3]).
-export([change_password/4]).
-export([change_password/5]).



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
    %% We just validate we have a group, the rest will be validate by
    %% bondy_security_user
    case bondy_security_user:add(RealmUri, validate(Info0, ?ADD_SPEC)) of
        {ok, _} = OK ->
            OK;
        {error, _} = Error ->
            Error
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update(uri(), binary(), map()) ->
    {ok, map()} | {error, term()} | no_return().

update(RealmUri, Username, Info0) ->
    bondy_security_user:update(
        RealmUri, Username, validate(Info0, ?UPDATE_SPEC)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec change_password(uri(), binary(), binary(), binary()) ->
    ok | {error, any()}.

change_password(RealmUri, _Issuer, Username, New) when is_binary(New) ->
    bondy_security_user:change_password(RealmUri, Username, New).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec change_password(uri(), binary(), binary(), binary(), binary()) ->
    ok | {error, any()}.

change_password(RealmUri, _Issuer, Username, New, Old) ->
    bondy_security_user:change_password(RealmUri, Username, New, Old).



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
    %% We do this since maps_utils:validate will remove keys that have no spec
    %% So we only validate groups here
    {ToValidate, Rest} = maps_utils:split([<<"groups">>], Info0),
    Info1 = maps:merge(Rest, maps_utils:validate(ToValidate, Spec)),
    maybe_add_groups(Info1).


%% @private
maybe_add_groups(#{<<"groups">> := Groups0} = M) ->
    Groups1 = [<<"resource_owners">> | Groups0],
    maps:put(<<"groups">>, sets:to_list(sets:from_list(Groups1)), M);

maybe_add_groups(#{} = M) ->
    %% For update op
    M.

