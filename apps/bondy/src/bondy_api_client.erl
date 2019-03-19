%% =============================================================================
%%  bondy_api_client.erl -
%%
%%  Copyright (c) 2016-2019 Ngineo Limited t/a Leapsight. All rights reserved.
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
-module(bondy_api_client).
-include_lib("wamp/include/wamp.hrl").

-define(ADD_SPEC, #{
    <<"client_id">> => #{
        alias => client_id,
        %% We rename the key to comply with bondy_security_user:t()
        key => <<"username">>,
        required => true,
        allow_null => true,
        allow_undefined => true,
        default => undefined,
        datatype => binary
    },
    <<"client_secret">> => #{
        alias => client_secret,
        %% We rename the key to comply with bondy_security_user:t()
        key => <<"password">>,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => binary
    },
    <<"groups">> => #{
        alias => groups,
        key => <<"groups">>,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => {list, binary},
        default => []
    }
}).



-define(UPDATE_SPEC, #{
    <<"client_secret">> => #{
        alias => client_secret,
        %% We rename the key to comply with bondy_security_user:t()
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
%% Creates a new user adding it to the `api_clients' group.
%% @end
%% -----------------------------------------------------------------------------
-spec add(uri(), map()) -> {ok, map()} | {error, atom() | map()}.

add(RealmUri, Info0) ->
    case bondy_security_user:add(RealmUri, validate(Info0, ?ADD_SPEC)) of
        {ok, Info1} ->
            {ok, to_client(Info1)};
        {error, _} = Error ->
            Error
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update(uri(), binary(), map()) -> ok| {error, term()} | no_return().

update(RealmUri, ClientId, Info0) ->
    bondy_security_user:update(
        RealmUri, ClientId, validate(Info0, ?UPDATE_SPEC)).


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
    %% So we only validate groups the following list here
    With = [<<"groups">>, <<"client_id">>, <<"client_secret">>],
    {ToValidate, Rest} = maps_utils:split(With, Info0),
    Info1 = maps:merge(Rest, maps_utils:validate(ToValidate, Spec)),
    maybe_add_groups(Info1).


%% @private
maybe_add_groups(#{<<"groups">> := Groups0} = M) ->
    Groups1 = [<<"api_clients">> | Groups0],
    maps:put(<<"groups">>, sets:to_list(sets:from_list(Groups1)), M);

maybe_add_groups(#{} = M) ->
    %% For update op
    M.

to_client(Map) ->
    {L, R} = maps_utils:split([<<"username">>], Map),
    #{<<"username">> := Username} = L,
    maps:put(<<"client_id">>, Username, R).
