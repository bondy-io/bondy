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


-define(DEFAULT_LIMIT, 1000).
-define(RESERVED_NS(NS),
    <<"Use of reserved namespace '", NS/binary, "'.">>
).

-type invoke_opts() :: #{
    error_formatter :=
        maybe(fun((Reason :: any()) -> wamp_error() | undefined)),
    call_opts       := map()
}.

%% API
-export([close_context/1]).
-export([features/0]).
-export([handle_message/2]).
-export([handle_peer_message/4]).
-export([is_feature_enabled/1]).
-export([registrations/1]).
-export([registrations/3]).
-export([registrations/4]).
-export([match_registrations/2]).
-export([callees/1]).
-export([callees/2]).
-export([callees/3]).
-export([register/4]).
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
    RealmUri :: uri(),
    Opts :: map(),
    Procedure :: uri(),
    Term :: pid() | function() | module()) ->
    {ok, id()}
    | {ok, id(), pid()}
    | {error, already_exists | any()}
    | no_return().

register(_RealmUri, _Opts, _Procedure, Fun) when is_function(Fun, 2) ->
    error(not_implemented);

register(RealmUri, Opts0, Procedure, Pid) when is_pid(Pid) ->
    Opts = Opts0#{shared_registration => true},
    do_register(Procedure, Opts, {RealmUri, Pid});

register(RealmUri, Opts, Procedure, Mod) when is_atom(Mod) ->
    bondy_wamp_callback:conforms(Mod) orelse error({badarg, Mod}),
    do_register(Procedure, Opts, {RealmUri, Mod}).


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
        Entries ->
            All = [
                {
                    bondy_registry_entry:node(E),
                    bondy_registry_entry:session_id(E)
                } || E <- Entries
            ],
            [
                #{node => N, session_id => S}
                || {N, S} <- sets:to_list(sets:from_list(All))
            ]
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
        {[], '$end_of_table'} ->
            [];
        {Entries, '$end_of_table'} ->
            All = [
                {
                    bondy_registry_entry:node(E),
                    bondy_registry_entry:session_id(E)
                } || E <- Entries
            ],
            [
                #{node => N, session_id => S}
                || {N, S} <- sets:to_list(sets:from_list(All))
            ]
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
        ok = bondy_rpc_promise:flush(bondy_context:peer_id(Ctxt)),
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
            bondy:send(bondy_context:peer_id(Ctxt), Reply);
        throw:not_found ->
            Reply = not_found_error(M, Ctxt),
            bondy:send(bondy_context:peer_id(Ctxt), Reply)
    end.


%% -----------------------------------------------------------------------------
%% @doc Handles inbound messages received from a peer (node).
%% @end
%% -----------------------------------------------------------------------------
-spec handle_peer_message(
    wamp_message(),
    To :: remote_peer_id(),
    From :: remote_peer_id(),
    Opts :: map()) ->
    ok | no_return().

