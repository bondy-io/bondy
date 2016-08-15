%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%% This module implements the capabilities of a Dealer. It is used by
%% {@link juno_router}.
%%
%% A Dealer is one of the two roles a Router plays. In particular a Dealer is
%% the middleman between an Caller and a Callee in an RPC interaction,
%% i.e. it works as a generic router for remote procedure calls
%% decoupling Callers and Callees.
%%
%% Callees register procedures they provide with Dealers.  Callers
%% initiate procedure calls first to Dealers.  Dealers route calls
%% incoming from Callers to Callees implementing the procedure called,
%% and route call results back from Callees to Callers.
%%
%% A Caller issues calls to remote procedures by providing the procedure
%% URI and any arguments for the call. The Callee will execute the
%% procedure using the supplied arguments to the call and return the
%% result of the call to the Caller.
%%
%% The Caller and Callee will usually run application code, while the
%% Dealer works as a generic router for remote procedure calls
%% decoupling Callers and Callees.
%%
%% Juno does not provide message transformations to ensure stability and safety.
%% As such, any required transformations should be handled by Callers and
%% Callees directly (notice that a Callee can be a middleman implementing the
%%  required transformations).
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
%%    given _pair_ of _Caller_ and _Callee_.
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
-module(juno_dealer).
-include_lib("wamp/include/wamp.hrl").
-include("juno.hrl").

%% API
-export([features/0]).
-export([handle_message/2]).
-export([is_feature_enabled/1]).
-export([close_context/1]).

%% =============================================================================
%% API
%% =============================================================================


-spec close_context(juno_context:context()) -> juno_context:context().
close_context(Ctxt) -> 
    juno_rpc:close_context(Ctxt).


-spec features() -> map().
features() ->
    ?DEALER_FEATURES.


-spec is_feature_enabled(dealer_features()) -> boolean().
is_feature_enabled(F) ->
    maps:get(F, ?DEALER_FEATURES).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec handle_message(M :: message(), Ctxt :: map()) -> ok | no_return().

