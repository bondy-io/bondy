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
%% Bondy does not provide message transformations to ensure stability and safety.
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
%%<pre>
%%        ,------.          ,------.               ,------.
%%        |Caller|          |Dealer|               |Callee|
%%        `--+---'          `--+---'               `--+---'
%%           |                 |                      |
%%           |                 |                      |
%%           |                 |       REGISTER       |
%%           |                 | <---------------------
%%           |                 |                      |
%%           |                 |  REGISTERED or ERROR |
%%           |                 | --------------------->
%%           |                 |                      |
%%           |                 |                      |
%%           |                 |                      |
%%           |                 |                      |
%%           |                 |                      |
%%           |                 |      UNREGISTER      |
%%           |                 | <---------------------
%%           |                 |                      |
%%           |                 | UNREGISTERED or ERROR|
%%           |                 | --------------------->
%%        ,--+---.          ,--+---.               ,--+---.
%%        |Caller|          |Dealer|               |Callee|
%%        `------'          `------'               `------'
%%</pre>
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
%%           | ---------------->                 |
%%           |                 |                 |
%%           |                 |    INVOCATION   |
%%           |                 | ---------------->
%%           |                 |                 |
%%           |                 |  YIELD or ERROR |
%%           |                 | <----------------
%%           |                 |                 |
%%           | RESULT or ERROR |                 |
%%           | <----------------                 |
%%        ,--+---.          ,--+---.          ,--+---.
%%        |Caller|          |Dealer|          |Callee|
%%        `------'          `------'          `------'
%%</pre>
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
-define(INVOCATION_QUEUE, bondy_rpc_promise).
-define(RPC_STATE_TABLE, bondy_rpc_state).



-record(last_invocation, {
    key     ::  {uri(), uri()},
    value   ::  id()
}).

-record(promise, {
    invocation_request_id   ::  id(),
    procedure_uri           ::  uri(),
    call_request_id         ::  id(),
    caller_pid              ::  pid(),
    caller_session_id       ::  id(),
    callee_pid              ::  pid(),
    callee_session_id       ::  id()
}).
-type promise() :: #promise{}.


%% API
-export([close_context/1]).
-export([features/0]).
-export([handle_message/2]).
-export([is_feature_enabled/1]).
-export([register/3]).
-export([registrations/1]).
-export([registrations/2]).
-export([registrations/3]).
-export([match_registrations/2]).

%% =============================================================================
%% API
%% =============================================================================


-spec close_context(bondy_context:context()) -> bondy_context:context().
close_context(Ctxt) -> 
    %% Cleanup callee role registrations
    ok = unregister_all(Ctxt),
    %% Cleanup invocations queue
    cleanup_queue(Ctxt).


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

