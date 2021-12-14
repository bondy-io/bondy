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

-define(INVOCATION_QUEUE, bondy_rpc_promise).

-record(bondy_rpc_promise, {
    invocation_id           ::  id(),
    procedure_uri           ::  maybe(uri()),
    call_id                 ::  maybe(id()),
    caller                  ::  bondy_ref:t(),
    callee                  ::  bondy_ref:t(),
    timestamp               ::  integer()
}).


-opaque t()                 :: #bondy_rpc_promise{}.
-type match_opts()          ::  #{
                                    id => id(),
                                    caller => bondy_ref:t(),
                                    callee => bondy_ref:t()
                                }.
-type dequeue_fun()         ::  fun((empty | {ok, t()}) -> any()).


-export_type([t/0]).
-export_type([match_opts/0]).
-export_type([dequeue_fun/0]).


-export([call_id/1]).
-export([callee/1]).
-export([caller/1]).
-export([dequeue_call/2]).
-export([dequeue_call/3]).
-export([dequeue_invocation/2]).
-export([dequeue_invocation/3]).
-export([enqueue/3]).
-export([flush/1]).
-export([invocation_id/1]).
-export([new/3]).
-export([new/5]).
-export([peek_call/2]).
-export([peek_invocation/2]).
-export([procedure_uri/1]).
-export([queue_size/0]).
-export([timestamp/1]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Creates a new promise for a remote invocation
%% @end
%% -----------------------------------------------------------------------------
-spec new(
    InvocationId :: id(),
    Callee :: bondy_ref:t(),
    Ctxt :: bondy_context:t()) -> t().

new(InvocationId, Callee, Caller) ->
    bondy_ref:is_type(Callee)
        orelse error({badarg, Callee}),

    bondy_ref:is_type(Caller)
        orelse error({badarg, Caller}),

    #bondy_rpc_promise{
        invocation_id = InvocationId,
        caller = Caller,
        callee = Callee,
        timestamp = erlang:monotonic_time()
    }.


%% -----------------------------------------------------------------------------
%% @doc Creates a new promise for a local call - invocation
%% @end
%% -----------------------------------------------------------------------------
-spec new(
    InvocationId :: id(),
    Callee :: bondy_ref:t(),
    Caller :: bondy_ref:t(),
    CallId :: id(),
    ProcUri :: uri()) -> t().

