%% =============================================================================
%%  bondy_dealer.erl -
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
%% <pre>
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
%% </pre>
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
%% <pre>
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
%% </pre>
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
%%    _Broker_ to do a time-consuming lookup in some database, whereas
%%    another register request second might be permissible immediately.
%% @end
%% =============================================================================
-module(bondy_dealer).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").


-define(DEFAULT_LIMIT, 1000).


%% API
-export([close_context/1]).
-export([features/0]).
-export([handle_message/2]).
-export([handle_peer_message/4]).
-export([is_feature_enabled/1]).
-export([register/3]).
-export([registrations/1]).
-export([registrations/3]).
-export([registrations/4]).
-export([match_registrations/2]).




%% =============================================================================
%% API
%% =============================================================================


-spec close_context(bondy_context:context()) -> bondy_context:context().

close_context(Ctxt) ->
    %% Cleanup callee role registrations
    ok = unregister_all(Ctxt),
    %% Cleanup invocations queue
    RealmUri = bondy_context:realm_uri(Ctxt),
    SessionId = bondy_context:session_id(Ctxt),
    ok = bondy_rpc_promise:flush(RealmUri, SessionId),
    Ctxt.


-spec features() -> map().

features() ->
    ?DEALER_FEATURES.


-spec is_feature_enabled(binary()) -> boolean().

is_feature_enabled(F) when is_binary(F) ->
    maps:get(F, ?DEALER_FEATURES, false).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec handle_message(M :: wamp_message(), Ctxt :: map()) -> ok | no_return().

