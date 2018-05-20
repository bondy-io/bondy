-module(bondy_wamp_utils).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").


-export([maybe_error/2]).
-export([validate_admin_call_args/3]).
-export([validate_admin_call_args/4]).
-export([validate_call_args/3]).
-export([validate_call_args/4]).



%% =============================================================================
%% API
%% =============================================================================




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
    %% We default to the session's Realm
    case {AdminOnly, bondy_context:realm_uri(Ctxt)} of
        {false, Uri} ->
            {ok, [Uri]};
        {_, ?BONDY_REALM_URI} ->
            {ok, [?BONDY_REALM_URI]};
        {_, _} ->
            {error, unauthorized(M)}
    end;

do_validate_call_args(
    #call{arguments = [Uri|_] = L} = M, Ctxt, _, _, AdminOnly) ->
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
        ?CALL,
        M#call.request_id,
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