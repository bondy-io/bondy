%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_dealer).
-moduledoc """
This module implements the capabilities of a Dealer. It is used by
`bondy_router`.

A Dealer is one of the two roles a Router plays. In particular a Dealer is
the middleman between an Caller and a Callee in an Routed RPC interaction,
i.e. it works as a generic router for remote procedure calls
decoupling Callers and Callees.

Callees register the procedures they provide with Dealers.  Callers
initiate procedure calls first to Dealers.  Dealers route calls
incoming from Callers to Callees implementing the procedure called,
and route call results back from Callees to Callers.

A Caller issues calls to remote procedures by providing the procedure
URI and any arguments for the call. The Callee will execute the
procedure using the supplied arguments to the call and return the
result of the call to the Caller.

The Caller and Callee will usually implement all business logic, while the
Dealer works as a generic router for remote procedure calls
decoupling Callers and Callees.

Bondy does not provide message transformations to ensure stability and
safety.
As such, any required transformations should be handled by Callers and
Callees directly (notice that a Callee can act as a middleman implementing
the required transformations).

The message flow between *Callees* and a *Dealer* for registering and
unregistering endpoints to be called over RPC involves the following
messages:

- `REGISTER`
- `REGISTERED`
- `UNREGISTER`
- `UNREGISTERED`
- `ERROR`

```mermaid
       ,------.          ,------.               ,------.
       |Caller|          |Dealer|               |Callee|
       `--+---'          `--+---'               `--+---'
          |                 |                      |
          |                 |                      |
          |                 |       REGISTER       |
          |                 | <---------------------
          |                 |                      |
          |                 |  REGISTERED or ERROR |
          |                 | --------------------->
          |                 |                      |
          |                 |                      |
          |                 |                      |
          |                 |                      |
          |                 |                      |
          |                 |      UNREGISTER      |
          |                 | <---------------------
          |                 |                      |
          |                 | UNREGISTERED or ERROR|
          |                 | --------------------->
       ,--+---.          ,--+---.               ,--+---.
       |Caller|          |Dealer|               |Callee|
       `------'          `------'               `------'
```

## Calling and Invocations

The message flow between *Callers*, a *Dealer* and *Callees* for
calling procedures and invoking endpoints involves the following
messages:

1. "CALL"
2. "RESULT"
3. "INVOCATION"
4. "YIELD"
5. "ERROR"

```mermaid
   sequenceDiagram
    %%{init: {'theme': 'neutral'} }%%
    Caller->>+Dealer: CALL
    Dealer->>Callee: INVOCATION
    Callee->>Dealer: YIELD | ERROR
    Dealer->>Caller: RESULT | ERROR
```

The execution of remote procedure calls is asynchronous, and there
may be more than one call outstanding.  A call is called outstanding
(from the point of view of the *Caller*), when a (final) result or
error has not yet been received by the *Caller*.

## Routing

The following sections describes how RPC routing is performed for all the
generic use cases involving clustering and bridge relay connections.
The following diagram shows the the example used in all the use cases, which
involves a single Caller making calls to four different Callees that are
local or remote to the caller.

Notice that the erlang code included in the diagram notes are to be
considered pseudo-code as they do not necessarily match the actual function
signatures.

```mermaid
  flowchart TB
    %%{init: {'theme': 'neutral'} }%%
    subgraph Bondy Cluster
    Node1
    Node2
    end
    subgraph Clients
    CALLER --> Node1
    CALLEE1 --> Node1
    CALLEE2 --> Node2
    end
    subgraph Bondy Edge Cluster
    EdgeNode1
    EdgeNode2
    end
    Node1 -.Bridge Relay Connection...- EdgeNode1
    subgraph Edge Clients
    CALLEE3 --> EdgeNode1
    CALLEE4 --> EdgeNode2
    end
```

### Call to a local Callee

```mermaid
    sequenceDiagram
    %%{init: {'theme': 'neutral'} }%%
    	autonumber
      participant CALLER
      participant node1 as DEALER<br/><br/>@node1
      participant CALLEE1
    	note over node1: CALLEE1 seq = 99
    	CALLER ->> node1:CALL.1
    	note over node1: CALLEE1 seq = 100
    	node1 -->> node1: promise:add({100, 1})
    	node1 ->> CALLEE1: INVOCATION.100
    	CALLEE1 ->> node1: YIELD.100
    	node1 -->> node1: bondy_rpc_promise:take({100, 1})
    	node1 ->> CALLER: RESULT.1
```

### Call to a Remote Callee

```mermaid
   sequenceDiagram
    %%{init: {'theme': 'neutral'} }%%
     autonumber
    	participant CALLER
    	participant Node1
    	participant Node2
    	participant CALLEE2
    	note over Node2: CALLEE2 seq = 99
    	CALLER ->> Node1:CALL.2
    	Node1 -->> Node1: bondy_rpc_promise:new_call(2)
    	rect RGB(230, 230, 230)
    	note over Node1,Node2: CLUSTER CONNECTION
    	Node1 -->> Node2: CALL.2
     end
    	Node2 -->> Node2: bondy_rpc_promise:new_invocation(100, 2)
    	note over Node2: CALLEE2 seq = 100
    	Node2 ->> CALLEE2: INVOCATION.100
    	CALLEE2 ->> Node2: YIELD.100
    	Node2 -->> Node2: bondy_rpc_promise:take({invocation, 100, '_'})
    	Node2 -->> Node1: RESULT.2
    	Node1 -->> Node1: bondy_rpc_promise:take({call, 2})
    	Node1 ->> CALLER: RESULT.2
```

### Call to Bridged Callee

```mermaid
  sequenceDiagram
    %%{init: {'theme': 'neutral'} }%%
    autonumber
    	participant CALLER
    	participant Node1
    	participant Node2
    	participant CALLEE2
    	note over Node2: CALLEE2 seq = 99
    	CALLER ->> Node1:CALL.2
    	Node1 -->> Node1: bondy_rpc_promise:new_call(2)
    	rect RGB(230, 230, 230)
    	note over Node1,Node2: CLUSTER CONNECTION
    	Node1 -->> Node2: CALL.2
     end
    	Node2 -->> Node2: bondy_rpc_promise:new_invocation(100, 2)
    	note over Node2: CALLEE2 seq = 100
    	Node2 ->> CALLEE2: INVOCATION.100
    	CALLEE2 ->> Node2: YIELD.100
    	Node2 -->> Node2: bondy_rpc_promise:take(invocation, 100, '_')
    	Node2 -->> Node1: RESULT.2
    	Node1 -->> Node1: bondy_rpc_promise:take({call, 2})
    	Node1 ->> CALLER: RESULT.2
```

### Call to remote Bridged Callee

```mermaid
   sequenceDiagram
    %%{init: {'theme': 'neutral'} }%%
    	participant CALLER
    	participant Node1
    	participant Node2
    	participant Bridged_Node1
    	participant Bridged_Node2
    	note over Bridged_Node2: CALLEE seq = 99
    	participant CALLEE4
    	CALLER ->> Node1:CALL.5
    	Node1 -->> Node1: promise:add({5, 5})
    	Node1 -->> Node2: Call.5
    	rect RGB(230, 230, 230)
    	note over Node2,Bridged_Node1: BRIDGE RELAY CONNECTION
      Node2 -->> Bridged_Node1:CALL.5
    	end
    	Bridged_Node1 -->> Bridged_Node2: CALL.5
    	note over Bridged_Node2: CALLEE4 seq = 100
    	Bridged_Node2 ->> CALLEE4: INVOCATION.100
    	CALLEE4 ->> Bridged_Node2: YIELD.100
    	Bridged_Node2 -->> Bridged_Node2: bondy_rpc_promise:take({invocation, 100, 5})
    	Bridged_Node2 -->> Bridged_Node1: RESULT.5
    	Bridged_Node1 -->> Node2: RESULT.5
    	Node2 -->> Node1: RESULT.5
    	Node1 ->> Node1: bondy_rpc_promise:take({call, 5})
    	Node1 ->> CALLER: RESULT.5
```

## Remote Procedure Call Ordering

Regarding **Remote Procedure Calls**, the ordering guarantees are as
follows:

If *Callee A* has registered endpoints for both **Procedure 1** and
**Procedure 2**, and *Caller B* first issues a **Call 1** to **Procedure
1** and then a **Call 2** to **Procedure 2**, and both calls are routed to
*Callee A*, then *Callee A* will first receive an invocation
corresponding to **Call 1** and then **Call 2**. This also holds if
**Procedure 1** and **Procedure 2** are identical.

In other words, WAMP guarantees ordering of invocations between any
given *pair* of *Caller* and *Callee*. The implementation preserves this
by handling CALL synchronously in the caller's transport process (Erlang
guarantees signal order between a pair of processes) and, when the callee
is on another node, by pinning the caller/callee pair to one relay
channel connection on egress and to one flow pool worker on ingress (see
`bondy_relay:routing_opts/2` and `bondy_router_worker:cast/3`), so the
pair's messages form a single FIFO pipeline end to end.

There are no guarantees on the order of call results and errors in
relation to *different* calls, since the execution of calls upon
different invocations of endpoints in *Callees* are running
independently.  A first call might require an expensive, long-running
computation, whereas a second, subsequent call might finish
immediately.

Further, if *Callee A* registers for **Procedure 1**, the "REGISTERED"
message will be sent by *Dealer* to *Callee A* before any
"INVOCATION" message for **Procedure 1**.

There is no guarantee regarding the order of return for multiple
subsequent register requests.  A register request might require the
*Dealer* to do a time-consuming lookup in some database, whereas
another register request second might be permissible immediately.
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_db_tables.hrl").
-include("bondy_uris.hrl").

-define(MATCH_LIMIT, 100).

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
    call_opts := map()
}.

-type call_fun() :: fun(
    (entry() | {error, any()}, bondy_context:t()) -> {ok, bondy_context:t()}
).
%% Aliases
-type entry() :: bondy_registry_entry:t().
-type trie_continuation() :: bondy_registry_store:continuation().
-type eot() :: bondy_registry_store:eot().

%% API
-export([callees/1]).
-export([callees/2]).
-export([callees/3]).
-export([features/0]).
-export([flush/2]).
-export([flush_callee_promises/2]).
-export([forward/2]).
-export([forward/3]).
-export([is_feature_enabled/1]).
-export([register/3]).
-export([register/4]).
-export([unregister/1]).
-export([unregister/2]).

-compile({no_auto_import, [register/2]}).

%% =============================================================================
%% API
%% =============================================================================

-spec features() -> map().

features() ->
    maps:from_list(bondy_config:get([wamp, dealer, features])).

-spec is_feature_enabled(binary() | atom()) -> boolean().

is_feature_enabled(F) when is_binary(F) ->
    try
        is_feature_enabled(binary_to_existing_atom(F))
    catch
        _:_ ->
            false
    end;
is_feature_enabled(F) when is_atom(F) ->
    bondy_config:get([wamp, dealer, features, F], false).

-doc """
Removes all registrations and all the pending items in the RPC promise
queue that are associated for reference `Ref` in realm `RealmUri`.
""".
-spec flush(RealmUri :: uri(), Ref :: bondy_ref:t()) -> ok.

flush(RealmUri, Ref) ->
    try
        %% TODO If registration is deleted we need to also call on_delete/1
        %% Cleanup all registrations for the ref's session.
        %% We do this before flushing promises so that any concurrent CALL
        %% cannot pick this ref as a callee after we start the flush.
        SessionId = bondy_ref:session_id(Ref),
        bondy_registry:remove_all(
            registration,
            RealmUri,
            SessionId,
            fun on_unregister/1,
            %% disable broadcast to avoid an avalanche on the other notes
            %% they will get this delete in the next AAE exchange
            #{broadcast => false}
        ),

        %% Cleanup all RPC queued invocations for Ref. For invocation
        %% promises where Ref is the callee, fast-fail the caller with
        %% wamp.error.no_eligible_callee instead of letting the call wait
        %% for its timeout. For invocation promises where Ref is the
        %% caller, INTERRUPT the callee so it stops working — possibly on
        %% a progressive-results stream — for a caller that will never
        %% consume the response.
        ok = bondy_rpc_promise:flush(
            RealmUri, Ref, #{
                on_callee_flush => fun send_no_eligible_callee/1,
                on_caller_flush => caller_flush_fun(Ref)
            }
        )
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(#{
                description =>
                    "Error while flushing registration and RPC promise "
                    "queue items",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace,
                realm_uri => RealmUri,
                ref => Ref
            }),
            ok
    end.

-doc """
Flushes any in-flight invocation promises where `Ref` is the callee,
replying to each caller with a `wamp.error.no_eligible_callee` ERROR
routed back through the promise's `via` queue.

