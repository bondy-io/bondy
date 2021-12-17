%% =============================================================================
%%  bondy_rpc_promise.erl -
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

%% -----------------------------------------------------------------------------
%% @doc A promise is used to implement a capability and a feature:
%% - the capability to match the callee response (wamp_yield() or wamp_error())
%% back to the origin wamp_call() and Caller
%% - the call_timeout feature at the dealer level
%% @end
%% -----------------------------------------------------------------------------
-module(bondy_rpc_promise).
-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-define(PROMISE_QUEUE, bondy_rpc_promise).

-record(bondy_rpc_promise, {
    procedure_uri           ::  maybe(uri()),
    invocation_id           ::  id(),
    call_id                 ::  maybe(id()),
    callee                  ::  bondy_ref:t(),
    caller                  ::  bondy_ref:t(),
    via                     ::  maybe(queue:queue(bondy_ref:t())),
    timestamp               ::  integer()
}).


-opaque t()                 ::  #bondy_rpc_promise{}.

%% We need realm and nodestrings because session ids are not globally unique,
%% and request ids are in the session scope sequences.
-type key()                 ::  {
                                    RealmUri :: uri(),
                                    InvocationId :: wildcard(id()),
                                    CallId :: wildcard(id()),
                                    CalleeNodestring :: wildcard(nodestring()),
                                    CalleeSession :: wildcard(id()),
                                    CallerNodestring :: wildcard(nodestring()),
                                    CallerSession :: wildcard(id())
                                }.
-type match_opts()          ::  #{
                                    id => id(),
                                    caller => bondy_ref:t(),
                                    callee => bondy_ref:t()
                                }.
-type dequeue_fun()         ::  fun((empty | {ok, t()}) -> any()).
-type wildcard(T)           ::  T | '_'.
-type opts()                ::  #{
                                    call_id => id(),
                                    procedure_uri => uri(),
                                    via =>
                                        bondy_ref:relay()
                                        | bondy_ref:bridge_relay()
                                }.

-export_type([t/0]).
-export_type([match_opts/0]).
-export_type([dequeue_fun/0]).


-export([call_id/1]).
-export([callee/1]).
-export([caller/1]).
-export([via/1]).
-export([dequeue/1]).
-export([dequeue/2]).
-export([enqueue/3]).
-export([flush/1]).
-export([invocation_id/1]).
-export([key_pattern/5]).
-export([new/3]).
-export([new/4]).
-export([peek/1]).
-export([procedure_uri/1]).
-export([queue_size/0]).
-export([timestamp/1]).


%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Creates a new promise for a remote invocation.
%% In this case the caller lives in a different node and has recorded a promise
%% using new/5 in its node.
%% @end
%% -----------------------------------------------------------------------------
-spec new(
    InvocationId :: id(),
    Callee :: bondy_ref:t(),
    Ctxt :: bondy_context:t()) -> t().

new(InvocationId, Callee, Caller) ->
    new(InvocationId, Callee, Caller, #{}).


%% -----------------------------------------------------------------------------
%% @doc Creates a new promise for a remote invocation.
%% In this case the caller lives in a different node and has recorded a promise
%% using new/5 in its node.
%% @end
%% -----------------------------------------------------------------------------
-spec new(
    InvocationId :: id(),
    Callee :: bondy_ref:t(),
    Ctxt :: bondy_context:t(),
    Opts :: opts()) -> t().

new(InvocationId, Callee, Caller, Opts) when is_integer(InvocationId) ->
    bondy_ref:is_type(Callee)
        orelse error({badarg, {callee, Callee}}),

    bondy_ref:is_type(Caller)
        orelse error({badarg, {caller, Caller}}),

    Via =
        case maps:get(via, Opts, undefined) of
            undefined ->
                queue:new();
            Term ->
                case queue:is_queue(Term) of
                    true ->
                        Term;
                    false ->
                        bondy_ref:is_type(Term)
                            orelse error({badarg, {via, Term}}),
                        queue:from_list([Term])
                end
        end,


    CallId = maps:get(call_id, Opts, undefined),
    is_integer(CallId)
        orelse CallId == undefined
        orelse error({badarg, {call_id, CallId}}),

    Uri = maps:get(procedure_uri, Opts, undefined),
    is_binary(Uri)
        orelse Uri == undefined
        orelse error({badarg, {procedure_uri, Uri}}),


    #bondy_rpc_promise{
        invocation_id = InvocationId,
        call_id = CallId,
        procedure_uri = Uri,
        caller = Caller,
        callee = Callee,
        via = Via,
        timestamp = erlang:monotonic_time()
    }.


