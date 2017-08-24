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




-define(BONDY_USER_ON_ADD, <<"com.leapsight.bondy.security.user_added">>).
-define(BONDY_USER_ON_DELETE, <<"com.leapsight.bondy.security.user_deleted">>).
-define(BONDY_USER_ON_UPDATE, <<"com.leapsight.bondy.security.user_updated">>).


-define(BONDY_GROUP_ON_ADD, <<"com.leapsight.bondy.security.group_added">>).
-define(BONDY_GROUP_ON_DELETE, <<"com.leapsight.bondy.security.group_deleted">>).
-define(BONDY_GROUP_ON_UPDATE, ).



-define(BONDY_SOURCE_ON_ADD, <<"com.leapsight.bondy.security.source_added">>).
-define(BONDY_SOURCE_ON_DELETE, <<"com.leapsight.bondy.security.source_deleted">>).

-define(BONDY_GATEWAY_CLIENT_LIST,
    <<"com.leapsight.bondy.api_gateway.list_clients">>).
-define(BONDY_GATEWAY_CLIENT_LOOKUP,
    <<"com.leapsight.bondy.api_gateway.fetch_client">>).


-define(BONDY_GATEWAY_CLIENT_ADDED,
    <<"com.leapsight.bondy.api_gateway.client_added">>).
-define(BONDY_GATEWAY_CLIENT_DELETED,
    <<"com.leapsight.bondy.api_gateway.client_deleted">>).
-define(BONDY_GATEWAY_CLIENT_UPDATED,
    <<"com.leapsight.bondy.api_gateway.client_updated">>).


-define(BONDY_GATEWAY_LIST_RESOURCE_OWNERS,
    <<"com.leapsight.bondy.api_gateway.list_resource_owners">>).
-define(BONDY_GATEWAY_FETCH_RESOURCE_OWNER,
    <<"com.leapsight.bondy.api_gateway.fetch_resource_owner">>).


-define(BONDY_GATEWAY_RESOURCE_OWNER_ADDED,
    <<"com.leapsight.bondy.api_gateway.resource_owner_added">>).
-define(BONDY_GATEWAY_RESOURCE_OWNER_DELETED,
    <<"com.leapsight.bondy.api_gateway.resource_owner_deleted">>).
-define(BONDY_GATEWAY_RESOURCE_OWNER_UPDATED,
    <<"com.leapsight.bondy.api_gateway.resource_owner_updated">>).


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

handle_call(#call{procedure_uri = <<"wamp.registration.lookup">>,
    arguments = [Proc|_] = L} = M, Ctxt) when length(L) =:= 1; length(L) =:= 2 -> % @TODO: Implement options
    Args = case bondy_registry:match(registration, Proc, Ctxt) of
        {[],'$end_of_table'} ->
            [];
        {Sessions,'$end_of_table'} ->
            [bondy_registry:entry_id(hd(Sessions))] % @TODO Get from round-robin?
    end,
    ReqId = M#call.request_id,
    R = wamp_message:result(ReqId, #{}, Args),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"wamp.registration.match">>,
    arguments = [Proc] = L} = M, Ctxt) when length(L) =:= 1 ->
    Args = case bondy_registry:match(registration, Proc, Ctxt) of
        {[],'$end_of_table'} ->
            [];
        {Sessions,'$end_of_table'} ->
            [bondy_registry:entry_id(hd(Sessions))] % @TODO Get from round-robin?
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

