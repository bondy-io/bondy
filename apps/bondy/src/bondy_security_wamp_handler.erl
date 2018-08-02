-module(bondy_security_wamp_handler).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").
-include("bondy_security.hrl").


%% -----------------------------------------------------------------------------
%% com.leapsight.bondy.security
%% -----------------------------------------------------------------------------
-define(LIST_REALMS,        <<"com.leapsight.bondy.security.list_realms">>).
-define(CREATE_REALM,       <<"com.leapsight.bondy.security.create_realm">>).
-define(REALM_ADDED,        <<"com.leapsight.bondy.security.realm_added">>).
-define(ENABLE_SECURITY,    <<"com.leapsight.bondy.security.enable">>).
-define(DISABLE_SECURITY,   <<"com.leapsight.bondy.security.disable">>).
-define(SECURITY_STATUS,    <<"com.leapsight.bondy.security.status">>).
-define(IS_SECURITY_ENABLED, <<"com.leapsight.bondy.security.is_enabled">>).
-define(CHANGE_PASSWORD,    <<"com.leapsight.bondy.security.change_password">>).

-define(LIST_USERS,         <<"com.leapsight.bondy.security.list_users">>).
-define(FIND_USER,          <<"com.leapsight.bondy.security.find_user">>).
-define(ADD_USER,           <<"com.leapsight.bondy.security.add_user">>).
-define(DELETE_USER,        <<"com.leapsight.bondy.security.delete_user">>).
-define(UPDATE_USER,        <<"com.leapsight.bondy.security.update_user">>).

-define(LIST_GROUPS,        <<"com.leapsight.bondy.security.list_groups">>).
-define(FIND_GROUP,         <<"com.leapsight.bondy.security.find_group">>).
-define(ADD_GROUP,          <<"com.leapsight.bondy.security.add_group">>).
-define(DELETE_GROUP,       <<"com.leapsight.bondy.security.delete_group">>).
-define(UPDATE_GROUP,       <<"com.leapsight.bondy.security.update_group">>).

-define(LIST_SOURCES,       <<"com.leapsight.bondy.security.list_sources">>).
-define(FIND_SOURCE,        <<"com.leapsight.bondy.security.find_source">>).
-define(ADD_SOURCE,         <<"com.leapsight.bondy.security.add_source">>).
-define(DELETE_SOURCE,      <<"com.leapsight.bondy.security.delete_source">>).


-export([handle_call/2]).



