%% =============================================================================
%%  bondy_rpc_promise.erl -
%%
%%  Copyright (c) 2016-2018 Ngineo Limited t/a Leapsight. All rights reserved.
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

-module(bondy_rpc_promise).
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").

-define(INVOCATION_QUEUE, bondy_rpc_promise).

-record(bondy_rpc_promise, {
    invocation_id       ::  id(),
    procedure_uri       ::  uri() | undefined,
    call_id             ::  id() | undefined,
    caller              ::  peer_id(),
    callee              ::  peer_id()
}).
-opaque t() :: #bondy_rpc_promise{}.

-export_type([t/0]).

-export([new/3]).
-export([new/5]).
-export([invocation_id/1]).
-export([procedure_uri/1]).
-export([call_id/1]).
-export([callee/1]).
-export([caller/1]).

-export([enqueue/3]).
-export([dequeue/2]).
-export([peek/2]).
-export([flush/2]).



%% =============================================================================
%% API
%% =============================================================================

%% -----------------------------------------------------------------------------
%% @doc Creates a new promise for a remote invocation
%% @end
%% -----------------------------------------------------------------------------
-spec new(
    RequestId :: id(),
    Callee :: remote_peer_id(),
    Ctxt :: bondy_context:t()) -> t().

new(ReqId, Callee, Caller) ->
    #bondy_rpc_promise{
        invocation_id = ReqId,
        caller = Caller,
        callee = Callee
    }.


%% -----------------------------------------------------------------------------
%% @doc Creates a new promise for a local call - invocation
%% @end
%% -----------------------------------------------------------------------------
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
enqueue(RealmUri, #bondy_rpc_promise{} = P, Timeout) ->
    InvocationId = P#bondy_rpc_promise.invocation_id,
    CallId = P#bondy_rpc_promise.call_id,
    %% We match realm_uri for extra validation
    {RealmUri, _Node, SessionId, _Pid} = P#bondy_rpc_promise.caller,
    Key = {RealmUri, InvocationId, CallId, SessionId},
    Opts = #{key => Key, ttl => Timeout},
    tuplespace_queue:enqueue(?INVOCATION_QUEUE, P, Opts).


%% -----------------------------------------------------------------------------
%% @doc Dequeues the promise that matches the Id for the IdType in Ctxt.
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue( uri(), {IdType :: invocation_id | call_id, Id :: id()}) ->
    empty | {ok, t()}.

dequeue(RealmUri, {invocation_id, Id}) ->
    dequeue_promise({RealmUri, Id, '_', '_'});

dequeue(RealmUri, {call_id, Id}) ->
    dequeue_promise({RealmUri, '_', Id, '_'}).



%% -----------------------------------------------------------------------------
%% @doc Dequeues the promise that matches the Id for the IdType in Ctxt.
%% @end
%% -----------------------------------------------------------------------------
-spec peek( uri(), {IdType :: invocation_id | call_id, Id :: id()}) ->
    empty | {ok, t()}.

peek(RealmUri, {invocation_id, Id}) ->
    peek_promise({RealmUri, Id, '_', '_'});

peek(RealmUri, {call_id, Id}) ->
    peek_promise({RealmUri, '_', Id, '_'}).



%% -----------------------------------------------------------------------------
%% @doc Removes all pending promises for the Ctxt's session from the queue.
%% @end
%% -----------------------------------------------------------------------------
-spec flush(uri(), id()) -> ok.

flush(RealmUri, SessionId) ->
    %% This will match all promises for SessionId
    Key = {RealmUri, '_', '_', SessionId},
    _N = tuplespace_queue:remove(?INVOCATION_QUEUE, #{key => Key}),
    ok.


%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
-spec dequeue_promise(tuple()) -> empty | {ok, t()}.

dequeue_promise(Key) ->
    Opts = #{key => Key},
    case tuplespace_queue:dequeue(?INVOCATION_QUEUE, Opts) of
        empty ->
            %% The promise might have expired so we GC it.
            case tuplespace_queue:remove(?INVOCATION_QUEUE, Opts) of
                0 -> empty;
                _ -> empty
            end;
        [#bondy_rpc_promise{} = Promise] ->
            {ok, Promise}
    end.


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