% this case is implemented synchronously by router 
% handle_message(
%     #register{procedure_uri = Uri, options = Opts, request_id = ReqId} = M, Ctxt) ->
%     %% Check if it has callee role?
%     Reply = case juno_rpc:register(Uri, Opts, Ctxt) of
%         {ok, RegId} ->
%             wamp_message:registered(ReqId, RegId);
%         {error, not_authorized} ->
%             wamp_message:error(
%                 ?REGISTER, ReqId, #{}, ?WAMP_ERROR_NOT_AUTHORIZED);
%         {error, procedure_already_exists} ->
%             wamp_message:error(
%                 ?REGISTER,ReqId, #{}, ?WAMP_ERROR_PROCEDURE_ALREADY_EXISTS)
%     end,
%     juno:send(Reply, Ctxt);

handle_message(#unregister{} = M, Ctxt) ->
    Reply  = case juno_rpc:unregister(M#unregister.registration_id, Ctxt) of
        ok ->
            wamp_message:unregistered(M#unregister.request_id);
        {error, not_authorized} ->
            wamp_message:error(
                ?UNREGISTER,
                M#unregister.request_id,
                #{},
                ?WAMP_ERROR_NOT_AUTHORIZED);
        {error, not_found} ->
            wamp_message:error(
                ?UNREGISTER,
                M#unregister.request_id,
                #{},
                ?WAMP_ERROR_NO_SUCH_REGISTRATION)
    end,
    juno:send(Reply, Ctxt);

handle_message(#cancel{} = M, Ctxt0) ->
    %% TODO check if authorized and if not throw wamp.error.not_authorized
    CallId = M#cancel.request_id,
    Opts = M#cancel.options,
    
    %% A response will be send asynchronously by another router process instance
    Fun = fun(InvocationId, Callee, Ctxt1) ->
        M = wamp_message:interrupt(InvocationId, Opts),
        ok = juno:send(M, Callee, Ctxt1),
        {ok, Ctxt1}
    end,
    {ok, _Ctxt2} = juno_rpc:dequeue_invocations(CallId, Fun, Ctxt0),
    ok;
   

handle_message(#yield{} = M, Ctxt0) ->
    %% A Callee is replying to a previous wamp_invocation() message 
    %% which we generated based on a Caller wamp_call() message
    %% We need to match the the wamp_yield() with the originating
    %% wamp_invocation() using the request_id, and with that match the
    %% wamp_call() request_id and find the caller pid.

    %% @TODO
    Fun = fun(CallId, Caller, Ctxt1) ->
        M = wamp_message:result(
            CallId, 
            M#yield.options,  %% TODO check if yield.options should be assigned to result.details
            M#yield.arguments, 
            M#yield.payload),
        ok = juno:send(M, Caller, Ctxt1),
        {ok, Ctxt1}
    end,
    {ok, _Ctxt2} = juno_rpc:dequeue_call(M#yield.request_id, Fun, Ctxt0),
    ok;

handle_message(#error{request_type = Type} = M, Ctxt0)
when Type == ?INVOCATION orelse Type == ?INTERRUPT ->
    Fun = fun(CallId, Caller, Ctxt1) ->
        M = wamp_message:error(
                Type, 
                CallId, 
                M#error.details, 
                M#error.error_uri, 
                M#error.arguments, 
                M#error.payload),
        ok = juno:send(M, Caller, Ctxt1),
        {ok, Ctxt1}
    end,
    {ok, _Ctxt2} = juno_rpc:dequeue_call(M#error.request_id, Fun, Ctxt0),
    ok;

handle_message(#call{procedure_uri = ?JUNO_USER_ADD} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

handle_message(#call{procedure_uri = ?JUNO_USER_DELETE} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

handle_message(#call{procedure_uri = ?JUNO_USER_LIST} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

handle_message(#call{procedure_uri = ?JUNO_USER_LOOKUP} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

handle_message(#call{procedure_uri = ?JUNO_USER_UPDATE} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

handle_message(#call{procedure_uri = ?JUNO_GROUP_ADD} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

handle_message(#call{procedure_uri = ?JUNO_GROUP_DELETE} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

handle_message(#call{procedure_uri = ?JUNO_GROUP_LIST} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

handle_message(#call{procedure_uri = ?JUNO_GROUP_LOOKUP} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

handle_message(#call{procedure_uri = ?JUNO_GROUP_UPDATE} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

handle_message(#call{procedure_uri = ?JUNO_SOURCE_ADD} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

handle_message(#call{procedure_uri = ?JUNO_SOURCE_DELETE} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

handle_message(#call{procedure_uri = ?JUNO_SOURCE_LIST} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

handle_message(#call{procedure_uri = ?JUNO_SOURCE_LOOKUP} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

handle_message(#call{procedure_uri = <<"wamp.registration.list">>} = M, Ctxt) ->
    ReqId = M#call.request_id,
    Res = #{
        <<"exact">> => [], % @TODO
        <<"prefix">> => [], % @TODO
        <<"wildcard">> => [] % @TODO
    },
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

handle_message(#call{procedure_uri = <<"wamp.registration.lookup">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

handle_message(#call{procedure_uri = <<"wamp.registration.match">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

handle_message(#call{procedure_uri = <<"wamp.registration.get">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

handle_message(
    #call{procedure_uri = <<"wamp.registration.list_callees">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

handle_message(
    #call{procedure_uri = <<"wamp.registration.count_callees">>} = M, Ctxt) ->
    %% @TODO
    ReqId = M#call.request_id,
    Res = #{count => 0},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

handle_message(#call{} = M, Ctxt0) ->
    %% TODO check if authorized and if not throw wamp.error.not_authorized
    Details = #{}, % @TODO

    %% juno_rpc:invoke/5 takes a fun which takes the registration_id of the 
    %% procedure and the callee
    %% Based on procedure registration and passed options, juno_rpc will
    %% determine how many invocations and to whom we should do.
    Fun = fun(RegId, Callee, Ctxt1) ->
        ReqId = wamp_id:new(global),
        Args = M#call.arguments,
        Payload = M#call.payload,
        M = wamp_message:invocation(ReqId, RegId, Details, Args, Payload),
        ok = juno:send(Callee, M, Ctxt1),
        {ok, ReqId, Ctxt1}
    end,

    %% A response will be send asynchronously by another router process instance
    {ok, _Ctxt2} = juno_rpc:invoke(
        M#call.request_id,
        M#call.procedure_uri,
        Fun,
        M#call.options,
        Ctxt0),
    ok.


%% =============================================================================
%% PRIVATE
%% =============================================================================
