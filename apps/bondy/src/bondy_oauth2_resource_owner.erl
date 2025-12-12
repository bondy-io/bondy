%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_oauth2_resource_owner).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_oauth.hrl").

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
-define(TYPE, outh2_resource_owner).

-type t()       ::  bondy_rbac_user:t().

-export([add/2]).
-export([remove/2]).
-export([update/3]).
-export([change_password/4]).
-export([change_password/5]).
-export([to_external/1]).


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

add(RealmUri, Data) ->
    %% We just validate we have a group, the rest will be validate by
    %% bondy_rbac_user
    User = bondy_rbac_user:new(validate(Data, ?ADD_SPEC)),
    bondy_rbac_user:add(RealmUri, User).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec update(uri(), binary(), map()) ->
    {ok, t()} | {error, term()} | no_return().

update(RealmUri, ClientId, Data0) ->
    Data = validate(Data0, ?UPDATE_SPEC),
    bondy_rbac_user:update(RealmUri, ClientId, Data).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec change_password(uri(), binary(), binary(), binary()) ->
    ok | {error, any()}.

change_password(RealmUri, _Issuer, Username, New) when is_binary(New) ->
    bondy_rbac_user:change_password(RealmUri, Username, New).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec change_password(uri(), binary(), binary(), binary(), binary()) ->
    ok | {error, any()}.

change_password(RealmUri, _Issuer, Username, New, Old) ->
    bondy_rbac_user:change_password(RealmUri, Username, New, Old).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec remove(uri(), list() | binary()) -> ok.

remove(RealmUri, Id) ->
    bondy_rbac_user:remove(RealmUri, Id).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec to_external(t()) -> map().

to_external(Owner) ->
    bondy_rbac_user:to_external(Owner).


%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
validate(Data0, Spec) ->
    %% We do this since maps_utils:validate will remove keys that have no spec
    %% So we only validate groups here
    Data = maps_utils:validate(Data0, Spec, #{keep_unknown => true}),
    maybe_add_groups(Data).


%% @private
maybe_add_groups(#{<<"groups">> := Groups0} = M) ->
    Groups1 = [?RESOURCE_OWNERS | Groups0],
    maps:put(<<"groups">>, lists:usort(Groups1), M);

maybe_add_groups(#{} = M) ->
    %% For update op
    M.