Used by the registry to fast-fail callers when a remote node goes down
and its callees are being pruned, so they don't wait for the call
timeout. Unlike `flush/2`, this does not touch registrations — the
caller is expected to have already removed them.
""".
-spec flush_callee_promises(RealmUri :: uri(), Ref :: bondy_ref:t()) -> ok.

flush_callee_promises(RealmUri, Ref) ->
    try
        bondy_rpc_promise:flush(
            RealmUri, Ref, #{on_callee_flush => fun send_no_eligible_callee/1}
        )
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(#{
                description =>
                    "Error while flushing RPC promise queue items",
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace,
                realm_uri => RealmUri,
                ref => Ref
            }),
            ok
    end.

-doc """
Creates a local registration.

If the registration is done using a callback module, only the invoke single
strategy can be used (i.e. `shared_registration` and `sharded_registration`
are also disabled). Also the callback module needs to conform to the
`wamp_api_callback` behaviour, otherwise the call fails with a `badarg`
exception.
""".
-spec register(Procedure :: uri(), Opts :: map(), Ref :: bondy_context:t()) ->
    {ok, id()}
    | {error, already_exists | any()}
    | no_return().

register(Procedure, Opts, Ctxt) when is_map(Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    Ref = bondy_context:ref(Ctxt),

    register(Procedure, Opts, RealmUri, Ref).

-spec register(
    Procedure :: uri(),
    Opts :: map(),
    RealmUri :: uri(),
    Ref :: bondy_ref:t() | bondy_context:t()
) ->
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

    case bondy_registry:add(registration, RealmUri, Procedure, Opts, Ref) of
        {ok, {Entry, _}} ->
            {ok, bondy_registry_entry:id(Entry)};
        {error, {already_exists, _}} ->
            {error, already_exists};
        {error, _} = Error ->
            Error
    end.

-doc """
For internal Bondy use.

Terminates the process identified by `Pid` by
`bondy_subscribers_sup:terminate_subscriber/1`.
""".
-spec unregister(pid()) -> ok | {error, not_found}.

unregister(Callee) when is_integer(Callee) ->
    error(not_implemented);
unregister(Callee) when is_pid(Callee) ->
    error(not_implemented).

-spec unregister(RegId :: id(), bondy_context:t() | uri()) ->
    ok | {error, not_found}.

unregister(RegId, Ctxt) when is_map(Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    unregister(RegId, RealmUri);
unregister(RegId, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),

    case bondy_registry:lookup(registration, RealmUri, RegId) of
        {error, not_found} = Error ->
            Error;
        {ok, Entry} ->
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

-spec callees(RealmUri :: uri()) -> [map()] | no_return().

callees(RealmUri) ->
    %% TODO paginate and groupBy sessionID, so that we call
    %% bondy_session_id:to_external only once per session.
    case bondy_registry:match(registration, RealmUri, '_') of
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

-spec callees(RealmUri :: uri(), ProcedureUri :: uri()) ->
    [map()] | no_return().

callees(RealmUri, ProcedureUri) ->
    callees(RealmUri, ProcedureUri, #{}).

-spec callees(RealmUri :: uri(), ProcedureUri :: uri(), Opts :: map()) ->
    [map()] | no_return().

callees(RealmUri, ProcedureUri, Opts0) ->
    %% TODO ask the registry to offer callees/3

    %% We do not support limits yet
    Opts = maps:without([limit], Opts0),

    case bondy_registry:match(registration, RealmUri, ProcedureUri, Opts) of
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

-doc """
This function is called by `bondy_router` to handle inbound messages
sentt by WAMP peers connected to this Bondy node.
""".
-spec forward(M :: wamp_message(), Ctxt :: map()) -> ok.

forward(M, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),

    try
        do_forward(M, Ctxt)
    catch
        _:{not_authorized, Reason} ->
            Reply = bondy_wamp_message:error_from(
                M,
                #{},
                ?WAMP_NOT_AUTHORIZED,
                [Reason],
                #{message => Reason}
            ),
            bondy:send(RealmUri, bondy_context:ref(Ctxt), Reply);
        throw:not_found ->
            Reply = not_found_error(M, Ctxt),
            bondy:send(RealmUri, bondy_context:ref(Ctxt), Reply);
        throw:{progressive_calls_unsupported, Role} ->
            %% A progressive-input CALL whose caller/callee did not announce the
            %% feature — rejected (no silent degrade for a started stream).
            Reply = progressive_calls_error(M, {unsupported, Role}),
            bondy:send(RealmUri, bondy_context:ref(Ctxt), Reply);
        throw:{progressive_calls_violation, _} ->
            Reply = progressive_calls_error(M, violation),
            bondy:send(RealmUri, bondy_context:ref(Ctxt), Reply);
        Class:Reason:Stacktrace ->
            TraceId = bondy_utils:uuid(),
            ?LOG_ERROR(#{
                description =>
                    ~"Error while evaluating inbound message. Returning ERROR",
                reason => Reason,
                class => Class,
                stacktrace => Stacktrace,
                data => M,
                trace_id => TraceId
            }),

            Reply = bondy_wamp_message:error_from(
                M,
                #{},
                ?BONDY_ERROR_INTERNAL,
                [~"Internal system error"],
                #{trace_id => TraceId}
            ),
            bondy:send(RealmUri, bondy_context:ref(Ctxt), Reply)
    end.

-doc """
Handles inbound messages received from a relay i.e. a cluster peer node
or `bridge_relay` i.e. edge client or server.
""".
-spec forward(wamp_message(), To :: bondy_ref:t(), Opts :: map()) ->
    ok | no_return().

forward(#call{} = Msg, _Hint, #{rib_completion := true} = Opts0) ->
    %% A node-addressed forwarded CALL: the caller node routed to this NODE,
    %% and the entry it selected from its replica travelled only as a hint —
    %% it may be stale. Re-select among the live LOCAL registrations for the
    %% procedure and dispatch to the winner; with none, fail fast back to the
    %% caller, whose call promise matches the ERROR. Local-only selection
    %% also guarantees a forwarded call is never forwarded again.
    Opts = maps:remove(rib_completion, Opts0),
    RealmUri = ?GET_REALM_URI(Opts),
    ProcUri = Msg#call.procedure_uri,
    Caller = maps:get(from, Opts, undefined),
    CallId = key_value:get(['$private', call_id], Msg#call.options, undefined),

    case
        is_feature_enabled(progressive_calls) andalso
            find_input_stream(RealmUri, Caller, CallId)
    of
        {invocation_chunk, Promise} ->
            %% A subsequent chunk of an in-flight remote progressive stream:
            %% deliver it to the callee already handling the open invocation
            %% rather than re-selecting (which would start a new invocation).
            forward_input_chunk(Msg, Promise, RealmUri, Caller);
        violation ->
            %% The request id is live on a NON-progressive call. node1 rejects
            %% this before forwarding, so reaching here is defensive — reject
            %% with the same vocabulary the origin node uses (symmetric rule).
            reply_progressive_calls_error(Msg, violation, Opts);
        _ ->
            %% Feature off (short-circuit `false`) or no open stream (`none`):
            %% a first chunk or a plain call. Re-select a live local callee.
            case rib_local_callee(RealmUri, ProcUri, Msg, Opts) of
                {ok, Entry} ->
                    ok = rib_count(
                        bondy_rpc_rib_completions_total, #{outcome => ok}
                    ),
                    forward(
                        rib_rebind(Msg, Entry),
                        bondy_registry_entry:ref(Entry),
                        Opts
                    );
                {error, _} ->
                    ok = rib_count(
                        bondy_rpc_rib_completions_total, #{outcome => miss}
                    ),
                    reply_no_eligible_callee(Msg, Opts)
            end
    end;
forward(#call{} = Msg, Callee, #{from := Caller} = Opts) ->
    %% A remote Caller is making a CALL to a local Callee or local bridged
    %% Callee.
    true == bondy_ref:is_local(Callee) orelse
        error({forwarding_error, callback_no_local}),

    %% Fails with no_realm exception if not present
    RealmUri = ?GET_REALM_URI(Opts),
    CalleeType = bondy_ref:type(Callee),

    %% Owner-node gate for a progressive-input first chunk: a CALL carrying
    %% `progress` is admissible only if this (local) callee announced
    %% `progressive_calls`. Computed as a bound boolean so the guarded clause
    %% below can reject before an invocation is ever built — the mirror of the
    %% caller gate, closing the distributed no-silent-degrade hole. Non-callee
    %% target types take their own clauses first and never consult it.
    Admissible = progressive_input_admissible(Msg, Callee),

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
        _ when CalleeType == bridge_relay ->
            %% We need to send the CALL to the bridge relay,
            %% no need for a call promise here as there is one on the Caller's
            %% node. A progressive-input first chunk is NOT gated here: this hop
            %% cannot see the edge callee's features (its session lives on the
            %% edge node), so the gate runs at the edge node that hosts the
            %% callee — the same "gate at the callee's node" rule as a cluster
            %% callee.
            {To, SendOpts} = bondy:prepare_send(Callee, Opts),
            bondy:send(RealmUri, To, Msg, SendOpts);
        _ when
            (CalleeType == client orelse CalleeType == internal) andalso
                not Admissible
        ->
            %% Progressive-input first chunk to a callee that did not announce
            %% `progressive_calls`: reject (no silent degrade for a started
            %% stream); the ERROR relays back to the caller's node.
            reply_progressive_calls_error(Msg, {unsupported, callee}, Opts);
        _ when CalleeType == client orelse CalleeType == internal ->
            %% A pid- or name-target callee. `internal` covers non-callback
            %% refs admitted by register/4 (a callback target is handled by
            %% the first clause); they receive INVOCATION like any client.
            %% We now turn the CALL into an INVOCATION.
            {To, SendOpts} = bondy:prepare_send(Callee, Opts),

            %% Internal refs may carry no session; fall back to a global
            %% id rather than a session-scoped one.
            InvocationId =
                case bondy_ref:session_id(Callee) of
                    undefined ->
                        bondy_message_id:global();
                    CalleeSessionId ->
                        bondy_message_id:session(RealmUri, CalleeSessionId)
                end,
            Timeout = bondy_utils:timeout(Opts),

            %% receive_progress reaches the callee only if it announced
            %% progressive_call_results (the caller was already gated at
            %% the origin node).
            GatedMsg = gate_receive_progress(
                Msg, bondy_ref:session_id(Callee)
            ),
            Invocation = call_to_invocation(GatedMsg, InvocationId),

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

            PromiseOpts = maybe_mark_progressive_input(
                maybe_mark_progress(
                    #{
                        procedure_uri => Msg#call.procedure_uri,
                        via => Via,
                        timeout => Timeout,
                        deadline => promise_deadline(Msg#call.options)
                    },
                    maps:get(
                        receive_progress, Invocation#invocation.details, false
                    )
                ),
                Invocation
            ),

            Promise = bondy_rpc_promise:new_invocation(
                RealmUri,
                Caller,
                CallId,
                Callee,
                InvocationId,
                PromiseOpts
            ),

            ok = bondy_rpc_promise:add(Promise),

            %% We send the invocation to the local callee
            %% (no use of via here)
            bondy:send(RealmUri, To, Invocation, SendOpts)
    end;
forward(#cancel{} = M, _Addressed, #{from := Caller} = Opts) ->
    %% A remote Caller (or its node, after the caller died) is cancelling
    %% a previous CALL made to a local Callee. The CALL request id plus the
    %% Caller identify the invocation uniquely, so the invocation id and the
    %% actual local callee are recovered from the invocation promise — the
    %% CANCEL may be node-addressed (carrying only the owner node, not the
    %% resolved callee) when routing ran on the RIB, so the address the
    %% CANCEL arrived on is not the callee. Mode semantics: `kill` keeps the
    %% promise (the callee's ERROR settles the call), `killnowait` and `skip`
    %% take it so any late response is discarded; `skip` sends no INTERRUPT.
    %% The INTERRUPT is only sent to a callee that announced call_canceling.

    %% Fails with no_realm exception if not present
    RealmUri = ?GET_REALM_URI(Opts),

    CallId = M#cancel.request_id,
    Mode = cancel_mode(maps:get(mode, M#cancel.options, skip)),

    Key = bondy_rpc_promise:invocation_key_pattern(
        RealmUri,
        Caller,
        CallId,
        '_',
        '_'
    ),

    Result =
        case Mode of
            kill -> bondy_rpc_promise:find(Key);
            _ -> bondy_rpc_promise:take(Key)
        end,

    case Result of
        {ok, _Promise} when Mode == skip ->
            ok;
        {ok, Promise} ->
            Callee = bondy_rpc_promise:callee(Promise),
            Interruptible = session_feature(
                bondy_ref:session_id(Callee), callee, call_canceling
            ),

            case Interruptible of
                true ->
                    InvocationId =
                        bondy_rpc_promise:invocation_id(Promise),
                    Interrupt = bondy_wamp_message:interrupt(
                        InvocationId, maps:with([mode], M#cancel.options)
                    ),
                    {To, SendOpts} = bondy:prepare_send(
                        Callee, #{from => Caller}
                    ),
                    bondy:send(RealmUri, To, Interrupt, SendOpts);
                false ->
                    ok
            end;
        error ->
            %% The promise already expired; the Caller would have already
            %% received a TIMEOUT error as a response for the original
            %% CALL.
            no_matching_promise(M)
    end;
forward(#result{} = M, Caller, #{from := _Callee} = Opts) ->
    %% A remote Callee is returning a RESULT to CALL done on behalf of a
    %% local Caller.

    %% Fails with no_realm exception if not present
    RealmUri = ?GET_REALM_URI(Opts),

    CallId = M#result.request_id,

    Key = bondy_rpc_promise:call_key_pattern(RealmUri, Caller, CallId),

    case maps:get(progress, M#result.details, false) of
        true ->
            %% A progressive RESULT settles nothing: the call promise stays
            %% in place to match further RESULTs (and eventually the final
            %% one), and — per the WAMP timeout semantics for progressive
            %% calls — slides the promise expiry (capped by any
            %% CALL.Options._deadline). A progressive RESULT for a promise
            %% that was not marked receive_progress can only come from a
            %% peer node without progressive support (a version-mixed
            %% cluster); a peer cannot be aborted, so demote it to the
            %% final result (flag removed, promise taken).
            case bondy_rpc_promise:find(Key) of
                {ok, Promise} ->
                    case
                        bondy_rpc_promise:get(
                            receive_progress, Promise, false
                        )
                    of
                        true ->
                            _ = bondy_rpc_promise:refresh(Promise),
                            bondy:send(RealmUri, Caller, M);
                        false ->
                            ?LOG_WARNING(#{
                                description =>
                                    "Received a progressive RESULT for a "
                                    "call that did not request progressive "
                                    "results. Demoting it to the final "
                                    "result.",
                                realm_uri => RealmUri,
                                call_id => CallId
                            }),
                            M1 = M#result{
                                details =
                                    maps:remove(progress, M#result.details)
                            },
                            case bondy_rpc_promise:take(Key) of
                                {ok, P} ->
                                    ok = notify_call_latency(P),
                                    bondy:send(RealmUri, Caller, M1);
                                error ->
                                    no_matching_promise(M1)
                            end
                    end;
                error ->
                    no_matching_promise(M)
            end;
        false ->
            case bondy_rpc_promise:take(Key) of
                {ok, Promise} ->
                    %% Even if promise has timeout but
                    %% bondy_rpc_promise_manager has not evicted it yet.
                    ok = notify_call_latency(Promise),
                    bondy:send(RealmUri, Caller, M);
                error ->
                    no_matching_promise(M)
            end
    end;
forward(#error{request_type = ?CALL} = M, Caller, Opts) ->
    %% A remote callee is returning an ERROR to an CALL done
    %% on behalf of a local Caller.

    %% Fails with no_realm exception if not present
    RealmUri = ?GET_REALM_URI(Opts),

    CallId = M#error.request_id,

    Key = bondy_rpc_promise:call_key_pattern(RealmUri, Caller, CallId),

    Status =
        case M#error.error_uri of
            ?WAMP_ERROR_TIMEOUT ->
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
        {ok, Promise} ->
            ok = notify_call_latency(Promise),
            case maybe_rib_retry(M, Promise, RealmUri, Caller) of
                true ->
                    %% Re-routed to another candidate node (or completed
                    %% locally) — the caller keeps waiting on the same call.
                    ok;
                false ->
                    bondy:send(RealmUri, Caller, strip_rib_details(M), #{})
            end;
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

%% @private
-doc "We handle messages from our local clients.".
-spec do_forward(M :: wamp_message(), Ctxt :: map()) -> ok | no_return().

do_forward(#register{} = M, Ctxt) ->
    %% A local Callee
    handle_register(M, Ctxt);
do_forward(#unregister{} = M, Ctxt) ->
    %% A local Callee
    handle_unregister(M, Ctxt);
do_forward(#call{procedure_uri = Uri} = M0, Ctxt) ->
    %% A local Caller.
    ok = bondy_rbac:authorize(<<"wamp.call">>, Uri, Ctxt),

    %% Honour CALL.Options.receive_progress only when both the dealer and
    %% the caller support progressive results; otherwise remove it here so
    %% no downstream path can act on it.
    M = maybe_strip_receive_progress(M0, Ctxt),

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
    %% The mode arrives as a binary (validated CANCEL option); normalise it to
    %% the atom the handle_cancel/3 clauses match on.
    handle_cancel(
        M, Ctxt0, cancel_mode(maps:get(mode, M#cancel.options, skip))
    );
do_forward(#yield{} = M, Ctxt0) ->
    %% A local Callee is replying to an INVOCATION message.
    %% We match the YIELD with the original INVOCATION using the request_id,
    %% and with that retrieve the CALL request_id to find the Caller.

    RealmUri = bondy_context:realm_uri(Ctxt0),
    Callee = bondy_context:ref(Ctxt0),
    InvocationId = M#yield.request_id,
    Key = bondy_rpc_promise:invocation_key_pattern(
        RealmUri,
        '_',
        '_',
        Callee,
        InvocationId
    ),

    case maps:get(progress, M#yield.options, false) of
        true ->
            handle_progressive_yield(M, Key, RealmUri, Callee);
        false ->
            case bondy_rpc_promise:take(Key) of
                {ok, Promise} ->
                    %% Caller can be local or remote. When the Caller is local
                    %% this resolves the whole call (only one promise exists),
                    %% so it is the local-call latency observation point; for
                    %% a remote Caller its own node observes latency on the
                    %% call promise instead.
                    ok = notify_call_latency(Promise),
                    send_yield_result(M, Promise, RealmUri, Callee);
                error ->
                    no_matching_promise(M)
            end
    end,

    ok;
do_forward(#error{request_type = Type} = M, Ctxt0) when
    Type == ?INVOCATION orelse Type == ?INTERRUPT
->
    %% A local Callee is replying to a previous INVOCATION | INTERRUPT.
    %% We match the ERROR with the original INVOCATION
    %% using the request_id, and with that match the CALL request_id
    %% to find the Caller.
    RealmUri = bondy_context:realm_uri(Ctxt0),
    Callee = bondy_context:ref(Ctxt0),
    InvocationId = M#error.request_id,
    Key = bondy_rpc_promise:invocation_key_pattern(
        RealmUri,
        '_',
        '_',
        Callee,
        InvocationId
    ),

    %% We determine the operation and response error type depending on
    %% incoming type
    {NewType, Result} =
        case Type of
            ?INVOCATION ->
                {?CALL, bondy_rpc_promise:take(Key)};
            ?INTERRUPT ->
                %% If the INTERRUPT failed, then the Callee might still reply to
                %% the call, so we do not take it.
                {?CANCEL, bondy_rpc_promise:find(Key)}
        end,

    case Result of
        {ok, Promise} ->
            _ = (NewType == ?CALL andalso notify_call_latency(Promise)),
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

%% @private
-doc """
If the callback module returns other than `ok` or `reply` we need to
find the callee in the registry.
""".
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
        {continue, #call{} = M1} ->
            handle_call(M1, Ctxt, M1#call.procedure_uri, DefaultOpts);
        {continue, #call{} = M1, Fun} ->
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
            Error = bondy_wamp_api_utils:no_such_procedure_error(M0),
            bondy:send(RealmUri, Caller, Error);
        error:#error{} = Error ->
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
            Error = bondy_wamp_api_utils:maybe_error({error, Reason}, M0),
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

apply_dynamic_callback(#call{options = #{ppt_scheme := _}} = Msg, _, _) ->
    bondy_wamp_message:error(
        ?CALL,
        Msg#call.request_id,
        Msg#call.options,
        ?WAMP_INVALID_ARGUMENT,
        [~"Payload Passthru Mode is not supported on Bondy Meta API."]
    );
apply_dynamic_callback(#call{} = Msg0, Callee, CBArgs) ->
    Msg = bondy_wamp_message:decode_partial(Msg0),

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
            bondy_wamp_message:result(
                CallId,
                Details,
                Args,
                KWArgs
            );
        {error, Uri, Details, Args, KWArgs} ->
            bondy_wamp_message:error(
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

%% @private
-doc """
A local Caller is cancelling a previous CALL.