handle_message(
    #register{procedure_uri = Uri, options = Opts, request_id = ReqId}, Ctxt) ->
    %% Check if it has callee role?
    case register(Uri, Opts, Ctxt) of
        {ok, Map, IsFirst} ->
            R = wamp_message:registered(ReqId, maps:get(id, Map)),
            ok = bondy:send(bondy_context:peer_id(Ctxt), R),
            on_register(IsFirst, Map, Ctxt);
        {error, {not_authorized, Mssg}} ->
            R = wamp_message:error(
                ?REGISTER, ReqId, #{}, ?WAMP_ERROR_NOT_AUTHORIZED, [Mssg]),
            bondy:send(bondy_context:peer_id(Ctxt), R);
        {error, {procedure_already_exists, Mssg}} ->
            R = wamp_message:error(
                ?REGISTER, 
                ReqId, 
                #{}, 
                ?WAMP_ERROR_PROCEDURE_ALREADY_EXISTS, 
                [Mssg]
            ),
            bondy:send(bondy_context:peer_id(Ctxt), R)
    end;

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
                [Mssg]);
        {error, not_found} ->
            wamp_message:error(
                ?UNREGISTER,
                M#unregister.request_id,
                #{},
                ?WAMP_ERROR_NO_SUCH_REGISTRATION)
    end,
    bondy:send(bondy_context:peer_id(Ctxt), Reply);

handle_message(#cancel{} = M, Ctxt0) ->
    %% TODO check if authorized and if not throw wamp.error.not_authorized
    CallId = M#cancel.request_id,
    Opts = M#cancel.options,
    
    %% A response will be send asynchronously by another router process instance
    Fun = fun(InvocationId, CalleeId, Ctxt1) ->
        R = wamp_message:interrupt(InvocationId, Opts),
        ok = bondy:send(CalleeId, R),
        {ok, Ctxt1}
    end,
    {ok, _Ctxt2} = dequeue_invocations(CallId, Fun, Ctxt0),
    ok;
   

handle_message(#yield{} = M, Ctxt0) ->
    %% A Callee is replying to a previous wamp_invocation() message 
    %% which we generated based on a Caller wamp_call() message
    %% We need to match the the wamp_yield() with the originating
    %% wamp_invocation() using the request_id, and with that match the
    %% wamp_call() request_id and find the caller pid.

    %% @TODO
    Fun = fun(CallId, Caller, Ctxt1) ->
        R = wamp_message:result(
            CallId, 
            M#yield.options,  %% TODO check if yield.options should be assigned to result.details
            M#yield.arguments, 
            M#yield.arguments_kw),
        ok = bondy:send(Caller, R),
        {ok, Ctxt1}
    end,
    {ok, _Ctxt2} = dequeue_call(M#yield.request_id, Fun, Ctxt0),
    ok;

handle_message(#error{request_type = Type} = M, Ctxt0)
when Type == ?INVOCATION orelse Type == ?INTERRUPT ->
    Fun = fun(CallId, Caller, Ctxt1) ->
        R = wamp_message:error(
            Type, 
            CallId, 
            M#error.details, 
            M#error.error_uri, 
            M#error.arguments, 
            M#error.arguments_kw),
        ok = bondy:send(Caller, R),
        {ok, Ctxt1}
    end,
    {ok, _Ctxt2} = dequeue_call(M#error.request_id, Fun, Ctxt0),
    ok;

handle_message(
    #call{procedure_uri = <<"com.leapsight.bondy", _/binary>>} = M, Ctxt) ->
    bondy_dealer_meta:handle_call(M, Ctxt);

handle_message(#call{procedure_uri = <<"wamp.subscription.", _/binary>>} = M, Ctxt) ->
    bondy_broker:handle_call(M, Ctxt);

handle_message(#call{} = M, Ctxt0) ->
    %% invoke/5 takes a fun which takes the registration_id of the 
    %% procedure and the callee
    %% Based on procedure registration and passed options, we will
    %% determine how many invocations and to whom we should do.
    Fun = fun(Entry, {SId, Pid} = CalleeId, Ctxt1) 
        when is_integer(SId), is_pid(Pid) ->
        ReqId = bondy_utils:get_id(global),
        Args = M#call.arguments,
        Payload = M#call.arguments_kw,
        RegId = bondy_registry:entry_id(Entry),
        RegOpts = bondy_registry:options(Entry),
        CallOpts = M#call.options,
        Uri = M#call.procedure_uri,
        %% TODO check if authorized and if not throw wamp.error.not_authorized
        Details = prepare_invocation_details(Uri, CallOpts, RegOpts, Ctxt1),
        R = wamp_message:invocation(ReqId, RegId, Details, Args, Payload),
        ok = bondy:send(CalleeId, R, Ctxt1),
        {ok, ReqId, Ctxt1}
    end,

    %% A response will be send asynchronously by another router process instance
    invoke(M#call.request_id, M#call.procedure_uri, Fun, M#call.options, Ctxt0).


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
%% 'procedure_already_exists', '{not_authorized, binary()}' error.
%% @end
%% -----------------------------------------------------------------------------
-spec register(uri(), map(), bondy_context:context()) -> 
    {ok, map(), boolean()} 
    | {error, {not_authorized | procedure_already_exists, binary()}}.

register(<<"com.leapsight.bondy.", _/binary>>, _, _) ->
    {error, 
        {not_authorized, <<"Use of reserved namespace 'com.leapsight.bondy'.">>}
    };

register(<<"wamp.", _/binary>>, _, _) ->
    {error, {not_authorized, <<"Use of reserved namespace 'wamp'.">>}};

register(ProcUri, Options, Ctxt) ->
    case bondy_registry:add(registration, ProcUri, Options, Ctxt) of
        {ok, _Details, _IsFirst} = OK -> 
            OK;
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
    bondy_registry:remove(registration, RegId, Ctxt).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unregister_all(bondy_context:context()) -> ok.

unregister_all(Ctxt) ->
    bondy_registry:remove_all(registration, Ctxt).



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
        [bondy_registry:entry()], 
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
-spec registrations(RealmUri :: uri(), SessionId :: id()) ->
    [bondy_registry:entry()].

registrations(RealmUri, SessionId) ->
    bondy_registry:entries(registration, RealmUri, SessionId).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Returns the  list of registrations matching the RealmUri and SessionId.
%%
%% Use {@link registrations/3} to limit the number of registrations returned.
%% @end
%% -----------------------------------------------------------------------------
-spec registrations(RealmUri :: uri(), SessionId :: id(), non_neg_integer()) ->
    {
        [bondy_registry:entry()], 
        bondy_registry:continuation() | bondy_registry:eot()
    }.

registrations(RealmUri, SessionId, Limit) ->
    bondy_registry:entries(registration, RealmUri, SessionId, Limit).



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_registrations(uri(), bondy_context:context()) -> 
    {
        [bondy_registry:entry()], 
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
        [bondy_registry:entry()], 
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
        [bondy_registry:entry()], 
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
    CallerS = bondy_context:session(Ctxt0),
    CallerSId = bondy_session:id(CallerS),

    %% We asume that as with pubsub, the _Caller_ should not receive the
    %% invocation even if the _Caller_ is also a _Callee_ registered
    %% for that procedure.
    case match_registrations(ProcUri, Ctxt0, #{exclude => [CallerSId]}) of
        {[], ?EOT} ->
            Error = wamp_message:error(
                ?CALL, CallId, #{}, ?WAMP_ERROR_NO_SUCH_PROCEDURE),
            bondy:send(bondy_context:peer_id(Ctxt0), Error);
        Regs ->
            %%  A promise is used to implement a capability and a feature:
            %% - the capability to match the callee response 
            %% (wamp_yield() or wamp_error()) back to the originating 
            %% wamp_call() and Caller
            %% - the call_timeout feature at the dealer level
            Template = #promise{
                procedure_uri = ProcUri, 
                call_request_id = CallId,
                caller_pid = bondy_session:pid(CallerS),
                caller_session_id = CallerSId
            },

            %% TODO Should we invoke all matching invocations?

            %% We invoke Fun for each entry
            Fun = fun(Entry, Ctxt1) ->
                CalleeSId = bondy_registry:session_id(Entry),
                Callee = bondy_session:pid(bondy_session:fetch(CalleeSId)),
                {ok, Id, Ctxt2} = UserFun(
                    Entry, {CalleeSId, Callee}, Ctxt1),
                %% We complete the promise with the Callee data    
                Promise = Template#promise{
                    invocation_request_id = Id,
                    callee_session_id = CalleeSId,
                    callee_pid = Callee
                }, 
                %% We enqueue the promise with a timeout
                ok = enqueue_promise(
                    Id, Promise, bondy_utils:timeout(Opts), Ctxt2),
                {ok, Ctxt2}
            end,
            do_invoke(Regs, Fun, Ctxt0)
    end.
    




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

    case dequeue_promise(call_request_id, CallId, Ctxt) of
        ok ->
            %% Promises for this call were either interrupted by us, 
            %% fulfilled or timed out and garbage collected, we do nothing 
            {ok, Ctxt};
        {ok, timeout} ->
            %% Promises for this call were either interrupted by us or 
            %% timed out or caller died, we do nothing
            {ok, Ctxt};
        {ok, P} ->
            #promise{
                invocation_request_id = ReqId,
                callee_pid = Pid,
                callee_session_id = SessionId
            } = P,
            {ok, Ctxt1} = Fun(ReqId, {SessionId, Pid}, Ctxt),
            %% We iterate until there are no more pending invocation for the
            %% call_request_id == CallId
            dequeue_invocations(CallId, Fun, Ctxt1)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue_call(id(), function(), bondy_context:context()) -> 
    {ok, bondy_context:context()}.

dequeue_call(ReqId, Fun, Ctxt) when is_function(Fun, 3) ->
    case dequeue_promise(invocation_request_id, ReqId, Ctxt) of
        ok ->
            %% Promise was fulfilled or timed out and garbage collected,
            %% we do nothing 
            ok;
        {ok, timeout} ->
            %% Promise timed out, we do nothing
            ok;
        {ok, #promise{invocation_request_id = ReqId} = P} ->
            #promise{
                call_request_id = CallId,
                caller_pid = Pid,
                caller_session_id = SessionId
            } = P,
            Fun(CallId, {SessionId, Pid}, Ctxt)
    end.




%% =============================================================================
%% PRIVATE - INVOCATION STRATEGIES (LOAD BALANCING, FAIL OVER, ETC)
%% =============================================================================


%% @private
do_invoke({[], ?EOT}, _, _) ->
    ok;

do_invoke({L, ?EOT}, Fun, Ctxt) ->
    do_invoke(L, Fun, Ctxt);

do_invoke({L, Cont}, Fun, Ctxt) ->
    ok = do_invoke(L, Fun, Ctxt),
    do_invoke(match_registrations(Cont), Fun, Ctxt);

do_invoke(L, Fun, Ctxt) when is_list(L) ->
    %% Registrations have different invocation strategies provided by the
    %% 'invoke' key.
    Triples = [{
        bondy_registry:uri(E),
        maps:get(invoke, bondy_registry:options(E), ?INVOKE_SINGLE),
        E
    } || E <- L],
    do_invoke(Triples, undefined, Fun, Ctxt).


%% @private
-spec do_invoke(
    [{uri(), Strategy :: binary(), Entry :: tuple()}], 
    Acc :: tuple() | undefined, 
    Fun :: function(), 
    Ctxt :: bondy_context:context()) ->
    ok.

do_invoke([], undefined, _, _) ->
    ok;

do_invoke([], {_, ?INVOKE_SINGLE, []}, _, _) ->
    ok;

do_invoke([], {_, Invoke, L}, Fun, Ctxt0) ->
    {ok, _Ctxt1} = apply_invocation_strategy({Invoke, L}, Fun, Ctxt0),
    ok;

do_invoke([{Uri, ?INVOKE_SINGLE, E}|T], undefined, Fun, Ctxt0) ->
    {ok, Ctxt1} = apply_invocation_strategy(E, Fun, Ctxt0),
    %% We add an accummulator to drop any subsequent matching Uris.
    do_invoke(T, {Uri, ?INVOKE_SINGLE, []}, Fun, Ctxt1);

do_invoke(
    [{Uri, ?INVOKE_SINGLE, _}|T], {Uri, ?INVOKE_SINGLE, _} = Last, Fun, Ctxt) ->
    %% A single invocation strategy and we have multiple registrations so we
    %% ignore them
    %% Invoke should match too, otherwise there is an inconsistency
    %% in the registry
    do_invoke(T, Last, Fun, Ctxt);

do_invoke([{Uri, Invoke, E}|T], undefined, Fun, Ctxt) ->
    %% We do not apply the invocation yet as it is not single, so we need
    %% to accummulate and apply at the end.
    %% We build a list for subsequent entries for same Uri.
    do_invoke(T, {Uri, Invoke, [E]}, Fun, Ctxt);

do_invoke([{Uri, Invoke, E}|T], {Uri, Invoke, L}, Fun, Ctxt)  ->
    %% We do not apply the invocation yet as it is not single, so we need
    %% to accummulate and apply at the end.
    %% We build a list for subsequent entries for same Uri.
    %% Invoke should match too, otherwise there is an inconsistency
    %% in the registry
    do_invoke(T, {Uri, Invoke, [E|L]}, Fun, Ctxt);

do_invoke([{Uri, ?INVOKE_SINGLE, E}|T], {_, Invoke, L}, Fun, Ctxt0) ->
    %% We found another Uri so we invoke the previous one
    {ok, Ctxt1} = apply_invocation_strategy({Invoke, L}, Fun, Ctxt0),
    %% The new one is a sigle so we also invoke and continue
    {ok, Ctxt2} = apply_invocation_strategy(E, Fun, Ctxt1),
    do_invoke(T, {Uri, ?INVOKE_SINGLE, []}, Fun, Ctxt2);

do_invoke([{Uri, Invoke, E}|T], {_, Invoke, L}, Fun, Ctxt0)  ->
    %% We found another Uri so we invoke the previous one
    {ok, Ctxt1} = apply_invocation_strategy({Invoke, L}, Fun, Ctxt0),
    %% We do not apply the invocation yet as it is not single, so we need
    %% to accummulate and apply at the end.
    %% We build a list for subsequent entries for same Uri.
    do_invoke(T, {Uri, Invoke, [E]}, Fun, Ctxt1).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Implements load balancing and fail over invocation strategies.
%% This works over a list of registration entries for the SAME
%% procedure
%% @end
%% -----------------------------------------------------------------------------
-spec apply_invocation_strategy(term(), function(), bondy_context:context()) -> 
    {ok, bondy_context:context()}.

apply_invocation_strategy({?INVOKE_FIRST, L}, Fun, Ctxt) ->
    apply_first_available(L, Fun, Ctxt);

apply_invocation_strategy({?INVOKE_LAST, L}, Fun, Ctxt) ->
    apply_first_available(lists:reverse(L), Fun, Ctxt);

apply_invocation_strategy({?INVOKE_RANDOM, L}, Fun, Ctxt) ->
    apply_first_available(lists_utils:shuffle(L), Fun, Ctxt);

apply_invocation_strategy({?INVOKE_ROUND_ROBIN, L}, Fun, Ctxt) ->
    apply_round_robin(L, Fun, Ctxt);

apply_invocation_strategy(Entry, Fun, Ctxt) ->
    Fun(Entry, Ctxt).


%% @private
apply_first_available([], _, Ctxt) ->
    {ok, Ctxt};

apply_first_available([H|T], Fun, Ctxt) ->
    Pid = bondy_session:pid(bondy_registry:session_id(H)),
    case process_info(Pid) == undefined of
        true ->
            apply_first_available(T, Fun, Ctxt);
        false ->
            %% We finish doing the invocation
            Fun(H, Ctxt)
    end.


%% @private
-spec apply_round_robin(list(), function(), bondy_context:context()) -> 
    {ok, bondy_context:context()}.

apply_round_robin([], _, Ctxt) ->
    {ok, Ctxt};

apply_round_robin(L, Fun, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    Uri = bondy_registry:uri(hd(L)),
    apply_round_robin(get_last_invocation(RealmUri, Uri), L, Fun, Ctxt).


%% @private
apply_round_robin(_, [], _, Ctxt) ->
    {ok, Ctxt};

apply_round_robin(undefined, [H|T], Fun, Ctxt) ->
    %% We never invoke this procedure before or we reordered the round
    Pid = bondy_session:pid(bondy_registry:session_id(H)),
    case process_info(Pid) of
        undefined ->
            %% The peer connection must have been closed between
            %% the time we read and now.
            apply_round_robin(undefined, T, Fun, Ctxt);
        _ ->
            %% We update the invocation state
            ok = update_last_invocation(
                bondy_context:realm_uri(Ctxt),
                bondy_registry:uri(H),
                bondy_registry:entry_id(H)
            ),
            %% We do the invocation
            Fun(H, Ctxt)
    end;


apply_round_robin(#last_invocation{value = LastId}, L0, Fun, Ctxt) ->
    Pred = fun(E) -> LastId =:= bondy_registry:entry_id(E) end,
    L1 = lists_utils:rotate_right_with(Pred, L0),
    apply_round_robin(undefined, L1, Fun, Ctxt).


%% @private
get_last_invocation(RealmUri, Uri) ->
    case ets:lookup(rpc_state_table(RealmUri, Uri), {RealmUri, Uri}) of
        [] -> undefined;
        [Entry] -> Entry
    end.

update_last_invocation(RealmUri, Uri, Val) ->
    Entry = #last_invocation{key = {RealmUri, Uri}, value = Val},
    true = ets:insert(rpc_state_table(RealmUri, Uri), Entry),
    ok.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% A table that persists calls and maintains the state of the load 
%% balancing of invocations 
%% @end
%% -----------------------------------------------------------------------------
rpc_state_table(RealmUri, Uri) ->
    tuplespace:locate_table(?RPC_STATE_TABLE, {RealmUri, Uri}).





%% =============================================================================
%% PRIVATE: PROMISES
%% =============================================================================




%% @private
-spec enqueue_promise(
    id(), promise(), pos_integer(), bondy_context:context()) -> ok.

enqueue_promise(Id, Promise, Timeout, #{realm_uri := Uri}) ->
    #promise{call_request_id = CallId} = Promise,
    Key = {Uri, Id, CallId},
    Opts = #{key => Key, ttl => Timeout},
    tuplespace_queue:enqueue(?INVOCATION_QUEUE, Promise, Opts).


%% @private
dequeue_promise(invocation_request_id, Id, #{realm_uri := Uri}) ->
    dequeue_promise({Uri, Id, '_'});

dequeue_promise(call_request_id, Id, #{realm_uri := Uri}) ->
    dequeue_promise({Uri, '_', Id}).


%% @private
-spec dequeue_promise(tuple()) -> ok | {ok, timeout} | {ok, promise()}.

dequeue_promise(Key) ->
    case tuplespace_queue:dequeue(?INVOCATION_QUEUE, #{key => Key}) of
        empty ->
            %% The promise might have expired so we GC it.
            case tuplespace_queue:remove(?INVOCATION_QUEUE, #{key => Key}) of
                0 -> ok;
                _ -> {ok, timeout}
            end;
        [Promise] ->
            {ok, Promise}
    end.


%% @private
cleanup_queue(#{realm_uri := Uri, awaiting_calls := Set} = Ctxt) ->
    sets:fold(
        fun(Id, ICtxt) ->
            Key = {Uri, Id},
            _N = tuplespace_queue:remove(?INVOCATION_QUEUE, #{key => Key}),
            bondy_context:remove_awaiting_call(ICtxt, Id)
        end,
        Ctxt,
        Set
    );
    
cleanup_queue(Ctxt) ->
    Ctxt.


%% @private
on_register(true, Map, Ctxt) ->
    Uri = <<"wamp.registration.on_create">>,
    {ok, _} = bondy_broker:publish(Uri, #{}, [], Map, Ctxt),
    ok;

on_register(false, Map, Ctxt) ->
    Uri = <<"wamp.registration.on_register">>,
    {ok, _} = bondy_broker:publish(Uri, #{}, [], Map, Ctxt),
    ok.