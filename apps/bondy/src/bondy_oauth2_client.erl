%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_oauth2_client).
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_oauth.hrl").

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
    Groups1 = [?API_CLIENTS | Groups0],
    maps:put(<<"groups">>, lists:usort(Groups1), M);

maybe_add_groups(#{} = M) ->
    %% For update op
    M.
