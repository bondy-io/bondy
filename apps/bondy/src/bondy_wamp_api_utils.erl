%% =============================================================================
%%  bondy_wamp_utils.erl -
%%
%%  Copyright (c) 2016-2024 Leapsight. All rights reserved.
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

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_wamp_api_utils).
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").


-export([error/2]).
-export([maybe_error/2]).
-export([deprecated_procedure_error/1]).
-export([no_such_procedure_error/1]).
-export([no_such_procedure_error/3]).
-export([no_such_registration_error/1]).
-export([node_spec/0]).
-export([validate_admin_call_args/3]).
-export([validate_admin_call_args/4]).
-export([validate_call_args/3]).
-export([validate_call_args/4]).

-compile({no_auto_import, [error/2]}).



%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec node_spec() -> map().

node_spec() ->
    #{listen_addrs := Addrs0}  = NodeSpec = partisan:node_spec(),

    NodeSpec#{
        name => partisan:nodestring(),
        listen_addrs => [
            Addr#{ip => list_to_binary(inet:ntoa(IP))}
            || #{ip := IP} = Addr <- Addrs0
        ]
    }.


%% -----------------------------------------------------------------------------
%% @doc @throws bondy_wamp_message:error()
%% @end
%% -----------------------------------------------------------------------------
validate_call_args(Msg, Ctxt, Min) ->
    validate_call_args(Msg, Ctxt, Min, Min).


%% -----------------------------------------------------------------------------
%% @doc @throws bondy_wamp_message:error()
%% @end
%% -----------------------------------------------------------------------------
validate_call_args(Msg, Ctxt, Min, Max) ->
    Len = args_len(args(Msg)),
    do_validate_call_args(Msg, Ctxt, Min, Max, Len, false).


%% -----------------------------------------------------------------------------
%% @doc @throws bondy_wamp_message:error()
%% @end
%% -----------------------------------------------------------------------------
validate_admin_call_args(Msg, Ctxt, Min) ->
    validate_admin_call_args(Msg, Ctxt, Min, Min).


%% -----------------------------------------------------------------------------
%% @doc @throws bondy_wamp_message:error()
%% @end
%% -----------------------------------------------------------------------------
validate_admin_call_args(Msg, Ctxt, Min, Max) ->
    Len = args_len(args(Msg)),
    do_validate_call_args(Msg, Ctxt, Min, Max, Len, true).



