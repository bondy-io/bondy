%% =============================================================================
%%  bondy_dealer.erl -
%%
%%  Copyright (c) 2016-2021 Leapsight. All rights reserved.
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


%% =============================================================================
%% @doc
%% This module implements the capabilities of a Dealer. It is used by
%% {@link bondy_router}.
%%
%% A Dealer is one of the two roles a Router plays. In particular a Dealer is
%% the middleman between an Caller and a Callee in an RPC interaction,
%% i.e. it works as a generic router for remote procedure calls
%% decoupling Callers and Callees.
%%
%% Callees register the procedures they provide with Dealers.  Callers
%% initiate procedure calls first to Dealers.  Dealers route calls
%% incoming from Callers to Callees implementing the procedure called,
%% and route call results back from Callees to Callers.
%%
%% A Caller issues calls to remote procedures by providing the procedure
%% URI and any arguments for the call. The Callee will execute the
%% procedure using the supplied arguments to the call and return the
%% result of the call to the Caller.
%%
%% The Caller and Callee will usually implement all business logic, while the
%% Dealer works as a generic router for remote procedure calls
%% decoupling Callers and Callees.
%%
%% Bondy does not provide message transformations to ensure stability and
%% safety.
%% As such, any required transformations should be handled by Callers and
%% Callees directly (notice that a Callee can act as a middleman implementing
%% the required transformations).
%%
%% The message flow between _Callees_ and a _Dealer_ for registering and
%% unregistering endpoints to be called over RPC involves the following
%% messages:
%%
%%    1.  "REGISTER"
%%    2.  "REGISTERED"
%%    3.  "UNREGISTER"
%%    4.  "UNREGISTERED"
%%    5.  "ERROR"
%%
%% ```
%%        ,------.          ,------.               ,------.
%%        |Caller|          |Dealer|               |Callee|
%%        `--+---'          `--+---'               `--+---'
%%           |                 |                      |
%%           |                 |                      |
%%           |                 |       REGISTER       |
%%           |                 | &lt;---------------------
%%           |                 |                      |
%%           |                 |  REGISTERED or ERROR |
%%           |                 | ---------------------&gt;
%%           |                 |                      |
%%           |                 |                      |
%%           |                 |                      |
%%           |                 |                      |
%%           |                 |                      |
%%           |                 |      UNREGISTER      |
%%           |                 | &lt;---------------------
%%           |                 |                      |
%%           |                 | UNREGISTERED or ERROR|
%%           |                 | ---------------------&gt;
%%        ,--+---.          ,--+---.               ,--+---.
%%        |Caller|          |Dealer|               |Callee|
%%        `------'          `------'               `------'
%%
%% '''
%%
%% # Calling and Invocations
%%
%% The message flow between _Callers_, a _Dealer_ and _Callees_ for
%% calling procedures and invoking endpoints involves the following
%% messages:
%%
%%    1. "CALL"
%%
%%    2. "RESULT"
%%
%%    3. "INVOCATION"
%%
%%    4. "YIELD"
%%
%%    5. "ERROR"
%%
%% ```
%%        ,------.          ,------.          ,------.
%%        |Caller|          |Dealer|          |Callee|
%%        `--+---'          `--+---'          `--+---'
%%           |       CALL      |                 |
%%           | ----------------&gt;                 |
%%           |                 |                 |
%%           |                 |    INVOCATION   |
%%           |                 | ----------------&gt;
%%           |                 |                 |
%%           |                 |  YIELD or ERROR |
%%           |                 | %lt;----------------
%%           |                 |                 |
%%           | RESULT or ERROR |                 |
%%           | %lt;----------------                 |
%%        ,--+---.          ,--+---.          ,--+---.
%%        |Caller|          |Dealer|          |Callee|
%%        `------'          `------'          `------'
%%
%% '''
%%
%%    The execution of remote procedure calls is asynchronous, and there
%%    may be more than one call outstanding.  A call is called outstanding
%%    (from the point of view of the _Caller_), when a (final) result or
%%    error has not yet been received by the _Caller_.
%%
%% # Remote Procedure Call Ordering
%%
%%    Regarding *Remote Procedure Calls*, the ordering guarantees are as
%%    follows:
%%
%%    If _Callee A_ has registered endpoints for both *Procedure 1* and
%%    *Procedure 2*, and _Caller B_ first issues a *Call 1* to *Procedure
%%    1* and then a *Call 2* to *Procedure 2*, and both calls are routed to
%%    _Callee A_, then _Callee A_ will first receive an invocation
%%    corresponding to *Call 1* and then *Call 2*. This also holds if
%%    *Procedure 1* and *Procedure 2* are identical.
%%
%%    In other words, WAMP guarantees ordering of invocations between any
%%    given _pair_ of _Caller_ and _Callee_. The current implementation
%%    relies on Distributed Erlang which guarantees message ordering betweeen
%%    processes in different nodes.
%%
%%    There are no guarantees on the order of call results and errors in
%%    relation to _different_ calls, since the execution of calls upon
%%    different invocations of endpoints in _Callees_ are running
%%    independently.  A first call might require an expensive, long-running
%%    computation, whereas a second, subsequent call might finish
%%    immediately.
%%
%%    Further, if _Callee A_ registers for *Procedure 1*, the "REGISTERED"
%%    message will be sent by _Dealer_ to _Callee A_ before any
%%    "INVOCATION" message for *Procedure 1*.
%%
%%    There is no guarantee regarding the order of return for multiple
%%    subsequent register requests.  A register request might require the
%%    _Dealer_ to do a time-consuming lookup in some database, whereas
%%    another register request second might be permissible immediately.
%% @end
%% =============================================================================
-module(bondy_dealer).
-include_lib("wamp/include/wamp.hrl").
-include_lib("kernel/include/logger.hrl").
-include("bondy.hrl").


-define(RESERVED_NS(NS),
    <<"Use of reserved namespace '", NS/binary, "'.">>
).

-type invoke_opts() :: #{
    error_formatter :=
        maybe(fun((Reason :: any()) -> wamp_error() | undefined)),
    call_opts       := map()
}.

%% API
-export([callees/1]).
-export([callees/2]).
-export([callees/3]).
-export([close_context/1]).
-export([features/0]).
-export([handle_message/2]).
-export([handle_message/3]).
-export([is_feature_enabled/1]).
-export([match_registrations/2]).
-export([register/3]).
-export([registrations/1]).
-export([registrations/3]).
-export([registrations/4]).
-export([unregister/1]).
-export([unregister/2]).

-compile({no_auto_import, [register/2]}).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Creates a local registration.
%% If the registration is done using a callback module, only the invoke single
%% strategy can be used (i.e. shared_registration and sharded_registration are
%% also disabled). Also the callback module needs to conform to the
%% wamp_api_callback behaviour, otherwise the call fails with a badarg
%% exception.
%% @end
%% -----------------------------------------------------------------------------
-spec register(
    Procedure :: uri(),
    Opts :: map(),
    Ref :: bondy_ref:t() | bondy_context:t()) ->
    {ok, id()}
    | {ok, id(), pid()}
    | {error, already_exists | any()}
    | no_return().

register(Procedure, Opts, Ctxt) when is_map(Ctxt) ->
    register(Procedure, Opts, bondy_context:ref(Ctxt));

register(Procedure, Opts0, Ref) ->

    Opts =
        case bondy_ref:target_type(Ref) of
            pid ->
                Opts0#{shared_registration => true};

            name ->
                Opts0#{shared_registration => true};

            callback ->
                Opts0#{shared_registration => false}
        end,

    case bondy_registry:add(registration, Procedure, Opts, Ref) of
        {ok, Entry, _} ->
            {ok, bondy_registry_entry:id(Entry)};

        {error, {already_exists, _}} ->
            {error, already_exists}
    end.


%% -----------------------------------------------------------------------------
%% @doc For internal Bondy use.
%% Terminates the process identified by Pid by
%% bondy_subscribers_sup:terminate_subscriber/1
%% @end
%% -----------------------------------------------------------------------------
-spec unregister(pid()) -> ok | {error, not_found}.

unregister(Callee) when is_integer(Callee) ->
    error(not_implemented);

unregister(Callee) when is_pid(Callee) ->
    error(not_implemented).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unregister(RegId :: id(), bondy_context:t() | uri()) ->
    ok | {error, not_found}.

unregister(RegId, RealmUri) when is_binary(RealmUri) ->
    unregister(RegId, bondy_context:local_context(RealmUri));

unregister(RegId, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),

    case bondy_registry:lookup(registration, RegId, RealmUri) of
        {error, not_found} = Error ->
            Error;
        Entry ->
            case bondy_registry:remove(Entry) of
                ok ->
                    on_unregister(Entry, Ctxt);
                {ok, false} ->
                    on_unregister(Entry, Ctxt);
                {ok, true} ->
                    on_delete(Entry, Ctxt);
                Error ->
                    Error
            end
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec callees(RealmUri :: uri()) -> [map()] | no_return().

callees(RealmUri) ->
    case bondy_registry:entries(registration, RealmUri, '_', '_') of
        [] ->
            [];
        List ->
            Set = lists:foldl(
                fun(E, Acc) ->
                    Ref = bondy_registry_entry:ref(E),
                    M = #{
                        node => bondy_ref:nodestring(Ref),
                        session_id => bondy_ref:session_id(E)
                    },
                    sets:add_element(M, Acc)
                end,
                sets:new(),
                List
            ),
            sets:to_list(Set)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec callees(RealmUri :: uri(), ProcedureUri :: uri()) ->
    [map()] | no_return().

callees(RealmUri, ProcedureUri) ->
    callees(RealmUri, ProcedureUri, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec callees(RealmUri :: uri(), ProcedureUri :: uri(), Opts :: map()) ->
    [map()] | no_return().

callees(RealmUri, ProcedureUri, Opts) ->
    case bondy_registry:match(registration, ProcedureUri, RealmUri, Opts) of
        '$end_of_table' ->
            [];
        {List, Cont} ->
            Set = lists:foldl(
                fun(E, Acc) ->
                    Ref = bondy_registry_entry:ref(E),
                    M = #{
                        node => bondy_ref:nodestring(Ref),
                        session_id => bondy_ref:session_id(E)
                    },
                    sets:add_element(M, Acc)
                end,
                sets:new(),
                List
            ),
            Res = sets:to_list(Set),

            case Cont of
                '$end_of_table' ->
                    Res;
                _Cont ->
                    %% TODO
                    Res
            end

    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec close_context(bondy_context:t()) -> bondy_context:t().

close_context(Ctxt) ->
    try
        %% Cleanup registrations
        ok = unregister_all(Ctxt),
        %% Cleanup invocations queue
        ok = bondy_rpc_promise:flush(bondy_context:ref(Ctxt)),
        Ctxt
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(#{
                description => "Error while closing context",
                class => Class,
                reason => Reason,
                trace => Stacktrace
            }),
            Ctxt
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec features() -> map().

features() ->
    ?DEALER_FEATURES.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_feature_enabled(binary()) -> boolean().

is_feature_enabled(F) when is_binary(F) ->
    maps:get(F, ?DEALER_FEATURES, false).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec handle_message(M :: wamp_message(), Ctxt :: map()) -> ok | no_return().

handle_message(M, Ctxt) ->
    try
        do_handle_message(M, Ctxt)
    catch
        _:{not_authorized, Reason} ->
            Reply = wamp_message:error_from(
                M,
                #{},
                ?WAMP_NOT_AUTHORIZED,
                [Reason],
                #{message => Reason}
            ),
            bondy:send(bondy_context:ref(Ctxt), Reply);
        throw:not_found ->
            Reply = not_found_error(M, Ctxt),
            bondy:send(bondy_context:ref(Ctxt), Reply)
    end.


%% -----------------------------------------------------------------------------
%% @doc Handles inbound messages received from a relay i.e. a cluster peer node
%% or bridge_relay i.e. edge client or server.
%% @end
%% -----------------------------------------------------------------------------
-spec handle_message(wamp_message(), To :: bondy_ref:t(), Opts :: map()) ->
    ok | no_return().


handle_message(#invocation{} = Msg, Callee, #{from := Caller} = Opts) ->
    %% A remote Caller is making a CALL to a local Callee via a Relay.
    {To, SendOpts} = bondy:prepare_send(Callee, Opts),

    case bondy_ref:target_type(Callee) of
        callback ->
            %% A callback implemented procedure e.g. WAMP Session APIs
            %% on this node. We apply here as we do not need invoke/5 to
            %% enqueue a promise, we will call the module sequentially.

            %% INVOCATION already has the static arguments appended
            %% to its positional args (see call_to_invocation/4).
            CBArgs = [],
            Reply = apply_dynamic_callback(Msg, Callee, Caller, CBArgs),
            bondy:send(To, Reply, SendOpts);

        _ ->
            try
                RealmUri = bondy_ref:realm_uri(Callee),
                Timeout = bondy_utils:timeout(Opts),
                InvocationId = Msg#invocation.request_id,
                CallId = maps:get(
                    x_call_id, Msg#invocation.details, undefined
                ),
                Procedure = maps:get(
                    procedure, Msg#invocation.details, undefined
                ),

                %% If we are handling this here is because any remaining relays
                %% in the 'via' stack are part of the route back to the Caller.
                %% If this was an INVOCATION destined to another peer node then
                %% bondy_peer_wamp_relay would have forwarded itself.
                Via = maps:get(via, SendOpts, undefined),
                %% We enqueue an invocation promise so that we can match it
                %% with the future YIELD or ERROR response from the Callee.
                %% We add the relay so that we can route back the YIELD or
                %% ERROR response to Caller.
                Promise = bondy_rpc_promise:new(
                    InvocationId, Callee, Caller, #{
                        call_id => CallId,
                        procedure => Procedure,
                        via => Via
                    }
                ),

                ok = bondy_rpc_promise:enqueue(RealmUri, Promise, Timeout),

                %% We send the invocation to the local callee
                %% (no use of via here)
                bondy:send(To, Msg, SendOpts)

            catch
                error:_Reason ->
                    maybe_reroute_invocation(Msg, To, SendOpts)
            end
    end;

handle_message(#yield{} = M, Caller, #{from := Callee}) ->
    %% A remote Callee is returning a YIELD to an INVOCATION done
    %% on behalf of a local Caller.
    InvocationId = M#yield.request_id,
    RealmUri = bondy_ref:realm_uri(Caller),

    Key = bondy_rpc_promise:key_pattern(
        RealmUri, InvocationId, '_', Callee, Caller
    ),

    Fun = fun
        ({ok, Promise}) ->
            CallId = bondy_rpc_promise:call_id(Promise),
            Result = yield_to_result(CallId, M),
            bondy:send(Caller, Result);

        (empty) ->
            no_matching_promise(M)
    end,

    _ = bondy_rpc_promise:dequeue(Key, Fun),

    ok;

handle_message(
    #error{request_type = ?INVOCATION} = M, Caller, #{from := Callee}) ->
    %% A remote callee is returning an ERROR to an INVOCATION done
    %% on behalf of a local Caller.

    InvocationId = M#error.request_id,
    RealmUri = bondy_ref:realm_uri(Caller),

    Key = bondy_rpc_promise:key_pattern(
        RealmUri, InvocationId, '_', Callee, Caller
    ),

    Fun = fun
        ({ok, Promise}) ->
            CallId = bondy_rpc_promise:call_id(Promise),
            CallError = M#error{request_id = CallId, request_type = ?CALL},
            bondy:send(Caller, CallError, #{from => Callee});

        (empty) ->
            no_matching_promise(M)
    end,

    _ = bondy_rpc_promise:dequeue(Key, Fun),

    ok;

handle_message(#error{request_type = ?CANCEL} = M, Caller, #{from := Callee}) ->
    %% A CANCEL a local Caller made to a remote Callee has failed.
    %% We send the error back to the local Caller, keeping the promise to be
    %% able to match the still pending YIELD message,
    CallId = M#error.request_id,
    RealmUri = bondy_ref:realm_uri(Caller),

    Key = bondy_rpc_promise:key_pattern(
        RealmUri, '_', CallId, Callee, Caller
    ),

    case bondy_rpc_promise:peek(Key) of
        empty ->
            %% The promise already expired the Caller would have already
            %% received a TIMEOUT error as a response for the original CALL.
            no_matching_promise(M);

        {ok, _Promise} ->
            bondy:send(Caller, M, #{from => Callee})
    end;

handle_message(#interrupt{} = M, Callee, #{from := Caller}) ->
    %% A remote Caller is cancelling a previous CALL/INVOCATION
    %% made to a local Callee.
    InvocationId = M#interrupt.request_id,
    RealmUri = bondy_ref:realm_uri(Caller),

    Key = bondy_rpc_promise:key_pattern(
        RealmUri, InvocationId, '_', '_', Caller
    ),

    Fun = fun
        ({ok, _Promise}) ->
            bondy:send(Callee, M, #{from => Caller});

        (empty) ->
            %% The promise already expired the Caller would have already
            %% received a TIMEOUT error as a response for the original CALL.
            no_matching_promise(M)
    end,

    _ = bondy_rpc_promise:dequeue(Key, Fun),

    ok.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
maybe_reroute_invocation(#invocation{} = Msg, To, Opts) ->
    %% TODO https://www.notion.so/leapsight/Call-Re-Routing-c18901c7aaea4ef7896b993d4e5d307f

    %% We need to find another local callee to satisfy the original call,
    %% if it exists, then it is easy. But the reply might need to include the %% original Callee ref.
    %% If there are no local callees then we need to return either
    %% wamp.error.unavailable or wamp.error.no_eligible_callee and let the
    %% origin router re-route.

    Error = no_eligible_callee(
        invocation, Msg#invocation.registration_id
    ),
    bondy:send(To, Error, Opts).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec do_handle_message(M :: wamp_message(), Ctxt :: map()) -> ok | no_return().

do_handle_message(#register{} = M, Ctxt) ->
    handle_register(M, Ctxt);

do_handle_message(#unregister{} = M, Ctxt) ->
    handle_unregister(M, Ctxt);

do_handle_message(#call{procedure_uri = Uri} = M, Ctxt) ->
    %% A local caller
    ok = bondy_rbac:authorize(<<"wamp.call">>, Uri, Ctxt),

    case Uri of
        <<"bondy.", _/binary>> ->
            apply_static_callback(M, Ctxt, bondy_wamp_api);

        <<"com.bondy.", _/binary>> ->
            %% Alias for "bondy"
            apply_static_callback(M, Ctxt, bondy_wamp_api);

        <<"com.leapsight.bondy.", _/binary>> ->
            %% Deprecated API prefix. Now "bondy"
            apply_static_callback(M, Ctxt, bondy_wamp_api);

        <<"wamp.", _/binary>> ->
            apply_static_callback(M, Ctxt, bondy_wamp_meta_api);

        _ ->
            Opts = #{error_formatter => undefined},
            handle_call(M, Ctxt, Uri, Opts)
    end;

do_handle_message(#cancel{} = M, Ctxt0) ->
    %% A local callee is cancelling a previous call
    CallId = M#cancel.request_id,
    Caller = bondy_context:ref(Ctxt0),
    Opts = M#cancel.options,

    %% A response will be send asynchronously by another router process instance

    %% If the callee does not support call canceling, then behavior is 'skip'.
    %% We should check callee but that means we need to broadcast sessions.
    %% Another option is to pay the price and ask bondy to fail on the
    %% remote node after checking the callee does not support it.
    %% The caller is not affected, only in the kill case will receive an
    %% error later in the case of a remote callee.
    case maps:get(mode, Opts, skip) of
        kill ->
            %% INTERRUPT is sent to the callee, but ERROR is not returned
            %% to the caller until the callee has responded to INTERRUPT with
            %% ERROR. In this case, the caller may receive RESULT or
            %% another ERROR if the callee finishes processing the
            %% INVOCATION first.
            %% We thus peek (read) instead of dequeueing.
            Fun = fun(Promise, Ctxt1) ->
                %% If not authoried this will fail with an exception
                Uri = bondy_rpc_promise:procedure_uri(Promise),
                ok = bondy_rbac:authorize(<<"wamp.cancel">>, Uri, Ctxt1),

                InvocationId = bondy_rpc_promise:invocation_id(Promise),
                Callee = bondy_rpc_promise:callee(Promise),

                %% Via might be undefined
                Via = bondy_rpc_promise:via(Promise),

                SendOpts0 = bondy:add_via(Via, Opts#{from => Caller}),
                {To, SendOpts} = bondy:prepare_send(Callee, SendOpts0),

                R = wamp_message:interrupt(InvocationId, Opts),
                ok = bondy:send(To, R, SendOpts),

                {ok, Ctxt1}
            end,
            _ = peek_invocations(CallId, Fun, Ctxt0),
            ok;

        killnowait ->
            %% The pending call is canceled and ERROR is send immediately
            %% back to the caller. INTERRUPT is sent to the callee and any
            %% response to the invocation or interrupt from the callee is
            %% discarded when received.
            %% We dequeue the invocation, that way the response will be
            %% discarded.
            Fun = fun(Promise, Ctxt1) ->
                %% If not authoried this will fail with an exception
                Uri = bondy_rpc_promise:procedure_uri(Promise),
                ok = bondy_rbac:authorize(<<"wamp.cancel">>, Uri, Ctxt1),

                InvocationId = bondy_rpc_promise:invocation_id(Promise),
                Callee = bondy_rpc_promise:callee(Promise),

                Error = wamp_message:error(
                    ?CANCEL,
                    CallId,
                    #{},
                    ?WAMP_CANCELLED,
                    [<<"call_cancelled">>],
                    #{
                        description => <<"The call was cancelled by the user.">>
                    }
                ),

                %% We know the caller is a local session
                ok = bondy:send(Caller, Error, #{}),

                %% But Callee might be remote
                Interrupt = wamp_message:interrupt(InvocationId, Opts),
                Via = bondy_rpc_promise:via(Promise),

                SendOpts0 = bondy:add_via(Via, Opts#{from => Caller}),
                {To, SendOpts} = bondy:prepare_send(Callee, SendOpts0),

                ok = bondy:send(To, Interrupt, SendOpts),

                {ok, Ctxt1}
            end,
            _ = dequeue_invocations(CallId, M, Fun, Ctxt0),
            ok;

        skip ->
            %% The pending call is canceled and ERROR is sent immediately
            %% back to the caller. No INTERRUPT is sent to the callee and
            %% the result is discarded when received.
            %% We dequeue the invocation, that way the response will be
            %% discarded.
            %% TODO instead of dequeing, update the entry to reflect it was
            %% cancelled
            Fun = fun(Promise, Ctxt1) ->
                %% If not authoried this will fail with an exception
                Uri = bondy_rpc_promise:procedure_uri(Promise),
                ok = bondy_rbac:authorize(<<"wamp.cancel">>, Uri, Ctxt1),

                Error = wamp_message:error(
                    ?CANCEL,
                    CallId,
                    #{},
                    ?WAMP_CANCELLED,
                    [<<"call_cancelled">>],
                    #{
                        description => <<"The call was cancelled by the user.">>
                    }
                ),

                ok = bondy:send(Caller, Error, #{}),

                {ok, Ctxt1}
            end,
            _ = dequeue_invocations(CallId, M, Fun, Ctxt0),
            ok
    end;

do_handle_message(#yield{} = M, Ctxt0) ->
    %% A local Callee is replying to an INVOCATION.
    %% We match the YIELD with the original INVOCATION
    %% using the request_id, and with that match the CALL request_id
    %% to find the Caller.
    Callee = bondy_context:ref(Ctxt0),
    RealmUri = bondy_context:realm_uri(Ctxt0),
    InvocationId = M#yield.request_id,
    Key = bondy_rpc_promise:key_pattern(
        RealmUri, InvocationId, '_', Callee, '_'
    ),

    Fun = fun
        ({ok, Promise}) ->
            CallId = bondy_rpc_promise:call_id(Promise),
            Caller = bondy_rpc_promise:caller(Promise),

            %% Via might be undefined. If might have been set when handling the
            %% INVOCATION in handle_message/3 and provides the route back to
            %% the Caller i.e. a pipe of relays.
            Via = bondy_rpc_promise:via(Promise),

            SendOpts0 = #{from => Callee, via => Via},
            {To, SendOpts} = bondy:prepare_send(Caller, SendOpts0),

            IsRemoteCaller =
                Via =/= undefined orelse not bondy_ref:is_local(Caller),

            case IsRemoteCaller of
                true ->
                    %% We return the YIELD message
                    bondy:send(To, M, SendOpts);
                false ->
                    Result = yield_to_result(CallId, M),
                    bondy:send(To, Result, SendOpts)
            end;

        (empty) ->
            no_matching_promise(M)
    end,

    _ = bondy_rpc_promise:dequeue(Key, Fun),

    ok;

do_handle_message(#error{request_type = ?INVOCATION} = M, Ctxt0) ->
    %% A local Callee is replying to a previous INVOCATION.
    %% We match the ERROR with the original INVOCATION
    %% using the request_id, and with that match the CALL request_id
    %% to find the Caller.
    Callee = bondy_context:ref(Ctxt0),
    RealmUri = bondy_context:realm_uri(Ctxt0),
    InvocationId = M#error.request_id,
    Key = bondy_rpc_promise:key_pattern(
        RealmUri, InvocationId, '_', Callee, '_'
    ),

    Fun = fun
        ({ok, Promise}) ->
            CallId = bondy_rpc_promise:call_id(Promise),
            Caller = bondy_rpc_promise:caller(Promise),
            %% Via might be undefined. If might have been set when handling the
            %% INVOCATION in handle_message/3
            Via = bondy_rpc_promise:via(Promise),

            SendOpts0 = bondy:add_via(Via, #{from => Callee}),

            case bondy:prepare_send(Caller, SendOpts0) of
                {To, #{via := _} = SendOpts} ->
                    %% Caller is remote so the INVOCATION was forwarded to us,
                    %% we need to modify the ERROR to make it a CALL error
                    %% as we are sending back the error message directly to
                    %% the Caller.
                    Error = M#error{request_id = CallId, request_type = ?CALL},
                    bondy:send(To, Error, SendOpts);

                {To, SendOpts} ->
                    bondy:send(To, M, SendOpts)
            end;

        (empty) ->
            no_matching_promise(M)
    end,

    _ = bondy_rpc_promise:dequeue(Key, Fun),
    ok;

do_handle_message(#error{request_type = ?INTERRUPT} = M, Ctxt0) ->
    %% A callee is responding with an error to an INTERRUPT message
    %% We need to turn this into a CANCEL error
    Callee = bondy_context:ref(Ctxt0),
    RealmUri = bondy_context:realm_uri(Ctxt0),
    InvocationId = M#error.request_id,
    Key = bondy_rpc_promise:key_pattern(
        RealmUri, InvocationId, '_', Callee, '_'
    ),

    case bondy_rpc_promise:peek(Key) of
        {ok, Promise} ->
            CallId = bondy_rpc_promise:call_id(Promise),
            Caller = bondy_rpc_promise:caller(Promise),
            %% Via might be undefined. If might have been set when handling the
            %% INVOCATION in handle_message/3
            Via = bondy_rpc_promise:via(Promise),

            SendOpts0 = bondy:add_via(Via, #{from => Callee}),

            {To, SendOpts} = bondy:prepare_send(Caller, SendOpts0),
            CancelError = M#error{request_id = CallId, request_type = ?CALL},

            bondy:send(To, CancelError, SendOpts);

        empty ->
            %% Call was evicted or performed already by Callee
            no_matching_promise(M),
            ok
    end.


%% @private
handle_call(#call{} = Msg, Ctxt0, Uri, Opts0) ->
    CallUri = Msg#call.procedure_uri,
    Caller = bondy_context:ref(Ctxt0),

    %% Based on procedure registration and passed options, we will
    %% determine how many invocations and to whom we should do.
    Fun = fun
        (Entry, Ctxt) ->
            Callee = bondy_registry_entry:ref(Entry),
            IsLocal = bondy_ref:is_local(Callee),

            case bondy_ref:target_type(Callee) of
                callback when IsLocal == true, CallUri == Uri ->
                    %% A callback implemented procedure e.g. WAMP Session APIs
                    %% on this node. We apply here as we do not need invoke/5 to
                    %% enqueue a promise, we will apply the callback
                    %% and respond sequentially.
                    CBArgs = bondy_registry_entry:callback_args(Entry),
                    Reply = apply_dynamic_callback(Msg, Callee, Ctxt, CBArgs),

                    bondy:send(Caller, Reply, #{from => Callee}),
                    {ok, Ctxt};
                _ ->
                    %% All other cases, including remote callbacks,
                    %% we need to invoke normally
                    Invocation = call_to_invocation(Msg, Uri, Entry, Ctxt),
                    {ok, Invocation, Ctxt}
            end
    end,

    %% A response will be send asynchronously
    Opts = Opts0#{call_opts => Msg#call.options},

    invoke(Msg#call.request_id, Uri, Fun, Opts, Ctxt0).


%% -----------------------------------------------------------------------------
%% @private
%% @doc If the callback module returns ignore we need to find the callee in the
%% registry
%% @end
%% -----------------------------------------------------------------------------
apply_static_callback(#call{} = M0, Ctxt, Mod) ->
    %% Caller is always local.
    Caller = bondy_context:ref(Ctxt),
    DefaultOpts = #{error_formatter => undefined},

    try Mod:handle_call(M0, Ctxt) of
        ok ->
            ok;
        continue ->
            handle_call(M0, Ctxt, M0#call.procedure_uri, DefaultOpts);

        {continue, #call{} = M1}  ->
            handle_call(M1, Ctxt, M1#call.procedure_uri, DefaultOpts);

        {continue, #call{} = M1, Fun}  ->
            Opts = DefaultOpts#{error_formatter => Fun},
            handle_call(M1, Ctxt, M1#call.procedure_uri, Opts);

        {continue, Uri} when is_binary(Uri) ->
            handle_call(M0, Ctxt, Uri, DefaultOpts);

        {continue, Uri, Fun} when is_binary(Uri) ->
            Opts = DefaultOpts#{error_formatter => Fun},
            handle_call(M0, Ctxt, Uri, Opts);

        {reply, Reply} ->
            bondy:send(Caller, Reply)

    catch
        throw:no_such_procedure ->
            Error = bondy_wamp_utils:no_such_procedure_error(M0),
            bondy:send(Caller, Error);

        Class:Reason:Stacktrace ->
            ?LOG_WARNING(#{
                description => <<"Error while handling WAMP call">>,
                procedure => M0#call.procedure_uri,
                caller => bondy_context:session_id(Ctxt),
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            %% We catch any exception from handle/3 and turn it
            %% into a WAMP Error
            Error = bondy_wamp_utils:maybe_error({error, Reason}, M0),
            bondy:send(Caller, Error)
    end.


%% @private
apply_dynamic_callback(#call{} = Msg, Callee, Ctxt, CBArgs)
when is_map(Ctxt) ->
    ReqId = Msg#call.request_id,

    {M, F} = bondy_ref:callback(Callee),
    A = to_callback_args(Msg, CBArgs),

    try erlang:apply(M, F, A) of
        {ok, Details, Args, KWArgs} ->
            wamp_message:result(
                ReqId,
                Details,
                Args,
                KWArgs
            );

        {error, Uri, Details, Args, KWArgs} ->
            wamp_message:error(
                ?CALL,
                ReqId,
                Details,
                Uri,
                Args,
                KWArgs
            );

        Other ->
            error({invalid_return, Other})
    catch
        error:undef ->
            badarity_error(ReqId, ?CALL);

        error:{badarg, _} ->
            badarg_error(ReqId, ?CALL)
    end;

apply_dynamic_callback(#invocation{} = Msg, Callee, Caller, CBArgs) ->
    bondy_ref:is_type(Caller)
        orelse error({badarg, {caller, Caller}}),

    ReqId = Msg#invocation.request_id,

    {M, F} = bondy_ref:callback(Callee),

    A = to_callback_args(Msg, CBArgs),

    try erlang:apply(M, F, A) of
        {ok, Details, Args, KWArgs} ->
            wamp_message:result(
                ReqId,
                Details,
                Args,
                KWArgs
            );

        {error, Uri, Details, Args, KWArgs} ->
            wamp_message:error(
                ?INVOCATION,
                ReqId,
                Details,
                Uri,
                Args,
                KWArgs
            );

        Other ->
            error({invalid_return, Other})
    catch
        error:undef ->
            badarity_error(ReqId, ?INVOCATION);

        error:{badarg, _} ->
            badarg_error(ReqId, ?INVOCATION)
    end.


%% @private
to_callback_args(#call{} = Msg, ExtraArgs) ->
    lists:append([
        ExtraArgs,
        args_to_list(Msg#call.args),
        args_to_list(Msg#call.kwargs),
        args_to_list(Msg#call.options)
    ]);

to_callback_args(#invocation{} = Msg, ExtraArgs) ->
    lists:append([
        ExtraArgs,
        args_to_list(Msg#invocation.args),
        args_to_list(Msg#invocation.kwargs),
        args_to_list(Msg#invocation.details)
    ]).


%% @private
args_to_list(undefined) ->
    [];

args_to_list(L) when is_list(L) ->
    L;

args_to_list(M) when is_map(M) ->
    [M].


%% @private
-spec format_error(any(), map()) -> maybe(wamp_error()).

format_error(_, undefined) ->
    undefined;

format_error(_, #{error_formatter := undefined}) ->
    undefined;

format_error(Error, #{error_formatter := Fun}) ->
    Fun(Error).


%% @private
call_to_invocation(M, Uri, Entry, Ctxt1) ->
    ReqId = bondy_context:get_id(Ctxt1, session),
    Details = invocation_details(M#call.request_id, M, Uri, Entry, Ctxt1),
    KWArgs = M#call.kwargs,

    %% If this is a callback, then it must be a remote callback, as we should
    %% have handled the local callback sequentially.
    %% We add the statically defined arguments to the INVOCATION so that when
    %% we avoid the receiving node having to look the local copy of the entry
    %% to retrieve the arguments.
    Args =
        case bondy_registry_entry:is_callback(Entry) of
            true ->
                bondy_registry_entry:callback_args(Entry) ++ M#call.args;
            false ->
                M#call.args
        end,

    RegId =
        case bondy_registry_entry:is_proxy(Entry) of
            true ->
                %% The entry was registered by a bridge relay.
                %% We need to use the origin registration id (as
                %% opposed to the bridge relay's registration).
                bondy_registry_entry:origin_id(Entry);
            false ->
                bondy_registry_entry:id(Entry)
        end,

    wamp_message:invocation(ReqId, RegId, Details, Args, KWArgs).


%% @private
invocation_details(CallId, M, Uri, Entry, Ctxt) ->
    CallOpts = M#call.options,
    RegOpts = bondy_registry_entry:options(Entry),
    Details0 = #{
        procedure => Uri,
        trust_level => 0,
        x_call_id => CallId
    },

    %% TODO disclose info only if feature is announced by Callee, Dealer
    %% and Caller
    DiscloseMe = maps:get(disclose_me, CallOpts, true),
    DiscloseCaller = maps:get(disclose_caller, RegOpts, true),
    Details1 = case DiscloseCaller orelse DiscloseMe of
        true ->
            bondy_context:caller_details(Ctxt, Details0);
        false ->
            Details0
    end,

    Details2 = case maps:get('x_disclose_session_info', RegOpts, false) of
        true ->
            Session = bondy_context:session(Ctxt),
            Info = bondy_session:info(Session),
            Details1#{'x_session_info' => Info};
        false ->
            Details1
    end,

    % case bondy_registry_entry:is_proxy(Entry) of
    %     true ->
    %         maps:merge(Details2, bondy_registry_entry:proxy_details(Entry));
    %     false ->
    %         Details2
    % end.
    Details2.


%% -----------------------------------------------------------------------------
%% @doc
%% Registers an RPC endpoint.
%% If the registration already exists, it fails with a
%% `{not_authorized | procedure_already_exists, binary()}' reason.
%% @end
%% -----------------------------------------------------------------------------
handle_register(#register{procedure_uri = Uri} = M, Ctxt) ->
    ok = maybe_reserved_ns(Uri),
    ok = bondy_rbac:authorize(<<"wamp.register">>, Uri, Ctxt),

    #register{options = Opts0, request_id = ReqId} = M,

    %% We add an option used by bondy_registry
    Val = bondy_context:is_feature_enabled(Ctxt, callee, shared_registration),
    Opts = Opts0#{shared_registration => Val},

    Ref = bondy_context:ref(Ctxt),

    case bondy_registry:add(registration, Uri, Opts, Ref) of
        {ok, Entry, IsFirst} ->
            ok = on_register(IsFirst, Entry, Ctxt),
            Id = bondy_registry_entry:id(Entry),
            Reply = wamp_message:registered(ReqId, Id),
            bondy:send(Ref, Reply);

        {error, {already_exists, Entry}} ->
            Policy = bondy_registry_entry:match_policy(Entry),
            Msg = <<
                "The procedure is already registered by another peer ",
                "with policy ", $', Policy/binary, $', $.
            >>,
            Reply = wamp_message:error(
                ?REGISTER,
                ReqId,
                #{},
                ?WAMP_PROCEDURE_ALREADY_EXISTS,
                [Msg]
            ),
            bondy:send(Ref, Reply)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Unregisters an RPC endpoint.
%% If the registration does not exist, it fails with a 'no_such_registration' or
%% '{not_authorized, binary()}' error.
%% @end
%% -----------------------------------------------------------------------------
-spec handle_unregister(wamp_unregister(), bondy_context:t()) ->
    ok | no_return().

handle_unregister(#unregister{} = M, Ctxt) ->
    RegId = M#unregister.registration_id,
    RealmUri = bondy_context:realm_uri(Ctxt),
    %% TODO Shouldn't we restrict this operation to the peer who registered it?
    %% and/or a Bondy Admin for revoke registration?
    case bondy_registry:lookup(registration, RegId, RealmUri) of
        {error, not_found} ->
            throw(not_found);
        Entry ->
            Uri = bondy_registry_entry:uri(Entry),
            %% We authorize first
            ok = bondy_rbac:authorize(<<"wamp.unregister">>, Uri, Ctxt),
            unregister(Uri, M, Ctxt)
    end.


%% @private
unregister(Uri, M, Ctxt) ->
    ok = maybe_reserved_ns(Uri),
    RegId = M#unregister.request_id,
    ok = bondy_rbac:authorize(<<"wamp.unregister">>, Uri, Ctxt),
    ok = bondy_registry:remove(registration, RegId, Ctxt, fun on_unregister/2),
    Reply = wamp_message:unregistered(RegId),
    bondy:send(bondy_context:ref(Ctxt), Reply).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unregister_all(bondy_context:t()) -> ok.

unregister_all(Ctxt) ->
    bondy_registry:remove_all(registration, Ctxt, fun on_unregister/2).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Returns the list of registrations for the active session.
%%
%% When called with a bondy:context() it is equivalent to calling
%% registrations/2 with the RealmUri and SessionId extracted from the Context.
%% @end
%% -----------------------------------------------------------------------------
-spec registrations(bondy_registry:continuation()) ->
    {
        [bondy_registry_entry:t()],
        bondy_registry:continuation() | bondy_registry:eot()
    }
    | bondy_registry:eot().

registrations(?EOT) ->
    ?EOT;

registrations({registration, _} = Cont) ->
    bondy_registry:entries(Cont).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Returns the complete list of registrations matching the RealmUri
%% and SessionId.
%%
%% Use {@link registrations/3} and {@link registrations/1} to limit the
%% number of registrations returned.
%% @end
%% -----------------------------------------------------------------------------
-spec registrations(
    RealmUri :: uri(),
    Node :: atom() | '_',
    SessionId :: id() | '_') ->
    [bondy_registry_entry:t()].

registrations(RealmUri, Node, SessionId) ->
    bondy_registry:entries(registration, RealmUri, Node, SessionId).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Returns the  list of registrations matching the RealmUri and SessionId.
%%
%% Use {@link registrations/3} to limit the number of registrations returned.
%% @end
%% -----------------------------------------------------------------------------
-spec registrations(
    RealmUri :: uri(),
    Node :: atom() | '_',
    SessionId :: id() | '_',
    Limit :: non_neg_integer()) ->
    {[bondy_registry_entry:t()], bondy_registry_entry:continuation_or_eot()}
    | bondy_registry_entry:eot().

registrations(RealmUri, Node, SessionId, Limit) ->
    bondy_registry:entries(registration, RealmUri, Node, SessionId, Limit).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_registrations(uri(), bondy_context:t()) ->
    {
        [bondy_registry_entry:t()],
        bondy_registry:continuation() | bondy_registry:eot()
    }.

match_registrations(ProcUri, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    bondy_registry:match(registration, ProcUri, RealmUri).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_registrations(uri(), bondy_context:t(), map()) ->
    {
        [bondy_registry_entry:t()],
        bondy_registry:continuation() | bondy_registry:eot()
    }.

match_registrations(ProcUri, Ctxt, Opts) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    bondy_registry:match(registration, ProcUri, RealmUri, Opts).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_registrations(bondy_registry:continuation()) ->
    {
        [bondy_registry_entry:t()],
        bondy_registry:continuation() | bondy_registry:eot()
    }.

match_registrations({registration, _} = Cont) ->
    bondy_registry:match(Cont).


%% @private
-spec reply_error(wamp_error(), bondy_context:t()) -> ok.

reply_error(Error, Ctxt) ->
    bondy:send(
        bondy_context:ref(Ctxt),
        Error
    ).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue_invocations(
    id(), wamp_message(), function(), bondy_context:t()) ->
    {ok, bondy_context:t()}.

dequeue_invocations(CallId, M, Fun, Ctxt) when is_function(Fun, 2) ->
    Caller = bondy_context:ref(Ctxt),
    RealmUri = bondy_context:realm_uri(Ctxt),
    Key = bondy_rpc_promise:key_pattern(
        RealmUri, '_', CallId, '_', Caller
    ),

    case bondy_rpc_promise:dequeue(Key) of
        empty ->
            %% Promises for this call were either interrupted by us,
            %% fulfilled or timed out and/or garbage collected.
            ok = no_matching_promise(M),
            {ok, Ctxt};

        {ok, Promise} ->
            {ok, Ctxt1} = Fun(Promise, Ctxt),
            %% We iterate until there are no more pending invocation for the
            %% call_request_id == CallId
            dequeue_invocations(CallId, M, Fun, Ctxt1)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec peek_invocations(
    id(),
    fun((bondy_rpc_promise:t(), bondy_context:t()) -> {ok, bondy_context:t()}),
    bondy_context:t()) -> {ok, bondy_context:t()}.

peek_invocations(CallId, Fun, Ctxt) when is_function(Fun, 2) ->
    Caller = bondy_context:ref(Ctxt),
    RealmUri = bondy_context:realm_uri(Ctxt),
    Key = bondy_rpc_promise:key_pattern(
        RealmUri, '_', CallId, '_', Caller
    ),

    case bondy_rpc_promise:peek(Key) of
        empty ->
            {ok, Ctxt};
        {ok, Promise} ->
            {ok, Ctxt1} = Fun(Promise, Ctxt),
            %% We iterate until there are no more pending invocation for the
            %% call_request_id == CallId
            peek_invocations(CallId, Fun, Ctxt1)
    end.


%% @private
no_matching_promise(M) ->
    %% Promise was fulfilled or timed out and/or garbage collected,
    %% we do nothing.
    ?LOG_DEBUG(#{
        description => "Message ignored",
        reason => no_matching_promise,
        message => M
    }),
    ok.



%% =============================================================================
%% PRIVATE - INVOCATION STRATEGIES (LOAD BALANCING, FAIL OVER, ETC)
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @private
%% @doc Used to handle calls from local callers only
%% Throws {not_authorized, binary()}
%% @end
%% -----------------------------------------------------------------------------
-spec invoke(id(), uri(), function(), invoke_opts(), bondy_context:t()) -> ok.

invoke(CallId, ProcUri, UserFun, Opts, Ctxt0) when is_function(UserFun, 2) ->
    case match_registrations(ProcUri, Ctxt0, #{}) of
        ?EOT ->
            Error = case format_error(no_such_procedure, Opts) of
                undefined ->
                    bondy_wamp_utils:no_such_procedure_error(
                        ProcUri, ?CALL, CallId
                    );
                Value ->
                    Value
            end,
            reply_error(Error, Ctxt0);
        Regs ->
            %% We invoke Fun for each entry
            Fun = fun
                ({error, ErrorMap}, Ctxt1) when is_map(ErrorMap) ->
                    Error = case format_error(no_such_procedure, Opts) of
                        undefined ->
                            error_from_map(ErrorMap, CallId);
                        Value ->
                            Value
                    end,
                    ok = reply_error(Error, Ctxt1),
                    {ok, Ctxt1};

                ({error, noproc}, Ctxt1) ->
                    %% The local process associated with the entry
                    %% is no longer alive, we turn this into no_such_procedure
                    Error = case format_error(no_such_procedure, Opts) of
                        undefined ->
                            bondy_wamp_utils:no_such_procedure_error(
                                ProcUri, ?CALL, CallId
                            );
                        Value ->
                            Value
                    end,

                    ok = reply_error(Error, Ctxt1),
                    {ok, Ctxt1};

                (Entry, Ctxt1) ->
                    %% We invoke the provided fun which actually makes the
                    %% invocation
                    case UserFun(Entry, Ctxt1) of
                        {ok, Ctxt2} ->
                            %% UserFun sent a response sequentially, no need
                            %% for promises
                            {ok, Ctxt2};

                        {ok, #invocation{} = Msg, Ctxt2} ->
                            %% We sent an INVOCATION and we will be waiting for
                            %% an asynchronous response (YIELD | ERROR).
                            RealmUri = bondy_context:realm_uri(Ctxt1),
                            Caller = bondy_context:ref(Ctxt1),
                            ReqId = Msg#invocation.request_id,

                            Ref = bondy_registry_entry:ref(Entry),
                            Origin = bondy_registry_entry:origin_ref(Entry),

                            %% SendOpts might include 'via' field which we use
                            %% to build the promise
                            {Callee, SendOpts} = bondy:prepare_send(
                                Ref, Origin, Opts#{from => Caller}
                            ),

                            Promise = bondy_rpc_promise:new(
                                ReqId,
                                Callee,
                                Caller,
                                % SendOpts#{
                                %     call_id => CallId,
                                %     procedure_uri => ProcUri
                                % }
                                #{
                                    call_id => CallId,
                                    procedure_uri => ProcUri
                                }
                            ),

                            ok = bondy_rpc_promise:enqueue(
                                RealmUri,
                                Promise,
                                bondy_utils:timeout(call_opts(SendOpts))
                            ),

                            ok = bondy:send(Callee, Msg, SendOpts),

                            {ok, Ctxt2}
                    end
            end,
            invoke_aux(Regs, Fun, Opts, Ctxt0)
    end.


call_opts(#{call_opts := Val}) -> Val;
call_opts(_) -> #{}.


%% @private
invoke_aux(?EOT, _, _, _) ->
    ok;

invoke_aux({L, ?EOT}, Fun, Opts, Ctxt) ->
    invoke_aux(L, Fun, Opts, Ctxt);

invoke_aux({L, Cont}, Fun, Opts, Ctxt) ->
    ok = invoke_aux(L, Fun, Opts, Ctxt),
    invoke_aux(match_registrations(Cont), Fun, Opts, Ctxt);

invoke_aux(L, Fun, Opts, Ctxt) when is_list(L) ->
    %% Registrations have different invocation strategies provided by the
    %% 'invoke' key.
    Triples = [
        {
            bondy_registry_entry:uri(E),
            maps:get(invoke, bondy_registry_entry:options(E), ?INVOKE_SINGLE),
            E
        } || E <- L
    ],
    invoke_aux(Triples, undefined, Fun, Opts, Ctxt).


%% @private
-spec invoke_aux(
    [{uri(), Strategy :: binary(), Entry :: tuple()}],
    Last :: tuple() | undefined,
    Fun :: function(),
    Opts :: map(),
    Ctxt :: bondy_context:t()) ->
    ok.

invoke_aux([], undefined, _, _, _) ->
    ok;

invoke_aux([], {_, ?INVOKE_SINGLE, []}, _, _, _) ->
    ok;

invoke_aux([], {_, Invoke, L}, Fun, Opts, Ctxt0) ->
    {ok, _Ctxt1} = do_invoke({Invoke, L}, Fun, Opts, Ctxt0),
    ok;

invoke_aux([{Uri, ?INVOKE_SINGLE, E}|T], undefined, Fun, Opts, Ctxt0) ->
    {ok, Ctxt1} = do_invoke({?INVOKE_SINGLE, [E]}, Fun, Opts, Ctxt0),
    %% We add an accummulator to drop any subsequent matching Uris.
    invoke_aux(T, {Uri, ?INVOKE_SINGLE, []}, Fun, Opts, Ctxt1);

invoke_aux(
    [{Uri, ?INVOKE_SINGLE, _}|T], {Uri, ?INVOKE_SINGLE, _} = Last,
    Fun, Opts, Ctxt) ->
    %% A single invocation strategy and we have multiple registrations so we
    %% ignore them
    %% Invoke should match too, otherwise there is an inconsistency
    %% in the registry
    invoke_aux(T, Last, Fun, Opts, Ctxt);

invoke_aux([{Uri, Invoke, E}|T], undefined, Fun, Opts, Ctxt) ->
    %% We do not apply the invocation yet as it is not single, so we need
    %% to accummulate and apply at the end.
    %% We build a list for subsequent entries for same Uri.
    invoke_aux(T, {Uri, Invoke, [E]}, Fun, Opts, Ctxt);

invoke_aux([{Uri, Invoke, E}|T], {Uri, Invoke, L}, Fun, Opts, Ctxt)  ->
    %% We do not invoke yet as it is not single, so we need
    %% to accummulate and apply at the end using load balancing.
    %% We build a list for subsequent entries for same Uri.
    %% Invoke should match too, otherwise there is an inconsistency
    %% in the registry
    invoke_aux(T, {Uri, Invoke, [E|L]}, Fun, Opts, Ctxt);

invoke_aux([{Uri, ?INVOKE_SINGLE, E}|T], {_, Invoke, L}, Fun, Opts, Ctxt0) ->
    %% We found a different Uri so we invoke the previous one
    {ok, Ctxt1} = do_invoke({Invoke, L}, Fun, Opts, Ctxt0),
    %% The new one is a single so we also invoke and continue
    %% TODO why do we invoke this one?
    {ok, Ctxt2} = do_invoke({?INVOKE_SINGLE, [E]}, Fun, Opts, Ctxt1),
    invoke_aux(T, {Uri, ?INVOKE_SINGLE, []}, Fun, Opts, Ctxt2);

invoke_aux([{Uri, Invoke, E}|T], {_, Invoke, L}, Fun, Opts, Ctxt0)  ->
    %% We found another Uri so we invoke the previous one
    {ok, Ctxt1} = do_invoke({Invoke, L}, Fun, Opts, Ctxt0),
    %% We do not apply the invocation yet as it is not single, so we need
    %% to accummulate and apply at the end.
    %% We build a list for subsequent entries for same Uri.
    invoke_aux(T, {Uri, Invoke, [E]}, Fun, Opts, Ctxt1).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Implements load balancing and fail over invocation strategies.
%% This works over a list of registration entries for the SAME
%% procedure.
%% @end
%% -----------------------------------------------------------------------------
-spec do_invoke(term(), function(), map(), bondy_context:t()) ->
    {ok, bondy_context:t()}.


do_invoke({?INVOKE_SINGLE, [Entry]}, Fun, _, Ctxt) ->
    try
        %% This might be a callback implemented procedure
        Fun(Entry, Ctxt)
    catch
        throw:{error, _} = ErrorMap ->
            %% Unexpected error ocurred
            Fun(ErrorMap, Ctxt)
    end;

do_invoke({Strategy, L}, Fun, CallOpts0, Ctxt) ->
    try
        Opts = load_balancer_options(Strategy, CallOpts0),

        %% All this entries need to be registered by a process (internal or
        %% client), otherwise we will crash when bondy_rpc_load_balancer checks
        %% the process is alive. A callback implemented procedure should never
        %% reach this point anyway as they use INVOKE_SINGLE exclusively.
        case bondy_rpc_load_balancer:get(L, Opts) of
            {error, noproc} = Error ->
                %% We trid all callees in the list `L' but none was alive
                throw(Error);
            Entry ->
                Fun(Entry, Ctxt)
        end
    catch
        throw:{error, _} = ErrorMap ->
            %% Unexpected error ocurred
            Fun(ErrorMap, Ctxt)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc Adds support for (Sharded Registration)
%% [https://wamp-proto.org/_static/gen/wamp_latest.html#sharded-registration]
%% by transforming the call runmode and rkey properties into the ones
%% expected by the extensions to REGISTER.Options in order to reuse Bondy's
%% jump_consistent_hash load balancing strategy.
%%
%% @end
%% -----------------------------------------------------------------------------
load_balancer_options(Strategy, CallOpts0) ->
    CallOpts1 = coerce_strategy(Strategy, CallOpts0),
    coerce_routing_key(CallOpts1).


%% @private
coerce_strategy(_, #{runmode := <<"partition">>} = CallOpts) ->
    maps:put(strategy, jump_consistent_hash, CallOpts);

coerce_strategy(Strategy, CallOpts) ->
    %% An invalid runmode value would have been caught by
    %% wamp_message's validation.
    maps:put(strategy, Strategy, CallOpts).


%% @private
coerce_routing_key(#{rkey := Value} = CallOpts) ->
    maps:put('x_routing_key', Value, CallOpts);

coerce_routing_key(CallOpts) ->
    CallOpts.



%% =============================================================================
%% PRIVATE: META EVENTS
%% =============================================================================



%% @private
on_register(true, Entry, Ctxt) ->
    bondy_event_manager:notify({registration_created, Entry, Ctxt});

on_register(false, Entry, Ctxt) ->
    bondy_event_manager:notify({registration_added, Entry, Ctxt}).


%% @private
on_unregister(Entry, Ctxt) ->
    bondy_event_manager:notify({registration_removed, Entry, Ctxt}).


%% @private
on_delete(Map, Ctxt) ->
    bondy_event_manager:notify({registration_deleted, Map, Ctxt}).


error_from_map(Error, CallId) ->
    Msg = <<"The request failed due to invalid option parameters.">>,
    wamp_message:error(
        ?CALL,
        CallId,
        #{},
        ?WAMP_INVALID_ARGUMENT,
        [Msg],
        #{
            message => Msg,
            details => Error,
            description => <<"A required options parameter was missing in the request or while present they were malformed.">>
        }
    ).


%% @private
no_eligible_callee(call, CallId) ->
    Desc = <<"A call was forwarded throught the router cluster for a callee that is no longer available.">>,
    no_eligible_callee(?CALL, CallId, Desc);

no_eligible_callee(invocation, CallId) ->
    Desc = <<"An invocation was forwarded throught the router cluster to a callee that is no longer available.">>,
    no_eligible_callee(?INVOCATION, CallId, Desc).


%% @private
no_eligible_callee(Type, Id, Desc) ->
    Msg = <<
        "There are no elibible callees for the procedure."
    >>,
    wamp_message:error(
        Type,
        Id,
        #{},
        ?WAMP_NO_ELIGIBLE_CALLE,
        [Msg],
        #{message => Msg, description => Desc}
    ).


%% @private
badarity_error(CallId, Type) ->
    Msg = <<
        "The call was made passing the wrong number of positional arguments."
    >>,
    wamp_message:error(
        Type,
        CallId,
        #{},
        ?WAMP_INVALID_ARGUMENT,
        [Msg]
    ).


%% @private
badarg_error(CallId, Type) ->
    Msg = <<
        "The call was made passing invalid arguments."
    >>,
    wamp_message:error(
        Type,
        CallId,
        #{},
        ?WAMP_INVALID_ARGUMENT,
        [Msg]
    ).

%% @private
yield_to_result(CallId, M) ->
    wamp_message:result(
        CallId,
        %% TODO check if yield.options should be assigned to result.details
        M#yield.options,
        M#yield.args,
        M#yield.kwargs
    ).


%% @private
not_found_error(M, _Ctxt) ->
    Msg = iolist_to_binary(
        <<"There are no registered procedures matching the id ",
        $', (M#unregister.registration_id)/integer, $'>>
    ),
    wamp_message:error(
        ?UNREGISTER,
        M#unregister.request_id,
        #{},
        ?WAMP_NO_SUCH_REGISTRATION,
        [Msg],
        #{
            message => Msg,
            description => <<"The unregister request failed.">>
        }
    ).


%% @private
maybe_reserved_ns(<<"com.leapsight.bondy",  _/binary>>) ->
    throw({not_authorized, ?RESERVED_NS(<<"com.leapsight.bondy">>)});

maybe_reserved_ns(<<"bondy",  _/binary>>) ->
    throw({not_authorized, ?RESERVED_NS(<<"bondy">>)});

maybe_reserved_ns(<<"wamp",  _/binary>>) ->
    throw({not_authorized, ?RESERVED_NS(<<"wamp">>)});

maybe_reserved_ns(_) ->
    ok.