handle_peer_message(#yield{} = M, _Caller, Callee, _Opts) ->
    %% A remote callee is returning a yield to a local caller.
    Fun = fun
        (empty) ->
            no_matching_promise(M);
        ({ok, Promise}) ->
            LocalCaller = bondy_rpc_promise:caller(Promise),
            CallId = bondy_rpc_promise:call_id(Promise),
            Result = yield_to_result(CallId, M),
            bondy:send(Callee, LocalCaller, Result, #{})
    end,
    InvocationId = M#yield.request_id,
    _ = bondy_rpc_promise:dequeue_invocation(InvocationId, Callee, Fun),
    ok;

handle_peer_message(
    #error{request_type = ?INVOCATION} = M, _Caller, Callee, _Opts) ->
    %% A remote callee is returning an error to a local caller.
    Fun = fun
        (empty) ->
            no_matching_promise(M);
        ({ok, Promise}) ->
            LocalCaller = bondy_rpc_promise:caller(Promise),
            CallId = bondy_rpc_promise:call_id(Promise),
            CallError = M#error{request_id = CallId, request_type = ?CALL},
            bondy:send(Callee, LocalCaller, CallError, #{})
    end,
    InvocationId = M#error.request_id,
    _ = bondy_rpc_promise:dequeue_invocation(InvocationId, Callee, Fun),
    ok;

handle_peer_message(
    #error{request_type = ?CANCEL} = M, Caller, Callee, _Opts) ->
    %% A CANCEL we made to a remote callee has failed.
    %% We forward the error back to the local caller, keeping the promise to be
    %% able to match the future yield message,
    CallId = M#error.request_id,
    case bondy_rpc_promise:peek_call(CallId, Caller) of
        empty ->
            no_matching_promise(M);
        {ok, Promise} ->
            LocalCaller = bondy_rpc_promise:caller(Promise),
            bondy:send(Callee, LocalCaller, M, #{})
    end,
    ok;

handle_peer_message(#interrupt{} = M, _Callee, Caller, _Opts) ->
    %% A remote caller is cancelling a previous call-invocation
    %% made to our local callee.
    Fun = fun
        (empty) ->
            %% TODO We should reply with an error
            no_matching_promise(M);
        ({ok, Promise}) ->
            LocalCallee = bondy_rpc_promise:callee(Promise),
            bondy:send(Caller, LocalCallee, M, #{})
    end,
    InvocationId = M#interrupt.request_id,
    _ = bondy_rpc_promise:dequeue_invocation(InvocationId, Caller, Fun),
    ok;

handle_peer_message(
    #invocation{} = M, {RealmUri, _, undefined, Mod} = Callee, Caller, _Opts)
    when is_atom(Mod) ->
    Ctxt = bondy_context:local_context(RealmUri),
    {reply, Reply} = Mod:handle_invocation(M, Ctxt),
    bondy:send(Callee, Caller, Reply, #{});

handle_peer_message(#invocation{} = M, Callee, Caller, Opts) ->
    %% A remote caller is making a call to a local callee.
    %% We first need to find the registry entry to get the local callee
    %% At the moment we might not get the Pid in the Callee tuple,
    %% so we fetch it
    {RealmUri, Node, SessionId, _Pid} = Callee,
    Key = bondy_registry_entry:key_pattern(
        registration, RealmUri, Node, SessionId, M#invocation.registration_id
    ),

    %% We use lookup because the key is ground
    case bondy_registry:lookup(Key) of
        {error, not_found} ->
            bondy:send(
                Callee,
                Caller,
                no_eligible_callee(invocation, M#invocation.registration_id),
                #{}
            );
        Entry ->
            LocalCallee = bondy_registry_entry:peer_id(Entry),

            %% We enqueue the invocation so that we can match it with the
            %% YIELD or ERROR
            Promise = bondy_rpc_promise:new(
                M#invocation.request_id, LocalCallee, Caller
            ),

            Timeout = bondy_utils:timeout(Opts),

            ok = bondy_rpc_promise:enqueue(RealmUri, Promise, Timeout),
            bondy:send(Caller, LocalCallee, M, Opts)
    end.




%% =============================================================================
%% PRIVATE
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec do_handle_message(M :: wamp_message(), Ctxt :: map()) -> ok | no_return().

do_handle_message(#register{} = M, Ctxt) ->
    handle_register(M, Ctxt);

do_handle_message(#unregister{} = M, Ctxt) ->
    handle_unregister(M, Ctxt);

do_handle_message(#cancel{} = M, Ctxt0) ->
    %% TODO check if authorized and if not throw wamp.error.not_authorized
    CallId = M#cancel.request_id,
    Caller = bondy_context:peer_id(Ctxt0),
    Opts = M#cancel.options,

    %% We first use peek to find the Promise based on CallId so we can retreive
    %% the Procedure URI required for authrization
    Authorize = fun(Promise, Ctxt) ->
        Uri = bondy_rpc_promise:procedure_uri(Promise),
        ok = bondy_rbac:authorize(<<"wamp.cancel">>, Uri, Ctxt),
        {ok, Ctxt}
    end,
    _ = peek_invocations(CallId, Authorize, Ctxt0),

    %% A response will be send asynchronously by another router process instance

    %% If the callee does not support call canceling, then behavior is skip.
    %% We should check calle but that means we need to broadcast sessions.
    %% Another option is to pay the price and ask bondy to fail on the
    %% remote node after checking the callee does not support it.
    %% The caller is not affected, only in the kill case will receive an
    %% error later in the case of a remote callee.
    case maps:get(mode, Opts, skip) of
        kill ->
            %% INTERRUPT is sent to the callee, but ERROR is not returned
            %% to the caller until the callee has responded to INTERRUPT with
            %% ERROR. In this case, the caller may receive RESULT or
            %% anotehr ERROR if the callee finishes processing the
            %% INVOCATION first.
            %% We thus peek (read) instead of dequeueing.
            Fun = fun(Promise, Ctxt1) ->
                InvocationId = bondy_rpc_promise:invocation_id(Promise),
                Callee = bondy_rpc_promise:callee(Promise),
                R = wamp_message:interrupt(InvocationId, Opts),
                ok = bondy:send(Caller, Callee, R, #{}),
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
                InvocationId = bondy_rpc_promise:invocation_id(Promise),
                Callee = bondy_rpc_promise:callee(Promise),
                Caller = bondy_context:peer_id(Ctxt1),
                Mssg = <<"call_cancelled">>,
                Args = [Mssg],
                ArgsKw = #{
                    message => Mssg,
                    description => <<"The call was cancelled by the user.">>
                },
                Error = wamp_message:error(
                    ?CANCEL, CallId, #{}, ?WAMP_CANCELLED, Args, ArgsKw
                ),
                ok = bondy:send(Callee, Caller, Error, #{}),

                Interrupt = wamp_message:interrupt(InvocationId, Opts),
                ok = bondy:send(Caller, Callee, Interrupt, #{}),
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
                Callee = bondy_rpc_promise:callee(Promise),
                Caller = bondy_context:peer_id(Ctxt1),
                Mssg = <<"call_cancelled">>,
                Args = [Mssg],
                ArgsKw = #{
                    message => Mssg,
                    description => <<"The call was cancelled by the user.">>
                },
                Error = wamp_message:error(
                    ?CANCEL, CallId, #{}, ?WAMP_CANCELLED, Args, ArgsKw),

                ok = bondy:send(Callee, Caller, Error, #{}),

                {ok, Ctxt1}
            end,
            _ = dequeue_invocations(CallId, M, Fun, Ctxt0),
            ok
    end;

do_handle_message(#yield{} = M, Ctxt0) ->
    %% A Callee is replying to a previous wamp_invocation()
    %% which we generated based on a Caller wamp_call()
    %% We match the wamp_yield() with the originating wamp_invocation()
    %% using the request_id, and with that match the wamp_call() request_id
    %% to find the caller pid.
    Callee = bondy_context:peer_id(Ctxt0),
    Fun = fun
        (empty) ->
            no_matching_promise(M);
        ({ok, Promise}) ->
            Caller = bondy_rpc_promise:caller(Promise),
            case bondy_rpc_promise:call_id(Promise) of
                undefined ->
                    %% The caller is remote, we fwd the yield to the peer node
                    %% TODO make this explicit, at the moment a promise with
                    %% undefined callId is a promise for a remote callee
                    bondy:send(Callee, Caller, M, #{});
                CallId ->
                    Result = yield_to_result(CallId, M),
                    bondy:send(Callee, Caller, Result, #{})
            end
    end,
    InvocationId = M#yield.request_id,
    Callee = bondy_context:peer_id(Ctxt0),
    _ = bondy_rpc_promise:dequeue_invocation(InvocationId, Callee, Fun),
    ok;

do_handle_message(#error{request_type = ?INVOCATION} = M, Ctxt0) ->
    Callee = bondy_context:peer_id(Ctxt0),
    Fun = fun
        (empty) ->
            no_matching_promise(M);
        ({ok, Promise}) ->
            Caller = bondy_rpc_promise:caller(Promise),
            CallId = bondy_rpc_promise:call_id(Promise),
            CallError = case bondy:is_remote_peer(Caller) of
                true ->
                    %% We reply the invocation message as the remote node has
                    %% send us an invocation and not a call
                    M;
                false ->
                    M#error{request_id = CallId, request_type = ?CALL}
            end,
            bondy:send(Callee, Caller, CallError, #{})
    end,
    InvocationId = M#error.request_id,
    Callee = bondy_context:peer_id(Ctxt0),
    _ = bondy_rpc_promise:dequeue_invocation(InvocationId, Callee, Fun),
    ok;

do_handle_message(#error{request_type = ?INTERRUPT} = M, Ctxt0) ->
    %% A callee is responding with an error to an INTERRUPT message
    %% We need to turn this into a CANCEL error
    Callee = bondy_context:peer_id(Ctxt0),
    InvocationId = M#error.request_id,
    Caller = bondy_context:peer_id(Ctxt0),
    case bondy_rpc_promise:peek_invocation(InvocationId, Callee) of
        empty ->
            %% Call was evicted or performed already by Callee
            no_matching_promise(M);
        {ok, Promise} ->
            Caller = bondy_rpc_promise:caller(Promise),
            CallId = bondy_rpc_promise:call_id(Promise),
            CancelError = M#error{request_id = CallId, request_type = ?CALL},
            bondy:send(Callee, Caller, CancelError, #{})
    end,
    ok;

do_handle_message(#call{procedure_uri = Uri} = M, Ctxt) ->
    %% TODO Maybe
    %% ReqId = bondy_utils:get_id(global),
    %% spawn with pool -> bondy_wamp_meta_api:handle_call(M, Ctxt);
    %% {ok, ReqId, Ctxt}.
    ok = bondy_rbac:authorize(<<"wamp.call">>, Uri, Ctxt),
    handle_call(M, Ctxt).


%% @private
handle_call(#call{procedure_uri = <<"bondy.", _/binary>>} = M, Ctxt) ->
    callback(M, Ctxt, bondy_wamp_api);

handle_call(#call{procedure_uri = <<"wamp.", _/binary>>} = M, Ctxt) ->
    callback(M, Ctxt, bondy_wamp_meta_api);

handle_call(#call{procedure_uri = <<"com.bondy.", _/binary>>} = M, Ctxt) ->
    %% Alias for "bondy"
    callback(M, Ctxt, bondy_wamp_api);

handle_call(
    #call{procedure_uri = <<"com.leapsight.bondy.", _/binary>>} = M, Ctxt) ->
    %% Deprecated API prefix. Now "bondy"
    callback(M, Ctxt, bondy_wamp_api);

handle_call(#call{procedure_uri = Uri} = M, Ctxt) ->
    do_handle_call(M, Ctxt, Uri).


%% -----------------------------------------------------------------------------
%% @private
%% @doc If the callback module returns ignore we need to find the callee in the
%% registry
%% @end
%% -----------------------------------------------------------------------------
callback(#call{} = M0, Ctxt, Mod) ->
    PeerId = bondy_context:peer_id(Ctxt),
    DefaultOpts = #{error_formatter => undefined},

    try Mod:handle_call(M0, Ctxt) of
        ok ->
            ok;
        continue ->
            do_handle_call(M0, Ctxt, M0#call.procedure_uri, DefaultOpts);

        {continue, #call{} = M1}  ->
            do_handle_call(M1, Ctxt, M1#call.procedure_uri, DefaultOpts);

        {continue, #call{} = M1, Fun}  ->
            Opts = DefaultOpts#{error_formatter => Fun},
            do_handle_call(M1, Ctxt, M1#call.procedure_uri, Opts);

        {continue, Uri} when is_binary(Uri) ->
            do_handle_call(M0, Ctxt, Uri, DefaultOpts);

        {continue, Uri, Fun} when is_binary(Uri) ->
            Opts = DefaultOpts#{error_formatter => Fun},
            do_handle_call(M0, Ctxt, Uri, Opts);

        {reply, Reply} ->
            bondy:send(PeerId, Reply)
    catch
        throw:no_such_procedure ->
            Error = bondy_wamp_utils:no_such_procedure_error(M0),
            bondy:send(PeerId, Error);

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
            bondy:send(PeerId, Error)
    end.


%% @private
do_handle_call(M, Ctxt, Uri) ->
    do_handle_call(M, Ctxt, Uri, #{error_formatter => undefined}).


%% @private
do_handle_call(#call{} = M, Ctxt0, Uri, Opts0) ->
    MyNode = bondy_peer_service:mynode(),

    %% invoke/5 takes a fun which takes the registration_id of the
    %% procedure and the callee
    %% Based on procedure registration and passed options, we will
    %% determine how many invocations and to whom we should do.
    %% fun(Entry, Callee, Ctxt)
    Fun = fun
        (Entry, {_, Node, undefined, Mod}, Ctxt1)
        when is_atom(Mod), Node =:= MyNode, M#call.procedure_uri == Uri ->
            %% A callback implemented procedure e.g. WAMP Session APIs
            %% on this node
            %% We send here as we do not need invoke/5 to enqueue a promise,
            %% we will call the module sequentially.
            Invocation = call_to_invocation(M, Uri, Entry, Ctxt1),

            case Mod:handle_invocation(Invocation, Ctxt1) of
                ok ->
                    %% No reply needed
                    {ok, Ctxt1};

                {reply, #yield{} = Yield} ->
                    Reply = yield_to_result(M#call.request_id, Yield),
                    Caller = bondy_context:peer_id(Ctxt0),
                    ok = bondy:send(Caller, Reply),
                    {ok, Ctxt1};

                {reply, #error{} = Error0} ->
                    Caller = bondy_context:peer_id(Ctxt0),
                    Error = Error0#error{
                        request_id = M#call.request_id,
                        request_type = ?CALL
                    },
                    ok = bondy:send(Caller, Error),
                    {ok, Ctxt1};

                Other ->
                    %% we do not allow continue nor {continue, term()}
                    %% at this point
                    error({invalid_return, Other})

            end;

        (Entry, {_, _, undefined, Mod}, Ctxt1) when is_atom(Mod) ->
            %% A callback implemented procedure e.g. WAMP Session APIs
            %% on another node
            R = call_to_invocation(M, Uri, Entry, Ctxt1),
            {ok, R, Ctxt1};

        (Entry, {_, _, undefined, Pid}, Ctxt1) when is_pid(Pid) ->
            %% An internal callee process
            R = call_to_invocation(M, Uri, Entry, Ctxt1),
            {ok, R, Ctxt1};

        (Entry, {_, _, SessionId, Pid}, Ctxt1)
        when is_integer(SessionId), is_pid(Pid) ->
            R = call_to_invocation(M, Uri, Entry, Ctxt1),
            {ok, R, Ctxt1}
    end,

    %% A response will be send asynchronously
    Opts = Opts0#{call_opts => M#call.options},
    invoke(M#call.request_id, Uri, Fun, Opts, Ctxt0).


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
    %% TODO Revert to session-scoped Ids
    %% ReqId = bondy_utils:get_id({session, SessionId}),
    ReqId = bondy_utils:get_id(global),
    Args = M#call.args,
    Payload = M#call.kwargs,
    RegId = bondy_registry_entry:id(Entry),
    RegOpts = bondy_registry_entry:options(Entry),
    CallOpts = M#call.options,
    Details = prepare_invocation_details(Uri, CallOpts, RegOpts, Ctxt1),
    wamp_message:invocation(ReqId, RegId, Details, Args, Payload).


%% @private
prepare_invocation_details(Uri, CallOpts, RegOpts, Ctxt) ->
    Details0 = #{
        procedure => Uri,
        trust_level => 0
    },

    DiscloseMe = maps:get(disclose_me, CallOpts, true),
    DiscloseCaller = maps:get(disclose_caller, RegOpts, true),
    Details1 = case DiscloseCaller orelse DiscloseMe of
        true ->
            Details0#{
                caller => bondy_context:session_id(Ctxt),
                caller_authid => bondy_context:authid(Ctxt),
                caller_authrole => bondy_context:authrole(Ctxt),
                caller_authroles => bondy_context:authroles(Ctxt)
            };
        false ->
            Details0
    end,

    case maps:get('x_disclose_session_info', RegOpts, false) of
        true ->
            Session = bondy_context:session(Ctxt),
            Info = bondy_session:info(Session),
            Details1#{'x_session_info' => Info};
        false ->
            Details1
    end.


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
    PeerId = bondy_context:peer_id(Ctxt),

    %% We add an option used by bondy_registry
    Val = bondy_context:is_feature_enabled(Ctxt, callee, shared_registration),
    Opts = Opts0#{shared_registration => Val},

    case bondy_registry:add(registration, Uri, Opts, Ctxt) of
        {ok, Entry, IsFirst} ->
            ok = on_register(IsFirst, Entry, Ctxt),
            Id = bondy_registry_entry:id(Entry),
            Reply = wamp_message:registered(ReqId, Id),
            bondy:send(PeerId, Reply);
        {error, {already_exists, Entry}} ->
            Policy = bondy_registry_entry:match_policy(Entry),
            Mssg = <<
                "The procedure is already registered by another peer ",
                "with policy ", $', Policy/binary, $', $.
            >>,
            Reply = wamp_message:error(
                ?REGISTER,
                ReqId,
                #{},
                ?WAMP_PROCEDURE_ALREADY_EXISTS,
                [Mssg]
            ),
            bondy:send(PeerId, Reply)
    end.


%% @private
do_register(Procedure, Opts, Term) ->
    case
        bondy_registry:add(registration, Procedure, Opts, Term)
    of
        {ok, Entry, _} ->
            {ok, bondy_registry_entry:id(Entry)};

        {error, {already_exists, _}} ->
            {error, already_exists}
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
            ok = bondy_rbac:authorize(
                <<"wamp.unregister">>, Uri, Ctxt),
            unregister(Uri, M, Ctxt)
    end.


%% @private
unregister(Uri, M, Ctxt) ->
    ok = maybe_reserved_ns(Uri),
    RegId = M#unregister.request_id,
    ok = bondy_rbac:authorize(<<"wamp.unregister">>, Uri, Ctxt),
    ok = bondy_registry:remove(registration, RegId, Ctxt, fun on_unregister/2),
    Reply = wamp_message:unregistered(RegId),
    bondy:send(bondy_context:peer_id(Ctxt), Reply).


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
        bondy_context:peer_id(Ctxt),
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

dequeue_invocations(CallId, M, Fun, Ctxt) when is_function(Fun, 3) ->
    Caller = bondy_context:peer_id(Ctxt),
    case bondy_rpc_promise:dequeue_call(CallId, Caller) of
        empty ->
            %% Promises for this call were either interrupted by us,
            %% fulfilled or timed out and/or garbage collected.
            ok = no_matching_promise(M),
            {ok, Ctxt};
        {ok, P} ->
            ReqId = bondy_rpc_promise:invocation_id(P),
            Callee = bondy_rpc_promise:callee(P),
            {ok, Ctxt1} = Fun(ReqId, Callee, Ctxt),
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
    Caller = bondy_context:peer_id(Ctxt),
    case bondy_rpc_promise:peek_call(CallId, Caller) of
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
%% @doc
%% Throws {not_authorized, binary()}
%% @end
%% -----------------------------------------------------------------------------
-spec invoke(id(), uri(), function(), invoke_opts(), bondy_context:t()) -> ok.

invoke(CallId, ProcUri, UserFun, Opts, Ctxt0) when is_function(UserFun, 3) ->
    %% Contrary to pubusub, the _Caller_ can receive the
    %% invocation even if the _Caller_ is also a _Callee_ registered
    %% for that procedure.

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
                    Callee = bondy_registry_entry:peer_id(Entry),

                    %% We invoke the provided fun which actually makes the
                    %% invocation
                    case UserFun(Entry, Callee, Ctxt1) of
                        {ok, Ctxt2} ->
                            %% UserFun sent a response sequentially, no need
                            %% for promises
                            {ok, Ctxt2};

                        {ok, #invocation{} = Inv, Ctxt2} ->
                            RealmUri = bondy_context:realm_uri(Ctxt1),
                            Caller = bondy_context:peer_id(Ctxt1),
                            InvId = Inv#invocation.request_id,

                            %%  A promise is used to implement a capability and
                            %% a feature:
                            %% - the capability to match the callee response
                            %% (wamp_yield() or wamp_error()) back to the
                            %% originating wamp_call() and Caller
                            %% - the call_timeout feature at the dealer level
                            Promise = bondy_rpc_promise:new(
                                InvId, CallId, ProcUri, Callee, Ctxt2
                            ),

                            %% We enqueue the promise with a timeout
                            ok = bondy_rpc_promise:enqueue(
                                RealmUri,
                                Promise,
                                bondy_utils:timeout(call_opts(Opts))
                            ),

                            ok = bondy:send(Caller, Callee, Inv, #{}),

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
     Mssg = <<"The request failed due to invalid option parameters.">>,
    wamp_message:error(
        ?CALL,
        CallId,
        #{},
        ?WAMP_INVALID_ARGUMENT,
        [Mssg],
        #{
            message => Mssg,
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
    Mssg = <<
        "There are no elibible callees for the procedure."
    >>,
    wamp_message:error(
        Type,
        Id,
        #{},
        ?WAMP_NO_ELIGIBLE_CALLE,
        [Mssg],
        #{message => Mssg, description => Desc}
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
    Mssg = iolist_to_binary(
        <<"There are no registered procedures matching the id ",
        $', (M#unregister.registration_id)/integer, $'>>
    ),
    wamp_message:error(
        ?UNREGISTER,
        M#unregister.request_id,
        #{},
        ?WAMP_NO_SUCH_REGISTRATION,
        [Mssg],
        #{
            message => Mssg,
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