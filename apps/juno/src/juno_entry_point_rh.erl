%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%% A cowboy REST resource handler for the API entrypoint i.e. '/'.
%% @end
%% =============================================================================
-module(juno_entry_point_rh).
%% -behaviour(cowboy_rest).

-export([allowed_methods/2]).
-export([content_types_provided/2]).
-export([init/3]).
-export([rest_init/2]).
-export([is_authorized/2]).
-export([resource_exists/2]).
-export([resource_existed/2]).
-export([to_json/2]).


%% ============================================================================
%% COWBOY CALLBACKS
%% ============================================================================


init({tcp, http}, _Req, _Opts) ->
    {upgrade, protocol, cowboy_rest}.


rest_init(Req, _Opts) ->
    {ok, Req, undefined}.


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
