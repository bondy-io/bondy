%% =============================================================================
%% Copyright (C) NGINEO LIMITED 2016. All rights reserved.
%% =============================================================================


-module(juno_security_admin_rh).
-include_lib("wamp/include/wamp.hrl").
% -include("juno.hrl").

-record(state, {
    realm_uri :: uri(),
    entity :: atom(),
    property :: atom(),
    resource :: any(),
    is_collection :: boolean(),
    is_immutable :: boolean(),
    context :: juno_context:context(),
    bindings :: map()
}).

-export([allowed_methods/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([init/2]).
-export([delete_resource/2]).
-export([is_authorized/2]).
-export([resource_exists/2]).
-export([resource_existed/2]).
-export([from_json/2]).
-export([to_json/2]).


%% ============================================================================
%% COWBOY CALLBACKS
%% ============================================================================


init(Req, Opts) ->
    Ctxt = juno_context:set_peer(juno_context:new(), cowboy_req:peer(Req)),
    St = #state{
        context = Ctxt,
        entity = maps:get(entity, Opts),
        property = maps:get(property, Opts, undefined),
        is_collection = maps:get(is_collection, Opts, false),
        is_immutable = maps:get(is_immutable, Opts, false),
        bindings = cowboy_req:bindings(maps:from_list(Req))
    },
    {cowboy_rest, Req, St}.  


allowed_methods(Req, #state{is_collection = true} = State) ->
    Ms = [<<"GET">>, <<"HEAD">>, <<"OPTIONS">>] 
    ++ [<<"POST">> || not State#state.is_immutable],
    {Ms, Req, State};

allowed_methods(Req, #state{is_collection = false} = State) ->
    Ms = [<<"GET">>, <<"HEAD">>, <<"OPTIONS">>] 
    ++ [X || X <- [<<"PUT">>, <<"DELETE">>], not State#state.is_immutable],
    {Ms, Req, State}.


content_types_provided(Req, State) ->
    Types = [
        {<<"application/json">>, to_json}
    ],
    {Types, Req, State}.


content_types_accepted(Req, #state{is_immutable = true} = State) ->
    {[], Req, State};

content_types_accepted(Req, State) ->
    Types = [
        {<<"application/json">>, from_json}
    ],
    {Types, Req, State}.


is_authorized(Req, State) ->
    %% Check that the user has RBAC permissions
    {true, Req, State}.


resource_exists(Req, #state{is_collection = true} = State0) ->
    case maps:get(id, State0#state.bindings, undefined) of
        undefined ->
            {true, Req, State0};
        Id ->
            case lookup(State0#state.entity, Id) of
                not_found ->
                    {false, Req, State0};
                R ->
                    {true, Req, State0#state{resource = R}}
            end
    end.


resource_existed(Req, State) ->
    {false, Req, State}.


delete_resource(Req0, State) ->
    case delete(State#state.entity, State) of
        ok ->
            {true, Req0, State};
        {error, Reason} ->
            Req1 = pbs_rest_utils:set_resp_error_body(Reason, Req0),
            {false, Req1, State}
    end.


to_json(Req, State) ->
    Map = #{
        <<"ws">> => <<"/ws">>,
        <<"publications">> => <<"/publications">>,
        <<"calls">> => <<"/calls">>
    },
    JSON = jsx:encode(Map),
    {JSON, Req, State}.


from_json(Req, St) ->
    {true, Req, St}.





%% =============================================================================
%% PRIVATE
%% =============================================================================

id(State) ->
    maps:get(id, State#state.bindings).


%% @private
lookup(user, Id) ->
    juno_security:lookup_user(Id);

lookup(group, Id) ->
    juno_security:lookup_group(Id).


%% @private
delete(user, #state{property = source} = State) ->
    juno_security:del_user_source(id(State));

delete(user, State) ->
    juno_security:del_user(id(State));

delete(group, State) ->
    juno_security:del_group(id(State)).


%% @private
% add_user(Username, Password, Info) ->
%     case juno_security:add_user(Username, )
