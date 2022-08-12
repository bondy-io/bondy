%% =============================================================================
%%  bondy_oauth2_client.erl -
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
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
-module(bondy_oauth2_client).
-include_lib("wamp/include/wamp.hrl").

-define(ADD_SPEC, #{
    <<"client_id">> => #{
        alias => client_id,
        %% We rename the key to comply with bondy_rbac_user:t()
        key => <<"username">>,
        required => true,
        allow_null => true,
        allow_undefined => true,
        default => undefined,
        datatype => binary
    },
    <<"client_secret">> => #{
        alias => client_secret,
        %% We rename the key to comply with bondy_rbac_user:t()
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
        %% We rename the key to comply with bondy_rbac_user:t()
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

-type t()       ::  bondy_rbac_user:t().

-export([add/2]).
-export([remove/2]).
-export([update/3]).
-export([to_external/1]).




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

add(RealmUri, Data) ->
    User = bondy_rbac_user:new(validate(Data, ?ADD_SPEC)),
    bondy_rbac_user:add(RealmUri, User).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update(uri(), binary(), map()) ->
    {ok , t()} | {error, term()} | no_return().

update(RealmUri, ClientId, Data0) ->
    Data = validate(Data0, ?UPDATE_SPEC),
    bondy_rbac_user:update(RealmUri, ClientId, Data).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(uri(), binary()) -> ok.

remove(RealmUri, ClientId) ->
    bondy_rbac_user:remove(RealmUri, ClientId).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec to_external(t()) -> map().

to_external(Client) ->
    bondy_rbac_user:to_external(Client).


%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
validate(Data0, Spec) ->
    %% We do this since maps_utils:validate will remove keys that have no spec
    %% So we only validate groups the following list here
    Data = maps_utils:validate(Data0, Spec, #{keep_unknown => true}),
    maybe_add_groups(Data).


%% @private
maybe_add_groups(#{<<"groups">> := Groups0} = M) ->
    Groups1 = [<<"api_clients">> | Groups0],
    maps:put(<<"groups">>, lists:usort(Groups1), M);

maybe_add_groups(#{} = M) ->
    %% For update op
    M.