%% =============================================================================
%%  bondy_wamp_utils.erl -
%%
%%  Copyright (c) 2016-2019 Ngineo Limited t/a Leapsight. All rights reserved.
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
-module(bondy_wamp_utils).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").


-export([maybe_error/2]).
-export([validate_admin_call_args/3]).
-export([validate_admin_call_args/4]).
-export([validate_call_args/3]).
-export([validate_call_args/4]).
-export([no_such_procedure_error/1]).
-export([no_such_registration_error/1]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Creates a wamp_error() based on a wamp_call().
%% @end
%% -----------------------------------------------------------------------------
no_such_procedure_error(#call{} = M) ->
    Mssg = <<
        "There are no registered procedures matching the uri",
        $\s, $', (M#call.procedure_uri)/binary, $', $.
    >>,
    wamp_message:error(
        ?CALL,
        M#call.request_id,
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
    Mssg = <<"No registration exists for the supplied RegistrationId">>,
    wamp_message:error(
        ?UNREGISTER,
        RegId,
        #{},
        ?WAMP_NO_SUCH_REGISTRATION,
        [Mssg],
        #{
            message => Mssg,
            description => <<"No registration exists for the supplied RegistrationId or the details provided did not match an existing registration.">>
        }
    ).

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
    bondy_context:t(),
    MinArity :: integer(),
    MaxArity :: integer(),
    AdminOnly :: boolean()) ->
        {ok, Args :: list()} | {error, wamp_error()}.

do_validate_call_args(#call{arguments = L} = M, _, Min, _, _)
when length(L) + 1 < Min ->
    E = wamp_message:error(
        ?CALL,
        M#call.request_id,
        #{},
        ?WAMP_INVALID_ARGUMENT,
        [<<"Invalid number of arguments.">>],
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
        ?WAMP_INVALID_ARGUMENT,
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
    %% We are missing the RealmUri argument, we default to the session's Realm
    case {AdminOnly, bondy_context:realm_uri(Ctxt)} of
        {false, Uri} ->
            {ok, [Uri]};
        {true, ?BONDY_REALM_URI} ->
            {ok, [?BONDY_REALM_URI]};
        {_, _} ->
            {error, unauthorized(M)}
    end;

do_validate_call_args(
    #call{arguments = [Uri|_] = L} = M, Ctxt, Min, _, AdminOnly)
    when length(L) >= Min ->
    %% A call can only proceed if the session's Realm is the one being
    %% modified, unless the session's Realm is the Root Realm in which
    %% case any Realm can be modified
    case {AdminOnly, bondy_context:realm_uri(Ctxt)} of
        {false, Uri} ->
            %% Matches arg URI
            {ok, L};
        {_, ?BONDY_REALM_URI} ->
            %% Users logged in root realm can operate on any realm
            {ok, L};
        {_, _} ->
            {error, unauthorized(M)}
    end;

do_validate_call_args(
    #call{arguments = L} = M, Ctxt, Min, _, AdminOnly)
    when length(L) + 1 >= Min ->
    %% We are missing the RealmUri argument, we default to the session's Realm
    %% A call can only proceed if the session's Realm is the one being
    %% modified, unless the session's Realm is the Root Realm in which
    %% case any Realm can be modified
    case {AdminOnly, bondy_context:realm_uri(Ctxt)} of
        {false, Uri} ->
            {ok, [Uri|L]};
        {_, ?BONDY_REALM_URI} ->
            {ok, [?BONDY_REALM_URI|L]};
        {_, _} ->
            {error, unauthorized(M)}
    end.


%% @private
unauthorized(#subscribe{} = M) ->
    unauthorized(?SUBSCRIBE, M#subscribe.request_id);
unauthorized(#unsubscribe{} = M) ->
    unauthorized(?UNSUBSCRIBE, M#unsubscribe.request_id);
unauthorized(#register{} = M) ->
    unauthorized(?REGISTER, M#register.request_id);
unauthorized(#unregister{} = M) ->
    unauthorized(?REGISTER, M#unregister.request_id);
unauthorized(#call{} = M) ->
    unauthorized(?CALL, M#call.request_id);
unauthorized(#cancel{} = M) ->
    unauthorized(?CANCEL, M#cancel.request_id).


unauthorized(Type, ReqId) ->
    Mssg = <<
        "You have no authorisation to perform this operation on this realm."
    >>,
    Description = <<
        "The operation you've requested is a targeting a Realm "
        "that is not your session's realm or the operation is only "
        "supported when you are logged into the Bondy realm",
        $\s, $(, $", (?BONDY_REALM_URI)/binary, $", $), $.
    >>,
    wamp_message:error(
        Type,
        ReqId,
        #{},
        ?WAMP_NOT_AUTHORIZED,
        [Mssg],
        #{description => Description}
    ).


%% -----------------------------------------------------------------------------
%% @doc Returns a CALL RESULT or ERROR based on the first Argument
%% @end
%% -----------------------------------------------------------------------------
maybe_error(ok, #call{} = M) ->
    wamp_message:result(M#call.request_id, #{}, [], #{});

maybe_error({ok, Val}, #call{} = M) ->
    wamp_message:result(M#call.request_id, #{}, [Val], #{});

maybe_error({'EXIT', {Reason, _}}, M) ->
    maybe_error({error, Reason}, M);

maybe_error(#error{} = Error, _) ->
    Error;
maybe_error({error, #error{} = Error}, _) ->
    Error;

maybe_error({error, Reason}, #call{} = M) ->
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

maybe_error(Val, #call{} = M) ->
    wamp_message:result(M#call.request_id, #{}, [Val], #{}).