new(InvocationId, Callee, Caller, CallId, ProcUri) ->

    bondy_ref:is_type(Callee)
        orelse error({badarg, Callee}),

    #bondy_rpc_promise{
        invocation_id = InvocationId,
        call_id = CallId,
        procedure_uri = ProcUri,
        caller = Caller,
        callee = Callee,
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
%% @doc Returns the caller (`bondy_ref:t()') who made the call request associated
%% with this invocation promise.
%% @end
%% -----------------------------------------------------------------------------
-spec caller(t()) -> bondy_ref:t().

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

    Key = {RealmUri, InvocationId, Callee, undefined, Caller},

    Secs = erlang:round(Timeout / 1000),
    Opts = #{key => Key, ttl => Secs},
    tuplespace_queue:enqueue(?INVOCATION_QUEUE, P, Opts);

enqueue(RealmUri, #bondy_rpc_promise{} = P, Timeout) ->
    InvocationId = P#bondy_rpc_promise.invocation_id,
    CallId = P#bondy_rpc_promise.call_id,
    ProcUri = P#bondy_rpc_promise.procedure_uri,
    Caller = P#bondy_rpc_promise.caller,
    Callee = P#bondy_rpc_promise.callee,

    Key = {RealmUri, InvocationId, Callee, CallId, Caller},

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
    tuplespace_queue:enqueue(?INVOCATION_QUEUE, P, Opts).


%% -----------------------------------------------------------------------------
%% @doc Dequeues the promise that matches the Id for the IdType in Ctxt.
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue_call(CallId :: id(), Caller :: bondy_ref:t()) ->
    empty | {ok, t()}.

dequeue_call(Id, Caller) ->
    dequeue_promise(call_key_pattern(Id, Caller)).


%% -----------------------------------------------------------------------------
%% @doc Dequeues the promise that matches the Id for the IdType in Ctxt.
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue_call(
    CallId :: id(), Caller :: bondy_ref:t(), Fun :: dequeue_fun()) ->
    FunResult :: any().

dequeue_call(Id, Caller, Fun) ->
    dequeue_promise(call_key_pattern(Id, Caller), Fun).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue_invocation(CallId :: id(), Callee :: bondy_ref:t()) ->
    empty | {ok, t()}.

dequeue_invocation(Id, Callee) ->
    dequeue_promise(invocation_key_pattern(Id, Callee)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue_invocation(
    CallId :: id(), Callee :: bondy_ref:t(), Fun :: dequeue_fun()) ->
    FunResult :: any().

dequeue_invocation(Id, Callee, Fun) ->
    dequeue_promise(invocation_key_pattern(Id, Callee), Fun).


%% -----------------------------------------------------------------------------
%% @doc Reads the promise that matches the Id for the IdType in Ctxt.
%% @end
%% -----------------------------------------------------------------------------
-spec peek_call(CallId :: id(), Caller :: bondy_ref:t()) ->
    empty | {ok, t()}.

peek_call(CallId, Caller) ->
    peek_promise(call_key_pattern(CallId, Caller)).


%% -----------------------------------------------------------------------------
%% @doc Reads the promise that matches the Id for the IdType in Ctxt.
%% @end
%% -----------------------------------------------------------------------------
-spec peek_invocation(InvocationId :: id(), Callee :: bondy_ref:t()) ->
    empty | {ok, t()}.

peek_invocation(InvocationId, Callee) ->
    peek_promise(invocation_key_pattern(InvocationId, Callee)).


%% -----------------------------------------------------------------------------
%% @doc Removes all pending promises from the queue for the reference
%% @end
%% -----------------------------------------------------------------------------
-spec flush(bondy_ref:t()) -> ok.

flush(Ref) ->
    %% Ref can be caller and callee

    %% We remove all pending calls by Ref (as caller)
    Key1 = call_key_pattern('_', Ref),
    _ = tuplespace_queue:remove(?INVOCATION_QUEUE, #{key => Key1}),

    %% We remove all pending invocations by Ref (as callee)
    Key2 = call_key_pattern('_', Ref),
    _ = tuplespace_queue:remove(?INVOCATION_QUEUE, #{key => Key2}),

    ok.


queue_size() ->
    tuplespace_queue:size(?INVOCATION_QUEUE).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
call_key_pattern(CallId, Caller) ->
    Type = bondy_ref:type(Caller),
    RealmUri = bondy_ref:realm_uri(Caller),
    Target = bondy_ref:target(Caller),
    Node = bondy_ref:node(Caller),
    SessionId = '_',

    InvocationId = '_',
    Callee = '_',
    CallerPattern = bondy_ref:pattern(Type, RealmUri, Target, SessionId, Node),

    %% We exclude the pid from the match
    {RealmUri, InvocationId, Callee, CallId, CallerPattern}.


%% @private
invocation_key_pattern(InvocationId, Callee) ->
    Type = bondy_ref:type(Callee),
    RealmUri = bondy_ref:realm_uri(Callee),
    Target = '_',
    Node = bondy_ref:node(Callee),
    SessionId = bondy_ref:session_id(Callee),

    CalleePattern = bondy_ref:pattern(Type, RealmUri, Target, SessionId, Node),
    CallId = '_',
    Caller = '_',

    %% We exclude the pid from the match
    {RealmUri, InvocationId, CalleePattern, CallId, Caller}.


%% @private
-spec dequeue_promise(tuple()) -> empty | {ok, t()}.

dequeue_promise(Key) ->
    Opts = #{key => Key},
    case tuplespace_queue:dequeue(?INVOCATION_QUEUE, Opts) of
        empty ->
            empty;
        [#bondy_rpc_promise{} = Promise] ->
            {ok, Promise}
    end.


%% @private
-spec dequeue_promise(tuple(), dequeue_fun()) -> any().

dequeue_promise(Key, Fun) when is_function(Fun, 1) ->
    Fun(dequeue_promise(Key)).


%% @private
-spec peek_promise(tuple()) -> {ok, t()} | empty.

peek_promise(Key) ->
    Opts = #{key => Key},
    case tuplespace_queue:peek(?INVOCATION_QUEUE, Opts) of
        empty ->
            empty;
        [#bondy_rpc_promise{} = P] ->
            {ok, P}
    end.