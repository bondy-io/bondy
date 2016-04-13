%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
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


%% API
-export([handle_message/2]).


%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec handle_message(M :: message(), Ctxt :: map()) -> ok.
handle_message(#register{} = M, Ctxt) ->
    Reply  = try
        {ok, RegId} = juno_rpc:register(
            M#register.procedure_uri, M#register.options, Ctxt),
        wamp_message:registered(M#register.request_id, RegId)
    catch
        error:procedure_already_exists ->
            wamp_message:error(
                ?REGISTER,
                M#register.request_id,
                #{},
                ?WAMP_ERROR_PROCEDURE_ALREADY_EXISTS)
    end,
    juno:send(Reply, Ctxt),
    ok;

handle_message(#unregister{} = M, Ctxt) ->
    Reply  = try
        ok = juno_rpc:unregister(M#unregister.registration_id, Ctxt),
        wamp_message:unregistered(M#unregister.request_id)
    catch
        error:no_such_registration ->
            wamp_message:error(
                ?UNREGISTER,
                M#unregister.request_id,
                #{},
                ?WAMP_ERROR_NO_SUCH_REGISTRATION)
    end,
    juno:send(Reply, Ctxt),
    ok;

handle_message(#call{} = M, Ctxt) ->
    Opts = M#call.options,
    ok = juno_rpc:call(
        M#call.request_id,
        M#call.procedure_uri,
        Opts,
        M#call.arguments,
        M#call.payload,
        Ctxt),
    _T = timeout(Opts),
    ok.



%% =============================================================================
%% PRIVATE
%% =============================================================================



timeout(#{timeout := T}) when is_integer(T) ->
    T;
timeout(_) ->
    juno_config:call_timeout().
