%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_api_utils).
-moduledoc """
Utility functions for the Bondy WAMP API, including validation of
administrative call arguments and the construction of WAMP error messages.
""".
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

-spec node_spec() -> map().

node_spec() ->
    #{listen_addrs := Addrs0} = NodeSpec = partisan:node_spec(),

    NodeSpec#{
        name => partisan:nodestring(),
        listen_addrs => [
            Addr#{ip => list_to_binary(inet:ntoa(IP))}
         || #{ip := IP} = Addr <- Addrs0
        ]
    }.

-doc """
Throws a `bondy_wamp_message:error()`.
""".
validate_call_args(Msg, Ctxt, Min) ->
    validate_call_args(Msg, Ctxt, Min, Min).

-doc """
Throws a `bondy_wamp_message:error()`.
""".
validate_call_args(Msg, Ctxt, Min, Max) ->
    Len = args_len(args(Msg)),
    do_validate_call_args(Msg, Ctxt, Min, Max, Len, false).

-doc """
Throws a `bondy_wamp_message:error()`.
""".
validate_admin_call_args(Msg, Ctxt, Min) ->
    validate_admin_call_args(Msg, Ctxt, Min, Min).

-doc """
Throws a `bondy_wamp_message:error()`.
""".
validate_admin_call_args(Msg, Ctxt, Min, Max) ->
    Len = args_len(args(Msg)),
    do_validate_call_args(Msg, Ctxt, Min, Max, Len, true).

-doc """
Returns a CALL RESULT or ERROR based on the first Argument.
""".
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

error({not_authorized, Reason}, M) ->
    Map = bondy_error:to_map(bondy_error:from_term(Reason)),

    %% This clause has always put the error map in Args rather than a message,
    %% unlike every other error reply. The shape is kept so existing clients
    %% keep reading Args[0], and the standard payload is added in KWArgs.
    bondy_wamp_message:error_from(
        M,
        #{},
        ?WAMP_NOT_AUTHORIZED,
        [Map],
        Map
    );
error(Reason, #call{} = M) ->
    bondy_wamp_error:to_wamp(Reason, M).

deprecated_procedure_error(#call{procedure_uri = Uri} = M) ->
    do_deprecated_procedure_error(M, Uri);
deprecated_procedure_error(#invocation{details = #{procedure := Uri}} = M) ->
    do_deprecated_procedure_error(M, Uri).

-doc """
Creates a `wamp_error()` based on a `wamp_call()`.
""".
no_such_procedure_error(#call{procedure_uri = Uri} = M) ->
    no_such_procedure_error(Uri, ?CALL, M#call.request_id);
no_such_procedure_error(#invocation{details = #{procedure := Uri}} = M) ->
    no_such_procedure_error(Uri, ?CALL, M#invocation.request_id).

no_such_procedure_error(ProcUri, MType, ReqId) ->
    Error = bondy_error:new(no_such_procedure, #{
        details => #{procedure_uri => ProcUri}
    }),
    bondy_wamp_error:to_wamp(Error, MType, ReqId, #{}).

no_such_registration_error(RegId) when is_integer(RegId) ->
    Error = bondy_error:new(no_such_registration, #{
        details => #{registration_id => RegId}
    }),
    bondy_wamp_error:to_wamp(Error, ?UNREGISTER, RegId, #{}).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
-doc """
Validates that the first argument of the call is a RealmUri, defaulting to
use the session Realm's uri if one is not provided. It uses the MinArity
to determine whether the RealmUri argument is present or not.
Once the Realm is established it validates it is is equal to the
session's Realm or any other in case the session's realm is the root realm.
""".
-spec do_validate_call_args(
    wamp_call(),
    bondy_context:t(),
    MinArity :: pos_integer(),
    MaxArity :: pos_integer(),
    Len :: pos_integer(),
    AdminOnly :: boolean()
) -> Args :: list() | no_return().

do_validate_call_args(Msg, _, Min, _, Len, _) when Len + 1 < Min ->
    E = arity_error(
        Msg,
        <<"The procedure requires at least ", (integer_to_binary(Min))/binary,
            " positional arguments.">>,
        #{minimum_arity => Min}
    ),
    error(E);
do_validate_call_args(Msg, _, _, Max, Len, _) when Len > Max ->
    E = arity_error(
        Msg,
        <<"The procedure accepts at most ", (integer_to_binary(Max))/binary,
            " positional arguments.">>,
        #{maximum_arity => Max}
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
    #call{args = [Uri | _]} = Msg, Ctxt, Min, _, Len, AdminOnly
) when
    Len >= Min
->
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
    unauthorized(?UNREGISTER, M#unregister.request_id, Ctxt);
unauthorized(#call{} = M, Ctxt) ->
    unauthorized(?CALL, M#call.request_id, Ctxt);
unauthorized(#invocation{} = M, Ctxt) ->
    unauthorized(?INVOCATION, M#invocation.request_id, Ctxt);
unauthorized(#cancel{} = M, Ctxt) ->
    unauthorized(?CANCEL, M#cancel.request_id, Ctxt).

%% @private
unauthorized(Type, ReqId, Ctxt) ->
    Uri = bondy_context:realm_uri(Ctxt),
    Message = <<
        "You have no authorisation to perform this operation on this realm."
    >>,
    Description = <<
        "The operation you've requested is targeting a realm ",
        $\s,
        $(,
        $",
        Uri/binary,
        $",
        $),
        $,,
        " that is not your session's realm or the operation is only "
        "supported when performed by a session on the Bondy Master Realm.",
        $\s,
        $(,
        $",
        (?MASTER_REALM_URI)/binary,
        $",
        $),
        $.
    >>,
    Error = bondy_error:new(not_authorized, #{
        message => Message,
        description => Description,
        details => #{
            realm_uri => Uri,
            master_realm_uri => ?MASTER_REALM_URI
        }
    }),
    bondy_wamp_error:to_wamp(Error, Type, ReqId, #{}).

%% @private
arity_error(Msg, Description, Details) ->
    Error = bondy_error:new(invalid_argument, #{
        message => ~"Invalid number of positional arguments.",
        description => Description,
        details => Details
    }),
    bondy_wamp_error:to_wamp(
        Error, ?CALL, bondy_wamp_message:request_id(Msg), #{}
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
    Error = bondy_error:new(deprecated_procedure, #{
        details => #{procedure_uri => Uri}
    }),
    bondy_wamp_error:to_wamp(Error, M).
