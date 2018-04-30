%% =============================================================================
%%  bondy_dealer_meta.erl -
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


-module(bondy_dealer_meta).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").



%% -----------------------------------------------------------------------------
%% com.leapsight.bondy.security
%% -----------------------------------------------------------------------------
-define(BONDY_USER_ON_ADD, <<"com.leapsight.bondy.security.user_added">>).
-define(BONDY_USER_ON_DELETE, <<"com.leapsight.bondy.security.user_deleted">>).
-define(BONDY_USER_ON_UPDATE, <<"com.leapsight.bondy.security.user_updated">>).
-define(BONDY_GROUP_ON_ADD, <<"com.leapsight.bondy.security.group_added">>).
-define(BONDY_GROUP_ON_DELETE,
    <<"com.leapsight.bondy.security.group_deleted">>
).
-define(BONDY_GROUP_ON_UPDATE,
    <<"com.leapsight.bondy.security.group_updated">>
).
-define(BONDY_SOURCE_ON_ADD, <<"com.leapsight.bondy.security.source_added">>).
-define(BONDY_SOURCE_ON_DELETE,
    <<"com.leapsight.bondy.security.source_deleted">>
).

%% -----------------------------------------------------------------------------
%% com.leapsight.bondy.api_gateway
%% -----------------------------------------------------------------------------
-define(BONDY_GATEWAY_CLIENT_LIST,
    <<"com.leapsight.bondy.api_gateway.list_clients">>
).
-define(BONDY_GATEWAY_CLIENT_LOOKUP,
    <<"com.leapsight.bondy.api_gateway.fetch_client">>
).
-define(BONDY_GATEWAY_CLIENT_ADDED,
    <<"com.leapsight.bondy.api_gateway.client_added">>
).
-define(BONDY_GATEWAY_CLIENT_DELETED,
    <<"com.leapsight.bondy.api_gateway.client_deleted">>
).
-define(BONDY_GATEWAY_CLIENT_UPDATED,
    <<"com.leapsight.bondy.api_gateway.client_updated">>
).
-define(BONDY_GATEWAY_LIST_RESOURCE_OWNERS,
    <<"com.leapsight.bondy.api_gateway.list_resource_owners">>
).
-define(BONDY_GATEWAY_FETCH_RESOURCE_OWNER,
    <<"com.leapsight.bondy.api_gateway.fetch_resource_owner">>
).
-define(BONDY_GATEWAY_RESOURCE_OWNER_ADDED,
    <<"com.leapsight.bondy.api_gateway.resource_owner_added">>
).
-define(BONDY_GATEWAY_RESOURCE_OWNER_DELETED,
    <<"com.leapsight.bondy.api_gateway.resource_owner_deleted">>
).
-define(BONDY_GATEWAY_RESOURCE_OWNER_UPDATED,
    <<"com.leapsight.bondy.api_gateway.resource_owner_updated">>
).

-define(BONDY_REVOKE_USER_TOKEN,
    <<"com.leapsight.bondy.oauth2.revoke_user_token">>
).




-export([handle_call/2]).


%% =============================================================================
%% API
%% =============================================================================


-spec handle_call(M :: wamp_message(), Ctxt :: map()) -> ok | no_return().

%% -----------------------------------------------------------------------------
%% WAMP META PROCEDURES
%% -----------------------------------------------------------------------------

handle_call(#call{procedure_uri = <<"wamp.registration.list">>} = M, Ctxt) ->
    ReqId = M#call.request_id,
    Res = #{
        ?EXACT_MATCH => [], % @TODO
        ?PREFIX_MATCH => [], % @TODO
        ?WILDCARD_MATCH => [] % @TODO
    },
    R = wamp_message:result(ReqId, #{}, [Res]),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(
    #call{
        procedure_uri = <<"wamp.registration.lookup">>,
        arguments = [Proc|_] = L
    } = M,
    Ctxt) when length(L) =:= 1; length(L) =:= 2 ->
    % @TODO: Implement options
    Args = case bondy_registry:match(registration, Proc, Ctxt) of
        {[], '$end_of_table'} ->
            [];
        {Sessions, '$end_of_table'} ->
            [bondy_registry_entry:id(hd(Sessions))] % @TODO Get from round-robin?
    end,
    ReqId = M#call.request_id,
    R = wamp_message:result(ReqId, #{}, Args),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(
    #call{
        procedure_uri = <<"wamp.registration.match">>,
        arguments = [Proc] = L
    } = M,
    Ctxt) when length(L) =:= 1 ->
    Args = case bondy_registry:match(registration, Proc, Ctxt) of
        {[], '$end_of_table'} ->
            [];
        {Sessions, '$end_of_table'} ->
            [bondy_registry_entry:id(hd(Sessions))] % @TODO Get from round-robin?
    end,
    ReqId = M#call.request_id,
    R = wamp_message:result(ReqId, #{}, Args),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"wamp.registration.get">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(
    #call{procedure_uri = <<"wamp.registration.list_callees">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{
    procedure_uri = <<"wamp.registration.count_callees">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{count => 0},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);


%% -----------------------------------------------------------------------------
%% BONDY API GATEWAY META PROCEDURES
%% -----------------------------------------------------------------------------

