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
            %% Reserved
            false;
        (all) ->
            %% Reserved
            false;
        (undefined) ->
            {ok, undefined};
        (null) ->
            {ok, undefined};
        (_) ->
            true
    end
).


-define(CLIENT_UPDATE_SPEC, #{
    <<"client_secret">> => #{
        alias => client_secret,
        key => <<"client_secret">>,
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
        allow_null => true,
        allow_undefined => true,
        datatype => map
    }
}).

-define(CLIENT_SPEC, #{
    <<"client_id">> => #{
        alias => client_id,
        key => <<"client_id">>,
        required => true,
        allow_null => true,
        allow_undefined => true,
        default => undefined,
        datatype => binary,
        validator => ?VALIDATE_USERNAME
    },
    <<"client_secret">> => #{
        alias => client_secret,
        key => <<"client_secret">>,
        required => true,
        allow_null => false,
        allow_undefined => false,
        datatype => binary,
        default => fun() ->
            bondy_oauth2:generate_fragment(48)
        end
    },
    <<"groups">> => #{
        alias => groups,
        key => <<"groups">>,
        required => true,
        allow_null => false,
        allow_undefined => false,
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
        ok = maybe_init_group(RealmUri),
        case validate(Info0, ?CLIENT_SPEC) of
            {undefined, _Info, _Opts} = Val ->
                %% We will generate a client_id and try 3 times
                %% This is to contemplate the unusual case in which the
                %% uuid generated has already been used
                %% (most probably due to manual input)
                do_add(RealmUri, Val, 3);
            Val ->
                do_add(RealmUri, Val, 0)
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
-spec update(uri(), binary(), map()) -> ok| {error, term()} | no_return().

update(RealmUri, ClientId, Info0) ->
    ok = maybe_init_group(RealmUri),
    {undefined, Opts, _} = validate(Info0, ?CLIENT_UPDATE_SPEC),
    bondy_security:alter_user(RealmUri, ClientId, Opts).


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
do_add(RealmUri, {undefined, Opts, Info}, Retries) ->
    Id = bondy_utils:uuid(),
    do_add(RealmUri, {Id, Opts, maps:put(<<"client_id">>, Id, Info)}, Retries);

do_add(RealmUri, {Id, Opts, Info}, Retries) ->
    case bondy_security:add_user(RealmUri, Id, Opts) of
        {error, role_exists} when Retries > 0 ->
            do_add(RealmUri, {undefined, Opts, Info}, Retries - 1);
        {error, _} = Error ->
            Error;
        ok ->
            {ok, Info}
    end.




%% @private
validate(Info0, Spec) ->
    Info1 = maps_utils:validate(Info0, Spec),
    Groups = [<<"api_clients">> | maps:get(<<"groups">>, Info1, [])],
    Opts = [{<<"groups">>, Groups} | maps:to_list(maps:with([<<"meta">>], Info1))],
    Pass = case maps:find(<<"client_secret">>, Info1) of
        {ok, Val} ->
            [{<<"password">>, Val}];
        error ->
            []
    end,
    Id = maps:get(<<"client_id">>, Info1, undefined),
    {Id, lists:append(Pass, Opts), Info1}.


%% @private
maybe_init_group(RealmUri) ->
    G = #{
        <<"name">> => <<"api_clients">>,
        <<"meta">> => #{
            <<"description">> => <<"A group of applications making protected resource requests through Bondy API Gateway by themselves or on behalf of a Resource Owner.">>
            }
    },
    case bondy_security_group:lookup(RealmUri, <<"api_clients">>) of
        {error, not_found} ->
            bondy_security_group:add(RealmUri, G);
        _ ->
            ok
    end.