handle_call(#call{procedure_uri = ?CREATE_REALM} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Map]} ->
            Val = bondy_wamp_utils:maybe_error(
                catch bondy_realm:to_map(bondy_realm:add(Map)), M),
            maybe_realm_added(Val, Ctxt);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?LIST_REALMS} = M, Ctxt) ->
    R = bondy_wamp_utils:maybe_error(
        catch [bondy_realm:to_map(X) || X <- bondy_realm:list()],
        M
    ),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?ENABLE_SECURITY} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            bondy_wamp_utils:maybe_error(
                catch bondy_realm:enable_security(bondy_realm:fetch(Uri)),
                M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?DISABLE_SECURITY} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            bondy_wamp_utils:maybe_error(
                catch bondy_realm:disable_security(bondy_realm:fetch(Uri)),
                M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?SECURITY_STATUS} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            bondy_wamp_utils:maybe_error(
                catch bondy_realm:security_status(bondy_realm:fetch(Uri)),
                M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?IS_SECURITY_ENABLED} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            bondy_wamp_utils:maybe_error(
                catch bondy_realm:is_security_enabled(bondy_realm:fetch(Uri)), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?ADD_USER} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Info]} ->
            Val = bondy_wamp_utils:maybe_error(
                bondy_security_user:add(Uri, Info), M),
            maybe_user_added(Uri, Val, Ctxt);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?UPDATE_USER} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 3) of
        {ok, [Uri, Username, Info]} ->
            Val = bondy_wamp_utils:maybe_error(
                bondy_security_user:update(Uri, Username, Info), M),
            maybe_user_updated(Uri, Val, Ctxt);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?DELETE_USER} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Username]} ->
            Val = bondy_wamp_utils:maybe_error(
                bondy_security_user:remove(Uri, Username), M),
            maybe_user_deleted(Uri, Val, Ctxt);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?LIST_USERS} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            bondy_wamp_utils:maybe_error(bondy_security_user:list(Uri), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?FIND_USER} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Username]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_user:lookup(Uri, Username), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?CHANGE_PASSWORD} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 3, 4) of
        {ok, [Uri, Username, New]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_user:change_password(Uri, Username, New),
                M
            );
        {ok, [Uri, Username, New, Old]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_user:change_password(Uri, Username, New, Old),
                M
            );
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?ADD_GROUP} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Info]} ->
            Val = bondy_wamp_utils:maybe_error(
                bondy_security_group:add(Uri, Info), M),
            maybe_group_added(Uri, Val, Ctxt);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?DELETE_GROUP} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Name]} ->
            Val = bondy_wamp_utils:maybe_error(
                bondy_security_group:remove(Uri, Name), M),
            maybe_group_deleted(Uri, Val, Ctxt);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?LIST_GROUPS} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            bondy_wamp_utils:maybe_error(bondy_security_group:list(Uri), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?FIND_GROUP} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Name]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_group:lookup(Uri, Name), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?UPDATE_GROUP} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 3) of
        {ok, [Uri, Name, Info]} ->
            Val = bondy_wamp_utils:maybe_error(
                bondy_security_group:update(Uri, Name, Info), M),
            maybe_group_updated(Uri, Val, Ctxt);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?ADD_SOURCE} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?DELETE_SOURCE} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?LIST_SOURCES} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = ?FIND_SOURCE} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{} = M, Ctxt) ->
    Error = bondy_wamp_utils:no_such_procedure_error(M),
    bondy:send(bondy_context:peer_id(Ctxt), Error).



%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
maybe_realm_added(#error{} = Error, _) ->
    Error;

maybe_realm_added(#result{arguments = Args} = Res, Ctxt) ->
    _ = bondy_broker:publish(
        #{exclude_me => false}, ?REALM_ADDED, Args, #{}, Ctxt),
    Res.


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


%% @private
maybe_group_added(_, #error{} = Error, _) ->
    Error;

maybe_group_added(Uri, #result{arguments = Args} = Res, Ctxt) ->
    _ = bondy_broker:publish(#{}, ?GROUP_ADDED, Args, #{}, Ctxt),
    case bondy_context:realm_uri(Ctxt) of
        Uri ->
            Res;
        Other ->
            _ = bondy_broker:publish(
                #{}, {Other, ?GROUP_ADDED}, Args, #{}, Ctxt),
            Res
    end.


%% @private
maybe_group_updated(_, #error{} = Error, _) ->
    Error;

maybe_group_updated(Uri, #result{arguments = Args} = Res, Ctxt) ->
    _ = bondy_broker:publish(#{}, ?GROUP_UPDATED, Args, #{}, Ctxt),
    case bondy_context:realm_uri(Ctxt) of
        Uri ->
            Res;
        Other ->
            _ = bondy_broker:publish(
                #{}, {Other, ?GROUP_UPDATED}, Args, #{}, Ctxt),
            Res
    end.


%% @private
maybe_group_deleted(_, #error{} = Error, _) ->
    Error;

maybe_group_deleted(Uri, #result{arguments = Args} = Res, Ctxt) ->
    _ = bondy_broker:publish(#{}, ?GROUP_DELETED, Args, #{}, Ctxt),
    case bondy_context:realm_uri(Ctxt) of
        Uri ->
            Res;
        Other ->
            _ = bondy_broker:publish(
                #{}, {Other, ?GROUP_DELETED}, Args, #{}, Ctxt),
            Res
    end.