%% -----------------------------------------------------------------------------
%% @doc Returns the invocation request identifier
%% @end
%% -----------------------------------------------------------------------------
invocation_id(#bondy_rpc_promise{invocation_id = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the call request identifier
%% @end
%% -----------------------------------------------------------------------------
call_id(#bondy_rpc_promise{call_id = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the callee (`bondy_ref:t()') that is the target of this invocation
%% promise.
%% @end
%% -----------------------------------------------------------------------------
-spec callee(t()) -> bondy_ref:t().

callee(#bondy_rpc_promise{callee = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the caller (`bondy_ref:t()') who made the call request
%% associated with this invocation promise.
%% @end
%% -----------------------------------------------------------------------------
-spec caller(t()) -> bondy_ref:t().

caller(#bondy_rpc_promise{caller = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc Returns the queue of relays that are needed to forward an invocation
%% result to the caller.
%% @end
%% -----------------------------------------------------------------------------
-spec via(t()) -> queue:queue(bondy_ref:relay() | bondy_ref:bridge_relay()).

via(#bondy_rpc_promise{via = Val}) ->
    Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
procedure_uri(#bondy_rpc_promise{procedure_uri = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
timestamp(#bondy_rpc_promise{timestamp = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc Adds the invocation promise `P' to the promise queue for realm
%% `RealmUri' using a timeout of `Timeout'.
%%
%% If the promise is not dequeued before `Timeout' milliseconds, the caller
%% will receive an error with reason "wamp.error.timeout".
%% @end
%% -----------------------------------------------------------------------------
enqueue(RealmUri, #bondy_rpc_promise{call_id = undefined} = P, Timeout) ->
    InvocationId = P#bondy_rpc_promise.invocation_id,
    Caller = P#bondy_rpc_promise.caller,
    Callee = P#bondy_rpc_promise.callee,

    Key = key(RealmUri, InvocationId, undefined, Callee, Caller),

    Secs = erlang:round(Timeout / 1000),
    Opts = #{key => Key, ttl => Secs},
    tuplespace_queue:enqueue(?PROMISE_QUEUE, P, Opts);

enqueue(RealmUri, #bondy_rpc_promise{} = P, Timeout) ->
    InvocationId = P#bondy_rpc_promise.invocation_id,
    CallId = P#bondy_rpc_promise.call_id,
    ProcUri = P#bondy_rpc_promise.procedure_uri,
    Caller = P#bondy_rpc_promise.caller,
    Callee = P#bondy_rpc_promise.callee,

    Key = key(RealmUri, InvocationId, CallId, Callee, Caller),

    OnEvict = fun(_) ->
        ?LOG_DEBUG(#{
            description => "RPC Promise evicted from queue",
            realm_uri => RealmUri,
            caller => Caller,
            procedure_uri => ProcUri,
            invocation_id => InvocationId,
            call_id => CallId,
            timeout => Timeout
        }),
        Mssg = iolist_to_binary(
            io_lib:format(
                "The operation could not be completed in time"
                " (~p milliseconds).",
                [Timeout]
            )
        ),
        Error = wamp_message:error(
            ?CALL,
            CallId,
            #{
                procedure_uri => ProcUri,
                timeout => Timeout
            },
            ?WAMP_TIMEOUT,
            [Mssg]
        ),
        bondy:send(Caller, Error)
    end,

    Secs = erlang:round(Timeout / 1000),
    Opts = #{key => Key, ttl => Secs, on_evict => OnEvict},
    tuplespace_queue:enqueue(?PROMISE_QUEUE, P, Opts).


%% -----------------------------------------------------------------------------
%% @doc Pattern for dequeueing
%% @end
%% -----------------------------------------------------------------------------
-spec key_pattern(
    RealmUri :: uri(),
    InvocationId :: id(),
    CallId :: id(),
    Callee :: bondy_ref:t(),
    Caller :: bondy_ref:t()) -> key().

key_pattern(RealmUri, InvocationId, CallId, Callee, Caller) ->
    InvocationId == '_' orelse is_integer(InvocationId)
        orelse error({badarg, {invocation_id, InvocationId}}),

    CallId == '_' orelse is_integer(CallId)
        orelse error({badarg, {invocation_id, CallId}}),

    P0 = {
        RealmUri,
        InvocationId,
        CallId,
        '_', '_',
        '_', '_'
    },

    P1 = case Callee of
        '_' ->
            P0;
        _ ->
            CalleeNode = bondy_ref:nodestring(Callee),
            CalleeSession = bondy_ref:session_id(Callee),
            setelement(5, setelement(4, P0, CalleeNode), CalleeSession)
    end,

    case Caller of
        '_' ->
            P1;
        _ ->
            CallerNode = bondy_ref:nodestring(Caller),
            CallerSession = bondy_ref:session_id(Caller),
            setelement(7, setelement(6, P0, CallerNode), CallerSession)
    end.


%% -----------------------------------------------------------------------------
%% @doc Dequeues the promise that matches key pattern
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue(Key :: key()) -> empty | {ok, t()}.

dequeue(Key) ->
    Opts = #{key => Key},

    case tuplespace_queue:dequeue(?PROMISE_QUEUE, Opts) of
        [#bondy_rpc_promise{} = Promise] ->
            {ok, Promise};
        empty ->
            empty
    end.


%% -----------------------------------------------------------------------------
%% @doc Dequeues the promise that matches key pattern
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue(key(), dequeue_fun()) -> any().

dequeue(Key, Fun) when is_function(Fun, 1) ->
    Fun(dequeue(Key)).



%% -----------------------------------------------------------------------------
%% @doc Reads the promise that matches the key pattern
%% @end
%% -----------------------------------------------------------------------------
-spec peek(key()) -> {ok, t()} | empty.

peek(Key) ->
    Opts = #{key => Key},
    case tuplespace_queue:peek(?PROMISE_QUEUE, Opts) of
        empty ->
            empty;
        [#bondy_rpc_promise{} = P] ->
            {ok, P}
    end.


%% -----------------------------------------------------------------------------
%% @doc Removes all pending promises from the queue for the reference
%% @end
%% -----------------------------------------------------------------------------
-spec flush(bondy_ref:t()) -> ok.

flush(Ref) ->
    %% Ref can be caller and callee
    RealmUri = bondy_ref:realm_uri(Ref),
    AsCaller =  key_pattern(
        RealmUri, '_', '_', '_', Ref
    ),
    AsCallee =  key_pattern(
        RealmUri, '_', '_', Ref, '_'
    ),

    %% We remove all pending calls by Ref (as caller)
    _ = tuplespace_queue:remove(?PROMISE_QUEUE, #{key => AsCaller}),

    %% We remove all pending invocations by Ref (as callee)
    _ = tuplespace_queue:remove(?PROMISE_QUEUE, #{key => AsCallee}),

    ok.


queue_size() ->
    tuplespace_queue:size(?PROMISE_QUEUE).



%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
key(RealmUri, InvocationId, CallId, Callee, Caller) ->
    CalleeNode = bondy_ref:nodestring(Callee),
    CalleeSession = bondy_ref:session_id(Callee),
    CallerNode = bondy_ref:nodestring(Caller),
    CallerSession = bondy_ref:session_id(Caller),
    {
        RealmUri,
        InvocationId,
        CallId,
        CalleeNode, CalleeSession,
        CallerNode, CallerSession
    }.


