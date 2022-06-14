%% =============================================================================
%%  bondy_dealer.erl -
%%
%%  Copyright (c) 2016-2022 Leapsight. All rights reserved.
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
%% @doc This module implements the capabilities of a Dealer. It is used by
%% {@link bondy_router}.
%%
%% A Dealer is one of the two roles a Router plays. In particular a Dealer is
%% the middleman between an Caller and a Callee in an Routed RPC interaction,
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
%% <ol>
%% <li>`REGISTER'</li>
%% <li>`REGISTERED'</li>
%% <li>`UNREGISTER'</li>
%% <li>`UNREGISTERED'</li>
%% <li>`ERROR'</li>
%% </ol>
%%
%% ```
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
%% '''
%%
%% == Calling and Invocations ==
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
%% <pre><code class="mermaid">
%%    sequenceDiagram
%%     %%{init: {'theme': 'neutral'} }%%
%%     Caller->>+Dealer: CALL
%%     Dealer->>Callee: INVOCATION
%%     Callee->>Dealer: YIELD | ERROR
%%     Dealer->>Caller: RESULT | ERROR
%% </code></pre>
%%
%%    The execution of remote procedure calls is asynchronous, and there
%%    may be more than one call outstanding.  A call is called outstanding
%%    (from the point of view of the _Caller_), when a (final) result or
%%    error has not yet been received by the _Caller_.
%%
%% == Routing ==
%% The following sections describes how RPC routing is performed for all the
%% generic use cases involving clustering and bridge relay connections.
%% The following diagram shows the the example used in all the use cases, which
%% involves a single Caller making calls to four different Callees that are
%% local or remote to the caller.
%%
%% Notice that the erlang code included in the diagram notes are to be
%% considered pseudo-code as they do not necesarily match the actual function
%% signatures.
%%
%% <pre><code class="mermaid">
%%   flowchart TB
%%     %%{init: {'theme': 'neutral'} }%%
%%     subgraph Bondy Cluster
%%     Node1
%%     Node2
%%     end
%%     subgraph Clients
%%     CALLER --> Node1
%%     CALLEE1 --> Node1
%%     CALLEE2 --> Node2
%%     end
%%     subgraph Bondy Edge Cluster
%%     EdgeNode1
%%     EdgeNode2
%%     end
%%     Node1 -.Bridge Relay Connection...- EdgeNode1
%%     subgraph Edge Clients
%%     CALLEE3 --> EdgeNode1
%%     CALLEE4 --> EdgeNode2
%%     end
%% </code></pre>
%%
%% === Call to a local Callee ===
%%
%% <pre><code class="mermaid">
%%     sequenceDiagram
%%     %%{init: {'theme': 'neutral'} }%%
%%     	autonumber
%%       participant CALLER
%%       participant node1
%%       participant CALLEE1
%%     	note over node1: CALLEE1 seq = 99
%%     	CALLER ->> node1:CALL.1
%%     	note over node1: CALLEE1 seq = 100
%%     	node1 -->> node1: promise:add({100, 1})
%%     	node1 ->> CALLEE1: INVOCATION.100
%%     	CALLEE1 ->> node1: YIELD.100
%%     	node1 -->> node1: bondy_rpc_promise:take({100, 1})
%%     	node1 ->> CALLER: RESULT.1
%% </code></pre>
%%
%% === Call to a Remote Callee ===
%%
%% <pre><code class="mermaid">
%%    sequenceDiagram
%%     %%{init: {'theme': 'neutral'} }%%
%%      autonumber
%%     	participant CALLER
%%     	participant Node1
%%     	participant Node2
%%     	participant CALLEE2
%%     	note over Node2: CALLEE2 seq = 99
%%     	CALLER ->> Node1:CALL.2
%%     	Node1 -->> Node1: bondy_rpc_promise:new_call(2)
%%     	rect RGB(230, 230, 230)
%%     	note over Node1,Node2: CLUSTER CONNECTION
%%     	Node1 -->> Node2: CALL.2
%%      end
%%     	Node2 -->> Node2: bondy_rpc_promise:new_invocation(100, 2)
%%     	note over Node2: CALLEE2 seq = 100
%%     	Node2 ->> CALLEE2: INVOCATION.100
%%     	CALLEE2 ->> Node2: YIELD.100
%%     	Node2 -->> Node2: bondy_rpc_promise:take({invocation, 100, '_'})
%%     	Node2 -->> Node1: RESULT.2
%%     	Node1 -->> Node1: bondy_rpc_promise:take({call, 2})
%%     	Node1 ->> CALLER: RESULT.2
%% </code></pre>
%%
%% === Call to Bridged Callee ===
%%
%% <pre><code class="mermaid">
%%   sequenceDiagram
%%     %%{init: {'theme': 'neutral'} }%%
%%     autonumber
%%     	participant CALLER
%%     	participant Node1
%%     	participant Node2
%%     	participant CALLEE2
%%     	note over Node2: CALLEE2 seq = 99
%%     	CALLER ->> Node1:CALL.2
%%     	Node1 -->> Node1: bondy_rpc_promise:new_call(2)
%%     	rect RGB(230, 230, 230)
%%     	note over Node1,Node2: CLUSTER CONNECTION
%%     	Node1 -->> Node2: CALL.2
%%      end
%%     	Node2 -->> Node2: bondy_rpc_promise:new_invocation(100, 2)
%%     	note over Node2: CALLEE2 seq = 100
%%     	Node2 ->> CALLEE2: INVOCATION.100
%%     	CALLEE2 ->> Node2: YIELD.100
%%     	Node2 -->> Node2: bondy_rpc_promise:take(invocation, 100, '_')
%%     	Node2 -->> Node1: RESULT.2
%%     	Node1 -->> Node1: bondy_rpc_promise:take({call, 2})
%%     	Node1 ->> CALLER: RESULT.2
%% </code></pre>
%%
%% === Call to remote Bridged Callee ===
%%
%% <pre><code class="mermaid">
%%    sequenceDiagram
%%     %%{init: {'theme': 'neutral'} }%%
%%     	participant CALLER
%%     	participant Node1
%%     	participant Node2
%%     	participant Bridged_Node1
%%     	participant Bridged_Node2
%%     	note over Bridged_Node2: CALLEE seq = 99
%%     	participant CALLEE4
%%     	CALLER ->> Node1:CALL.5
%%     	Node1 -->> Node1: promise:add({5, 5})
%%     	Node1 -->> Node2: Call.5
%%     	rect RGB(230, 230, 230)
%%     	note over Node2,Bridged_Node1: BRIDGE RELAY CONNECTION
%%       Node2 -->> Bridged_Node1:CALL.5
%%     	end
%%     	Bridged_Node1 -->> Bridged_Node2: CALL.5
%%     	note over Bridged_Node2: CALLEE4 seq = 100
%%     	Bridged_Node2 ->> CALLEE4: INVOCATION.100
%%     	CALLEE4 ->> Bridged_Node2: YIELD.100
%%     	Bridged_Node2 -->> Bridged_Node2: bondy_rpc_promise:take({invocation, 100, 5})
%%     	Bridged_Node2 -->> Bridged_Node1: RESULT.5
%%     	Bridged_Node1 -->> Node2: RESULT.5
%%     	Node2 -->> Node1: RESULT.5
%%     	Node1 ->> Node1: bondy_rpc_promise:take({call, 5})
%%     	Node1 ->> CALLER: RESULT.5
%% </code></pre>
%%
%% == Remote Procedure Call Ordering ==
%%
%% Regarding *Remote Procedure Calls*, the ordering guarantees are as
%% follows:
%%
%% If _Callee A_ has registered endpoints for both *Procedure 1* and
%% *Procedure 2*, and _Caller B_ first issues a *Call 1* to *Procedure
%% 1* and then a *Call 2* to *Procedure 2*, and both calls are routed to
%% _Callee A_, then _Callee A_ will first receive an invocation
%% corresponding to *Call 1* and then *Call 2*. This also holds if
%% *Procedure 1* and *Procedure 2* are identical.
%%
%% In other words, WAMP guarantees ordering of invocations between any
%% given _pair_ of _Caller_ and _Callee_. The current implementation
%% relies on Distributed Erlang which guarantees message ordering betweeen
%% processes in different nodes.
%%
%% There are no guarantees on the order of call results and errors in
%% relation to _different_ calls, since the execution of calls upon
%% different invocations of endpoints in _Callees_ are running
%% independently.  A first call might require an expensive, long-running
%% computation, whereas a second, subsequent call might finish
%% immediately.
%%
%% Further, if _Callee A_ registers for *Procedure 1*, the "REGISTERED"
%% message will be sent by _Dealer_ to _Callee A_ before any
%% "INVOCATION" message for *Procedure 1*.
%%
%% There is no guarantee regarding the order of return for multiple
%% subsequent register requests.  A register request might require the
%% _Dealer_ to do a time-consuming lookup in some database, whereas
%% another register request second might be permissible immediately.
%% @end
%% =============================================================================
-module(bondy_dealer).

-include_lib("kernel/include/logger.hrl").
-include_lib("wamp/include/wamp.hrl").
-include("bondy.hrl").


-define(RESERVED_NS(NS),
    <<"Use of reserved namespace '", NS/binary, "'.">>
).

-define(GET_REALM_URI(Map),
    case maps:find(realm_uri, Map) of
        {ok, Val} -> Val;
        error -> error(no_realm)
    end
).

-type invoke_opts() :: #{
    error_formatter :=
        optional(fun((Reason :: any()) -> optional(wamp_error()))),
    call_opts       := map()
}.

%% API
-export([callees/1]).
-export([callees/2]).
-export([callees/3]).
-export([features/0]).
-export([flush/2]).
-export([forward/2]).
-export([forward/3]).
-export([is_feature_enabled/1]).
-export([match_registrations/2]).
-export([register/3]).
-export([register/4]).
-export([registrations/1]).
-export([registrations/2]).
-export([registrations/3]).
-export([unregister/1]).
-export([unregister/2]).

-compile({no_auto_import, [register/2]}).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec features() -> map().

features() ->
    ?DEALER_FEATURES.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec is_feature_enabled(binary()) -> boolean().

is_feature_enabled(F) when is_binary(F) ->
    maps:get(F, ?DEALER_FEATURES, false).


%% -----------------------------------------------------------------------------
%% @doc Removes all registrations and all the pending items in the RPC promise
%% queue that are associated for reference `Ref' in realm `RealmUri'.
%% @end
%% -----------------------------------------------------------------------------
-spec flush(RealmUri :: uri(), Ref :: bondy_ref:t()) -> ok.

flush(RealmUri, Ref) ->
    try
        %% TODO If registration is deleted we need to also call on_delete/1
        %% Cleanup all registrations for the ref's session
        SessionId = bondy_ref:session_id(Ref),
        bondy_registry:remove_all(
            registration, RealmUri, SessionId, fun on_unregister/1
        ),

        %% Cleanup all RPC queued invocations for Ref
        ok = bondy_rpc_promise:flush(RealmUri, Ref)

    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(#{
                description => "Error while flushing registration and RPC promise queue items",
                class => Class,
                reason => Reason,
                trace => Stacktrace,
                realm_uri => RealmUri,
                ref => Ref
            }),
            ok
    end.


%% -----------------------------------------------------------------------------
%% @doc Creates a local registration.
%% If the registration is done using a callback module, only the invoke single
%% strategy can be used (i.e. shared_registration and sharded_registration are
%% also disabled). Also the callback module needs to conform to the
%% wamp_api_callback behaviour, otherwise the call fails with a badarg
%% exception.
%% @end
%% -----------------------------------------------------------------------------
-spec register(Procedure :: uri(), Opts :: map(), Ref :: bondy_context:t()) ->
    {ok, id()}
    | {error, already_exists | any()}
    | no_return().

register(Procedure, Opts, Ctxt) when is_map(Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    Ref = bondy_context:ref(Ctxt),

    register(Procedure, Opts, RealmUri, Ref).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec register(
    Procedure :: uri(),
    Opts :: map(),
    RealmUri :: uri(),
    Ref :: bondy_ref:t() | bondy_context:t()) ->
    {ok, id()}
    | {error, already_exists | any()}
    | no_return().

register(Procedure, Opts0, RealmUri, Ref) ->

    Opts =
        case bondy_ref:target_type(Ref) of
            pid ->
                Opts0#{shared_registration => true};

            name ->
                Opts0#{shared_registration => true};

            callback ->
                Opts0#{shared_registration => false}
        end,

    case bondy_registry:add(registration, Procedure, Opts, RealmUri, Ref) of
        {ok, Entry, _} ->
            {ok, bondy_registry_entry:id(Entry)};

        {error, {already_exists, _}} ->
            {error, already_exists}
    end.


%% -----------------------------------------------------------------------------
%% @doc For internal Bondy use.
%% Terminates the process identified by Pid by
%% bondy_subscribers_sup:terminate_subscriber/1
%% @end
%% -----------------------------------------------------------------------------
-spec unregister(pid()) -> ok | {error, not_found}.

unregister(Callee) when is_integer(Callee) ->
    error(not_implemented);

unregister(Callee) when is_pid(Callee) ->
    error(not_implemented).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unregister(RegId :: id(), bondy_context:t() | uri()) ->
    ok | {error, not_found}.

unregister(RegId, Ctxt) when is_map(Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    unregister(RegId, RealmUri);

unregister(RegId, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),

    case bondy_registry:lookup(registration, RegId, RealmUri) of
        {error, not_found} = Error ->
            Error;
        Entry ->
            case bondy_registry:remove(Entry) of
                ok ->
                    on_unregister(Entry);
                {ok, false} ->
                    on_unregister(Entry);
                {ok, true} ->
                    on_delete(Entry);
                Error ->
                    Error
            end
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec callees(RealmUri :: uri()) -> [map()] | no_return().

callees(RealmUri) ->
    %% TODO paginate and groupBy sessionID, so that we call
    %% bondy_session_id:to_external only once per session.
    case bondy_registry:entries(registration, RealmUri, '_') of
        [] ->
            [];
        List ->
            Set = lists:foldl(
                fun(E, Acc) ->
                    Ref = bondy_registry_entry:ref(E),
                    SessionId = bondy_registry_entry:session_id(E),
                    ExtId = bondy_session_id:to_external(SessionId),
                    M = #{
                        node => bondy_ref:nodestring(Ref),
                        session_id => ExtId
                    },
                    sets:add_element(M, Acc)
                end,
                sets:new(),
                List
            ),
            sets:to_list(Set)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec callees(RealmUri :: uri(), ProcedureUri :: uri()) ->
    [map()] | no_return().

callees(RealmUri, ProcedureUri) ->
    callees(RealmUri, ProcedureUri, #{}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec callees(RealmUri :: uri(), ProcedureUri :: uri(), Opts :: map()) ->
    [map()] | no_return().

callees(RealmUri, ProcedureUri, Opts) ->
    %% TODO paginate and groupBy sessionID, so that we call
    %% bondy_session_id:to_external only once per session.

    case bondy_registry:match(registration, ProcedureUri, RealmUri, Opts) of
        '$end_of_table' ->
            [];
        {List, Cont} ->
            Set = lists:foldl(
                fun(E, Acc) ->
                    Ref = bondy_registry_entry:ref(E),
                    SessionId = bondy_registry_entry:session_id(E),
                    ExtId = bondy_session_id:to_external(SessionId),
                    M = #{
                        node => bondy_ref:nodestring(Ref),
                        session_id => ExtId
                    },
                    sets:add_element(M, Acc)
                end,
                sets:new(),
                List
            ),
            Res = sets:to_list(Set),

            case Cont of
                '$end_of_table' ->
                    Res;
                _Cont ->
                    %% TODO
                    Res
            end

    end.


%% -----------------------------------------------------------------------------
%% @doc
%% This function is called by {@link bondy_router} to handle inbound messages
%% sentt by WAMP peers connected to this Bondy node.
%% @end
%% -----------------------------------------------------------------------------
-spec forward(M :: wamp_message(), Ctxt :: map()) -> ok | no_return().

forward(M, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),

    try

        do_forward(M, Ctxt)

    catch
        _:{not_authorized, Reason} ->
            Reply = wamp_message:error_from(
                M,
                #{},
                ?WAMP_NOT_AUTHORIZED,
                [Reason],
                #{message => Reason}
            ),
            bondy:send(RealmUri, bondy_context:ref(Ctxt), Reply);

        throw:not_found ->
            Reply = not_found_error(M, Ctxt),
            bondy:send(RealmUri, bondy_context:ref(Ctxt), Reply)
    end.


%% -----------------------------------------------------------------------------
%% @doc Handles inbound messages received from a relay i.e. a cluster peer node
%% or bridge_relay i.e. edge client or server.
%% @end
%% -----------------------------------------------------------------------------
-spec forward(wamp_message(), To :: bondy_ref:t(), Opts :: map()) ->
    ok | no_return().

forward(#call{} = Msg, Callee, #{from := Caller} = Opts) ->
    %% A remote Caller is making a CALL to a local Callee or local bridged
    %% Callee.
    true == bondy_ref:is_local(Callee)
        orelse error({forwarding_error, callback_no_local}),

    %% Fails with no_realm exception if not present
    RealmUri = ?GET_REALM_URI(Opts),
    CalleeType = bondy_ref:type(Callee),


    case bondy_ref:target_type(Callee) of
        callback ->
            %% A callback implemented procedure e.g. WAMP Session APIs.
            %% We apply here as we do not need invoke/5 to
            %% enqueue a promise, we will call the module sequentially.

            %% CALL already has the static arguments appended
            %% to its positional args (see call_to_invocation/4) so we use
            %% apply_dynamic_callback/3.
            Response = apply_dynamic_callback(Msg, Callee),

            {To, SendOpts0} = bondy:prepare_send(Caller, Opts),
            SendOpts = SendOpts0#{from => Callee},

            bondy:send(RealmUri, To, Response, SendOpts);

        _  when CalleeType == bridge_relay ->
            %% We need to send the CALL to the bridge relay,
            %% no need for a call promise here as there is one on the Caller's
            %% node.
            {To, SendOpts} = bondy:prepare_send(Callee, Opts),
            bondy:send(RealmUri, To, Msg, SendOpts);

        _  when CalleeType == client ->
            %% We now turn the CALL into an INVOCATION.
            {To, SendOpts} = bondy:prepare_send(Callee, Opts),

            CalleeSessionId = bondy_ref:session_id(Callee),
            InvocationId = bondy_session:gen_message_id(CalleeSessionId),
            Timeout = bondy_utils:timeout(Opts),

            Invocation = call_to_invocation(Msg, InvocationId),

            %% If we are handling this here is because any remaining relays
            %% in the 'via' stack are part of the route back to the Caller.
            Via = maps:get(via, SendOpts, undefined),

            %% We enqueue an invocation promise so that we can match it
            %% with the future YIELD or ERROR response from the Callee.
            %% We add the via stack so that we can route back the YIELD or
            %% ERROR response to Caller.
            %% Notice that this is a second promise for the associated CALL.
            %% The first one was enqueued at the origin node and it is used
            %% to trigger a timeout to the caller or match the RESULT |
            %% ERROR that this second promise will match in this node,
            %% which is the one connected to the Callee (or a Bridge Relay
            %% to a node that is connected to the Callee).
            CallId = key_value:get(
                ['$private', call_id], Msg#call.options, undefined
            ),
            Procedure = maps:get(
                procedure, Msg#call.options, undefined
            ),

            PromiseOpts = #{
                procedure => Procedure,
                via => Via,
                timeout => Timeout
            },

            Promise = bondy_rpc_promise:new_invocation(
                RealmUri,
                Caller, CallId,
                Callee, InvocationId,
                PromiseOpts
            ),

            ok = bondy_rpc_promise:add(Promise),

            %% We send the invocation to the local callee
            %% (no use of via here)
            bondy:send(RealmUri, To, Invocation, SendOpts)
    end;

forward(#cancel{} = M, Callee, #{from := Caller} = Opts) ->
    %% A remote Caller is cancelling a previous CALL made to a local Callee.

    %% Fails with no_realm exception if not present
    RealmUri = ?GET_REALM_URI(Opts),

    InvocationId = M#interrupt.request_id,

    Key = bondy_rpc_promise:invocation_key_pattern(
        RealmUri,
        Caller, '_',
        Callee, InvocationId
    ),

    case bondy_rpc_promise:take(Key) of
        {ok, _Promise} ->
            bondy:send(RealmUri, Callee, M, #{from => Caller});

        error ->
            %% The promise already expired the Caller would have already
            %% received a TIMEOUT error as a response for the original CALL.
            no_matching_promise(M)
    end;

forward(#result{} = M, Caller, #{from := _Callee} = Opts) ->
    %% A remote Callee is returning a RESULT to CALL done on behalf of a
    %% local Caller.

    %% Fails with no_realm exception if not present
    RealmUri = ?GET_REALM_URI(Opts),

    CallId = M#result.request_id,

    Key = bondy_rpc_promise:call_key_pattern(RealmUri, Caller, CallId),

    case bondy_rpc_promise:take(Key) of
        {ok, _Promise} ->
            %% Even if promise has timeout but bondy_rpc_promise_manager has
            %% not evicted it yet.
            bondy:send(RealmUri, Caller, M);

        error ->
            no_matching_promise(M)
    end;

forward(#error{request_type = ?CALL} = M, Caller, Opts) ->
    %% A remote callee is returning an ERROR to an CALL done
    %% on behalf of a local Caller.

    %% Fails with no_realm exception if not present
    RealmUri = ?GET_REALM_URI(Opts),

    CallId = M#error.request_id,

    Key = bondy_rpc_promise:call_key_pattern(RealmUri, Caller, CallId),

    Status = case M#error.error_uri of
        ?WAMP_TIMEOUT ->
            %% This is a peer node's promise manager timeout error produced
            %% while matching an expired invocation promise, so we want to
            %% match the local promise even if it is timeout to
            %% prevent the local promise manager to generate another one based
            %% on the call promise.
            expired;
        _ ->
            active
    end,

    case bondy_rpc_promise:take(Key, Status) of
        {ok, _Promise} ->
            bondy:send(RealmUri, Caller, M, #{});

        error ->
            %% The promise timed out already and local promise manager evicted
            %% it sending the timeout error message to caller
            no_matching_promise(M)
    end;

forward(#error{request_type = ?CANCEL} = M, Caller, Opts) ->
    %% A CANCEL a local Caller made to a remote Callee has failed.
    %% We send the error back to the local Caller, keeping the promise to be
    %% able to match the still pending YIELD message,

    %% Fails with no_realm exception if not present
    RealmUri = ?GET_REALM_URI(Opts),

    CallId = M#error.request_id,

    Key = bondy_rpc_promise:call_key_pattern(RealmUri, Caller, CallId),

    case bondy_rpc_promise:find(Key) of
        {ok, _Promise} ->
            %% Even if promise has timeout but bondy_rpc_promise_manager has
            %% not evicted it yet.
            bondy:send(RealmUri, Caller, M, #{});
        error ->
            %% The promise already expired the Caller would have already
            %% received a TIMEOUT error as a response for the original CALL.
            no_matching_promise(M)
    end.



%% =============================================================================
%% PRIVATE
%% =============================================================================




% maybe_reassign_invocation(
%     #invocation{} = Msg, To, #{realm_uri := RealmUri} = Opts) ->
%     %% TODO https://www.notion.so/leapsight/Call-Re-Routing-c18901c7aaea4ef7896b993d4e5d307f

%     %% We need to find another local callee to satisfy the original call,
%     %% if it exists, then it is easy. But the reply might need to include the %% original Callee ref.
%     %% If there are no local callees then we need to return either
%     %% wamp.error.unavailable or wamp.error.no_eligible_callee and let the
%     %% origin router re-route.

%     Error = no_eligible_callee(
%         invocation, Msg#invocation.registration_id
%     ),
%     bondy:send(RealmUri, To, Error, Opts).


%% -----------------------------------------------------------------------------
%% @private
%% @doc We handle messages from our local clients.
%% @end
%% -----------------------------------------------------------------------------
-spec do_forward(M :: wamp_message(), Ctxt :: map()) -> ok | no_return().

do_forward(#register{} = M, Ctxt) ->
    %% A local Callee
    handle_register(M, Ctxt);

do_forward(#unregister{} = M, Ctxt) ->
    %% A local Callee
    handle_unregister(M, Ctxt);

do_forward(#call{procedure_uri = Uri} = M, Ctxt) ->
    %% A local Caller.
    ok = bondy_rbac:authorize(<<"wamp.call">>, Uri, Ctxt),

    %% We need to determined whether the procedure is implemented by a static
    %% callback.
    case Uri of
        <<"bondy.", _/binary>> ->
            apply_static_callback(M, Ctxt, bondy_wamp_api);

        <<"com.bondy.", _/binary>> ->
            %% Alias for "bondy"
            apply_static_callback(M, Ctxt, bondy_wamp_api);

        <<"com.leapsight.bondy.", _/binary>> ->
            %% Deprecated API prefix. Now "bondy"
            apply_static_callback(M, Ctxt, bondy_wamp_api);

        <<"wamp.", _/binary>> ->
            apply_static_callback(M, Ctxt, bondy_wamp_meta_api);

        _ ->
            Opts = #{error_formatter => undefined},
            handle_call(M, Ctxt, Uri, Opts)
    end;

do_forward(#cancel{} = M, Ctxt0) ->
    %% A local Caller is cancelling a previous call.
    %% A response will be send asynchronously by another router process
    %% instance.

    %% If the callee does not support call canceling, then behavior is 'skip'.
    %% We should check callee but that means we need to broadcast sessions.
    %% Another option is to pay the price and ask bondy to fail on the
    %% remote node after checking the callee does not support it.
    %% The caller is not affected, only in the kill case will receive an
    %% error later in the case of a remote callee.
    handle_cancel(M, Ctxt0, maps:get(mode, M#cancel.options, skip));

do_forward(#yield{} = M, Ctxt0) ->
    %% A local Callee is replying to an INVOCATION message.
    %% We match the YIELD with the original INVOCATION using the request_id,
    %% and with that retrieve the CALL request_id to find the Caller.

    RealmUri = bondy_context:realm_uri(Ctxt0),
    Callee = bondy_context:ref(Ctxt0),
    InvocationId = M#yield.request_id,
    Key = bondy_rpc_promise:invocation_key_pattern(
        RealmUri,
        '_', '_',
        Callee, InvocationId
    ),

    case bondy_rpc_promise:take(Key) of
        {ok, Promise} ->
            %% Caller can be local or remote.
            Caller = bondy_rpc_promise:caller(Promise),
            CallId = bondy_rpc_promise:call_id(Promise),

            %% Via might be undefined or might have been set when handling the
            %% INVOCATION in forward/3 and provides the route back to
            %% the Caller i.e. a pipe of relays.
            Via = bondy_rpc_promise:via(Promise),
            SendOpts0 = #{from => Callee, via => Via},
            {To, SendOpts} = bondy:prepare_send(Caller, SendOpts0),

            %% If Caller is remote the RESULT will be forwarded through relays
            %% and potentially bridge relays till the Caller. When RESULT
            %% arrives at the node where the Caller is connected we will match
            %% a call_promise.
            %% If Caller is local, then we are done (as we only created one
            %% promise).
            Result = wamp_message:result(
                CallId,
                %% TODO check if yield.options should be assigned to result.details
                M#yield.options,
                M#yield.args,
                M#yield.kwargs
            ),

            bondy:send(RealmUri, To, Result, SendOpts);

        error ->
            no_matching_promise(M)
    end,

    ok;

do_forward(#error{request_type = Type} = M, Ctxt0)
when Type == ?INVOCATION orelse Type == ?INTERRUPT ->
    %% A local Callee is replying to a previous INVOCATION | INTERRUPT.
    %% We match the ERROR with the original INVOCATION
    %% using the request_id, and with that match the CALL request_id
    %% to find the Caller.
    RealmUri = bondy_context:realm_uri(Ctxt0),
    Callee = bondy_context:ref(Ctxt0),
    InvocationId = M#error.request_id,
    Key = bondy_rpc_promise:invocation_key_pattern(
        RealmUri,
        '_', '_',
        Callee, InvocationId
    ),

    %% We determine the operation and response error type depending on
    %% incoming type
    {NewType, Result} = case Type of
        ?INVOCATION ->
            {?CALL, bondy_rpc_promise:take(Key)};

        ?INTERRUPT ->
            %% If the INTERRUPT failed, then the Callee might still reply to
            %% the call, so we do not take it.
            {?CANCEL, bondy_rpc_promise:find(Key)}
    end,

    case Result of
        {ok, Promise} ->
            CallId = bondy_rpc_promise:call_id(Promise),
            %% Caller can be local or remote.
            Caller = bondy_rpc_promise:caller(Promise),
            %% Via might be undefined.
            Via = bondy_rpc_promise:via(Promise),
            SendOpts0 = #{from => Callee, via => Via},
            {To, SendOpts} = bondy:prepare_send(Caller, SendOpts0),

            Error = M#error{request_id = CallId, request_type = NewType},
            bondy:send(RealmUri, To, Error, SendOpts);

        error ->
            no_matching_promise(M)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc If the callback module returns other than `ok' or `reply' we need to
%% find the callee in the registry.
%% @end
%% -----------------------------------------------------------------------------
apply_static_callback(#call{} = M0, Ctxt, Mod) ->
    %% Caller is always local.
    Caller = bondy_context:ref(Ctxt),
    DefaultOpts = #{error_formatter => undefined},
    RealmUri = bondy_context:realm_uri(Ctxt),

    try Mod:handle_call(M0, Ctxt) of
        ok ->
            ok;
        continue ->
            handle_call(M0, Ctxt, M0#call.procedure_uri, DefaultOpts);

        {continue, #call{} = M1}  ->
            handle_call(M1, Ctxt, M1#call.procedure_uri, DefaultOpts);

        {continue, #call{} = M1, Fun}  ->
            Opts = DefaultOpts#{error_formatter => Fun},
            handle_call(M1, Ctxt, M1#call.procedure_uri, Opts);

        {continue, Uri} when is_binary(Uri) ->
            handle_call(M0, Ctxt, Uri, DefaultOpts);

        {continue, Uri, Fun} when is_binary(Uri) ->
            Opts = DefaultOpts#{error_formatter => Fun},
            handle_call(M0, Ctxt, Uri, Opts);

        {reply, Reply} ->
            bondy:send(RealmUri, Caller, Reply)

    catch
        throw:no_such_procedure ->
            Error = bondy_wamp_utils:no_such_procedure_error(M0),
            bondy:send(RealmUri, Caller, Error);

        Class:Reason:Stacktrace ->
            ?LOG_WARNING(#{
                description => <<"Error while handling WAMP call">>,
                procedure => M0#call.procedure_uri,
                caller => Caller,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            %% We catch any exception from handle/3 and turn it
            %% into a WAMP Error
            Error = bondy_wamp_utils:maybe_error({error, Reason}, M0),
            bondy:send(RealmUri, Caller, Error)
    end.


%% @private
-spec apply_dynamic_callback(wamp_call(), bondy_ref:t()) ->
    wamp_result() | wamp_error().

apply_dynamic_callback(#call{} = Msg, Callee) ->
    apply_dynamic_callback(Msg, Callee, []).


%% @private
-spec apply_dynamic_callback(wamp_call(), bondy_ref:t(), [any()]) ->
    wamp_result() | wamp_error().

apply_dynamic_callback(#call{} = Msg, Callee, CBArgs) ->
    CallId = Msg#call.request_id,

    A = lists:append([
        args_to_list(CBArgs),
        args_to_list(Msg#call.args),
        args_to_list(Msg#call.kwargs),
        args_to_list(Msg#call.options)
    ]),

    {M, F} = bondy_ref:callback(Callee),

    try erlang:apply(M, F, A) of
        {ok, Details, Args, KWArgs} ->
            wamp_message:result(
                CallId,
                Details,
                Args,
                KWArgs
            );

        {error, Uri, Details, Args, KWArgs} ->
            wamp_message:error(
                ?CALL,
                CallId,
                Details,
                Uri,
                Args,
                KWArgs
            );

        Other ->
            error({invalid_return, Other})
    catch
        error:undef ->
            badarity_error(CallId, ?CALL);

        error:{badarg, _} ->
            badarg_error(CallId, ?CALL)
    end.


%% @private
args_to_list(undefined) ->
    [];

args_to_list(L) when is_list(L) ->
    L;

args_to_list(M) when is_map(M) ->
    [M].


%% @private
-spec format_error(any(), map()) -> optional(wamp_error()).

format_error(_, undefined) ->
    undefined;

format_error(_, #{error_formatter := undefined}) ->
    undefined;

format_error(Error, #{error_formatter := Fun}) ->
    Fun(Error).


%% -----------------------------------------------------------------------------
%% @private
%% @doc A local Caller is cancelling a previous CALL.
%% @end
%% -----------------------------------------------------------------------------
handle_cancel(#cancel{} = M, Ctxt0, kill) ->
    %% INTERRUPT is sent to the callee, but ERROR is not returned
    %% to the caller until the callee has responded to INTERRUPT with
    %% ERROR. In this case, the caller may receive RESULT or
    %% another ERROR if the callee finishes processing the
    %% INVOCATION first.
    %% We thus read the promise instead of taking it.
    RealmUri = bondy_context:realm_uri(Ctxt0),
    CallId = M#cancel.request_id,
    Caller = bondy_context:ref(Ctxt0),
    Opts = #cancel.options,

    Fun = fun(Promise, Ctxt1) ->
        %% If not authoried this will fail with an exception
        Uri = bondy_rpc_promise:procedure_uri(Promise),
        ok = bondy_rbac:authorize(<<"wamp.cancel">>, Uri, Ctxt1),

        InvocationId = bondy_rpc_promise:invocation_id(Promise),
        Callee = bondy_rpc_promise:callee(Promise),

        %% Via might be undefined
        Via = bondy_rpc_promise:via(Promise),
        SendOpts0 = #{from => Caller, via => Via},
        {To, SendOpts} = bondy:prepare_send(Callee, SendOpts0),

        R = wamp_message:interrupt(InvocationId, Opts),
        ok = bondy:send(RealmUri, To, R, SendOpts),

        {ok, Ctxt1}
    end,

    _ = find_invocations(CallId, Fun, Ctxt0),
    ok;

handle_cancel(#cancel{} = M, Ctxt0, killnowait) ->
    %% The pending call is canceled and ERROR is send immediately
    %% back to the caller. INTERRUPT is sent to the callee and any
    %% response to the invocation or interrupt from the callee is
    %% discarded when received.
    %% We take the invocation, that way the response will be
    %% discarded.
    RealmUri = bondy_context:realm_uri(Ctxt0),
    CallId = M#cancel.request_id,
    Caller = bondy_context:ref(Ctxt0),
    Opts = #cancel.options,

    Fun = fun(Promise, Ctxt1) ->
        %% If not authoried this will fail with an exception
        Uri = bondy_rpc_promise:procedure_uri(Promise),
        ok = bondy_rbac:authorize(<<"wamp.cancel">>, Uri, Ctxt1),

        InvocationId = bondy_rpc_promise:invocation_id(Promise),
        Callee = bondy_rpc_promise:callee(Promise),

        Error = wamp_message:error(
            ?CALL,
            CallId,
            #{},
            ?WAMP_CANCELLED,
            [<<"call_cancelled">>],
            #{
                description => <<"The call was cancelled by the user.">>
            }
        ),

        %% We know the caller is local
        ok = bondy:send(RealmUri, Caller, Error, #{}),

        %% But Callee might be remote
        Interrupt = wamp_message:interrupt(InvocationId, Opts),
        Via = bondy_rpc_promise:via(Promise),
        SendOpts0 = #{from => Caller, via => Via},
        {To, SendOpts} = bondy:prepare_send(Callee, SendOpts0),

        ok = bondy:send(RealmUri, To, Interrupt, SendOpts),

        {ok, Ctxt1}
    end,
    _ = take_invocations(CallId, M, Fun, Ctxt0),
    ok;

handle_cancel(#cancel{} = M, Ctxt0, skip) ->
    %% The pending call is canceled and ERROR is sent immediately
    %% back to the caller. No INTERRUPT is sent to the callee and
    %% the result is discarded when received.
    %% We dequeue the invocation, that way the response will be
    %% discarded.
    %% TODO instead of dequeing, update the entry to reflect it was
    %% cancelled
    CallId = M#cancel.request_id,
    Caller = bondy_context:ref(Ctxt0),

    Fun = fun(Promise, Ctxt1) ->
        %% If not authoried this will fail with an exception
        Uri = bondy_rpc_promise:procedure_uri(Promise),
        ok = bondy_rbac:authorize(<<"wamp.cancel">>, Uri, Ctxt1),

        Error = wamp_message:error(
            ?CANCEL,
            CallId,
            #{},
            ?WAMP_CANCELLED,
            [<<"call_cancelled">>],
            #{
                description => <<"The call was cancelled by the user.">>
            }
        ),

        RealmUri = bondy_context:realm_uri(Ctxt1),
        ok = bondy:send(RealmUri, Caller, Error, #{}),

        {ok, Ctxt1}
    end,

    _ = take_invocations(CallId, M, Fun, Ctxt0),

    ok.


%% -----------------------------------------------------------------------------
%% @doc
%% Registers an RPC endpoint.
%% If the registration already exists, it fails with a
%% `{not_authorized | procedure_already_exists, binary()}' reason.
%% @end
%% -----------------------------------------------------------------------------
handle_register(#register{procedure_uri = Uri} = M, Ctxt) ->
    ok = maybe_reserved_ns(Uri),
    ok = bondy_rbac:authorize(<<"wamp.register">>, Uri, Ctxt),

    #register{options = Opts0, request_id = ReqId} = M,

    %% We add an option used by bondy_registry
    Val = bondy_context:is_feature_enabled(Ctxt, callee, shared_registration),
    Opts = Opts0#{shared_registration => Val},

    RealmUri = bondy_context:realm_uri(Ctxt),
    Ref = bondy_context:ref(Ctxt),

    case bondy_registry:add(registration, Uri, Opts, RealmUri, Ref) of
        {ok, Entry, IsFirst} ->
            ok = on_register(IsFirst, Entry),
            Id = bondy_registry_entry:id(Entry),
            Reply = wamp_message:registered(ReqId, Id),
            bondy:send(RealmUri, Ref, Reply);

        {error, {already_exists, Entry}} ->
            Policy = bondy_registry_entry:match_policy(Entry),
            Msg = <<
                "The procedure is already registered by another peer ",
                "with policy ", $', Policy/binary, $', $.
            >>,
            Reply = wamp_message:error(
                ?REGISTER,
                ReqId,
                #{},
                ?WAMP_PROCEDURE_ALREADY_EXISTS,
                [Msg]
            ),
            bondy:send(RealmUri, Ref, Reply)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Unregisters an RPC endpoint.
%% If the registration does not exist, it fails with a 'no_such_registration' or
%% '{not_authorized, binary()}' error.
%% @end
%% -----------------------------------------------------------------------------
-spec handle_unregister(wamp_unregister(), bondy_context:t()) ->
    ok | no_return().

handle_unregister(#unregister{} = M, Ctxt) ->
    RegId = M#unregister.registration_id,
    RealmUri = bondy_context:realm_uri(Ctxt),

    %% TODO Shouldn't we restrict this operation to the peer who registered it?
    %% and/or a Bondy Admin for revoke registration?
    case bondy_registry:lookup(registration, RegId, RealmUri) of
        {error, not_found} ->
            throw(not_found);

        Entry ->
            Uri = bondy_registry_entry:uri(Entry),
            %% We authorize first
            ok = bondy_rbac:authorize(<<"wamp.unregister">>, Uri, Ctxt),
            unregister(Uri, M, Ctxt)
    end.


%% @private
unregister(Uri, M, Ctxt) ->
    ok = maybe_reserved_ns(Uri),
    RealmUri = bondy_context:realm_uri(Ctxt),

    ok = bondy_rbac:authorize(<<"wamp.unregister">>, Uri, Ctxt),

    ok = bondy_registry:remove(
        registration, M#unregister.registration_id, Ctxt, fun on_unregister/1
    ),

    Reply = wamp_message:unregistered(M#unregister.request_id),

    bondy:send(RealmUri, bondy_context:ref(Ctxt), Reply).


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
    }
    | bondy_registry:eot().

registrations(?EOT) ->
    ?EOT;

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
-spec registrations(
    RealmUri :: uri(), SessionId :: bondy_session_id:t() | '_') ->
    [bondy_registry_entry:t()].

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
-spec registrations(
    RealmUri :: uri(),
    SessionId :: bondy_session_id:t() | '_',
    Limit :: non_neg_integer()) ->
    {[bondy_registry_entry:t()], bondy_registry_entry:continuation_or_eot()}
    | bondy_registry_entry:eot().

registrations(RealmUri, SessionId, Limit) ->
    bondy_registry:entries(registration, RealmUri, SessionId, Limit).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_registrations(uri(), bondy_context:t()) ->
    {
        [bondy_registry_entry:t()],
        bondy_registry:continuation() | bondy_registry:eot()
    }.

match_registrations(ProcUri, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    bondy_registry:match(registration, ProcUri, RealmUri).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_registrations(uri(), bondy_context:t(), map()) ->
    {
        [bondy_registry_entry:t()],
        bondy_registry:continuation() | bondy_registry:eot()
    }.

match_registrations(ProcUri, Ctxt, Opts) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    bondy_registry:match(registration, ProcUri, RealmUri, Opts).


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


%% @private
-spec reply_error(wamp_error(), bondy_context:t()) -> ok.

reply_error(Error, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    bondy:send(RealmUri, bondy_context:ref(Ctxt), Error).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec take_invocations(
    id(), wamp_message(), function(), bondy_context:t()) ->
    {ok, bondy_context:t()}.

take_invocations(CallId, M, Fun, Ctxt) when is_function(Fun, 2) ->
    Caller = bondy_context:ref(Ctxt),
    RealmUri = bondy_context:realm_uri(Ctxt),
    Key = bondy_rpc_promise:invocation_key_pattern(
        RealmUri,
        Caller, CallId,
        '_', '_'
    ),

    case bondy_rpc_promise:take(Key) of
        {ok, Promise} ->
            {ok, Ctxt1} = Fun(Promise, Ctxt),
            %% We iterate until there are no more pending invocation for the
            %% call_request_id == CallId
            take_invocations(CallId, M, Fun, Ctxt1);
        error ->
            %% Promises for this call were either interrupted by us,
            %% fulfilled or timed out and evicted
            ok = no_matching_promise(M),
            {ok, Ctxt}
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec find_invocations(
    id(),
    fun((bondy_rpc_promise:t(), bondy_context:t()) -> {ok, bondy_context:t()}),
    bondy_context:t()) -> {ok, bondy_context:t()}.

find_invocations(CallId, Fun, Ctxt) when is_function(Fun, 2) ->
    Caller = bondy_context:ref(Ctxt),
    RealmUri = bondy_context:realm_uri(Ctxt),
    Key = bondy_rpc_promise:invocation_key_pattern(
        RealmUri,
        Caller, CallId,
        '_', '_'
    ),

    case bondy_rpc_promise:find(Key) of
        {ok, Promise} ->
            {ok, Ctxt1} = Fun(Promise, Ctxt),
            %% We iterate until there are no more pending invocation for the
            %% call_request_id == CallId
            find_invocations(CallId, Fun, Ctxt1);
        error ->
            {ok, Ctxt}
    end.


%% @private
no_matching_promise(M) ->
    %% Promise was fulfilled or timed out and evicted. We do nothing.
    ?LOG_DEBUG(#{
        description => "Message ignored",
        reason => no_matching_promise,
        message => M
    }),
    ok.



%% =============================================================================
%% PRIVATE - CALLS AND INVOCATION STRATEGIES (LOAD BALANCING, FAIL OVER, ETC)
%% =============================================================================



%% @private
handle_call(#call{} = Msg, Ctxt0, Uri, Opts0) ->
    RealmUri = bondy_context:realm_uri(Ctxt0),
    CallUri = Msg#call.procedure_uri,
    %% Extract caller here to avoid copying the entire Ctxt0 in Fun
    Caller = bondy_context:ref(Ctxt0),

    %% Based on procedure registration and passed options, we will
    %% determine how many invocations and to whom we should do.
    %% A response to the caller will be send asynchronously by handle_call
    %% using the following fun.
    Fun = fun
        (Entry, Ctxt) ->
            Callee = bondy_registry_entry:ref(Entry),
            CalleeType = bondy_ref:type(Callee),
            IsLocal = bondy_ref:is_local(Callee),

            case bondy_ref:target_type(Callee) of
                callback when IsLocal == true, CallUri == Uri ->
                    %% A callback implemented procedure e.g. WAMP Session APIs
                    %% on this node. We apply here as we do not need invoke/5 to
                    %% enqueue a promise, we will apply the callback
                    %% and respond sequentially.
                    CBArgs = bondy_registry_entry:callback_args(Entry),
                    Response = apply_dynamic_callback(Msg, Callee, CBArgs),

                    %% We reply to Caller
                    bondy:send(RealmUri, Caller, Response, #{from => Callee}),

                    %% We return no message as we already replied
                    {ok, Ctxt};

                _ when IsLocal == false orelse CalleeType == bridge_relay ->
                    %% We will forward the call to the cluster peer node or
                    %% bridged node where the Callee is located, so we need to
                    %% gather all local context and create a new Call. This new Call will include a '$private' field under 'options'.
                    Call = prepare_call(Msg, Uri, Entry, Ctxt),
                    {ok, Call, Ctxt};

                _ ->
                    %% A local Callee. We create an invocation.
                    Invocation = call_to_invocation(Msg, Uri, Entry, Ctxt),
                    {ok, Invocation, Ctxt}
            end
    end,

    Opts = Opts0#{call_opts => Msg#call.options},

    handle_call(Msg#call.request_id, Uri, Fun, Opts, Ctxt0).


%% -----------------------------------------------------------------------------
%% @private
%% @doc Used to handle calls from local callers only
%% Throws {not_authorized, binary()}
%% @end
%% -----------------------------------------------------------------------------
-spec handle_call(id(), uri(), function(), invoke_opts(), bondy_context:t()) ->
    ok.

handle_call(CallId, ProcUri, UserFun, Opts, Ctxt0)
when is_function(UserFun, 2) ->
    RealmUri = bondy_context:realm_uri(Ctxt0),

    case match_registrations(ProcUri, Ctxt0, #{}) of
        ?EOT ->
            Error = case format_error(no_such_procedure, Opts) of
                undefined ->
                    bondy_wamp_utils:no_such_procedure_error(
                        ProcUri, ?CALL, CallId
                    );
                Value ->
                    Value
            end,
            reply_error(Error, Ctxt0);
        Regs ->
            %% We invoke Fun for each entry
            Fun = fun
                ({error, ErrorMap}, Ctxt1) when is_map(ErrorMap) ->
                    Error = case format_error(no_such_procedure, Opts) of
                        undefined ->
                            error_from_map(ErrorMap, CallId);
                        Value ->
                            Value
                    end,
                    ok = reply_error(Error, Ctxt1),
                    {ok, Ctxt1};

                ({error, noproc}, Ctxt1) ->
                    %% The local process associated with the entry
                    %% is no longer alive, we turn this into no_such_procedure
                    Error = case format_error(no_such_procedure, Opts) of
                        undefined ->
                            bondy_wamp_utils:no_such_procedure_error(
                                ProcUri, ?CALL, CallId
                            );
                        Value ->
                            Value
                    end,

                    ok = reply_error(Error, Ctxt1),
                    {ok, Ctxt1};

                (Entry, Ctxt1) ->
                    %% We invoke the provided fun which returns a command.
                    case UserFun(Entry, Ctxt1) of
                        {ok, Ctxt2} ->
                            %% UserFun sent a response sequentially, no need
                            %% for promises. This is the case for callback
                            %% implemented procedures.
                            {ok, Ctxt2};


                        {ok, Msg, Ctxt2} ->
                            Caller = bondy_context:ref(Ctxt1),
                            Ref = bondy_registry_entry:ref(Entry),
                            Origin = bondy_registry_entry:origin_ref(Entry),

                            %% SendOpts might include 'via' field which we use
                            %% to build the promise
                            {Callee, SendOpts} = bondy:prepare_send(
                                Ref, Origin, Opts#{from => Caller}
                            ),

                            Timeout = bondy_utils:timeout(call_opts(SendOpts)),

                            PromiseOpts = #{
                                procedure_uri => ProcUri,
                                timeout => Timeout
                            },

                            Promise = case Msg of
                                #call{} ->
                                    %% The callee is on another node or bridged
                                    %% cluster so we forward the call.
                                    %% We will store a local call promise,
                                    %% to match the incoming forwarded RESULT |
                                    %% ERROR.
                                    %% The remote node will store an invocation
                                    %% promise.
                                    bondy_rpc_promise:new_call(
                                        RealmUri,
                                        Caller,
                                        CallId,
                                        PromiseOpts
                                    );

                                #invocation{request_id = InvocationId} ->
                                    %% The callee is local.
                                    %% We will store an invocation promise
                                    %% to match the incoming YIELD | ERROR.
                                    bondy_rpc_promise:new_invocation(
                                        RealmUri,
                                        Caller, CallId,
                                        Callee, InvocationId,
                                        PromiseOpts
                                    )
                            end,

                            ok = bondy_rpc_promise:add(Promise),

                            ok = bondy:send(RealmUri, Callee, Msg, SendOpts),

                            {ok, Ctxt2}
                    end
            end,
            handle_call_aux(Regs, Fun, Opts, Ctxt0)
    end.


%% @private
handle_call_aux(?EOT, _, _, _) ->
    ok;

handle_call_aux({L, ?EOT}, Fun, Opts, Ctxt) ->
    handle_call_aux(L, Fun, Opts, Ctxt);

handle_call_aux({L, Cont}, Fun, Opts, Ctxt) ->
    ok = handle_call_aux(L, Fun, Opts, Ctxt),
    handle_call_aux(match_registrations(Cont), Fun, Opts, Ctxt);

handle_call_aux(L, Fun, Opts, Ctxt) when is_list(L) ->
    %% Registrations have different invocation strategies provided by the
    %% 'invoke' key.
    Triples = [
        {
            bondy_registry_entry:uri(E),
            maps:get(invoke, bondy_registry_entry:options(E), ?INVOKE_SINGLE),
            E
        } || E <- L
    ],
    handle_call_aux(Triples, undefined, Fun, Opts, Ctxt).


%% @private
-spec handle_call_aux(
    [{uri(), Strategy :: binary(), Entry :: tuple()}],
    Last :: tuple() | undefined,
    Fun :: function(),
    Opts :: map(),
    Ctxt :: bondy_context:t()) ->
    ok.

handle_call_aux([], undefined, _, _, _) ->
    ok;

handle_call_aux([], {_, ?INVOKE_SINGLE, []}, _, _, _) ->
    ok;

handle_call_aux([], {_, Invoke, L}, Fun, Opts, Ctxt0) ->
    {ok, _Ctxt1} = do_call({Invoke, L}, Fun, Opts, Ctxt0),
    ok;

handle_call_aux([{Uri, ?INVOKE_SINGLE, E}|T], undefined, Fun, Opts, Ctxt0) ->
    {ok, Ctxt1} = do_call({?INVOKE_SINGLE, [E]}, Fun, Opts, Ctxt0),
    %% We add an accummulator to drop any subsequent matching Uris.
    handle_call_aux(T, {Uri, ?INVOKE_SINGLE, []}, Fun, Opts, Ctxt1);

handle_call_aux(
    [{Uri, ?INVOKE_SINGLE, _}|T], {Uri, ?INVOKE_SINGLE, _} = Last,
    Fun, Opts, Ctxt) ->
    %% A single invocation strategy and we have multiple registrations so we
    %% ignore them
    %% Invoke should match too, otherwise there is an inconsistency
    %% in the registry
    handle_call_aux(T, Last, Fun, Opts, Ctxt);

handle_call_aux([{Uri, Invoke, E}|T], undefined, Fun, Opts, Ctxt) ->
    %% We do not apply the invocation yet as it is not single, so we need
    %% to accummulate and apply at the end.
    %% We build a list for subsequent entries for same Uri.
    handle_call_aux(T, {Uri, Invoke, [E]}, Fun, Opts, Ctxt);

handle_call_aux([{Uri, Invoke, E}|T], {Uri, Invoke, L}, Fun, Opts, Ctxt)  ->
    %% We do not invoke yet as it is not single, so we need
    %% to accummulate and apply at the end using load balancing.
    %% We build a list for subsequent entries for same Uri.
    %% Invoke should match too, otherwise there is an inconsistency
    %% in the registry
    handle_call_aux(T, {Uri, Invoke, [E|L]}, Fun, Opts, Ctxt);

handle_call_aux([{Uri, ?INVOKE_SINGLE, E}|T], {_, Invoke, L}, Fun, Opts, Ctxt0) ->
    %% We found a different Uri so we invoke the previous one
    {ok, Ctxt1} = do_call({Invoke, L}, Fun, Opts, Ctxt0),
    %% The new one is a single so we also invoke and continue
    %% TODO why do we invoke this one?
    {ok, Ctxt2} = do_call({?INVOKE_SINGLE, [E]}, Fun, Opts, Ctxt1),
    handle_call_aux(T, {Uri, ?INVOKE_SINGLE, []}, Fun, Opts, Ctxt2);

handle_call_aux([{Uri, Invoke, E}|T], {_, Invoke, L}, Fun, Opts, Ctxt0)  ->
    %% We found another Uri so we invoke the previous one
    {ok, Ctxt1} = do_call({Invoke, L}, Fun, Opts, Ctxt0),
    %% We do not apply the invocation yet as it is not single, so we need
    %% to accummulate and apply at the end.
    %% We build a list for subsequent entries for same Uri.
    handle_call_aux(T, {Uri, Invoke, [E]}, Fun, Opts, Ctxt1).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Implements load balancing and fail over invocation strategies.
%% This works over a list of registration entries for the SAME
%% procedure.
%% @end
%% -----------------------------------------------------------------------------
-spec do_call(term(), function(), map(), bondy_context:t()) ->
    {ok, bondy_context:t()}.


do_call({?INVOKE_SINGLE, [Entry]}, Fun, _, Ctxt) ->
    try
        %% This might be a callback implemented procedure
        Fun(Entry, Ctxt)
    catch
        throw:{error, _} = ErrorMap ->
            %% Unexpected error ocurred
            Fun(ErrorMap, Ctxt)
    end;

do_call({Strategy, L}, Fun, CallOpts0, Ctxt) ->
    Opts = load_balancer_options(Strategy, CallOpts0),

    try
        %% All this entries need to be registered by a process (internal or
        %% client), otherwise we will crash when bondy_rpc_load_balancer checks
        %% the process is alive. A callback implemented procedure should never
        %% reach this point anyway as they use INVOKE_SINGLE exclusively.
        case bondy_rpc_load_balancer:select(L, Opts) of
            {ok, Entry} ->
                Fun(Entry, Ctxt);
            {error, _} = Error ->
                %% We tried all callees in the list `L' but none was alive
                Fun(Error, Ctxt)
        end
    catch
        throw:{error, _} = ErrorMap ->
            %% Validation error occurred
            Fun(ErrorMap, Ctxt)
    end.


%% -----------------------------------------------------------------------------
%% @private
%% @doc Adds support for (Sharded Registration)
%% [https://wamp-proto.org/_static/gen/wamp_latest.html#sharded-registration]
%% by transforming the call runmode and rkey properties into the ones
%% expected by the extensions to REGISTER.Options in order to reuse Bondy's
%% jump_consistent_hash load balancing strategy.
%%
%% @end
%% -----------------------------------------------------------------------------
load_balancer_options(Strategy, CallOpts0) ->
    CallOpts1 = coerce_strategy(Strategy, CallOpts0),
    coerce_routing_key(CallOpts1).


%% @private
coerce_strategy(_, #{runmode := <<"partition">>} = CallOpts) ->
    maps:put(strategy, jump_consistent_hash, CallOpts);

coerce_strategy(Strategy, CallOpts) ->
    %% An invalid runmode value would have been caught by
    %% wamp_message's validation.
    maps:put(strategy, Strategy, CallOpts).


%% @private
coerce_routing_key(#{rkey := Value} = CallOpts) ->
    maps:put('x_routing_key', Value, CallOpts);

coerce_routing_key(CallOpts) ->
    CallOpts.


%% @private
%% @doc We add context and metadata to the details of the CALL so that we
%% con forward it to a remote node or create an INVOCATION with it.
%% @end
prepare_call(M, Uri, Entry, Ctxt) ->
    Args = maybe_append_callback_args(M#call.args, Entry),
    Options = append_options(
        M#call.options, M#call.request_id, Uri, Entry, Ctxt
    ),
    M#call{options = Options, args = Args}.


%% @private
call_to_invocation(#call{options = #{'$private' := _}} = M, _, Entry, _) ->
    Callee = bondy_registry_entry:ref(Entry),
    CalleeSessionId = bondy_ref:session_id(Callee),
    InvocationId = bondy_session:gen_message_id(CalleeSessionId),
    call_to_invocation(M, InvocationId);

call_to_invocation(#call{} = M, Uri, Entry, Ctxt) ->
    Callee = bondy_registry_entry:ref(Entry),
    CalleeSessionId = bondy_ref:session_id(Callee),
    InvocationId = bondy_session:gen_message_id(CalleeSessionId),
    call_to_invocation(prepare_call(M, Uri, Entry, Ctxt), InvocationId).


%% @private
call_to_invocation(#call{options = #{'$private' := Private}} = M, ReqId) ->
    RegistrationId = maps:get(registration_id, Private),
    Details = maps:get(invocation_details, Private),
    Args = M#call.args,
    KWArgs = M#call.kwargs,

    wamp_message:invocation(ReqId, RegistrationId, Details, Args, KWArgs).


%% @private
%% @doc If this is a callback, then it must be a remote callback, as we should
%% have handled the local callback sequentially.
%% We add the statically defined arguments to the INVOCATION so that
%% we avoid the receiving node having to look the local copy of the entry
%% to retrieve the arguments.
%% @end

maybe_append_callback_args(Args0, Entry) ->
    Args = args_to_list(Args0),

    case bondy_registry_entry:is_callback(Entry) of
        true ->
            bondy_registry_entry:callback_args(Entry) ++ Args;
        false ->
            Args
    end.


%% @private
append_options(Options, CallId, Uri, Entry, Ctxt) ->
    RegistrationId =
        case bondy_registry_entry:is_proxy(Entry) of
            true ->
                %% The entry was registered by a bridge relay.
                %% We need to use the origin registration id (as
                %% opposed to the bridge relay's registration).
                bondy_registry_entry:origin_id(Entry);
            false ->
                bondy_registry_entry:id(Entry)
        end,

    Details0 = #{
        procedure => Uri,
        trust_level => 0
    },

    %% We build the invocation details with local data, and store under
    %% CALL.options.'$private'

    %% TODO disclose info only if feature is announced by Callee, Dealer
    %% and Caller
    %% NOTICE: The spec defines disclose_me and disclose_caller BUT Autobhan
    %% has deprecated this in favour of a router-based authrotization which is
    %% unfortunate as the ideal solution should be the combination of both.
    %% So for the time being we revert this to `true'.
    DiscloseCaller = bondy_registry_entry:get_option(
        disclose_caller, Entry, true
    ),
    DiscloseMe = maps:get(disclose_me, Options, true),

    Details1 = case DiscloseCaller orelse DiscloseMe of
        true ->
            bondy_context:caller_details(Ctxt, Details0);
        false ->
            Details0
    end,

    DiscloseSession = bondy_registry_entry:get_option(
        'x_disclose_session_info', Entry, false
    ),

    Details = case DiscloseSession of
        true ->
            Session = bondy_context:session(Ctxt),
            Info0 = bondy_session:to_external(Session),

            %% To be deprecated, we should return Info0 on the next release
            Info = Info0#{
                'x_authroles' => bondy_session:authroles(Session),
                'x_meta' => key_value:get([authextra, meta], Info0, #{})
            },
            Details1#{'x_session_info' => Info};
        false ->
            Details1
    end,

    Options#{
        '$private' => #{
            call_id => CallId,
            registration_id => RegistrationId,
            invocation_details => Details
        }
    }.


%% @private
call_opts(#{call_opts := Val}) -> Val;
call_opts(_) -> #{}.


%% =============================================================================
%% PRIVATE: META EVENTS
%% =============================================================================



%% @private
on_register(true, Entry) ->
    bondy_event_manager:notify({registration_created, Entry});

on_register(false, Entry) ->
    bondy_event_manager:notify({registration_added, Entry}).


%% @private
on_unregister(Entry) ->
    bondy_event_manager:notify({registration_removed, Entry}).


%% @private
on_delete(Entry) ->
    bondy_event_manager:notify({registration_deleted, Entry}).


error_from_map(Error, CallId) ->
    Msg = <<"The request failed due to invalid option parameters.">>,
    wamp_message:error(
        ?CALL,
        CallId,
        #{},
        ?WAMP_INVALID_ARGUMENT,
        [Msg],
        #{
            message => Msg,
            details => Error,
            description => <<"A required options parameter was missing in the request or while present they were malformed.">>
        }
    ).


% %% @private
% no_eligible_callee(call, CallId) ->
%     Desc = <<"A call was forwarded throught the router cluster for a callee that is no longer available.">>,
%     no_eligible_callee(?CALL, CallId, Desc);

% no_eligible_callee(invocation, CallId) ->
%     Desc = <<"An invocation was forwarded throught the router cluster to a callee that is no longer available.">>,
%     no_eligible_callee(?INVOCATION, CallId, Desc).


% %% @private
% no_eligible_callee(Type, Id, Desc) ->
%     Msg = <<
%         "There are no elibible callees for the procedure."
%     >>,
%     wamp_message:error(
%         Type,
%         Id,
%         #{},
%         ?WAMP_NO_ELIGIBLE_CALLE,
%         [Msg],
%         #{message => Msg, description => Desc}
%     ).


%% @private
badarity_error(CallId, Type) ->
    Msg = <<
        "The call was made passing the wrong number of positional arguments."
    >>,
    wamp_message:error(
        Type,
        CallId,
        #{},
        ?WAMP_INVALID_ARGUMENT,
        [Msg]
    ).


%% @private
badarg_error(CallId, Type) ->
    Msg = <<
        "The call was made passing invalid arguments."
    >>,
    wamp_message:error(
        Type,
        CallId,
        #{},
        ?WAMP_INVALID_ARGUMENT,
        [Msg]
    ).


%% @private
not_found_error(M, _Ctxt) ->
    Msg = iolist_to_binary(
        <<"There are no registered procedures matching the id ",
        $', (M#unregister.registration_id)/integer, $'>>
    ),
    wamp_message:error(
        ?UNREGISTER,
        M#unregister.request_id,
        #{},
        ?WAMP_NO_SUCH_REGISTRATION,
        [Msg],
        #{
            message => Msg,
            description => <<"The unregister request failed.">>
        }
    ).


%% @private
maybe_reserved_ns(<<"com.leapsight.bondy",  _/binary>>) ->
    throw({not_authorized, ?RESERVED_NS(<<"com.leapsight.bondy">>)});

maybe_reserved_ns(<<"bondy",  _/binary>>) ->
    throw({not_authorized, ?RESERVED_NS(<<"bondy">>)});

maybe_reserved_ns(<<"wamp",  _/binary>>) ->
    throw({not_authorized, ?RESERVED_NS(<<"wamp">>)});

maybe_reserved_ns(_) ->
    ok.