handle_call(#call{
    procedure_uri = <<"wamp.registration.list_callees">>} = M, Ctxt) ->
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
    R = case validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Spec]} ->
            maybe_error(bondy_api_gateway:load(Spec), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(
    #call{procedure_uri = <<"com.leapsight.bondy.api_gateway.add_client">>} = M,
    Ctxt) ->
    R = case validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Info]} ->
            maybe_error(bondy_api_client:add(Uri, Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(
    #call{procedure_uri = <<"com.leapsight.bondy.api_gateway.update_client">>} = M,
    Ctxt) ->
    R = case validate_call_args(M, Ctxt, 3) of
        {ok, [Uri, Username, Info]} ->
            maybe_error(
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
    R = case validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Username]} ->
            maybe_error(
                bondy_api_client:remove(Uri, Username),
                M
            );
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{
    procedure_uri = <<"com.leapsight.bondy.api_gateway.add_resource_owner">>} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Info]} ->
            maybe_error(bondy_api_resource_owner:add(Uri, Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);


handle_call(#call{
    procedure_uri = <<"com.leapsight.bondy.api_gateway.update_resource_owner">>} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 3) of
        {ok, [Uri, Username, Info]} ->
            maybe_error(
                bondy_api_resource_owner:update(Uri, Username, Info),
                M
            );
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.api_gateway.delete_resource_owner">>} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Username]} ->
            maybe_error(
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
    R = case validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Map]} ->
            maybe_error(catch bondy_realm:to_map(bondy_realm:add(Map)), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{
    procedure_uri = <<"com.leapsight.bondy.security.list_realms">>} = M,
    Ctxt) ->
    R = maybe_error(
        catch [bondy_realm:to_map(X) || X <- bondy_realm:list()],
        M
    ),
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{
    procedure_uri = <<"com.leapsight.bondy.security.enable">>} = M,
    Ctxt) ->
    R = case validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            maybe_error(
                catch bondy_realm:enable_security(bondy_realm:fetch(Uri)),
                M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{
    procedure_uri = <<"com.leapsight.bondy.security.disable">>} = M, Ctxt) ->
    R = case validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            maybe_error(
                catch bondy_realm:disable_security(bondy_realm:fetch(Uri)),
                M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{
    procedure_uri = <<"com.leapsight.bondy.security.status">>} = M, Ctxt) ->
    R = case validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            maybe_error(
                catch bondy_realm:security_status(bondy_realm:fetch(Uri)),
                M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{
    procedure_uri = <<"com.leapsight.bondy.security.is_enabled">>} = M, Ctxt) ->
    R = case validate_admin_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            maybe_error(
                catch bondy_realm:is_security_enabled(bondy_realm:fetch(Uri)), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.add_user">>} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Info]} ->
            maybe_error(bondy_security_user:add(Uri, Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.update_user">>} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 3) of
        {ok, [Uri, Username, Info]} ->
            maybe_error(bondy_security_user:update(Uri, Username, Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.delete_user">>} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Username]} ->
            maybe_error(bondy_security_user:remove(Uri, Username), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.list_users">>} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            maybe_error(bondy_security_user:list(Uri), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.find_user">>} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Username]} ->
            maybe_error(bondy_security_user:lookup(Uri, Username), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.change_password">>} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 3, 4) of
        {ok, [Uri, Username, New]} ->
            maybe_error(
                bondy_security_user:change_password(Uri, Username, New),
                M
            );
        {ok, [Uri, Username, New, Old]} ->
            maybe_error(
                bondy_security_user:change_password(
                    Uri, Username, New, Old),
                M
            );
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.add_group">>} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Info]} ->
            maybe_error(bondy_security_group:add(Uri, Info), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.delete_group">>} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Name]} ->
            maybe_error(bondy_security_group:remove(Uri, Name), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.list_groups">>} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 1) of
        {ok, [Uri]} ->
            maybe_error(bondy_security_group:list(Uri), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.find_group">>} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 2) of
        {ok, [Uri, Name]} ->
            maybe_error(bondy_security_group:lookup(Uri, Name), M);
        {error, WampError} ->
            WampError
    end,
    bondy:send(bondy_context:peer_id(Ctxt), R);

handle_call(#call{procedure_uri = <<"com.leapsight.bondy.security.update_group">>} = M, Ctxt) ->
    R = case validate_call_args(M, Ctxt, 3) of
        {ok, [Uri, Name, Info]} ->
            maybe_error(bondy_security_group:update(Uri, Name, Info), M);
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



%% @private
maybe_error(ok, M) ->
    wamp_message:result(M#call.request_id, #{}, [], #{});

maybe_error({ok, Val}, M) ->
    wamp_message:result(M#call.request_id, #{}, [Val], #{});

maybe_error({'EXIT', {Reason, _}}, M) ->
    maybe_error({error, Reason}, M);

maybe_error({error, Reason}, M) ->
    #{<<"code">> := Code} = Map = bondy_error:map(Reason),
    Mssg = maps:get(<<"message">>, Map, <<>>),
    wamp_message:error(
        ?CALL,
        M#call.request_id,
        #{},
        bondy_error:code_to_uri(Code),
        [Mssg],
        Map
    );

maybe_error(Val, M) ->
    wamp_message:result(M#call.request_id, #{}, [Val], #{}).


%% @private
validate_call_args(Call, Ctxt, Min) ->
    validate_call_args(Call, Ctxt, Min, Min).


%% @private
validate_call_args(Call, Ctxt, Min, Max) ->
    do_validate_call_args(Call, Ctxt, Min, Max, false).


%% @private
validate_admin_call_args(Call, Ctxt, Min) ->
    validate_admin_call_args(Call, Ctxt, Min, Min).


%% @private
validate_admin_call_args(Call, Ctxt, Min, Max) ->
    do_validate_call_args(Call, Ctxt, Min, Max, true).

%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Validates that the first argument of the call is a RealmUri, defaulting to
%% use the session Realm's uri if one is not provided. It uses the MinArity
%% to determine whether the RealmUri argument is present or not.
%% Once the Realm is established it validates it is is equal to the
%% session's Realm or any other in case the session's realm is the root realm.
%% @end
%% -----------------------------------------------------------------------------
-spec do_validate_call_args(
    wamp_call(),
    bondy_context:context(),
    MinArity :: integer(),
    MaxArity :: integer(),
    AdminOnly :: boolean()) ->
        {ok, Args :: list()} | {error, wamp_error()}.

do_validate_call_args(#call{arguments = L} = M, _, Min, _, _) when length(L) + 1 < Min ->
    E = wamp_message:error(
        ?CALL,
        M#call.request_id,
        #{},
        ?WAMP_ERROR_INVALID_ARGUMENT,
        [<<"At least one argument is missing">>],
        #{
            description =>
            <<"The procedure requires at least ",
            (integer_to_binary(Min))/binary,
            " arguments.">>
        }
    ),
    {error, E};

do_validate_call_args(#call{arguments = L} = M, _, _, Max, _)
when length(L) > Max ->
    E = wamp_message:error(
        ?CALL,
        M#call.request_id,
        #{},
        ?WAMP_ERROR_INVALID_ARGUMENT,
        [<<"Invalid number of arguments.">>],
        #{
            description =>
            <<"The procedure accepts at most ",
            (integer_to_binary(Max))/binary,
            " arguments.">>
        }
    ),
    {error, E};

do_validate_call_args(#call{arguments = []} = M, Ctxt, _, _, AdminOnly) ->
    %% We default to the session's Realm
    case {AdminOnly, bondy_context:realm_uri(Ctxt)} of
        {false, Uri} ->
            {ok, [Uri]};
        {_, ?BONDY_REALM_URI} ->
            {ok, [?BONDY_REALM_URI]};
        {_, _} ->
            {error, unauthorized(M)}
    end;

do_validate_call_args(#call{arguments = [Uri|_] = L} = M, Ctxt, _, _, AdminOnly) ->
    %% A call can only proceed if the session's Realm is the one being
    %% modified, unless the session's Realm is the Root Realm in which
    %% case any Realm can be modified
    case {AdminOnly, bondy_context:realm_uri(Ctxt)} of
        {false, Uri} ->
            {ok, L};
        {_, ?BONDY_REALM_URI} ->
            {ok, L};
        {_, _} ->
            {error, unauthorized(M)}
    end.


%% @private
unauthorized(M) ->
    Mssg = <<"You have no authorisation to perform this operation on this realm.">>,
    Description = <<
        "The operation you've requested is a targeting a Realm that is not your session's realm or the operation is only supported when you are logged into the Bondy realm",
        $\s, $(, $", (?BONDY_REALM_URI)/binary, $", $), $.
    >>,
    wamp_message:error(
        ?CALL,
        M#call.request_id,
        #{},
        ?WAMP_ERROR_NOT_AUTHORIZED,
        [Mssg],
        #{description => Description}
    ).
