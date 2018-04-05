-module(bondy_rpc_promise).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-define(INVOCATION_QUEUE, bondy_rpc_promise).

-record(bondy_rpc_promise, {
    invocation_id       ::  id(),
    procedure_uri       ::  uri(),
    call_id             ::  id(),
    caller              ::  peer_id(),
    callee              ::  peer_id()
}).
-opaque t() :: #bondy_rpc_promise{}.

-export_type([t/0]).

-export([new/5]).
-export([invocation_id/1]).
-export([procedure_uri/1]).
-export([call_id/1]).
-export([callee/1]).
-export([caller/1]).

-export([enqueue/3]).
-export([dequeue/3]).
-export([flush/1]).



%% =============================================================================
%% API
%% =============================================================================



-spec new(
    RequestId :: id(),
    CallId :: id(),
    ProcUri :: uri(),
    Callee :: peer_id(),
    Ctxt :: bondy_context:t()) -> t().

new(ReqId, CallId, ProcUri, Callee, Ctxt) ->
    #bondy_rpc_promise{
        invocation_id = ReqId,
        procedure_uri = ProcUri,
        call_id = CallId,
        caller = bondy_context:peer_id(Ctxt),
        callee = Callee
    }.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
invocation_id(#bondy_rpc_promise{invocation_id = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
call_id(#bondy_rpc_promise{call_id = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
callee(#bondy_rpc_promise{callee = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
caller(#bondy_rpc_promise{caller = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
procedure_uri(#bondy_rpc_promise{procedure_uri = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
enqueue(#bondy_rpc_promise{} = P, Timeout, Ctxt) ->
    InvocationId = P#bondy_rpc_promise.invocation_id,
    CallId = P#bondy_rpc_promise.call_id,
    RealmUri = bondy_context:realm_uri(Ctxt),
    Key = {RealmUri, InvocationId, CallId},
    Opts = #{key => Key, ttl => Timeout},
    tuplespace_queue:enqueue(?INVOCATION_QUEUE, P, Opts).




%% -----------------------------------------------------------------------------
%% @doc Dequeues the promise that matches the Id for the IdType in Ctxt.
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue(
    IdType :: invocation_id | call_id, Id :: id(), Ctxt :: bondy_context:t()) ->
    ok | {ok, timeout} | {ok, t()}.

dequeue(invocation_id, Id, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    dequeue_promise({RealmUri, Id, '_'});

dequeue(call_id, Id, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    dequeue_promise({RealmUri, '_', Id}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec flush(bondy_context:t()) -> bondy_context:t().

flush(Ctxt) ->
    try bondy_context:realm_uri(Ctxt) of
        Uri ->
            Set = bondy_context:awaiting_calls(Ctxt),
            Fun = fun(Id, ICtxt) ->
                Key = {Uri, Id},
                _N = tuplespace_queue:remove(?INVOCATION_QUEUE, #{key => Key}),
                bondy_context:remove_awaiting_call(ICtxt, Id)
            end,
            sets:fold(Fun, Ctxt, Set)
    catch
        error:_ ->
            Ctxt
    end.


%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
-spec dequeue_promise(tuple()) -> ok | {ok, timeout} | {ok, t()}.

dequeue_promise(Key) ->
    case tuplespace_queue:dequeue(?INVOCATION_QUEUE, #{key => Key}) of
        empty ->
            %% The promise might have expired so we GC it.
            case tuplespace_queue:remove(?INVOCATION_QUEUE, #{key => Key}) of
                0 -> ok;
                _ -> {ok, timeout}
            end;
        [#bondy_rpc_promise{} = Promise] ->
            {ok, Promise}
    end.

