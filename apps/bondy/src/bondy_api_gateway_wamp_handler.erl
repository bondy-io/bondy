-module(bondy_api_gateway_wamp_handler).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_security.hrl").



%% -----------------------------------------------------------------------------
%% com.leapsight.bondy.api_gateway
%% -----------------------------------------------------------------------------
-define(LOAD_API,
    <<"com.leapsight.bondy.api_gateway.load">>
).
-define(CLIENT_LIST,
    <<"com.leapsight.bondy.api_gateway.list_clients">>
).
-define(CLIENT_LOOKUP,
    <<"com.leapsight.bondy.api_gateway.fetch_client">>
).
-define(ADD_CLIENT,
    <<"com.leapsight.bondy.api_gateway.add_client">>
).
-define(CLIENT_ADDED,
    <<"com.leapsight.bondy.api_gateway.client_added">>
).
-define(DELETE_CLIENT,
    <<"com.leapsight.bondy.api_gateway.delete_client">>
).
-define(CLIENT_DELETED,
    <<"com.leapsight.bondy.api_gateway.client_deleted">>
).
-define(UPDATE_CLIENT,
    <<"com.leapsight.bondy.api_gateway.update_client">>
).
-define(CLIENT_UPDATED,
    <<"com.leapsight.bondy.api_gateway.client_updated">>
).
-define(LIST_RESOURCE_OWNERS,
    <<"com.leapsight.bondy.api_gateway.list_resource_owners">>
).
-define(FETCH_RESOURCE_OWNER,
    <<"com.leapsight.bondy.api_gateway.fetch_resource_owner">>
).
-define(ADD_RESOURCE_OWNER,
    <<"com.leapsight.bondy.api_gateway.add_resource_owner">>
).
-define(RESOURCE_OWNER_ADDED,
    <<"com.leapsight.bondy.api_gateway.resource_owner_added">>
).
-define(DELETE_RESOURCE_OWNER,
    <<"com.leapsight.bondy.api_gateway.delete_resource_owner">>
).
-define(RESOURCE_OWNER_DELETED,
    <<"com.leapsight.bondy.api_gateway.resource_owner_deleted">>
).
-define(UPDATE_RESOURCE_OWNER,
    <<"com.leapsight.bondy.api_gateway.update_resource_owner">>
).
-define(RESOURCE_OWNER_UPDATED,
    <<"com.leapsight.bondy.api_gateway.resource_owner_updated">>
).

-export([handle_call/2]).




handle_call(#call{procedure_uri = ?LOAD_API} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Spec]} ->
            bondy_wamp_utils:maybe_error(catch bondy_api_gateway:load(Spec), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?ADD_CLIENT} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Info]} ->
            Val = bondy_wamp_utils:maybe_error(
                bondy_api_client:add(Uri, Info), M),
            maybe_user_added(Uri, Val, Ctxt);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?UPDATE_CLIENT} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 3) of
        {ok, [Uri, Username, Info]} ->
            Val = bondy_wamp_utils:maybe_error(
                bondy_api_client:update(Uri, Username, Info),
                M
            ),
            maybe_user_updated(Uri, Val, Ctxt);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?DELETE_CLIENT} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Username]} ->
            Val = bondy_wamp_utils:maybe_error(
                bondy_api_client:remove(Uri, Username),
                M
            ),
            maybe_user_deleted(Uri, Val, Ctxt);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?ADD_RESOURCE_OWNER} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Info]} ->
            Val = bondy_wamp_utils:maybe_error(
                bondy_api_resource_owner:add(Uri, Info), M),
            maybe_user_added(Uri, Val, Ctxt);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);


handle_call(#call{procedure_uri = ?UPDATE_RESOURCE_OWNER} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 3) of
        {ok, [Uri, Username, Info]} ->
            Val = bondy_wamp_utils:maybe_error(
                bondy_api_resource_owner:update(Uri, Username, Info),
                M
            ),
            maybe_user_updated(Uri, Val, Ctxt);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?DELETE_RESOURCE_OWNER} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Username]} ->
            Val = bondy_wamp_utils:maybe_error(
                bondy_api_resource_owner:remove(Uri, Username),
                M
            ),
            maybe_user_deleted(Uri, Val, Ctxt);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{} = M, Ctxt) ->
    Mssg = <<
        "There are no registered procedures matching the uri",
        $\s, $', (M#call.procedure_uri)/binary, $', $.
    >>,
    R = wamp_message:error(
        ?CALL,
        M#call.request_id,
        #{},
        ?WAMP_NO_SUCH_PROCEDURE,
        [Mssg],
        #{
            message => Mssg,
            description => <<"Either no registration exists for the requested procedure or the match policy used did not match any registered procedures.">>
        }
    ),
    bondy:send(bondy_context:peer_id(Ctxt), R).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
maybe_user_added(_, #error{} = Error, _) ->
    Error;

maybe_user_added(Uri, #result{arguments = Args} = Res, Ctxt) ->
    _ = bondy_broker:publish(#{}, ?USER_ADDED, Args, #{}, Ctxt),
    case bondy_context:realm_uri(Ctxt) of
        Uri ->
            Res;
        Other ->
            _ = bondy_broker:publish(#{}, {Other, ?USER_ADDED}, Args, #{}, Ctxt),
            Res
    end.


%% @private
maybe_user_updated(_, #error{} = Error, _) ->
    Error;

maybe_user_updated(Uri, #result{arguments = Args} = Res, Ctxt) ->
    _ = bondy_broker:publish(#{}, ?USER_UPDATED, Args, #{}, Ctxt),
    case bondy_context:realm_uri(Ctxt) of
        Uri ->
            Res;
        Other ->
            _ = bondy_broker:publish(
                #{}, {Other, ?USER_UPDATED}, Args, #{}, Ctxt),
            Res
    end.


%% @private
maybe_user_deleted(_, #error{} = Error, _) ->
    Error;

maybe_user_deleted(Uri, #result{arguments = Args} = Res, Ctxt) ->
    _ = bondy_broker:publish(#{}, ?USER_DELETED, Args, #{}, Ctxt),
    case bondy_context:realm_uri(Ctxt) of
        Uri ->
            Res;
        Other ->
            _ = bondy_broker:publish(
                #{}, {Other, ?USER_DELETED}, Args, #{}, Ctxt),
            Res
    end.


