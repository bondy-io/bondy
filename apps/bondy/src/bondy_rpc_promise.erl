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
%% @doc
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
    caller                  ::  peer_id(),
    callee                  ::  peer_id(),
    timestamp               ::  integer()
}).


-opaque t() :: #bondy_rpc_promise{}.
-type match_opts()      ::  #{
    id => id(),
    caller => peer_id(),
    callee => peer_id()
}.
-type dequeue_fun()     ::  fun((empty | {ok, t()}) -> any()).

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
    Callee :: remote_peer_id(),
    Ctxt :: bondy_context:t()) -> t().

new(InvocationId, Callee, Caller) ->
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
    CallId :: id(),
    ProcUri :: uri(),
    Callee :: peer_id(),
    Ctxt :: bondy_context:t()) -> t().

new(InvocationId, CallId, ProcUri, Callee, Ctxt) ->
    #bondy_rpc_promise{
        invocation_id = InvocationId,
        procedure_uri = ProcUri,
        call_id = CallId,
        caller = bondy_context:peer_id(Ctxt),
        callee = Callee,
        timestamp = bondy_context:request_timestamp(Ctxt)
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
-spec callee(t()) -> peer_id().
callee(#bondy_rpc_promise{callee = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec caller(t()) -> peer_id().
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
%% @doc
%% @end
%% -----------------------------------------------------------------------------
enqueue(RealmUri, #bondy_rpc_promise{} = P, Timeout) ->
    InvocationId = P#bondy_rpc_promise.invocation_id,
    ProcUri = P#bondy_rpc_promise.procedure_uri,
    CallId = P#bondy_rpc_promise.call_id,
    {_, _, CallerSessionId, _} = Caller = P#bondy_rpc_promise.caller,
    %% We match realm_uri for extra validation
    Key = key(RealmUri, P),

    OnEvict = fun(_) ->
        ?LOG_DEBUG(#{
            description => "RPC Promise evicted from queue",
            realm_uri => RealmUri,
            caller_session_id => CallerSessionId,
            invocation_id => InvocationId,
            procedure_uri => ProcUri,
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
-spec dequeue_call(CallId :: id(), Caller :: peer_id()) ->
    empty | {ok, t()}.

dequeue_call(Id, Caller) ->
    dequeue_promise(call_key_pattern(Id, Caller)).


%% -----------------------------------------------------------------------------
%% @doc Dequeues the promise that matches the Id for the IdType in Ctxt.
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue_call(CallId :: id(), Caller :: peer_id(), Fun :: dequeue_fun()) ->
    any().

dequeue_call(Id, Caller, Fun) ->
    dequeue_promise(call_key_pattern(Id, Caller), Fun).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue_invocation(CallId :: id(), Callee :: peer_id()) ->
    empty | {ok, t()}.

dequeue_invocation(Id, Callee) ->
    dequeue_promise(invocation_key_pattern(Id, Callee)).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue_invocation(CallId :: id(), Callee :: peer_id(), dequeue_fun()) ->
    any().

dequeue_invocation(Id, Callee, Fun) ->
    dequeue_promise(invocation_key_pattern(Id, Callee), Fun).


%% -----------------------------------------------------------------------------
%% @doc Reads the promise that matches the Id for the IdType in Ctxt.
%% @end
%% -----------------------------------------------------------------------------
-spec peek_call(CallId :: id(), Caller :: peer_id()) ->
    empty | {ok, t()}.

peek_call(CallId, Caller) ->
    peek_promise(call_key_pattern(CallId, Caller)).


%% -----------------------------------------------------------------------------
%% @doc Reads the promise that matches the Id for the IdType in Ctxt.
%% @end
%% -----------------------------------------------------------------------------
-spec peek_invocation(InvocationId :: id(), Callee :: peer_id()) ->
    empty | {ok, t()}.

peek_invocation(InvocationId, Callee) ->
    peek_promise(invocation_key_pattern(InvocationId, Callee)).


%% -----------------------------------------------------------------------------
%% @doc Removes all pending promises from the queue for the Caller's SessionId
%% @end
%% -----------------------------------------------------------------------------
-spec flush(local_peer_id()) -> ok.

flush(Caller) ->
    %% This will match all promises for SessionId
    Key = {element(1, Caller), {'_', setelement(4, Caller, '_')}, '_'},
    _N = tuplespace_queue:remove(?INVOCATION_QUEUE, #{key => Key}),
    ok.


queue_size() ->
    tuplespace_queue:size(?INVOCATION_QUEUE).


%% =============================================================================
%% PRIVATE
%% =============================================================================


key(RealmUri, #bondy_rpc_promise{} = P) ->
    CallId = P#bondy_rpc_promise.call_id,
    InvocationId = P#bondy_rpc_promise.invocation_id,
    %% {_, Node, CallerSessionId, _} = P#bondy_rpc_promise.caller,
    %% {_, Node, CalleeSessionId, _} = P#bondy_rpc_promise.callee,

    {
        RealmUri,
        {InvocationId, P#bondy_rpc_promise.callee},
        {CallId, P#bondy_rpc_promise.caller}
    }.


%% @private
call_key_pattern(CallId, {RealmUri, _, _, _} = Caller) ->
    %% We exclude the pid from the match
    {RealmUri, '_', {CallId, setelement(4, Caller, '_')}}.


%% @private
invocation_key_pattern(InvocationId, {RealmUri, _, _, _} = Callee) ->
    %% We exclude the pid from the match
    {RealmUri, {InvocationId, setelement(4, Callee, '_')}, '_'}.


%% @private
-spec dequeue_promise(tuple()) -> empty | {ok, t()}.

dequeue_promise(Key) ->
    Opts = #{key => Key},
    case tuplespace_queue:dequeue(?INVOCATION_QUEUE, Opts) of
        empty ->
            %% The promise might have expired so we GC it.
            %% case tuplespace_queue:remove(?INVOCATION_QUEUE, Opts) of
            %%     0 -> empty;
            %%     _ -> empty
            %% end;
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