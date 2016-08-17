%% =============================================================================
%% Copyright (C) NGINEO LIMITED 2016. All rights reserved.
%% =============================================================================


-module(juno_security_admin_rh).
-include_lib("wamp/include/wamp.hrl").
% -include("juno.hrl").

-record(state, {
    realm_uri :: uri(),
    entity :: atom(),
    master :: atom(),
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
        master = maps:get(master, Opts, undefined),
        is_collection = maps:get(is_collection, Opts, false),
        is_immutable = maps:get(is_immutable, Opts, false),
        bindings = maps:from_list(cowboy_req:bindings(Req))
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
    try lookup(State0#state.entity, realm_uri(State0), id(State0)) of
        not_found ->
            {false, Req, State0};
        R ->
            {true, Req, State0#state{resource = R}}
    catch
        _:{badkey, id} ->
            R = list(State0#state.entity, State0),
            State1 = State0#state{resource = R},
            {true, Req, State1}
    end;

resource_exists(Req, State0) ->
    case lookup(State0#state.entity, realm_uri(State0), id(State0)) of
        not_found ->
            {false, Req, State0};
        R ->
            {true, Req, State0#state{resource = R}}
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
    Body = jsx:encode(State#state.resource),
    {Body, Req, State}.


from_json(Req, St) ->
    % TODO
    {true, Req, St}.





%% =============================================================================
%% PRIVATE
%% =============================================================================

id(State) ->
    maps:get(id, State#state.bindings).

realm_uri(#state{realm_uri = Uri}) ->
    Uri.

%% @private
lookup(user, RealmUri, Id) ->
    juno_user:lookup(RealmUri, Id);

lookup(group, RealmUri, Id) ->
    juno_group:lookup(RealmUri, Id).


%% @private
delete(user, State) ->
    
    juno_security:del_user(realm_uri(State), id(State));

delete(group, State) ->
    juno_security:del_group(realm_uri(State), id(State));

delete(source, #state{master = user} = State) ->
    juno_security:del_user_source(realm_uri(State), id(State)).


list(user, State) ->
    juno_user:list(realm_uri(State));

list(group, State) ->
    juno_group:list(realm_uri(State));

list(source, State) ->
    juno_source:list(realm_uri(State)).

%% @private
% add_user(Username, Password, Info) ->
%     case juno_security:add_user(Username, )
