%% =============================================================================
%% Copyright (C) NGINEO LIMITED 2016. All rights reserved.
%% =============================================================================


-module(juno_admin_rh).
-include_lib("wamp/include/wamp.hrl").
% -include("juno.hrl").

-record(state, {
    realm_uri :: uri(),
    resource :: atom(),
    context :: juno_context:context()
}).

-export([allowed_methods/2]).
-export([content_types_provided/2]).
-export([init/2]).
-export([is_authorized/2]).
-export([resource_exists/2]).
-export([resource_existed/2]).
-export([to_json/2]).


%% ============================================================================
%% COWBOY CALLBACKS
%% ============================================================================


init(Req, #{resource := R}) ->
    Ctxt = juno_context:set_peer(juno_context:new(), cowboy_req:peer(Req)),
    St = #state{
        context = Ctxt,
        resource = R
    },
    {cowboy_rest, Req, St}.  


allowed_methods(Req, State) ->
  Ms = [<<"GET">>, <<"HEAD">>, <<"OPTIONS">>],
  {Ms, Req, State}.


content_types_provided(Req, State) ->
    Types = [
        {<<"application/json">>, to_json}
    ],
    {Types, Req, State}.


is_authorized(Req, State) ->
    {true, Req, State}.


resource_exists(Req, State) ->
    {true, Req, State}.


resource_existed(Req, State) ->
    {false, Req, State}.



to_json(Req, State) ->
    Map = #{
        <<"ws">> => <<"/ws">>,
        <<"publications">> => <<"/publications">>,
        <<"calls">> => <<"/calls">>
    },
    JSON = jsx:encode(Map),
    {JSON, Req, State}.