A call to a local callee is tracked by an invocation promise and handled
by `handle_cancel_local/3`. A call to a remote or bridged callee is
tracked by a call promise (the invocation promise lives on the callee's
node), so the CANCEL is relayed to that node, which resolves the local
invocation id and INTERRUPTs the callee (`forward/3`).
""".
handle_cancel(#cancel{} = M, Ctxt, Mode) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    Caller = bondy_context:ref(Ctxt),
    CallId = M#cancel.request_id,
    CallKey = bondy_rpc_promise:call_key_pattern(RealmUri, Caller, CallId),

    case bondy_rpc_promise:find(CallKey) of
        {ok, Promise} ->
            handle_cancel_remote(M, Ctxt, Mode, CallKey, Promise);
        error ->
            handle_cancel_local(M, Ctxt, Mode)
    end.

%% @private
%% Cancel a call whose callee is on another node or bridged cluster. For
%% `killnowait` and `skip` the caller is answered immediately and the call
%% promise settled here, so any late RESULT/ERROR relayed back is
%% discarded; for `kill` the promise stays — the callee's ERROR is relayed
%% back and settles the call. The CANCEL is forwarded in every mode (for
%% `skip` only so the callee's node drops its invocation promise). A
%% promise without a callee (a node-addressed routing retry with no owner
%% bound yet) cannot be routed to; the settled or expiring promise bounds
%% the call instead.
handle_cancel_remote(M, Ctxt, Mode, CallKey, Promise) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    Caller = bondy_context:ref(Ctxt),
    CallId = M#cancel.request_id,

    %% If not authorized this fails with an exception
    Uri = bondy_rpc_promise:procedure_uri(Promise),
    ok = bondy_rbac:authorize(<<"wamp.cancel">>, Uri, Ctxt),

    ok =
        case Mode of
            kill ->
                ok;
            _ ->
                _ = bondy_rpc_promise:take(CallKey),
                Error = bondy_wamp_message:error(
                    ?CALL,
                    CallId,
                    #{},
                    ?WAMP_CANCELLED,
                    [<<"call_cancelled">>],
                    #{
                        description =>
                            <<"The call was cancelled by the user.">>
                    }
                ),
                bondy:send(RealmUri, Caller, Error, #{})
        end,

    case bondy_rpc_promise:callee(Promise) of
        undefined ->
            ok;
        Callee ->
            {To, SendOpts} = bondy:prepare_send(Callee, #{from => Caller}),
            bondy:send(RealmUri, To, M, SendOpts)
    end.

%% @private
handle_cancel_local(#cancel{} = M, Ctxt0, kill) ->
    %% INTERRUPT is sent to the callee, but ERROR is not returned
    %% to the caller until the callee has responded to INTERRUPT with
    %% ERROR. In this case, the caller may receive RESULT or
    %% another ERROR if the callee finishes processing the
    %% INVOCATION first.
    %% We thus read the promise instead of taking it.
    RealmUri = bondy_context:realm_uri(Ctxt0),
    CallId = M#cancel.request_id,
    Caller = bondy_context:ref(Ctxt0),
    Opts = M#cancel.options,

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

        R = bondy_wamp_message:interrupt(InvocationId, Opts),
        ok = bondy:send(RealmUri, To, R, SendOpts),

        {ok, Ctxt1}
    end,

    _ = find_invocations(CallId, Fun, Ctxt0),
    ok;
handle_cancel_local(#cancel{} = M, Ctxt0, killnowait) ->
    %% The pending call is canceled and ERROR is send immediately
    %% back to the caller. INTERRUPT is sent to the callee and any
    %% response to the invocation or interrupt from the callee is
    %% discarded when received.
    %% We take the invocation, that way the response will be
    %% discarded.
    RealmUri = bondy_context:realm_uri(Ctxt0),
    CallId = M#cancel.request_id,
    Caller = bondy_context:ref(Ctxt0),
    Opts = M#cancel.options,

    Fun = fun(Promise, Ctxt1) ->
        %% If not authoried this will fail with an exception
        Uri = bondy_rpc_promise:procedure_uri(Promise),
        ok = bondy_rbac:authorize(<<"wamp.cancel">>, Uri, Ctxt1),

        InvocationId = bondy_rpc_promise:invocation_id(Promise),
        Callee = bondy_rpc_promise:callee(Promise),

        Error = bondy_wamp_message:error(
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
        Interrupt = bondy_wamp_message:interrupt(InvocationId, Opts),
        Via = bondy_rpc_promise:via(Promise),
        SendOpts0 = #{from => Caller, via => Via},
        {To, SendOpts} = bondy:prepare_send(Callee, SendOpts0),

        ok = bondy:send(RealmUri, To, Interrupt, SendOpts),

        {ok, Ctxt1}
    end,
    _ = take_invocations(CallId, M, Fun, Ctxt0),
    ok;
handle_cancel_local(#cancel{} = M, Ctxt0, skip) ->
    %% The pending call is canceled and ERROR is sent immediately
    %% back to the caller. No INTERRUPT is sent to the callee and
    %% the result is discarded when received.
    %% We dequeue the invocation, that way the response will be
    %% discarded.
    %% TODO instead of dequeuing, update the entry to reflect it was
    %% cancelled
    CallId = M#cancel.request_id,
    Caller = bondy_context:ref(Ctxt0),

    Fun = fun(Promise, Ctxt1) ->
        %% If not authoried this will fail with an exception
        Uri = bondy_rpc_promise:procedure_uri(Promise),
        ok = bondy_rbac:authorize(<<"wamp.cancel">>, Uri, Ctxt1),

        %% The cancellation acknowledgement is an ERROR for the CALL (the
        %% CANCEL message type has no ERROR counterpart in the spec).
        Error = bondy_wamp_message:error(
            ?CALL,
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

%% @private
cancel_mode(<<"kill">>) -> kill;
cancel_mode(<<"killnowait">>) -> killnowait;
cancel_mode(<<"skip">>) -> skip;
cancel_mode(Mode) when is_atom(Mode) -> Mode;
cancel_mode(_) -> skip.

-doc """
Registers an RPC endpoint.
If the registration already exists, it fails with a
`{not_authorized | procedure_already_exists, binary()}` reason.
""".
handle_register(#register{procedure_uri = Uri} = M, Ctxt) ->
    ok = maybe_reserved_ns(Uri),
    ok = bondy_rbac:authorize(<<"wamp.register">>, Uri, Ctxt),

    #register{options = Opts0, request_id = ReqId} = M,

    %% We add an option used by bondy_registry
    Val = bondy_context:is_feature_enabled(Ctxt, callee, shared_registration),
    Opts = Opts0#{shared_registration => Val},

    RealmUri = bondy_context:realm_uri(Ctxt),
    Ref = bondy_context:ref(Ctxt),

    case bondy_registry:add(registration, RealmUri, Uri, Opts, Ref) of
        {ok, {Entry, IsFirst}} ->
            ok = on_register(IsFirst, Entry),
            Id = bondy_registry_entry:id(Entry),
            Reply = bondy_wamp_message:registered(ReqId, Id),
            bondy:send(RealmUri, Ref, Reply);
        {error, {already_exists, Entry}} ->
            EntrySessionId = bondy_registry_entry:session_id(Entry),
            Who =
                case bondy:get_process_metadata() of
                    #{session_id := Id} when Id == EntrySessionId ->
                        <<"this session">>;
                    _ ->
                        <<"another session">>
                end,
            Policy = bondy_registry_entry:match_policy(Entry),
            Msg = <<
                "The procedure is already registered by ",
                Who/binary,
                " with policy ",
                $',
                Policy/binary,
                $',
                $.
            >>,
            Reply = bondy_wamp_message:error(
                ?REGISTER,
                ReqId,
                #{},
                ?WAMP_PROCEDURE_ALREADY_EXISTS,
                [Msg]
            ),
            bondy:send(RealmUri, Ref, Reply);
        {error, Reason} when is_atom(Reason) ->
            Msg = <<
                "Failed to register procedure, reason:",
                (atom_to_binary(Reason))/binary
            >>,
            Reply = bondy_wamp_message:error(
                ?REGISTER,
                ReqId,
                #{},
                ?BONDY_ERROR_INTERNAL,
                [Msg]
            ),
            bondy:send(RealmUri, Ref, Reply)
    end.

%% @private
-doc """
Unregisters an RPC endpoint.
If the registration does not exist, it fails with a `no_such_registration` or
`{not_authorized, binary()}` error.
""".
-spec handle_unregister(wamp_unregister(), bondy_context:t()) ->
    ok | no_return().

handle_unregister(#unregister{} = M, Ctxt) ->
    RegId = M#unregister.registration_id,
    RealmUri = bondy_context:realm_uri(Ctxt),

    %% TODO Shouldn't we restrict this operation to the peer who registered it?
    %% and/or a Bondy Admin for revoke registration?
    case bondy_registry:lookup(registration, RealmUri, RegId) of
        {error, not_found} ->
            throw(not_found);
        {ok, Entry} ->
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

    Reply = bondy_wamp_message:unregistered(M#unregister.request_id),

    bondy:send(RealmUri, bondy_context:ref(Ctxt), Reply).

%% @private
-spec reply_error(wamp_error(), bondy_context:t()) -> ok.

reply_error(Error, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    bondy:send(RealmUri, bondy_context:ref(Ctxt), Error).

%% @private
-spec take_invocations(
    id(), wamp_message(), function(), bondy_context:t()
) ->
    {ok, bondy_context:t()}.

take_invocations(CallId, M, Fun, Ctxt) when is_function(Fun, 2) ->
    Caller = bondy_context:ref(Ctxt),
    RealmUri = bondy_context:realm_uri(Ctxt),
    Key = bondy_rpc_promise:invocation_key_pattern(
        RealmUri,
        Caller,
        CallId,
        '_',
        '_'
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

%% @private
-spec find_invocations(
    id(),
    fun((bondy_rpc_promise:t(), bondy_context:t()) -> {ok, bondy_context:t()}),
    bondy_context:t()
) -> {ok, bondy_context:t()}.

find_invocations(CallId, Fun, Ctxt) when is_function(Fun, 2) ->
    Caller = bondy_context:ref(Ctxt),
    RealmUri = bondy_context:realm_uri(Ctxt),
    Key = bondy_rpc_promise:invocation_key_pattern(
        RealmUri,
        Caller,
        CallId,
        '_',
        '_'
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

%% @private
%% CALL.Options.receive_progress is honoured only when the dealer feature
%% `progressive_call_results` is enabled and the caller announced it in
%% HELLO (which also guarantees `call_canceling`, enforced at HELLO
%% validation). Otherwise the option is removed so that no downstream path
%% — invocation details, promise marking or forwarded CALLs — can act on
%% it.
maybe_strip_receive_progress(
    #call{options = #{receive_progress := true} = Opts} = M, Ctxt
) ->
    Supported =
        is_feature_enabled(progressive_call_results) andalso
            bondy_context:is_feature_enabled(
                Ctxt, caller, progressive_call_results
            ),

    case Supported of
        true ->
            M;
        false ->
            M#call{options = maps:remove(receive_progress, Opts)}
    end;
maybe_strip_receive_progress(M, _) ->
    M.

%% @private
%% INVOCATION.Details.receive_progress reaches a callee only when that
%% callee announced `progressive_call_results`. Otherwise the flag is
%% removed here — at the node hosting the callee — and the callee replies
%% with a single final YIELD, settling the call as a plain result.
gate_receive_progress(
    #call{
        options =
            #{
                '$private' :=
                    #{
                        invocation_details :=
                            #{receive_progress := true} = Details
                    } = Private
            } = Opts
    } = M,
    CalleeSessionId
) ->
    case session_feature(CalleeSessionId, callee, progressive_call_results) of
        true ->
            M;
        false ->
            M#call{
                options = Opts#{
                    '$private' := Private#{
                        invocation_details :=
                            maps:remove(receive_progress, Details)
                    }
                }
            }
    end;
gate_receive_progress(M, _) ->
    M.

%% @private
%% The feature a session announced for a role in HELLO. Sessions are
%% looked up locally, so this must only be used for refs targeting a
%% session on this node. Any failure (no session id, session gone) reads
%% as the feature being unsupported.
session_feature(SessionId, Role, Feature) when is_binary(SessionId) ->
    try bondy_session:roles(SessionId) of
        Roles when is_map(Roles) ->
            key_value:get([Role, features, Feature], Roles, false);
        _ ->
            false
    catch
        _:_ ->
            false
    end;
session_feature(_, _, _) ->
    false.

%% @private
maybe_mark_progress(PromiseOpts, true) ->
    PromiseOpts#{receive_progress => true};
maybe_mark_progress(PromiseOpts, _) ->
    PromiseOpts.

%% @private
%% Mark a promise as the target of a progressive INPUT stream (the mirror of
%% `receive_progress` for the results side). While marked, a CALL reusing the
%% caller's request id is treated as the next argument chunk (forwarded as another
%% INVOCATION with the same invocation id) rather than a duplicate; the promise is
%% NOT settled by the final input chunk — only by the eventual RESULT/ERROR. We
%% stash the `registration_id` and the base `invocation_details` so a subsequent
%% chunk can rebuild the INVOCATION without re-choosing a callee.
maybe_mark_progressive_input(PromiseOpts, #invocation{} = Inv) ->
    case maps:get(progress, Inv#invocation.details, false) of
        true ->
            PromiseOpts#{
                progressive_input => true,
                registration_id => Inv#invocation.registration_id,
                invocation_details => Inv#invocation.details
            };
        false ->
            PromiseOpts
    end;
maybe_mark_progressive_input(PromiseOpts, _) ->
    PromiseOpts.

%% @private
%% Mark a CALL promise (the caller-node side of a remote call) as the target of
%% a progressive INPUT stream. Unlike the invocation promise there is no
%% registration_id / invocation_details to stash — the caller node never chose a
%% callee; it only re-forwards subsequent chunks to the same owner node
%% (`callee` on the promise is that node ref). The invocation promise is created
%% and marked on the owner node.
maybe_mark_progressive_call_input(PromiseOpts, #call{
    options = #{progress := true}
}) ->
    PromiseOpts#{progressive_input => true};
maybe_mark_progressive_call_input(PromiseOpts, _) ->
    PromiseOpts.

%% @private
%% Is this CALL a subsequent chunk of an in-flight progressive-input stream? A
%% CALL that reuses the caller's request id matches the open invocation promise
%% for `(Caller, CallId)`; if that promise is marked `progressive_input` it is
%% the next chunk, otherwise it is a duplicate request id on a live call (a
%% protocol violation). A fresh request id matches nothing (`none`) — the common
%% path. Single-node: the invocation promise. The caller-side call promise for a
%% remote callee is handled by the distributed increment.
find_input_stream(RealmUri, Caller, CallId) ->
    InvPattern = bondy_rpc_promise:invocation_key_pattern(
        RealmUri, Caller, CallId, '_', '_'
    ),
    case bondy_rpc_promise:find(InvPattern) of
        {ok, Promise} ->
            %% Local callee (single node) or the owner node of a remote
            %% callee: the open invocation promise is the stream target.
            classify_input_stream(invocation_chunk, Promise);
        error ->
            CallPattern = bondy_rpc_promise:call_key_pattern(
                RealmUri, Caller, CallId
            ),
            case bondy_rpc_promise:find(CallPattern) of
                {ok, Promise} ->
                    %% Caller node of a remote callee: the open call promise
                    %% re-forwards each chunk to the owner node.
                    classify_input_stream(call_chunk, Promise);
                error ->
                    none
            end
    end.

%% @private
%% A promise matched the request id. It is a stream chunk iff the promise was
%% marked `progressive_input`; otherwise the id is live on a non-progressive
%% call — a protocol violation (D1).
classify_input_stream(Kind, Promise) ->
    case bondy_rpc_promise:get(progressive_input, Promise, false) of
        true ->
            {Kind, Promise};
        false ->
            violation
    end.

%% @private
%% Forward a subsequent argument chunk as another INVOCATION to the callee
%% already handling the stream, reusing the invocation id and registration id
%% stashed on the promise at the first chunk. `progress` marks a non-final chunk;
%% the final CALL (no `progress`) yields an INVOCATION without it, so the callee
%% learns the input is complete. The promise is refreshed (inter-chunk timeout)
%% but NOT settled — the eventual RESULT/ERROR settles it.
forward_input_chunk(Msg, Promise, RealmUri, Caller) ->
    Callee = bondy_rpc_promise:callee(Promise),
    InvocationId = bondy_rpc_promise:invocation_id(Promise),
    RegId = bondy_rpc_promise:get(registration_id, Promise, undefined),
    Base = bondy_rpc_promise:get(invocation_details, Promise, #{}),
    Details =
        case maps:get(progress, Msg#call.options, false) of
            true ->
                Base#{progress => true};
            false ->
                maps:remove(progress, Base)
        end,
    Invocation = bondy_wamp_message:invocation_from(
        Msg, InvocationId, RegId, Details
    ),
    _ = bondy_rpc_promise:refresh(Promise),
    bondy:send(RealmUri, Callee, Invocation, #{from => Caller}).

%% @private
%% Caller-node counterpart of `forward_input_chunk/4` for a REMOTE callee: the
%% chunk is re-forwarded to the same owner node the first chunk was routed to
%% (`callee` on the call promise is that node ref), node-addressed with
%% `rib_completion` so the owner re-resolves it against the open invocation
%% promise (see `forward/3`). The owner rebuilds the INVOCATION from the
%% `invocation_details` it stashed on the FIRST chunk, so for a subsequent chunk
%% it consumes only `'$private'.call_id` (to match the promise) and
%% `Options.progress` (final vs not) from this message. We nonetheless re-run the
%% full `prepare_call_rib/3` — which also rebuilds those unused details — so the
%% wire envelope is identical to the first chunk (one code path, and correct if a
%% future owner ever needs the details, e.g. a retry re-selecting a callee). The
%% call promise is refreshed but NOT settled — the eventual RESULT/ERROR settles
%% it.
forward_call_chunk(Msg, Promise, RealmUri, Caller, Ctxt) ->
    NodeRef = bondy_rpc_promise:callee(Promise),
    Call = prepare_call_rib(Msg, Msg#call.procedure_uri, Ctxt),
    {To, SendOpts} = bondy:prepare_send(NodeRef, #{from => Caller}),
    _ = bondy_rpc_promise:refresh(Promise),
    bondy:send(RealmUri, To, Call, SendOpts#{rib_completion => true}).

%% @private
%% First-chunk caller gate for a progressive-input CALL. The caller is local to
%% the node running `handle_call_matched` whatever the callee's location, so this
%% fires for both local and forwarded (remote-callee) routing. Unlike the results
%% feature there is NO silent degrade — an unsupported caller is rejected, since
%% it has already begun streaming.
maybe_gate_progressive_caller(#call{options = #{progress := true}}, Ctxt) ->
    bondy_context:is_feature_enabled(Ctxt, caller, progressive_calls) orelse
        throw({progressive_calls_unsupported, caller}),
    ok;
maybe_gate_progressive_caller(_, _) ->
    ok.

%% @private
%% First-chunk callee gate for a progressive-input CALL routed to a LOCAL callee.
%% A remote/bridged callee is gated at its own node (see the client clause of
%% `forward/3`), so this only rejects when the chosen entry lives here.
maybe_gate_progressive_callee(#call{options = #{progress := true}}, Entry) ->
    Callee = bondy_registry_entry:ref(Entry),
    case bondy_ref:is_local(Callee) of
        true ->
            progressive_callee_supported(Callee) orelse
                throw({progressive_calls_unsupported, callee}),
            ok;
        false ->
            ok
    end;
maybe_gate_progressive_callee(_, _) ->
    ok.

%% @private
%% Owner-node predicate mirroring `maybe_gate_progressive_callee/2` for a callee
%% reached via `forward/3` (a remote caller). A progressive-input CALL is
%% admissible only if the local callee announced `progressive_calls`; a
%% non-progressive CALL is always admissible. Returns a boolean (not a throw)
%% because `forward/3` runs on the relay-inbound path with no caller context to
%% unwind to — the rejection is sent back explicitly.
progressive_input_admissible(#call{options = #{progress := true}}, Callee) ->
    progressive_callee_supported(Callee);
progressive_input_admissible(_, _) ->
    true.

%% @private
%% Whether a callee's negotiated session role announced `progressive_calls`. The
%% one place the "callee supports progressive input" rule lives, shared by the
%% local gate and the owner-node predicate.
progressive_callee_supported(Callee) ->
    session_feature(bondy_ref:session_id(Callee), callee, progressive_calls).

%% @private
%% Build the client-facing ERROR for a rejected progressive-input CALL. Shared
%% by the local-caller path (the `forward/2` catch clauses) and the owner-node
%% path (`reply_progressive_calls_error/3`), so both reject an unsupported peer
%% or a reused request id with one message vocabulary.
progressive_calls_error(#call{} = Msg, {unsupported, Role}) ->
    Reason = iolist_to_binary([
        "The ",
        atom_to_binary(Role, utf8),
        " does not support the progressive_calls feature."
    ]),
    bondy_wamp_message:error_from(
        Msg, #{}, ?WAMP_OPTION_NOT_ALLOWED, [Reason], #{message => Reason}
    );
progressive_calls_error(#call{} = Msg, violation) ->
    Reason = <<"A request id of an in-flight call was reused.">>,
    bondy_wamp_message:error_from(
        Msg, #{}, ?WAMP_PROTOCOL_VIOLATION, [Reason], #{message => Reason}
    ).

%% @private
%% Send a progressive-input rejection back to the caller from the callee's owner
%% node. The ERROR follows the `via` route stashed in `Opts` back to the origin
%% node, whose call promise matches it and fails the caller's call fast.
reply_progressive_calls_error(#call{} = Msg, Kind, #{from := Caller} = Opts) ->
    RealmUri = ?GET_REALM_URI(Opts),
    Error = progressive_calls_error(Msg, Kind),
    {To, SendOpts} = bondy:prepare_send(Caller, Opts),
    bondy:send(RealmUri, To, Error, SendOpts).

%% @private
%% Absolute expiry cap from the CALL.Options._deadline extension (ms from
%% now). For a progressive call the WAMP timeout is an inter-result
%% inactivity window that each progressive result restarts, so without a
%% deadline a slowly-dripping stream is unbounded; the deadline bounds the
%% whole call. Extension options pass validation untyped, so anything but
%% a usable integer means no deadline.
promise_deadline(CallOpts) ->
    case maps:get('_deadline', CallOpts, undefined) of
        D when is_integer(D) andalso D > 0 ->
            erlang:system_time(millisecond) + D;
        _ ->
            infinity
    end.

%% @private
%% A YIELD marked progressive settles nothing: the invocation promise
%% stays in place to match further YIELDs and the RESULT forwarded to the
%% caller carries Details.progress = true (call latency is observed on the
%% final settlement only). Per the WAMP spec the call timeout is, for a
%% progressive call, the limit between the call and the first result and
%% between results thereafter — so each progressive result slides the
%% promise expiry (capped by any CALL.Options._deadline).
%%
%% A progressive YIELD for a promise that was not marked receive_progress
%% is a protocol violation: the callee's session is closed and the YIELD
%% dropped (the session cleanup flushes the promise, fast-failing the
%% caller with no_eligible_callee). A callee without a local session (an
%% internal target, which cannot be closed) is demoted to a final result
%% instead.
handle_progressive_yield(M0, Key, RealmUri, Callee) ->
    case bondy_rpc_promise:find(Key) of
        {ok, Promise} ->
            case bondy_rpc_promise:get(receive_progress, Promise, false) of
                true ->
                    _ = bondy_rpc_promise:refresh(Promise),
                    send_yield_result(M0, Promise, RealmUri, Callee);
                false ->
                    handle_progressive_violation(M0, Key, RealmUri, Callee)
            end;
        error ->
            no_matching_promise(M0)
    end.

%% @private
handle_progressive_violation(M0, Key, RealmUri, Callee) ->
    ?LOG_WARNING(#{
        description =>
            "Callee sent a progressive YIELD for a call that did not "
            "request progressive results. This is a protocol violation.",
        realm_uri => RealmUri,
        callee => Callee,
        invocation_id => M0#yield.request_id
    }),

    SessionId = bondy_ref:session_id(Callee),

    Session =
        case SessionId == undefined of
            true -> {error, not_found};
            false -> bondy_session:lookup(SessionId)
        end,

    case Session of
        {ok, S} ->
            bondy_session_manager:close(S, ?WAMP_PROTOCOL_VIOLATION);
        {error, not_found} ->
            %% No closable session — demote to the final result so the
            %% caller is still answered.
            M = M0#yield{
                options = maps:remove(progress, M0#yield.options)
            },
            case bondy_rpc_promise:take(Key) of
                {ok, P} ->
                    ok = notify_call_latency(P),
                    send_yield_result(M, P, RealmUri, Callee);
                error ->
                    no_matching_promise(M)
            end
    end.

%% @private
%% Turns a YIELD into a RESULT and routes it towards the caller.
%%
%% Via might be undefined or might have been set when handling the
%% INVOCATION in forward/3 and provides the route back to the Caller i.e.
%% a pipe of relays. If the Caller is remote the RESULT will be forwarded
%% through relays and potentially bridge relays till the Caller; when it
%% arrives at the node where the Caller is connected it will match a call
%% promise. If the Caller is local, we are done (only one promise exists).
send_yield_result(M, Promise, RealmUri, Callee) ->
    Caller = bondy_rpc_promise:caller(Promise),
    CallId = bondy_rpc_promise:call_id(Promise),
    Via = bondy_rpc_promise:via(Promise),
    SendOpts0 = #{from => Callee, via => Via},
    {To, SendOpts} = bondy:prepare_send(Caller, SendOpts0),

    Result = bondy_wamp_message:result_from(
        M,
        CallId,
        %% We fwd all yield options (we know we should at least forward
        %% all ppt_* attributes in Options; progress also survives here).
        M#yield.options
    ),

    bondy:send(RealmUri, To, Result, SendOpts).

%% @private
%% Emits the latency (promise creation to first response) for a settled
%% promise, inline via telemetry (`bondy_prometheus` sinks it into
%% `bondy_wamp_call_latency_milliseconds` /
%% `bondy_wamp_invocation_latency_milliseconds`).
%%
%% A call promise measures the full CALL round trip. An invocation
%% promise measures the INVOCATION→YIELD leg (≈ callee execution +
%% transport) — and when its caller is LOCAL it is also the only promise
%% for the call, so it doubles as the call round-trip observation (a
%% remote caller's node observes call latency on its own call promise).
notify_call_latency(Promise) ->
    case bondy_rpc_promise:procedure_uri(Promise) of
        Uri when is_binary(Uri) ->
            Elapsed =
                erlang:system_time(millisecond) -
                    bondy_rpc_promise:timestamp(Promise),
            case bondy_rpc_promise:type(Promise) of
                call ->
                    bondy_telemetry:rpc_latency(call, Uri, Elapsed);
                invocation ->
                    ok = bondy_telemetry:rpc_latency(
                        invocation, Uri, Elapsed
                    ),
                    Caller = bondy_rpc_promise:caller(Promise),
                    case bondy_ref:is_local(Caller) of
                        true ->
                            bondy_telemetry:rpc_latency(call, Uri, Elapsed);
                        false ->
                            ok
                    end
            end;
        _ ->
            ok
    end.

%% =============================================================================
%% PRIVATE - CALLS AND INVOCATION STRATEGIES (LOAD BALANCING, FAIL OVER, ETC)
%% =============================================================================

%% @private
-spec handle_call(wamp_call(), bondy_context:t(), uri(), map()) -> ok.

handle_call(#call{} = Msg, Ctxt0, Uri, Opts0) ->
    RealmUri = bondy_context:realm_uri(Ctxt0),
    CallUri = Msg#call.procedure_uri,
    %% Extract caller here to avoid copying the entire Ctxt0 in Fun
    Caller = bondy_context:ref(Ctxt0),

    %% Based on procedure registration and passed options, we will
    %% determine how many invocations and to whom we should do.
    %% A response to the caller will be send asynchronously by handle_call
    %% using the following fun.
    Fun = fun(Entry, Ctxt) ->
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
                %% gather all local context and create a new Call. This new
                %% Call will include a '$private' field under 'options'.
                Call = prepare_call(Msg, Uri, Entry, Ctxt),
                {ok, Call, Ctxt};
            _ ->
                %% A local Callee. We create an invocation.
                Invocation = call_to_invocation(Msg, Uri, Entry, Ctxt),
                {ok, Invocation, Ctxt}
        end
    end,

    Opts = Opts0#{call_opts => Msg#call.options},

    handle_call(Msg, Uri, Fun, Opts, Ctxt0).

%% @private
-doc """
Used to handle calls from local callers only.
Throws `{not_authorized, binary()}`.
""".
-spec handle_call(
    wamp_call(), uri(), call_fun(), invoke_opts(), bondy_context:t()
) ->
    ok.

handle_call(Msg, ProcUri, Fun, Opts, Ctxt) when is_function(Fun, 2) ->
    CallId = Msg#call.request_id,
    RealmUri = bondy_context:realm_uri(Ctxt),
    Caller = bondy_context:ref(Ctxt),

    %% Progressive Calls: only when the dealer feature is enabled do we check
    %% whether this CALL reuses the caller's request id — i.e. is a subsequent
    %% argument chunk of an in-flight progressive-input stream. The feature is
    %% off by default, so a normal deployment pays no per-call promise lookup.
    case
        is_feature_enabled(progressive_calls) andalso
            find_input_stream(RealmUri, Caller, CallId)
    of
        {invocation_chunk, Promise} ->
            %% Local callee (or owner node): forward another INVOCATION to the
            %% same callee/invocation id; do not re-choose or create a promise.
            forward_input_chunk(Msg, Promise, RealmUri, Caller);
        {call_chunk, Promise} ->
            %% Caller node of a remote callee: re-forward the chunk to the same
            %% owner node the first chunk was routed to; do not re-run routing.
            forward_call_chunk(Msg, Promise, RealmUri, Caller, Ctxt);
        violation ->
            %% The request id is live on a NON-progressive call.
            throw({progressive_calls_violation, CallId});
        _ ->
            %% Feature off (short-circuit `false`) or no open stream (`none`):
            %% a first chunk of a stream, or a plain call.
            handle_call_matched(Msg, ProcUri, Fun, Opts, Ctxt, CallId, RealmUri)
    end.

%% @private
handle_call_matched(Msg, ProcUri, Fun, Opts, Ctxt, CallId, RealmUri) ->
    %% Progressive-input first chunk: the caller must have announced
    %% `progressive_calls` (a stream cannot be silently degraded the way
    %% progressive results can). The caller is local to this node regardless of
    %% where the callee is chosen, so gate it before routing; the callee is
    %% gated where it lives — locally below, or at its owning node for a
    %% forwarded call (see the client clause of forward/3).
    ok = maybe_gate_progressive_caller(Msg, Ctxt),

    %% choose/2 expects a match result w/continuations
    Matches = bondy_registry:find_matches(
        registration, RealmUri, ProcUri, reg_match_opts()
    ),

    Chosen = choose_rib(Matches, RealmUri, ProcUri, Opts),

    case Chosen of
        {ok, Entry} ->
            ok = maybe_gate_progressive_callee(Msg, Entry),
            do_call(CallId, ProcUri, Fun, Opts, Ctxt, Entry);
        {forward_node, Nodestring} ->
            rib_forward_call(Msg, CallId, ProcUri, Opts, Ctxt, Nodestring);
        {error, noproc} ->
            %% The matches were all dead (local process dead or remote target
            %% unreachable)
            Error =
                case format_error(no_such_procedure, Opts) of
                    undefined ->
                        bondy_wamp_api_utils:no_such_procedure_error(
                            ProcUri, ?CALL, CallId
                        );
                    Value ->
                        Value
                end,

            ok = reply_error(Error, Ctxt);
        {error, ErrorMap} when is_map(ErrorMap) ->
            %% bondy_rpc_load_balancer opts validation error
            ErrorMsg = <<
                "The request failed due to invalid option parameters."
            >>,

            ErrorOpts = maps:with(?WAMP_PPT_ATTRS, Msg#call.options),

            Error = bondy_wamp_message:error(
                ?CALL,
                CallId,
                ErrorOpts,
                ?WAMP_INVALID_ARGUMENT,
                [ErrorMsg],
                #{
                    message => ErrorMsg,
                    details => ErrorMap,
                    description => <<
                        "A required options parameter was missing in the "
                        "request or while present they were malformed."
                    >>
                }
            ),
            ok = reply_error(Error, Ctxt)
    end.

%% @private
-spec do_call(
    id(), uri(), call_fun(), invoke_opts(), bondy_context:t(), entry()
) -> ok.

do_call(CallId, ProcUri, UserFun, Opts, Ctxt0, Entry) ->
    %% We invoke the provided fun which returns a command.
    case UserFun(Entry, Ctxt0) of
        {ok, _} ->
            %% UserFun sent a response sequentially, no need
            %% for promises. This is the case for callback
            %% implemented procedures.
            ok;
        {ok, Msg, Ctxt1} ->
            RealmUri = bondy_context:realm_uri(Ctxt1),
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
                timeout => Timeout,
                deadline => promise_deadline(call_opts(SendOpts))
            },

            {Promise, SendOpts1} =
                case Msg of
                    #call{} ->
                        %% The callee is on another node or bridged
                        %% cluster so we forward the call.
                        %% We will store a local call promise,
                        %% to match the incoming forwarded RESULT |
                        %% ERROR.
                        %% The remote node will store an invocation
                        %% promise.
                        %% A receive_progress option (already caller-gated)
                        %% marks the promise so progressive RESULTs coming
                        %% back do not settle it. We store the callee so a
                        %% CANCEL (user-issued or caller-death) can be
                        %% routed to the callee's node.
                        P = bondy_rpc_promise:new_call(
                            RealmUri,
                            Caller,
                            CallId,
                            maybe_mark_progressive_call_input(
                                maybe_mark_progress(
                                    PromiseOpts#{callee => Callee},
                                    maps:get(
                                        receive_progress,
                                        Msg#call.options,
                                        false
                                    )
                                ),
                                Msg
                            )
                        ),
                        {P, maybe_rib_completion(SendOpts, Ref)};
                    #invocation{request_id = InvocationId} ->
                        %% The callee is local.
                        %% We will store an invocation promise
                        %% to match the incoming YIELD | ERROR.
                        %% The promise is marked progressive iff the flag
                        %% survived both caller- and callee-side gating into
                        %% the INVOCATION details.
                        P = bondy_rpc_promise:new_invocation(
                            RealmUri,
                            Caller,
                            CallId,
                            Callee,
                            InvocationId,
                            maybe_mark_progressive_input(
                                maybe_mark_progress(
                                    PromiseOpts,
                                    maps:get(
                                        receive_progress,
                                        Msg#invocation.details,
                                        false
                                    )
                                ),
                                Msg
                            )
                        ),
                        {P, SendOpts}
                end,

            ok = bondy_rpc_promise:add(Promise),

            ok = bondy:send(RealmUri, Callee, Msg, SendOpts1)
    end.

-doc """
Assumes `Entries` is sorted using `bondy_registry_entry:mg_comparator()`.
""".
-spec choose(
    Entries :: {[entry()], trie_continuation() | eot()} | eot(),
    CallOpts :: map()
) -> {ok, Entry :: entry()} | {error, noproc}.

choose(?EOT, _) ->
    {error, noproc};
choose({L, Cont}, CallOpts) ->
    choose(L, CallOpts, undefined, [], Cont).

-doc """
Assumes `Entries` is sorted using `bondy_registry_entry:mg_comparator()`.
""".
-spec choose(
    Entries :: [entry()],
    CallOpts :: map(),
    Group :: {Uri :: uri(), Match :: binary(), Invoke :: binary()} | undefined,
    Acc :: [entry()],
    Cont :: trie_continuation()
) ->
    {ok, Entry :: entry()} | {error, noproc | any()}.

choose([], _, _, [], ?EOT) ->
    {error, noproc};
choose([], CallOpts, _, [], Cont) ->
    choose(bondy_registry:find_matches(Cont), CallOpts);
choose([], CallOpts, {_, _, Invoke}, Acc, Cont) ->
    L = lists:reverse(Acc),
    LBOpts = lb_opts(Invoke, CallOpts),

    case bondy_rpc_load_balancer:select(L, LBOpts) of
        {ok, _} = OK ->
            OK;
        {error, noproc} ->
            choose(bondy_registry:find_matches(Cont), CallOpts);
        Error ->
            Error
    end;
choose([H | T], CallOpts, LastGroup, Acc, Cont) ->
    Uri = bondy_registry_entry:uri(H),
    Match = bondy_registry_entry:match_policy(H),
    Invoke = bondy_registry_entry:invocation_policy(H),
    Group = {Uri, Match, Invoke},

    case LastGroup == undefined orelse LastGroup == Group of
        true ->
            %% We accummulate until we find no more matches for Group
            choose(T, CallOpts, Group, [H | Acc], Cont);
        false ->
            %% All entries in Acc belong to same group, we reverse to restore
            %% the original order
            L = lists:reverse(Acc),
            LBOpts = lb_opts(Invoke, CallOpts),

            case bondy_rpc_load_balancer:select(L, LBOpts) of
                {ok, _} = OK ->
                    OK;
                {error, noproc} ->
                    %% We continue w/next group, we reset Acc
                    choose(T, CallOpts, Group, [H], Cont);
                Error ->
                    Error
            end
    end.

%% @private
-doc """
Adds support for
[Sharded Registration](https://wamp-proto.org/_static/gen/wamp_latest.html#sharded-registration)
by transforming the call runmode and rkey properties into the ones
expected by the extensions to `REGISTER.Options` in order to reuse Bondy's
`jump_consistent_hash` load balancing strategy.
""".
lb_opts(Strategy, CallOpts0) ->
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
    maps:put('_routing_key', Value, CallOpts);
coerce_routing_key(CallOpts) ->
    CallOpts.

%% @private
-doc """
We add context and metadata to the details of the CALL so that we
con forward it to a remote node or create an INVOCATION with it.
""".
prepare_call(M, Uri, Entry, Ctxt) ->
    Args = maybe_append_callback_args(M#call.args, Entry),
    Options = prepare_call_options(
        M#call.options, M#call.request_id, Uri, Entry, Ctxt
    ),
    M#call{options = Options, args = Args}.

%% @private
call_to_invocation(#call{options = #{'$private' := _}} = M, _, Entry, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    Callee = bondy_registry_entry:ref(Entry),
    CalleeSessionId = bondy_ref:session_id(Callee),
    InvocationId = bondy_message_id:session(RealmUri, CalleeSessionId),
    call_to_invocation(
        gate_receive_progress(M, CalleeSessionId), InvocationId
    );
call_to_invocation(#call{} = M, Uri, Entry, Ctxt) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    Callee = bondy_registry_entry:ref(Entry),
    CalleeSessionId = bondy_ref:session_id(Callee),
    InvocationId = bondy_message_id:session(RealmUri, CalleeSessionId),
    Call = prepare_call(M, Uri, Entry, Ctxt),
    call_to_invocation(
        gate_receive_progress(Call, CalleeSessionId), InvocationId
    ).

%% @private
call_to_invocation(#call{options = #{'$private' := Private}} = M, ReqId) ->
    RegistrationId = maps:get(registration_id, Private),
    Details = maps:get(invocation_details, Private),
    bondy_wamp_message:invocation_from(M, ReqId, RegistrationId, Details).

%% @private
-doc """
If this is a callback, then it must be a remote callback, as we should
have handled the local callback sequentially.
We add the statically defined arguments to the INVOCATION so that
we avoid the receiving node having to look the local copy of the entry
to retrieve the arguments.
""".
maybe_append_callback_args(Args0, Entry) ->
    Args = args_to_list(Args0),

    case bondy_registry_entry:is_callback(Entry) of
        true ->
            bondy_registry_entry:callback_args(Entry) ++ Args;
        false ->
            Args
    end.

%% @private
-doc """
An internal function that we use to parse and evaluate `CALL.Options`. We
use this to cache certain metadata we need to either forward the CALL
to another node and/or turn the CALL into an INVOCATION.
The resulting CALL has `Options.'$private'` field with subfields `call_id`,
`registration_id` and `invocation_details`. The latter is the map we will pass
as value to `INVOCATION.Details`.
""".
prepare_call_options(Opts, CallId, Uri, Entry, Ctxt) ->
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

    EOpts = bondy_registry_entry:options(Entry),

    %% Forward PPT attributes to INVOCATION.Details
    Details0 = maps:with(?WAMP_PPT_ATTRS, Opts),
    Details1 = Details0#{procedure => Uri, trust_level => 0},
    Details2 = maybe_receive_progress(Details1, Opts),
    Details2b = maybe_progress(Details2, Opts),
    Details3 = maybe_disclose_caller(Details2b, Ctxt, EOpts, Opts),
    Details = maybe_disclose_session(Details3, Ctxt, EOpts, Opts),

    %% We build the invocation details with local data, and store under
    %% CALL.options.'$private'
    Opts#{
        '$private' => #{
            call_id => CallId,
            registration_id => RegistrationId,
            invocation_details => Details
        }
    }.

%% @private
%% Carry a (caller-gated) receive_progress option into the INVOCATION
%% details. The callee-side gate (`gate_receive_progress/2`) runs later, at
%% the node hosting the selected callee.
maybe_receive_progress(Details, #{receive_progress := true}) ->
    Details#{receive_progress => true};
maybe_receive_progress(Details, _) ->
    Details.

%% @private
%% Carry CALL.Options.progress (a progressive-input chunk marker) into the
%% INVOCATION details. The call was already gated at `handle_call/5` (dealer +
%% caller + callee all announced `progressive_calls`), so this only runs for a
%% supported progressive call; a plain call never carries `progress`.
maybe_progress(Details, #{progress := true}) ->
    Details#{progress => true};
maybe_progress(Details, _) ->
    Details.

%% @private
%% TODO disclose info only if feature is announced by Callee, Dealer
%% and Caller
%% NOTICE: The spec defines disclose_me and disclose_caller BUT Autobhan
%% has deprecated this in favour of a router-based authrotization which is
%% unfortunate as the ideal solution should be the combination of both.
%% So for the time being we revert this to `true'.
maybe_disclose_caller(Acc, Ctxt, EOpts, Opts) ->
    Disclose =
        maps:get(disclose_caller, EOpts, true) orelse
            maps:get(disclose_me, Opts, true),

    case Disclose of
        true ->
            bondy_context:caller_details(Ctxt, Acc);
        false ->
            Acc
    end.

%% @private
maybe_disclose_session(Acc, Ctxt, #{'_disclose_session_info' := true}, _) ->
    Session = bondy_context:session(Ctxt),
    Info = bondy_session:to_external(Session),
    Acc#{'_session_info' => Info};
maybe_disclose_session(Acc, Ctxt, #{'x_disclose_session_info' := true}, _) ->
    %% To be deprecated
    Session = bondy_context:session(Ctxt),
    Info = bondy_session:to_external(Session),
    Acc#{
        'x_session_info' => Info#{
            'x_authroles' => bondy_session:authroles(Session),
            'x_meta' => key_value:get([authextra, meta], Info, #{})
        }
    };
maybe_disclose_session(Acc, _, _, _) ->
    Acc.

%% @private
call_opts(#{call_opts := Val}) -> Val;
call_opts(_) -> #{}.

%% =============================================================================
%% PRIVATE: META EVENTS
%% =============================================================================

%% @private
%% The aggregate metric is counted unconditionally (telemetry); the WAMP
%% meta-event publication is demand-gated (see bondy_meta_events).
on_register(true, Entry) ->
    ok = bondy_telemetry:registry_event(registration, created, Entry),
    bondy_meta_events:maybe_publish(created, Entry);
on_register(false, Entry) ->
    ok = bondy_telemetry:registry_event(registration, added, Entry),
    bondy_meta_events:maybe_publish(added, Entry).

%% @private
on_unregister(Entry) ->
    ok = bondy_telemetry:registry_event(registration, removed, Entry),
    bondy_meta_events:maybe_publish(removed, Entry).

%% @private
on_delete(Entry) ->
    ok = bondy_telemetry:registry_event(registration, deleted, Entry),
    bondy_meta_events:maybe_publish(deleted, Entry).

%% @private
-doc """
Replies to the caller of an in-flight invocation promise with a
`wamp.error.no_eligible_callee` ERROR. Used by `flush/2` when the callee
session dies, so callers fast-fail instead of waiting for the call
timeout. The reply is routed back through any relays stored in the
promise's `via` queue.
""".
%% @private
%% Hierarchical (RIB `read` mode) selection: the caller picks a NODE — self,
%% or a peer advertising the procedure in the stub view — and the winning
%% node completes the selection among its own live local registrations.
%% Groups (pattern × policy) are tried in match-policy precedence order,
%% mirroring `choose/2`. Remote FULL entries in the trie are deliberately
%% ignored: under `read`, remote reachability comes from the stubs alone
%% (the full-entry replication is the rollback net).
choose_rib(Matches, RealmUri, ProcUri, Opts) ->
    Entries =
        case Matches of
            ?EOT -> [];
            {L, _} -> L;
            L when is_list(L) -> L
        end,
    Locals = [E || E <- Entries, bondy_registry_entry:is_local(E)],
    StubGroups = bondy_registry_rib:match_stubs(RealmUri, ProcUri),
    try_rib_groups(rib_groups(Locals, StubGroups), RealmUri, ProcUri, Opts).

%% @private
%% Merge local entries and remote stubs into per-(pattern, policy) groups,
%% ordered by match-policy precedence (exact, then prefix most-specific
%% first, then wildcard).
rib_groups(Locals, StubGroups) ->
    M0 = lists:foldr(
        fun(E, Acc) ->
            K = {
                bondy_registry_entry:uri(E),
                bondy_registry_entry:match_policy(E)
            },
            Invoke = bondy_registry_entry:get_option(
                invoke, E, ?INVOKE_SINGLE
            ),
            maps:update_with(
                K,
                fun({Inv, Es, Ss}) -> {Inv, [E | Es], Ss} end,
                {Invoke, [E], []},
                Acc
            )
        end,
        #{},
        Locals
    ),
    M1 = lists:foldl(
        fun({Pattern, Policy, Ns}, Acc) ->
            K = {Pattern, Policy},
            Invoke =
                case Ns of
                    [{_, S} | _] -> maps:get(invoke, S, ?INVOKE_SINGLE);
                    [] -> ?INVOKE_SINGLE
                end,
            maps:update_with(
                K,
                fun({Inv, Es, _}) -> {Inv, Es, Ns} end,
                {Invoke, [], Ns},
                Acc
            )
        end,
        M0,
        StubGroups
    ),
    Keys = lists:sort(
        fun(A, B) -> rib_rank(A) =< rib_rank(B) end, maps:keys(M1)
    ),
    [{K, maps:get(K, M1)} || K <- Keys].

%% @private
rib_rank({Pattern, ?EXACT_MATCH}) -> {0, -byte_size(Pattern)};
rib_rank({Pattern, ?PREFIX_MATCH}) -> {1, -byte_size(Pattern)};
rib_rank({Pattern, _}) -> {2, -byte_size(Pattern)}.

%% @private
%% Node-stage selection per group: `self` (summarised from the group's local
%% entries) competes with the remote stub nodes; `self` winning falls into
%% the existing local load balancer, a peer winning yields a node-addressed
%% forward. A group with no live candidates falls through to the next.
try_rib_groups([], _, _, _) ->
    {error, noproc};
try_rib_groups(
    [{_K, {Invoke, LocalsG, Stubs0}} | Rest], RealmUri, ProcUri, Opts
) ->
    %% Retry exclusion: nodes that already answered a completion miss for
    %% this call are out of the candidate set (self never misses — a local
    %% win invokes directly).
    Stubs =
        case maps:get(rib_exclude, Opts, []) of
            [] ->
                Stubs0;
            Excluded ->
                [S || {N, _} = S <- Stubs0, not lists:member(N, Excluded)]
        end,
    SelfUnits =
        case LocalsG of
            [] ->
                [];
            _ ->
                Created = [bondy_registry_entry:created(E) || E <- LocalsG],
                [
                    {self, #{
                        count => length(LocalsG),
                        earliest => lists:min(Created),
                        latest => lists:max(Created)
                    }}
                ]
        end,
    LBOpts = lb_opts(Invoke, Opts),

    Result = bondy_rpc_load_balancer:select_node(
        SelfUnits ++ Stubs,
        LBOpts#{realm_uri => RealmUri, uri => ProcUri}
    ),

    case Result of
        {ok, self} ->
            case bondy_rpc_load_balancer:select(LocalsG, LBOpts) of
                {ok, _} = OK ->
                    OK;
                {error, _} ->
                    try_rib_groups(Rest, RealmUri, ProcUri, Opts)
            end;
        {ok, Nodestring} when is_binary(Nodestring) ->
            {forward_node, Nodestring};
        {error, noproc} ->
            try_rib_groups(Rest, RealmUri, ProcUri, Opts)
    end.

%% @private
%% Forward `Msg` node-addressed to `Nodestring` for owner-side completion:
%% no entry is chosen here — the call is prepared entry-less and the owner
%% binds its own selected registration (`rib_rebind/2`). The address ref
%% only carries the node; the receiving clause ignores it as a callee.
rib_forward_call(Msg, CallId, ProcUri, Opts, Ctxt, Nodestring) ->
    RealmUri = bondy_context:realm_uri(Ctxt),
    Caller = bondy_context:ref(Ctxt),
    Call = prepare_call_rib(Msg, ProcUri, Ctxt),
    Timeout = bondy_utils:timeout(call_opts(Opts)),
    %% The retry budget rides in the call promise: on a PRE-invocation miss
    %% (the owner found no live local callee) the promise's taker re-selects
    %% among the remaining candidate nodes. The prepared entry-less CALL is
    %% node-agnostic, so it is stored as-is for re-sending.
    Max = routing_max_candidates(Msg#call.options),
    Retry = #{
        call => Call,
        opts => Opts,
        tried => [Nodestring],
        remaining => Max - 1
    },
    send_rib_call(
        RealmUri,
        Caller,
        CallId,
        ProcUri,
        Call,
        Opts,
        Nodestring,
        Timeout,
        Retry
    ).

%% @private
%% Send a node-addressed entry-less CALL to `Nodestring` under a fresh call
%% promise carrying the retry state. Shared by the first send and by every
%% retry (which passes the REMAINING time as `Timeout`, so retries never
%% extend the original call deadline).
send_rib_call(
    RealmUri, Caller, CallId, ProcUri, Call, Opts, Nodestring, Timeout, Retry
) ->
    NodeRef = bondy_ref:new(internal, self(), undefined, Nodestring),
    {To, SendOpts} = bondy:prepare_send(NodeRef, Opts#{from => Caller}),

    Promise = bondy_rpc_promise:new_call(
        RealmUri,
        Caller,
        CallId,
        maybe_mark_progressive_call_input(
            maybe_mark_progress(
                #{
                    procedure_uri => ProcUri,
                    timeout => Timeout,
                    deadline => promise_deadline(Call#call.options),
                    rib_retry => Retry,
                    %% Node-addressed: the callee is whichever local
                    %% registration the owner node completes to. Address the
                    %% node so a caller CANCEL or a caller-death flush relays
                    %% there — the owner node resolves its invocation and
                    %% INTERRUPTs (see forward/3).
                    callee => NodeRef
                },
                maps:get(receive_progress, Call#call.options, false)
            ),
            Call
        )
    ),
    ok = bondy_rpc_promise:add(Promise),

    ok = bondy:send(RealmUri, To, Call, SendOpts#{rib_completion => true}).

%% @private
%% Total distinct nodes a CALL may be routed to before its failure is
%% final: the `CALL.Options._routing_max_candidates` extension (declared in
%% bondy_config's WAMP extended_options), default 2 — the original
%% candidate plus one retry. Extension options pass validation untyped, so
%% anything but a usable integer falls back to the default.
routing_max_candidates(CallOpts) ->
    case maps:get('_routing_max_candidates', CallOpts, 2) of
        N when is_integer(N) andalso N >= 1 ->
            N;
        _ ->
            2
    end.

%% @private
%% Bounded pre-invocation retry: when a node-addressed CALL comes back with
%% the owner's completion-miss error — guaranteed pre-invocation, so
%% at-most-once invocation is preserved — re-run node selection excluding
%% every node already tried, within the original call deadline and the
%% `routing_max_candidates` budget. Any other ERROR (including a
%% no_eligible_callee produced by a callee-death flush, which lacks the
%% marker because an invocation WAS in flight) is final. Returns `true`
%% iff the call was re-routed and the caller must keep waiting.
maybe_rib_retry(
    #error{
        error_uri = ?WAMP_NO_ELIGIBLE_CALLE,
        details = #{rib_completion_miss := true}
    } = M,
    Promise,
    RealmUri,
    Caller
) ->
    case bondy_rpc_promise:info(Promise) of
        #{rib_retry := #{remaining := N} = Retry} when N > 0 ->
            case promise_remaining_time(Promise) of
                0 ->
                    rib_retry_exhausted();
                Timeout ->
                    rib_retry(M, Promise, RealmUri, Caller, Retry, Timeout)
            end;
        #{rib_retry := _} ->
            %% Candidate budget spent.
            rib_retry_exhausted();
        _ ->
            %% Not a node-addressed call of ours — nothing to retry.
            false
    end;
maybe_rib_retry(_, _, _, _) ->
    false.

%% @private
rib_retry_exhausted() ->
    ok = rib_count(bondy_rpc_rib_retries_total, #{outcome => exhausted}),
    false.

%% @private
%% Record a routing metric without ever raising — this runs on the relayed
%% ERROR path, where a metrics hiccup must never cost the caller its reply.
rib_count(Name, Label) ->
    try
        bondy_metrics:counter(#{name => Name, label => Label})
    catch
        _:_ ->
            ok
    end.

%% @private
%% Milliseconds left before the original call deadline, `infinity` for an
%% unbounded call, `0` when already past it.
promise_remaining_time(Promise) ->
    case bondy_rpc_promise:expiry(Promise) of
        infinity ->
            infinity;
        Expiry when is_integer(Expiry) ->
            max(0, Expiry - erlang:system_time(millisecond))
    end.

%% @private
%% Re-select and re-route a node-addressed CALL after a completion miss.
%% Selection re-runs from a FRESH match (the local view may have learned of
%% the miss meanwhile) with the failed nodes excluded; `self` competes
%% again, so a local registration can absorb the retry — dispatched exactly
%% as owner-side completion dispatches it (the stored CALL is entry-less).
rib_retry(M, Promise, RealmUri, Caller, Retry, Timeout) ->
    #{call := Call0, opts := Opts0, tried := Tried, remaining := N} = Retry,
    CallId = M#error.request_id,
    ProcUri = bondy_rpc_promise:procedure_uri(Promise),

    %% The retried leg runs on the REMAINING time, not a fresh budget.
    Call = rib_call_with_timeout(Call0, Timeout),

    Matches = bondy_registry:find_matches(
        registration, RealmUri, ProcUri, reg_match_opts()
    ),

    case choose_rib(Matches, RealmUri, ProcUri, Opts0#{rib_exclude => Tried}) of
        {ok, Entry} ->
            ok = rib_count(bondy_rpc_rib_retries_total, #{outcome => local}),
            ok = forward(
                rib_rebind(Call, Entry),
                bondy_registry_entry:ref(Entry),
                #{realm_uri => RealmUri, from => Caller}
            ),
            true;
        {forward_node, Nodestring} ->
            ok = rib_count(bondy_rpc_rib_retries_total, #{outcome => node}),
            ok = send_rib_call(
                RealmUri,
                Caller,
                CallId,
                ProcUri,
                Call,
                Opts0,
                Nodestring,
                Timeout,
                Retry#{tried := [Nodestring | Tried], remaining := N - 1}
            ),
            true;
        {error, noproc} ->
            %% No untried candidate is left — the miss is final.
            rib_retry_exhausted()
    end.

%% @private
rib_call_with_timeout(#call{options = O} = C, Timeout) when
    is_integer(Timeout)
->
    C#call{options = O#{timeout => Timeout}};
rib_call_with_timeout(C, _) ->
    C.

%% @private
%% The completion-miss marker is routing-internal — never relay it to the
%% client.
strip_rib_details(#error{details = Details} = M) when is_map(Details) ->
    M#error{details = maps:remove(rib_completion_miss, Details)};
strip_rib_details(M) ->
    M.

%% @private
%% As `prepare_call/4` but entry-less: `registration_id => undefined` marks
%% the call node-addressed so the owner binds its own selection. Without an
%% entry there are no entry options, so caller disclosure follows the
%% defaults and entry-opted session disclosure is not available.
prepare_call_rib(M, Uri, Ctxt) ->
    Opts = M#call.options,
    Details0 = maps:with(?WAMP_PPT_ATTRS, Opts),
    Details1 = Details0#{procedure => Uri, trust_level => 0},
    Details2 = maybe_receive_progress(Details1, Opts),
    Details3 = maybe_progress(Details2, Opts),
    Details = maybe_disclose_caller(Details3, Ctxt, #{}, Opts),
    M#call{
        options = Opts#{
            '$private' => #{
                call_id => M#call.request_id,
                registration_id => undefined,
                invocation_details => Details
            }
        }
    }.

%% @private
%% Bind an entry-less node-addressed CALL to the owner-selected entry: the
%% owner's registration id replaces the `undefined` marker and, for a
%% callback entry, the statically defined arguments are appended (the caller
%% could not — it never chose an entry). An entry-addressed CALL (a sender
%% without `read` mode) passes through untouched.
rib_rebind(
    #call{options = #{'$private' := #{registration_id := undefined} = P} = O} =
        M,
    Entry
) ->
    RegId =
        case bondy_registry_entry:is_proxy(Entry) of
            true -> bondy_registry_entry:origin_id(Entry);
            false -> bondy_registry_entry:id(Entry)
        end,
    Args = maybe_append_callback_args(M#call.args, Entry),
    M#call{
        options = O#{'$private' := P#{registration_id := RegId}},
        args = Args
    };
rib_rebind(M, _) ->
    M.

%% @private
%% A forwarded cluster CALL is node-addressed: tag it so the receiving node
%% re-selects among ITS live local registrations instead of trusting this
%% node's — possibly stale — choice of entry. Bridge-relay targets keep the
%% entry-addressed contract (the edge owns its registry).
maybe_rib_completion(Opts, Ref) ->
    case
        not bondy_ref:is_local(Ref) andalso
            bondy_ref:type(Ref) =/= bridge_relay
    of
        true ->
            Opts#{rib_completion => true};
        false ->
            Opts
    end.

%% @private
%% Owner-side completion for a node-addressed forwarded CALL: select among
%% the live LOCAL registrations only. Match-policy precedence and the
%% per-group invocation-policy selection are the same as for a caller-side
%% CALL (`choose/2`); the continuation is dropped deliberately — re-fetching
%% it would reintroduce remote entries.
rib_local_callee(RealmUri, ProcUri, Msg, Opts) ->
    Matches = bondy_registry:find_matches(
        registration, RealmUri, ProcUri, reg_match_opts()
    ),
    Entries =
        case Matches of
            ?EOT -> [];
            {L, _Cont} -> L;
            L when is_list(L) -> L
        end,
    Locals = [E || E <- Entries, bondy_registry_entry:is_local(E)],
    choose({Locals, ?EOT}, Opts#{call_opts => Msg#call.options}).

%% @private
%% The registration match options a CALL routes with: all match policies
%% when pattern-based registration is enabled, exact only otherwise.
reg_match_opts() ->
    case
        bondy_config:get([wamp, dealer, features, pattern_based_registration])
    of
        true ->
            #{limit => ?MATCH_LIMIT, match => '_'};
        false ->
            #{limit => ?MATCH_LIMIT, match => ?EXACT_MATCH}
    end.

%% @private
%% A node-addressed forwarded CALL found no live local callee (a stale
%% route): return ?WAMP_NO_ELIGIBLE_CALLE to the caller node, whose call
%% promise matches the ERROR. The `rib_completion_miss` detail marks the
%% failure as PRE-invocation — no INVOCATION was dispatched — which makes
%% it the one no_eligible_callee the caller node may safely retry on
%% another candidate node. The same error produced by a callee-death flush
%% (an invocation WAS in flight) never carries the marker and is never
%% retried, preserving at-most-once invocation.
reply_no_eligible_callee(#call{} = Msg, #{from := Caller} = Opts) ->
    RealmUri = ?GET_REALM_URI(Opts),
    Reason = <<"There are no eligible callees for the procedure.">>,
    Error0 = bondy_wamp_message:error_from(
        Msg,
        #{},
        ?WAMP_NO_ELIGIBLE_CALLE,
        [Reason],
        #{
            message => Reason,
            description => <<
                "The node this call was routed to no longer has a live "
                "registration for the procedure."
            >>
        }
    ),
    %% The marker is stamped on the record AFTER construction, deliberately
    %% bypassing the details validation: it must never be part of the
    %% client-facing details vocabulary, so a client-crafted ERROR carrying
    %% it is stripped at wire decode (unknown key) and can never force a
    %% retry of a delivered invocation. Only this node-internal path can
    %% produce it; peers relay records verbatim.
    Error = Error0#error{
        details = (Error0#error.details)#{rib_completion_miss => true}
    },
    {To, SendOpts} = bondy:prepare_send(Caller, Opts),
    bondy:send(RealmUri, To, Error, SendOpts).

%% @private
%% Flush callback for promises whose caller session `Ref` died. Per the
%% WAMP spec the dealer INTERRUPTs (mode killnowait) callees still
%% servicing the departed caller's calls:
%%
%% - invocation promise → the callee is local: INTERRUPT it directly
%%   (skipped for self-calls — the callee IS the dying session — and for
%%   callees that did not announce `call_canceling`).
%% - call promise → the callee is remote (a resolved entry or, for a
%%   node-addressed RIB call, the owner node) or bridged: relay a CANCEL
%%   (mode killnowait) keyed by the call id; the callee's node resolves
%%   its invocation promise and INTERRUPTs (see forward/3). A promise
%%   without a callee cannot be routed to and simply expires.
caller_flush_fun(Ref) ->
    RefSessionId = bondy_ref:session_id(Ref),

    fun(Promise) ->
        case bondy_rpc_promise:type(Promise) of
            invocation ->
                interrupt_local_callee(Promise, RefSessionId);
            call ->
                cancel_remote_callee(Promise)
        end
    end.

%% @private
interrupt_local_callee(Promise, RefSessionId) ->
    Callee = bondy_rpc_promise:callee(Promise),
    CalleeSessionId = bondy_ref:session_id(Callee),

    Interruptible =
        CalleeSessionId =/= RefSessionId andalso
            session_feature(CalleeSessionId, callee, call_canceling),

    case Interruptible of
        true ->
            RealmUri = bondy_rpc_promise:realm_uri(Promise),
            InvocationId = bondy_rpc_promise:invocation_id(Promise),
            Caller = bondy_rpc_promise:caller(Promise),
            Via = bondy_rpc_promise:via(Promise),

            Interrupt = bondy_wamp_message:interrupt(
                InvocationId, #{mode => <<"killnowait">>}
            ),
            SendOpts0 = #{from => Caller, via => Via},
            {To, SendOpts} = bondy:prepare_send(Callee, SendOpts0),
            _ = bondy:send(RealmUri, To, Interrupt, SendOpts),
            ok;
        false ->
            ok
    end.

%% @private
cancel_remote_callee(Promise) ->
    case bondy_rpc_promise:callee(Promise) of
        undefined ->
            ok;
        Callee ->
            RealmUri = bondy_rpc_promise:realm_uri(Promise),
            CallId = bondy_rpc_promise:call_id(Promise),
            Caller = bondy_rpc_promise:caller(Promise),

            Cancel = bondy_wamp_message:cancel(
                CallId, #{mode => <<"killnowait">>}
            ),
            {To, SendOpts} = bondy:prepare_send(Callee, #{from => Caller}),
            _ = bondy:send(RealmUri, To, Cancel, SendOpts),
            ok
    end.

%% @private
send_no_eligible_callee(Promise) ->
    RealmUri = bondy_rpc_promise:realm_uri(Promise),
    Caller = bondy_rpc_promise:caller(Promise),
    Callee = bondy_rpc_promise:callee(Promise),
    CallId = bondy_rpc_promise:call_id(Promise),
    Via = bondy_rpc_promise:via(Promise),

    Msg = <<"There are no eligible callees for the procedure.">>,
    Description = <<
        "The callee handling this call became unavailable "
        "while the call was in flight."
    >>,
    Error = bondy_wamp_message:error(
        ?CALL,
        CallId,
        #{},
        ?WAMP_NO_ELIGIBLE_CALLE,
        [Msg],
        #{message => Msg, description => Description}
    ),

    SendOpts0 = #{from => Callee, via => Via},
    {To, SendOpts} = bondy:prepare_send(Caller, SendOpts0),
    _ = bondy:send(RealmUri, To, Error, SendOpts),
    ok.

%% %% @private
%% revoke(_Entry) ->
%%     If the Callee does not support registration_revocation, the Dealer may
%%     still revoke a registration to support administrative functionality. In
%%     this case, the Dealer MUST NOT send an UNREGISTERED message to the
%%     Callee. The Callee MAY use the registration meta event
%%     wamp.registration.on_unregister to determine whether a session is
%%     removed from a registration.
%%     ok.

%% %% @private
%% no_eligible_callee(call, CallId) ->
%%     Desc = <<"A call was forwarded through the router cluster for a callee that is no longer available.">>,
%%     no_eligible_callee(?CALL, CallId, Desc);

%% no_eligible_callee(invocation, CallId) ->
%%     Desc = <<"An invocation was forwarded through the router cluster to a callee that is no longer available.">>,
%%     no_eligible_callee(?INVOCATION, CallId, Desc).

%% %% @private
%% no_eligible_callee(Type, Id, Desc) ->
%%     Msg = <<
%%         "There are no elibible callees for the procedure."
%%     >>,
%%     bondy_wamp_message:error(
%%         Type,
%%         Id,
%%         #{},
%%         ?WAMP_NO_ELIGIBLE_CALLE,
%%         [Msg],
%%         #{message => Msg, description => Desc}
%%     ).

%% @private
badarity_error(CallId, Type) ->
    Msg = <<
        "The call was made passing the wrong number of positional arguments."
    >>,
    bondy_wamp_message:error(
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
    bondy_wamp_message:error(
        Type,
        CallId,
        #{},
        ?WAMP_INVALID_ARGUMENT,
        [Msg]
    ).

%% @private
not_found_error(M, _Ctxt) ->
    Msg = iolist_to_binary(
        [
            "There are no registered procedures matching the id ",
            $',
            M#unregister.registration_id,
            $'
        ]
    ),
    bondy_wamp_message:error(
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
maybe_reserved_ns(<<"com.leapsight.bondy", _/binary>>) ->
    throw({not_authorized, ?RESERVED_NS(<<"com.leapsight.bondy">>)});
maybe_reserved_ns(<<"bondy", _/binary>>) ->
    throw({not_authorized, ?RESERVED_NS(<<"bondy">>)});
maybe_reserved_ns(<<"wamp", _/binary>>) ->
    throw({not_authorized, ?RESERVED_NS(<<"wamp">>)});
maybe_reserved_ns(_) ->
    ok.