handle_call(
    #call{procedure_uri = <<"com.leapsight.bondy.api_gateway.load">>} = M,
    Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Spec]} ->
            bondy_wamp_utils:maybe_error(catch bondy_api_gateway:load(Spec), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(
    #call{procedure_uri = <<"com.leapsight.bondy.api_gateway.add_client">>} = M,
    Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Info]} ->
            bondy_wamp_utils:maybe_error(bondy_api_client:add(Uri, Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(
    #call{procedure_uri = <<"com.leapsight.bondy.api_gateway.update_client">>} = M,
    Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 3) of
        {ok, [Uri, Username, Info]} ->
            bondy_wamp_utils:maybe_error(
                bondy_api_client:update(Uri, Username, Info),
                M
            );
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(
    #call{procedure_uri = <<"com.leapsight.bondy.api_gateway.delete_client">>} = M,
    Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Username]} ->
            bondy_wamp_utils:maybe_error(
                bondy_api_client:remove(Uri, Username),
                M
            );
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{
    procedure_uri = <<"com.leapsight.bondy.api_gateway.add_resource_owner">>} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Info]} ->
            bondy_wamp_utils:maybe_error(
                bondy_api_resource_owner:add(Uri, Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);


handle_call(#call{
    procedure_uri = <<"com.leapsight.bondy.api_gateway.update_resource_owner">>} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 3) of
        {ok, [Uri, Username, Info]} ->
            bondy_wamp_utils:maybe_error(
                bondy_api_resource_owner:update(Uri, Username, Info),
                M
            );
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.api_gateway.delete_resource_owner">>} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Username]} ->
            bondy_wamp_utils:maybe_error(
                bondy_api_resource_owner:remove(Uri, Username),
                M
            );
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

%% -----------------------------------------------------------------------------
%% BONDY SECURITY META PROCEDURES
%% -----------------------------------------------------------------------------

handle_call(#call{
    procedure_uri = <<"com.leapsight.bondy.security.create_realm">>} = M,
    Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Map]} ->
            bondy_wamp_utils:maybe_error(
                catch bondy_realm:to_map(bondy_realm:add(Map)), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{
    procedure_uri = <<"com.leapsight.bondy.security.list_realms">>} = M,
    Ctxt) ->
    R = bondy_wamp_utils:maybe_error(
        catch [bondy_realm:to_map(X) || X <- bondy_realm:list()],
        M
    ),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{
    procedure_uri = <<"com.leapsight.bondy.security.enable">>} = M,
    Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            bondy_wamp_utils:maybe_error(
                catch bondy_realm:enable_security(bondy_realm:fetch(Uri)),
                M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{
    procedure_uri = <<"com.leapsight.bondy.security.disable">>} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            bondy_wamp_utils:maybe_error(
                catch bondy_realm:disable_security(bondy_realm:fetch(Uri)),
                M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{
    procedure_uri = <<"com.leapsight.bondy.security.status">>} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            bondy_wamp_utils:maybe_error(
                catch bondy_realm:security_status(bondy_realm:fetch(Uri)),
                M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{
    procedure_uri = <<"com.leapsight.bondy.security.is_enabled">>} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            bondy_wamp_utils:maybe_error(
                catch bondy_realm:is_security_enabled(bondy_realm:fetch(Uri)), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.add_user">>} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Info]} ->
            bondy_wamp_utils:maybe_error(bondy_security_user:add(Uri, Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.update_user">>} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 3) of
        {ok, [Uri, Username, Info]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_user:update(Uri, Username, Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.delete_user">>} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Username]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_user:remove(Uri, Username), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.list_users">>} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            bondy_wamp_utils:maybe_error(bondy_security_user:list(Uri), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.find_user">>} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Username]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_user:lookup(Uri, Username), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.change_password">>} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 3, 4) of
        {ok, [Uri, Username, New]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_user:change_password(Uri, Username, New),
                M
            );
        {ok, [Uri, Username, New, Old]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_user:change_password(
                    Uri, Username, New, Old),
                M
            );
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.add_group">>} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Info]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_group:add(Uri, Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.delete_group">>} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Name]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_group:remove(Uri, Name), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.list_groups">>} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            bondy_wamp_utils:maybe_error(bondy_security_group:list(Uri), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.find_group">>} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Name]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_group:lookup(Uri, Name), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.update_group">>} = M, Ctxt) ->
    R = case bondy_wamp_utils:validate_call_args(M, Ctxt, 3) of
        {ok, [Uri, Name, Info]} ->
            bondy_wamp_utils:maybe_error(
                bondy_security_group:update(Uri, Name, Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.add_source">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.delete_source">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.list_sources">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.find_source">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    R = wamp_message:result(ReqId, #{}, [], Res),
    bondy:send(bondy_context:peer_id(Ctxt), R);

%% =============================================================================
%% BACKUPS
%% =============================================================================

handle_call(
    #call{procedure_uri = <<"com.leapsight.bondy.backup.", _/binary>>} = M,
    Ctxt) ->
    bondy_backup_wamp_handler:handle_call(M, Ctxt);


%% =============================================================================
%% OAUTH2
%% =============================================================================

handle_call(
    #call{procedure_uri = <<"com.leapsight.bondy.oauth2.", _/binary>>} = M,
    Ctxt) ->
    bondy_oauth2_wamp_handler:handle_call(M, Ctxt);

handle_call(#call{} = M, Ctxt) ->
    Mssg = <<
        "There are no registered procedures matching the uri",
        $\s, $', (M#call.procedure_uri)/binary, $', $.
    >>,
    R = wamp_message:error(
        ?CALL,
        M#call.request_id,
        #{},
        ?WAMP_ERROR_NO_SUCH_PROCEDURE,
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






