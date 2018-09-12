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
    caller              ::  bondy_wamp_peer:t(),
    callee              ::  bondy_wamp_peer:t()
    timestamp                               :: integer()
}).


-opaque t() :: #bondy_rpc_promise{}.
-type match_opts()      ::  #{
    id => id(),
    caller => bondy_wamp_peer:t(),
    callee => bondy_wamp_peer:t()
}.
-type dequeue_fun()     ::  fun((empty | {ok, t()}) -> any()).

-export_type([t/0]).
-export_type([match_opts/0]).
-export_type([dequeue_fun/0]).

-export([call_id/1]).
-export([callee/1]).
-export([caller/1]).
-export([realm_uri/1]).
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
    Callee :: bondy_wamp_peer:remote(),
    Caller :: bondy_context:t()) -> t().

new(InvocationId, Callee, Caller) ->
    %% Realm Uris should match
    bondy_wamp_peer:realm_uri(Caller) =:= bondy_wamp_peer:realm_uri(Callee) orelse error(badarg),

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
    Callee :: bondy_wamp_peer:t(),
    Caller :: bondy_wamp_peer:t()) -> t().

new(InvocationId, CallId, ProcUri, Callee, Caller) ->
    #bondy_rpc_promise{
        invocation_id = InvocationId,
        procedure_uri = ProcUri,
        call_id = CallId,
        caller = Caller,
        callee = Callee
        timestamp = bondy_context:request_timestamp(Ctxt)
    }.



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
realm_uri(#bondy_rpc_promise{caller = Caller}) ->
    bondy_wamp_peer:realm_uri(Caller).


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
-spec callee(t()) -> bondy_wamp_peer:t().
callee(#bondy_rpc_promise{callee = Val}) -> Val.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec caller(t()) -> bondy_wamp_peer:t().
caller(#bondy_rpc_promise{caller = Val}) -> Val.


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
    %% We validate the realm
    RealmUri == realm_uri(P) orelse error(badarg),

    Key = key(P),
    InvocationId = P#bondy_rpc_promise.invocation_id,
    CallId = P#bondy_rpc_promise.call_id,
    CallerSessionId = bondy_wamp_peer:session_id(P#bondy_rpc_promise.caller),

    OnEvict = fun(_) ->
        _ = lager:debug(
            "RPC Promise evicted from queue;"
            " realm_uri=~p, caller_session_id=~p, invocation_id=~p, call_id=~p"
            " timeout=~p",
            [RealmUri, CallerSessionId, InvocationId, CallId, Timeout]
        )
    end,
    Secs = erlang:round(Timeout / 1000),
    Opts = #{key => Key, ttl => Secs, on_evict => OnEvict},
    tuplespace_queue:enqueue(?INVOCATION_QUEUE, P, Opts).


%% -----------------------------------------------------------------------------
%% @doc Dequeues the promise that matches the Id for the IdType in Ctxt.
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue_call(CallId :: id(), Caller :: bondy_wamp_peer:t()) ->
    empty | {ok, t()}.

dequeue_call(CallId, Caller) ->
    RealmUri = bondy_wamp_peer:realm_uri(Caller),
    Pattern = key_pattern(RealmUri, '_', call_key(CallId, Caller)),
    dequeue_promise(Pattern).


%% -----------------------------------------------------------------------------
%% @doc Dequeues the promise that matches the Id for the IdType in Ctxt.
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue_call(
    CallId :: id(), Caller :: bondy_wamp_peer:t(), Fun :: dequeue_fun()) ->
    empty | {ok, t()}.

dequeue_call(CallId, Caller, Fun) ->
    RealmUri = bondy_wamp_peer:realm_uri(Caller),
    Pattern = key_pattern(RealmUri, '_', call_key(CallId, Caller)),
    dequeue_promise(Pattern, Fun).


%% -----------------------------------------------------------------------------
%% @doc Reads the promise that matches the Id for the IdType in Ctxt.
%% @end
%% -----------------------------------------------------------------------------
-spec peek_call(CallId :: id(), Caller :: bondy_wamp_peer:t()) ->
    empty | {ok, t()}.

peek_call(CallId, Caller) ->
    RealmUri = bondy_wamp_peer:realm_uri(Caller),
    Pattern = key_pattern(RealmUri, '_', call_key(CallId, Caller)),
    peek_promise(Pattern).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue_invocation(InvocationId :: id(), Callee :: bondy_wamp_peer:t()) ->
    empty | {ok, t()}.

dequeue_invocation(InvocationId, Callee) ->
    RealmUri = bondy_wamp_peer:realm_uri(Callee),
    Pattern = key_pattern(RealmUri, invocation_key(InvocationId, Callee), '_'),
    dequeue_promise(Pattern).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue_invocation(
    InvocationId :: id(), Callee :: bondy_wamp_peer:t(), dequeue_fun()) ->
    empty | {ok, t()}.

dequeue_invocation(InvocationId, Callee, Fun) ->
    RealmUri = bondy_wamp_peer:realm_uri(Callee),
    Pattern = key_pattern(RealmUri, invocation_key(InvocationId, Callee), '_'),
    dequeue_promise(Pattern, Fun).


%% -----------------------------------------------------------------------------
%% @doc Reads the promise that matches the Id for the IdType in Ctxt.
%% @end
%% -----------------------------------------------------------------------------
-spec peek_invocation(InvocationId :: id(), Callee :: bondy_wamp_peer:t()) ->
    empty | {ok, t()}.

peek_invocation(InvocationId, Callee) ->
    RealmUri = bondy_wamp_peer:realm_uri(Callee),
    Pattern = key_pattern(RealmUri, invocation_key(InvocationId, Callee), '_'),
    peek_promise(Pattern).


%% -----------------------------------------------------------------------------
%% @doc Removes all pending promises from the queue for the Caller's SessionId
%% @end
%% -----------------------------------------------------------------------------
-spec flush(bondy_wamp_peer:local()) -> ok.

flush(Caller) ->
    %% This will match all promises for SessionId
    RealmUri = bondy_wamp_peer:realm_uri(Caller),
    Pattern = {RealmUri, '_', call_key('_', Caller)},
    _N = tuplespace_queue:remove(?INVOCATION_QUEUE, #{key => Pattern}),
    ok.


queue_size() ->
    tuplespace_queue:size(?INVOCATION_QUEUE).



%% =============================================================================
%% PRIVATE
%% =============================================================================




%% @private
key(#bondy_rpc_promise{} = P) ->
    {realm_uri(P), invocation_key(P), call_key(P)}.


%% @private
key_pattern(RealmUri, '_', CallKey) ->
    {RealmUri, '_', CallKey};

key_pattern(RealmUri, InvocationKey, '_') ->
    {RealmUri, InvocationKey, '_'}.


%% private
call_key(#bondy_rpc_promise{} = P) ->
    call_key(P#bondy_rpc_promise.call_id, P#bondy_rpc_promise.caller).


%% @private
call_key(CallId, Caller) ->
    CallerNode = bondy_wamp_peer:node(Caller),
    CallerSessionId = bondy_wamp_peer:session_id(Caller),
    {CallerNode, CallerSessionId, CallId}.

%% private
invocation_key(#bondy_rpc_promise{} = P) ->
    invocation_key(
        P#bondy_rpc_promise.invocation_id, P#bondy_rpc_promise.callee).


%% @private
invocation_key(InvocationId, Callee) ->
    CalleeNode = bondy_wamp_peer:node(Callee),
    CalleeSessionId = bondy_wamp_peer:session_id(Callee),
    {CalleeNode, CalleeSessionId, InvocationId}.


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
