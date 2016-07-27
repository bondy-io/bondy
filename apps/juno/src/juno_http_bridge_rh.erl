%% =============================================================================
%% Copyright (C) NGINEO LIMITED 2016. All rights reserved.
%% =============================================================================


-module(juno_http_bridge_rh).
-include_lib("wamp/include/wamp.hrl").
% -include("juno.hrl").

-record(state, {
    realm_uri :: uri(),
    resource :: atom(),
    context :: juno_context:context()
}).

-define(DELETE, <<"DELETE">>).
-define(GET, <<"GET">>).
-define(HEAD, <<"HEAD">>).
-define(OPTIONS, <<"OPTIONS">>).
-define(POST, <<"POST">>).
-define(PUT, <<"PUT">>).

-export([allowed_methods/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([init/2]).
-export([is_authorized/2]).
-export([resource_exists/2]).
-export([resource_existed/2]).
-export([to_json/2]).
-export([from_json/2]).


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


allowed_methods(Req, #state{resource = entry_point} = St) ->
  Ms = [?OPTIONS, ?GET],
  {Ms, Req, St};

allowed_methods(Req, #state{resource = call} = St) ->
  Ms = [?OPTIONS, ?POST],
  {Ms, Req, St};

allowed_methods(Req, #state{resource = event} = St) ->
  Ms = [?OPTIONS, ?POST],
  {Ms, Req, St};

allowed_methods(Req, St) ->
  Ms = [?DELETE, ?GET, ?HEAD, ?OPTIONS, ?POST, ?PUT],
  {Ms, Req, St}.



content_types_provided(Req, State) ->
    Types = [
        {<<"application/json">>, to_json}
    ],
    {Types, Req, State}.


content_types_accepted(Req, State) ->
    Types = [
        {<<"application/json">>, from_json}
    ],
    {Types, Req, State}.


is_authorized(Req, State) ->
    % @TODO
    juno_rest_utils:is_authorized(
        Req, fun(Realm) -> State#state{realm_uri = Realm} end).


resource_exists(Req, State) ->
    {true, Req, State}.


resource_existed(Req, State) ->
    {false, Req, State}.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
from_json(Req0, St) ->
    try
        {ok, Data, Req1} = cowboy_req:body(Req0),
        Obj = jsx:decode(Data, [return_maps]),
        do_from_json(Obj, Req1, St)
    catch
        _:Reason ->
            io:format(
                "Error ~p~n Stack ~p~n", [Reason, erlang:get_stacktrace()]),
            lager:debug(
                "Error ~p~n Stack ~p~n", [Reason, erlang:get_stacktrace()]),
            % {false, lsd_rest_utils:set_resp_error_body(Reason, Req), St}
            {false, Req0, St}
    end.


to_json(Req, #state{resource = entry_point} = St) ->
    Map = #{
        <<"ws">> => <<"/ws">>,
        <<"publications">> => <<"/publications">>,
        <<"calls">> => <<"/calls">>,
        <<"subscriptions">> => <<"/subscriptions">>,
        <<"registrations">> => <<"/registrations">>
    },
    JSON = jsx:encode(Map),
    {JSON, Req, St}.




%% =============================================================================
%% PRIVATE
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
do_from_json(_Obj, Req, #state{resource = call} = St) ->
    % TODO
    {ok, Req, St};

do_from_json(_Obj, Req, #state{resource = event} = St) ->
    % TODO
    {ok, Req, St};

do_from_json(_Obj, Req, #state{resource = subscription} = St) ->
    % TODO
    {ok, Req, St};

do_from_json(Obj, Req0, #state{resource = registration} = St) ->
    #{<<"procedure">> := ProcUri} = Obj,
    Opts = maps:without([<<"procedure">>], Obj),
    {ok, Id} = juno_rpc:register(ProcUri, Opts, St#state.context),
    Body = jsx:encode(#{registration_id => Id}),
    Req1 = cowboy_req:set_resp_body(Body, Req0),
    {ok, Req1, St}.