%% handle_message(
%%     #register{procedure_uri = Uri, options = Opts, request_id = ReqId}, Ctxt) ->
%%     %% Check if it has callee role?
%%     case register(Uri, Opts, Ctxt) of
%%         {ok, Map, IsFirst} ->
%%             R = wamp_message:registered(ReqId, maps:get(id, Map)),
%%             ok = bondy:send(bondy_context:peer_id(Ctxt), R),
%%             on_register(IsFirst, Map, Ctxt);
%%         {error, {not_authorized, Mssg}} ->
%%             R = wamp_message:error(
%%                 ?REGISTER,
%%                 ReqId,
%%                 #{},
%%                 ?WAMP_ERROR_NOT_AUTHORIZED,
%%                 [Mssg],
%%                 #{message => Mssg}
%%             ),
%%             bondy:send(bondy_context:peer_id(Ctxt), R);
%%         {error, {procedure_already_exists, Mssg}} ->
%%             R = wamp_message:error(
%%                 ?REGISTER,
%%                 ReqId,
%%                 #{},
%%                 ?WAMP_ERROR_PROCEDURE_ALREADY_EXISTS,
%%                 [Mssg],
%%                 #{message => Mssg}
%%             ),
%%             bondy:send(bondy_context:peer_id(Ctxt), R)
%%     end;

handle_message(#unregister{} = M, Ctxt) ->
    Reply  = case unregister(M#unregister.registration_id, Ctxt) of
        ok ->
            wamp_message:unregistered(M#unregister.request_id);
        {error, {not_authorized, Mssg}} ->
            wamp_message:error(
                ?UNREGISTER,
                M#unregister.request_id,
                #{},
                ?WAMP_ERROR_NOT_AUTHORIZED,
                [Mssg],
                #{message => Mssg}
            );
        {error, not_found} ->
            Mssg = iolist_to_binary(
                <<"There are no registered procedures matching the id ",
                $', (M#unregister.registration_id)/integer, $'>>
            ),
            wamp_message:error(
                ?UNREGISTER,
                M#unregister.request_id,
                #{},
                ?WAMP_ERROR_NO_SUCH_REGISTRATION,
                [Mssg],
                #{
                    message => Mssg,
                    description => <<"The unregister request failed.">>
                }
            )
    end,
    bondy:send(bondy_context:peer_id(Ctxt), Reply);

handle_message(#cancel{} = M, Ctxt0) ->
    %% TODO check if authorized and if not throw wamp.error.not_authorized
    CallId = M#cancel.request_id,
    Opts = M#cancel.options,

    %% A response will be send asynchronously by another router process instance

    %% If the callee does not support call canceling, then behavior is skip.
    %% We should check calle but that means we need to broadcast sessions
    %% another option is to pay the price and ask bondy to fail on the
    %% remote node after checking the callee does not support it.
    %% The caller is not affected, only in the kill case will receive an
    %% error later in the case of a remote callee.
    case maps:get(mode, Opts, skip) of
        kill ->
            %% INTERRUPT is sent to the callee, but ERROR is not returned
            %% to the caller until after the callee has responded to the
            %% canceled call. In this case the caller may receive RESULT or
            %% ERROR depending whether the callee finishes processing the
            %% invocation or the interrupt first.
            %% We peek instead of dequeueing.
            Fun = fun(InvocationId, Callee, Ctxt1) ->
                R = wamp_message:interrupt(InvocationId, Opts),
                ok = bondy:send(Callee, R),
                {ok, Ctxt1}
            end,
            _ = peek_invocations(CallId, Fun, Ctxt0),
            ok;
        killnowait ->
            %% The pending call is canceled and ERROR is send immediately
            %% back to the caller. INTERRUPT is sent to the callee and any
            %% response to the invocation or interrupt from the callee is
            %% discarded when received.
            %% We dequeue, that way the response will be discarded.
            Fun = fun(InvocationId, Callee, Ctxt1) ->
                Caller = bondy_context:peer_id(Ctxt1),
                Mssg = <<"call_cancelled">>,
                Args = [Mssg],
                ArgsKw = #{
                    message => Mssg,
                    description => <<"The call was cancelled by the user.">>
                },
                Error = wamp_message:error(
                    ?CANCEL, CallId, #{}, ?WAMP_ERROR_CANCELLED, Args, ArgsKw),
                ok = bondy:send(Caller, Error),

                Interrupt = wamp_message:interrupt(InvocationId, Opts),
                ok = bondy:send(Callee, Interrupt),
                {ok, Ctxt1}
            end,
            _ = dequeue_invocations(CallId, Fun, Ctxt0),
            ok;
        skip ->
            %% The pending call is canceled and ERROR is sent immediately
            %% back to the caller. No INTERRUPT is sent to the callee and
            %% the result is discarded when received.
            %% We dequeue,
            Fun = fun(_InvocationId, _Callee, Ctxt1) ->
                Caller = bondy_context:peer_id(Ctxt1),
                Mssg = <<"call_cancelled">>,
                Args = [Mssg],
                ArgsKw = #{
                    message => Mssg,
                    description => <<"The call was cancelled by the user.">>
                },
                Error = wamp_message:error(
                    ?CANCEL, CallId, #{}, ?WAMP_ERROR_CANCELLED, Args, ArgsKw),
                ok = bondy:send(Caller, Error),
                {ok, Ctxt1}
            end,
            _ = dequeue_invocations(CallId, Fun, Ctxt0),
            ok
    end;

handle_message(#yield{} = M, Ctxt0) ->
    %% A Callee is replying to a previous wamp_invocation()
    %% which we generated based on a Caller wamp_call()
    %% We match the wamp_yield() with the originating wamp_invocation()
    %% using the request_id, and with that match the wamp_call() request_id
    %% to find the caller pid.

    Fun = fun(Promise) ->
        CallId = bondy_rpc_promise:call_id(Promise),
        Caller = bondy_rpc_promise:caller(Promise),
        Result = wamp_message:result(
            CallId,
            %% TODO check if yield.options should be assigned to result.details
            M#yield.options,
            M#yield.arguments,
            M#yield.arguments_kw),
        bondy:send(Caller, Result)
    end,
    RealmUri = bondy_context:realm_uri(Ctxt0),
    dequeue_call({invocation_id, M#yield.request_id}, Fun, RealmUri);

handle_message(#error{request_type = Type} = M, Ctxt0)
when Type == ?INVOCATION orelse Type == ?INTERRUPT ->
    {NewType, Hint} = case Type of
        ?INVOCATION -> {?CALL, {invocation_id, M#error.request_id}};
        ?INTERRUPT -> {?CANCEL, {call_id, M#error.request_id}}
    end,
    Fun = fun(Promise) ->
        Caller = bondy_rpc_promise:caller(Promise),
        bondy:send(Caller, M#error{request_type = NewType})
    end,
    RealmUri = bondy_context:realm_uri(Ctxt0),
    dequeue_call(Hint, Fun, RealmUri);

handle_message(
    #call{procedure_uri = <<"com.leapsight.bondy", _/binary>>} = M, Ctxt) ->
    bondy_dealer_meta:handle_call(M, Ctxt);

handle_message(
    #call{procedure_uri = <<"wamp.registration", _/binary>>} = M, Ctxt) ->
    bondy_dealer_meta:handle_call(M, Ctxt);

handle_message(
    #call{procedure_uri = <<"wamp.subscription.", _/binary>>} = M, Ctxt) ->
    bondy_broker:handle_call(M, Ctxt);

handle_message(#call{} = M, Ctxt0) ->
    %% invoke/5 takes a fun which takes the registration_id of the
    %% procedure and the callee
    %% Based on procedure registration and passed options, we will
    %% determine how many invocations and to whom we should do.
    Fun = fun
        (Entry, {_RealmUri, _Node, SessionId, Pid} = Callee, Ctxt1)
        when is_integer(SessionId), is_pid(Pid) ->
            ReqId = bondy_utils:get_id(global),
            Args = M#call.arguments,
            Payload = M#call.arguments_kw,
            RegId = bondy_registry_entry:id(Entry),
            RegOpts = bondy_registry_entry:options(Entry),
            CallOpts = M#call.options,
            Uri = M#call.procedure_uri,
            %% TODO check if authorized and if not throw wamp.error.not_authorized
            Details = prepare_invocation_details(Uri, CallOpts, RegOpts, Ctxt1),
            R = wamp_message:invocation(ReqId, RegId, Details, Args, Payload),
            ok = bondy:send(Callee, R, Ctxt1),
            {ok, ReqId, Ctxt1}
    end,

    %% A response will be send asynchronously by another router process instance
    invoke(M#call.request_id, M#call.procedure_uri, Fun, M#call.options, Ctxt0).



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

handle_peer_message(#error{request_type = Type} = M, Caller, _From, _Opts)
when Type == ?CALL orelse Type == ?CANCEL ->
    %% A CALL or CANCEL we made to a remote callee has failed,
    %% We forward the error back to the local caller.
    Hint = case Type of
        ?CALL -> {invocation_id, M#error.request_id};
        ?CANCEL -> {call_id, M#error.request_id}
    end,
    Fun = fun(Promise) ->
        LocalCaller = bondy_rpc_promise:caller(Promise),
        bondy:send(LocalCaller, M)
    end,
    RealmUri = element(1, Caller),
    dequeue_call(Hint, Fun, RealmUri);

handle_peer_message(#interrupt{} = M, Callee, _From, _Opts) ->
    %% A remote caller is cancelling a previous call-invocation
    %% made to a local callee.
    Fun = fun(_Promise) ->
        bondy:send(Callee, M)
    end,
    RealmUri = element(1, Callee),
    Hint = {invocation_id, M#interrupt.request_id},
    dequeue_call(Hint, Fun, RealmUri);

handle_peer_message(#invocation{} = M, Callee, {_, _} = Caller, Opts) ->
    %% A remote caller is making a call to a local callee.

    %% We first need to find the registry entry to get the local callee
    {RealmUri, Node, SessionId} = Callee,
    Key = bondy_registry_entry:key_pattern(
        registration, RealmUri, Node, SessionId, M#invocation.registration_id),

    %% We use lookup because the key is ground
    case bondy_registry:lookup(Key) of
        {error, not_found} ->
            bondy:send(
                Caller,
                no_eligible_callee(invocation, M#invocation.registration_id)
            );
        Entry ->
            LocalCallee = bondy_registry_entry:peer_id(Entry),
            %% We enqueue the invocation so that we can match it with the
            %% YIELD or ERROR
            %% handle_message will match this using the {invocation_id, Id} hint
            Promise = bondy_rpc_promise:new(
                M#invocation.request_id, LocalCallee, Caller),
            Timeout = bondy_utils:timeout(Opts),
            ok = bondy_rpc_promise:enqueue(RealmUri, Promise, Timeout),
            bondy:send(LocalCallee, M, Opts)
    end;

handle_peer_message(#result{} = M, Caller, _Callee, _Opts) ->
    %% A remote callee is returning a result to a local caller.
    CallId = M#result.request_id,
    Fun = fun(Promise) ->
        LocalCaller = bondy_rpc_promise:caller(Promise),
        bondy:send(LocalCaller, M)
    end,
    RealmUri = element(1, Caller),
    dequeue_call({call_id, CallId}, Fun, RealmUri).




%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
prepare_invocation_details(Uri, CallOpts, RegOpts, Ctxt) ->
    DiscloseMe = maps:get(disclose_me, CallOpts, false),
    DiscloseCaller = maps:get(disclose_caller, RegOpts, false),
    M0 = #{
        procedure => Uri,
        trust_level => 0
    },
    case DiscloseCaller orelse DiscloseMe of
        true ->
            M0#{caller => bondy_context:session_id(Ctxt)};
        false ->
            M0
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Registers an RPC endpoint.
%% If the registration already exists, it fails with a
%% `{not_authorized | procedure_already_exists, binary()}' error.
%% @end
%% -----------------------------------------------------------------------------
-spec register(uri(), map(), bondy_context:context()) ->
    {ok, map()}
    | {error, {not_authorized | procedure_already_exists, binary()}}.

register(<<"com.leapsight.bondy.", _/binary>>, _, _) ->
    {error,
        {not_authorized, <<"Use of reserved namespace 'com.leapsight.bondy'.">>}
    };

register(<<"wamp.", _/binary>>, _, _) ->
    {error, {not_authorized, <<"Use of reserved namespace 'wamp'.">>}};

register(ProcUri, Options, Ctxt) ->
    case bondy_registry:add(registration, ProcUri, Options, Ctxt) of
        {ok, Details, IsFirst} ->
            ok = on_register(IsFirst, Details, Ctxt),
            {ok, Details};
        {error, {already_exists, #{match := Policy}}} ->
            {error, {
                procedure_already_exists,
                <<"The procedure is already registered by another peer with policy ", $', Policy/binary, $', $.>>
                }
            }
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Unregisters an RPC endpoint.
%% If the registration does not exist, it fails with a 'no_such_registration' or
%% '{not_authorized, binary()}' error.
%% @end
%% -----------------------------------------------------------------------------
-spec unregister(id(), bondy_context:context()) ->
    ok | {error, {not_authorized, binary()} | not_found}.

unregister(<<"com.leapsight.bondy.", _/binary>>, _) ->
    {error,
        {not_authorized, <<"Use of reserved namespace 'com.leapsight.bondy'.">>}
    };

unregister(<<"wamp.", _/binary>>, _) ->
    {error, {not_authorized, <<"Use of reserved namespace 'wamp'.">>}};

unregister(RegId, Ctxt) ->
    %% TODO Shouldn't we restrict this operation to the peer who registered it?
    %% or a Bondy Admin?
    bondy_registry:remove(registration, RegId, Ctxt, fun on_unregister/2).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unregister_all(bondy_context:context()) -> ok.

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
    }.

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
-spec registrations(RealmUri :: uri(), Node :: atom(), SessionId :: id()) ->
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
    RealmUri :: uri(), Node :: atom(),SessionId :: id(), non_neg_integer()) ->
    {
        [bondy_registry_entry:t()],
        bondy_registry:continuation() | bondy_registry:eot()
    }.

registrations(RealmUri, Node, SessionId, Limit) ->
    bondy_registry:entries(registration, RealmUri, Node, SessionId, Limit).



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_registrations(uri(), bondy_context:context()) ->
    {
        [bondy_registry_entry:t()],
        bondy_registry:continuation() | bondy_registry:eot()
    }.

match_registrations(ProcUri, Ctxt) ->
    bondy_registry:match(registration, ProcUri, Ctxt).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_registrations(uri(), bondy_context:context(), map()) ->
    {
        [bondy_registry_entry:t()],
        bondy_registry:continuation() | bondy_registry:eot()
    }.

match_registrations(ProcUri, Ctxt, Opts) ->
    bondy_registry:match(registration, ProcUri, Ctxt, Opts).


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




%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Throws {not_authorized, binary()}
%% @end
%% -----------------------------------------------------------------------------
-spec invoke(id(), uri(), function(), map(), bondy_context:context()) -> ok.

invoke(CallId, ProcUri, UserFun, Opts, Ctxt0) when is_function(UserFun, 3) ->

    %% Contrary to pubusub, the _Caller_ can receive the
    %% invocation even if the _Caller_ is also a _Callee_ registered
    %% for that procedure.
    case match_registrations(ProcUri, Ctxt0, #{}) of
        {[], ?EOT} ->
            reply_error(ProcUri, CallId, Ctxt0);
        Regs ->
            %% TODO Should we invoke all matching invocations?

            %% We invoke Fun for each entry
            Fun = fun
                ({error, noproc}, Ctxt1) ->
                    %% The local process associated with the entry
                    %% is no longer alive.
                    reply_error(ProcUri, CallId, Ctxt1);
                (Entry, Ctxt1) ->
                    Callee = bondy_registry_entry:peer_id(Entry),

                    %% We invoke the provided fun which actually makes the
                    %% invocation
                    {ok, InvocationId, Ctxt2} = UserFun(Entry, Callee, Ctxt1),

                    %%  A promise is used to implement a capability and a
                    %% feature:
                    %% - the capability to match the callee response
                    %% (wamp_yield() or wamp_error()) back to the originating
                    %% wamp_call() and Caller
                    %% - the call_timeout feature at the dealer level
                    Promise = bondy_rpc_promise:new(
                        InvocationId, CallId, ProcUri, Callee, Ctxt1),
                    RealmUri = bondy_context:realm_uri(Ctxt1),
                    %% We enqueue the promise with a timeout
                    ok = bondy_rpc_promise:enqueue(
                        RealmUri, Promise, bondy_utils:timeout(Opts)),

                    {ok, Ctxt2}
            end,
            invoke(Regs, Fun, Ctxt0)
    end.


%% @private
-spec reply_error(uri(), id(), bondy_context:t()) -> ok.

reply_error(ProcUri, CallId, Ctxt) ->
    bondy:send(
        bondy_context:peer_id(Ctxt),
        no_such_procedure(ProcUri, CallId)
    ).



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue_invocations(id(), function(), bondy_context:context()) ->
    {ok, bondy_context:context()}.

dequeue_invocations(CallId, Fun, Ctxt) when is_function(Fun, 3) ->
    % #{session := S} = Ctxt,
    % Caller = bondy_session:pid(S),
    RealmUri = bondy_context:realm_uri(Ctxt),
    case bondy_rpc_promise:dequeue(RealmUri, call_id, CallId) of
        empty ->
            %% Promises for this call were either interrupted by us,
            %% fulfilled or timed out and garbage collected, we do nothing
            {ok, Ctxt};
        {ok, P} ->
            ReqId = bondy_rpc_promise:invocation_id(P),
            Callee = bondy_rpc_promise:callee(P),
            {ok, Ctxt1} = Fun(ReqId, Callee, Ctxt),
            %% We iterate until there are no more pending invocation for the
            %% call_request_id == CallId
            dequeue_invocations(CallId, Fun, Ctxt1)
    end.



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec peek_invocations(id(), function(), bondy_context:context()) ->
    {ok, bondy_context:context()}.

peek_invocations(CallId, Fun, Ctxt) when is_function(Fun, 3) ->
    % #{session := S} = Ctxt,
    % Caller = bondy_session:pid(S),
    RealmUri = bondy_context:realm_uri(Ctxt),
    case bondy_rpc_promise:peek(RealmUri, call_id, CallId) of
        empty ->
            {ok, Ctxt};
        {ok, P} ->
            ReqId = bondy_rpc_promise:invocation_id(P),
            Callee = bondy_rpc_promise:callee(P),
            {ok, Ctxt1} = Fun(ReqId, Callee, Ctxt),
            %% We iterate until there are no more pending invocation for the
            %% call_request_id == CallId
            peek_invocations(CallId, Fun, Ctxt1)
    end.
%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue_call({invocation_id | call_id, id()}, function(), uri()) -> ok.

dequeue_call(Hint, Fun, RealmUri) when is_function(Fun, 1) ->
    case bondy_rpc_promise:dequeue(RealmUri, Hint) of
        ok ->
            %% Promise was fulfilled or timed out and garbage collected,
            %% we do nothing
            ok;
        {ok, timeout} ->
            %% Promise timed out, it will be GC'd, we do nothing
            ok;
        {ok, Promise} ->
            Fun(Promise)
    end.




%% =============================================================================
%% PRIVATE - INVOCATION STRATEGIES (LOAD BALANCING, FAIL OVER, ETC)
%% =============================================================================


%% @private
invoke({[], ?EOT}, _, _) ->
    ok;

invoke({L, ?EOT}, Fun, Ctxt) ->
    invoke(L, Fun, Ctxt);

invoke({L, Cont}, Fun, Ctxt) ->
    ok = invoke(L, Fun, Ctxt),
    invoke(match_registrations(Cont), Fun, Ctxt);

invoke(L, Fun, Ctxt) when is_list(L) ->
    %% Registrations have different invocation strategies provided by the
    %% 'invoke' key.
    Triples = [{
        bondy_registry_entry:uri(E),
        maps:get(invoke, bondy_registry_entry:options(E), ?INVOKE_SINGLE),
        E
    } || E <- L],
    invoke(Triples, undefined, Fun, Ctxt).


%% @private
-spec invoke(
    [{uri(), Strategy :: binary(), Entry :: tuple()}],
    Acc :: tuple() | undefined,
    Fun :: function(),
    Ctxt :: bondy_context:context()) ->
    ok.

invoke([], undefined, _, _) ->
    ok;

invoke([], {_, ?INVOKE_SINGLE, []}, _, _) ->
    ok;

invoke([], {_, Invoke, L}, Fun, Ctxt0) ->
    {ok, _Ctxt1} = do_invoke({Invoke, L}, Fun, Ctxt0),
    ok;

invoke([{Uri, ?INVOKE_SINGLE, E}|T], undefined, Fun, Ctxt0) ->
    {ok, Ctxt1} = do_invoke({?INVOKE_SINGLE, [E]}, Fun, Ctxt0),
    %% We add an accummulator to drop any subsequent matching Uris.
    invoke(T, {Uri, ?INVOKE_SINGLE, []}, Fun, Ctxt1);

invoke(
    [{Uri, ?INVOKE_SINGLE, _}|T], {Uri, ?INVOKE_SINGLE, _} = Last, Fun, Ctxt) ->
    %% A single invocation strategy and we have multiple registrations so we
    %% ignore them
    %% Invoke should match too, otherwise there is an inconsistency
    %% in the registry
    invoke(T, Last, Fun, Ctxt);

invoke([{Uri, Invoke, E}|T], undefined, Fun, Ctxt) ->
    %% We do not apply the invocation yet as it is not single, so we need
    %% to accummulate and apply at the end.
    %% We build a list for subsequent entries for same Uri.
    invoke(T, {Uri, Invoke, [E]}, Fun, Ctxt);

invoke([{Uri, Invoke, E}|T], {Uri, Invoke, L}, Fun, Ctxt)  ->
    %% We do not apply the invocation yet as it is not single, so we need
    %% to accummulate and apply at the end.
    %% We build a list for subsequent entries for same Uri.
    %% Invoke should match too, otherwise there is an inconsistency
    %% in the registry
    invoke(T, {Uri, Invoke, [E|L]}, Fun, Ctxt);

invoke([{Uri, ?INVOKE_SINGLE, E}|T], {_, Invoke, L}, Fun, Ctxt0) ->
    %% We found a different Uri so we invoke the previous one
    {ok, Ctxt1} = do_invoke({Invoke, L}, Fun, Ctxt0),
    %% The new one is a single so we also invoke and continue
    {ok, Ctxt2} = do_invoke({?INVOKE_SINGLE, [E]}, Fun, Ctxt1),
    invoke(T, {Uri, ?INVOKE_SINGLE, []}, Fun, Ctxt2);

invoke([{Uri, Invoke, E}|T], {_, Invoke, L}, Fun, Ctxt0)  ->
    %% We found another Uri so we invoke the previous one
    {ok, Ctxt1} = do_invoke({Invoke, L}, Fun, Ctxt0),
    %% We do not apply the invocation yet as it is not single, so we need
    %% to accummulate and apply at the end.
    %% We build a list for subsequent entries for same Uri.
    invoke(T, {Uri, Invoke, [E]}, Fun, Ctxt1).


%% @private
invocation_strategy(?INVOKE_SINGLE) -> single;
invocation_strategy(?INVOKE_FIRST) -> first;
invocation_strategy(?INVOKE_LAST) -> last;
invocation_strategy(?INVOKE_RANDOM) -> random;
invocation_strategy(?INVOKE_ROUND_ROBIN) -> round_robin.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Implements load balancing and fail over invocation strategies.
%% This works over a list of registration entries for the SAME
%% procedure
%% @end
%% -----------------------------------------------------------------------------
-spec do_invoke(term(), function(), bondy_context:context()) ->
    {ok, bondy_context:context()}.


do_invoke({WAMPStrategy, L}, Fun, Ctxt) ->
    Strategy = invocation_strategy(WAMPStrategy),
    case bondy_rpc_load_balancer:get(L, #{strategy => Strategy}) of
        {error, noproc} = Error ->
            Fun(Error, Ctxt);
        Entry ->
            Fun(Entry, Ctxt)
    end.





%% =============================================================================
%% PRIVATE: META EVENTS
%% =============================================================================



%% @private
on_register(true, Map, Ctxt) ->
    Uri = <<"wamp.registration.on_create">>,
    {ok, _} = bondy_broker:publish(Uri, #{}, [], Map, Ctxt),
    ok;

on_register(false, Map, Ctxt) ->
    Uri = <<"wamp.registration.on_register">>,
    {ok, _} = bondy_broker:publish(Uri, #{}, [], Map, Ctxt),
    ok.

%% @private
on_unregister(Map, Ctxt) ->
    Uri = <<"wamp.registration.on_unregister">>,
    {ok, _} = bondy_broker:publish(Uri, #{}, [], Map, Ctxt),
    ok.


no_such_procedure(ProcUri, CallId) ->
    Mssg = <<
        "There are no registered procedures matching the uri",
        $\s, $', ProcUri/binary, $', $.
    >>,
    wamp_message:error(
        ?CALL,
        CallId,
        #{},
        ?WAMP_ERROR_NO_SUCH_PROCEDURE,
        [Mssg],
        #{
            message => Mssg,
            description => <<"Either no registration exists for the requested procedure,the match policy used did not match any registered procedures.">>
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
        ?WAMP_ERROR_NO_ELIGIBLE_CALLE,
        [Mssg],
        #{ message => Mssg, description => Desc}
    ).