%% -----------------------------------------------------------------------------
%% @doc Returns a CALL RESULT or ERROR based on the first Argument
%% @end
%% -----------------------------------------------------------------------------
maybe_error(ok, M) ->
    bondy_wamp_message:result(bondy_wamp_message:request_id(M), #{});

maybe_error({ok, Val}, M) ->
    bondy_wamp_message:result(bondy_wamp_message:request_id(M), #{}, [Val]);

maybe_error({'EXIT', {Reason, _}}, M) ->
    maybe_error({error, Reason}, M);

maybe_error(#error{} = Error, _) ->
    Error;

maybe_error({error, #error{} = Error}, _) ->
    Error;

maybe_error({error, Reason}, M) ->
    error(Reason, M);

maybe_error(Val, M) ->
    bondy_wamp_message:result(bondy_wamp_message:request_id(M), #{}, [Val]).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
error({not_authorized, Reason}, M) ->
    Map = bondy_error_utils:map(Reason),

    bondy_wamp_message:error_from(
        M,
        #{},
        ?WAMP_NOT_AUTHORIZED,
        [Map]
    );

error(Reason, #call{} = M) ->
    #{<<"code">> := Code} = Map = bondy_error_utils:map(Reason),
    Mssg = maps:get(<<"message">>, Map, <<>>),
    bondy_wamp_message:error_from(
        M,
        #{},
        bondy_error_utils:code_to_uri(Code),
        [Mssg],
        Map
    ).

deprecated_procedure_error(#call{procedure_uri = Uri} = M) ->
    do_deprecated_procedure_error(M, Uri);

deprecated_procedure_error(#invocation{details = #{procedure := Uri}} = M) ->
    do_deprecated_procedure_error(M, Uri).


%% -----------------------------------------------------------------------------
%% @doc Creates a wamp_error() based on a wamp_call().
%% @end
%% -----------------------------------------------------------------------------
no_such_procedure_error(#call{procedure_uri = Uri} = M) ->
    no_such_procedure_error(Uri, ?CALL, M#call.request_id);

no_such_procedure_error(#invocation{details = #{procedure := Uri}} = M) ->
    no_such_procedure_error(Uri, ?CALL, M#invocation.request_id).


no_such_procedure_error(ProcUri, MType, ReqId) ->
    Mssg = <<
        "There are no registered procedures matching the uri",
        $\s, $', ProcUri/binary, $', $.
    >>,
    bondy_wamp_message:error(
        MType,
        ReqId,
        #{},
        ?WAMP_NO_SUCH_PROCEDURE,
        [Mssg],
        #{
            message => Mssg,
            description => <<"Either no registration exists for the requested procedure or the match policy used did not match any registered procedures.">>
        }
    ).

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
no_such_registration_error(RegId) when is_integer(RegId) ->
    bondy_wamp_message:error(
        ?UNREGISTER,
        RegId,
        #{},
        ?WAMP_NO_SUCH_REGISTRATION,
        [<<"No registration exists for the supplied RegistrationId">>]
    ).



%% =============================================================================
%% PRIVATE
%% =============================================================================



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
    bondy_context:t(),
    MinArity :: pos_integer(),
    MaxArity :: pos_integer(),
    Len :: pos_integer(),
    AdminOnly :: boolean()) -> Args :: list() | no_return().

do_validate_call_args(Msg, _, Min, _, Len, _) when Len + 1 < Min ->
    E = bondy_wamp_message:error(
        ?CALL,
        bondy_wamp_message:request_id(Msg),
        #{},
        ?WAMP_INVALID_ARGUMENT,
        [<<"Invalid number of positional arguments.">>],
        #{
            description =>
            <<"The procedure requires at least ",
            (integer_to_binary(Min))/binary,
            " positional arguments.">>
        }
    ),
    error(E);

do_validate_call_args(Msg, _, _, Max, Len, _) when Len > Max ->
    E = bondy_wamp_message:error(
        ?CALL,
        bondy_wamp_message:request_id(Msg),
        #{},
        ?WAMP_INVALID_ARGUMENT,
        [<<"Invalid number of positional arguments.">>],
        #{
            description =>
            <<"The procedure accepts at most ",
            (integer_to_binary(Max))/binary,
            " positional arguments.">>
        }
    ),
    error(E);

do_validate_call_args(Msg, Ctxt, Min, _, Len, AdminOnly) when Len == 0 ->
    %% We are missing the RealmUri argument, we default to the session's Realm
    case bondy_context:realm_uri(Ctxt) of
        Uri when AdminOnly == false ->
            [Uri];
        ?MASTER_REALM_URI when AdminOnly == true andalso Min == 0 ->
            [];
        ?MASTER_REALM_URI when AdminOnly == true ->
            [?MASTER_REALM_URI];
        _ ->
            error(unauthorized(Msg, Ctxt))
    end;

do_validate_call_args(
    #call{args = [Uri|_]} = Msg, Ctxt, Min, _, Len, AdminOnly)
    when Len >= Min ->
    %% A call can only proceed if the session's Realm matches the one passed in
    %% the arguments, unless the session's Realm is the Root Realm which allows
    %% operations on other realms
    case bondy_context:realm_uri(Ctxt) of
        Uri when AdminOnly == false ->
            %% Matches arg URI
            to_list(args(Msg));
        ?MASTER_REALM_URI ->
            %% Users logged in root realm can operate on any realm
            to_list(args(Msg));
        _ ->
            error(unauthorized(Msg, Ctxt))
    end;

do_validate_call_args(Msg, Ctxt, Min, _, Len, AdminOnly) when Len + 1 >= Min ->
    %% We are missing the RealmUri argument, we default to the session's Realm
    %% A call can only proceed if the session's Realm matches the one passed in
    %% the arguments, unless the session's Realm is the Root Realm which allows
    %% operations on other realms
    case {AdminOnly, bondy_context:realm_uri(Ctxt)} of
        {false, Uri} ->
            [Uri | to_list(args(Msg))];
        {_, ?MASTER_REALM_URI} ->
            [?MASTER_REALM_URI | to_list(args(Msg))];
        {_, _} ->
            error(unauthorized(Msg, Ctxt))
    end.


%% @private
unauthorized(#subscribe{} = M, Ctxt) ->
    unauthorized(?SUBSCRIBE, M#subscribe.request_id, Ctxt);

unauthorized(#unsubscribe{} = M, Ctxt) ->
    unauthorized(?UNSUBSCRIBE, M#unsubscribe.request_id, Ctxt);

unauthorized(#register{} = M, Ctxt) ->
    unauthorized(?REGISTER, M#register.request_id, Ctxt);

unauthorized(#unregister{} = M, Ctxt) ->
    unauthorized(?REGISTER, M#unregister.request_id), Ctxt;

unauthorized(#call{} = M, Ctxt) ->
    unauthorized(?CALL, M#call.request_id, Ctxt);

unauthorized(#invocation{} = M, Ctxt) ->
    unauthorized(?INVOCATION, M#invocation.request_id, Ctxt);

unauthorized(#cancel{} = M, Ctxt) ->
    unauthorized(?CANCEL, M#cancel.request_id, Ctxt).


%% @private
unauthorized(Type, ReqId, Ctxt) ->
    Uri = bondy_context:realm_uri(Ctxt),
    Mssg = <<
        "You have no authorisation to perform this operation on this realm."
    >>,
    Description = <<
        "The operation you've requested is targeting a realm ",
        $\s, $(, $", Uri/binary, $", $), $,,
        " that is not your session's realm or the operation is only "
        "supported when performed by a session on the Bondy Master Realm.",
        $\s, $(, $", (?MASTER_REALM_URI)/binary, $", $), $.
    >>,
    bondy_wamp_message:error(
        Type,
        ReqId,
        #{},
        ?WAMP_NOT_AUTHORIZED,
        [Mssg],
        #{description => Description}
    ).


%% @private
args(#call{args = Args}) -> Args;
args(#invocation{args = Args}) -> Args.


%% @private
args_len(undefined) -> 0;
args_len(L) when is_list(L) -> length(L).


%% @private
to_list(undefined) -> [];
to_list(L) when is_list(L) -> L.



do_deprecated_procedure_error(M, Uri) ->
    Reason = <<"The procedure '", Uri/binary, "' has been deprecated.">>,
    bondy_wamp_message:error_from(
        M,
        #{},
        ~"bondy.error.deprecated_procedure",
        [Reason],
        #{
            message => Reason
        }
    ).