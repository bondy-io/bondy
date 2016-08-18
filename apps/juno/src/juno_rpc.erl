%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

-module(juno_rpc).
-include_lib("wamp/include/wamp.hrl").
-include("juno.hrl").

-define(DEFAULT_LIMIT, 1000).
-define(INVOCATION_QUEUE, juno_rpc_promise).
-define(RPC_STATE_TABLE, juno_rpc_state).

-record(last_invocation, {
    key     ::  {uri(), uri()},
    value   ::  id()
}).

-record(promise, {
    invocation_request_id   ::  id(),
    procedure_uri           ::  uri(),
    call_request_id         ::  id(),
    caller_pid              ::  pid(),
    caller_session_id       ::  id(),
    callee_pid              ::  pid(),
    callee_session_id       ::  id()
}).
-type promise() :: #promise{}.


-export([close_context/1]).
-export([dequeue_call/3]).
-export([dequeue_invocations/3]).
-export([invoke/5]).
-export([match_registrations/1]).
-export([match_registrations/2]).
-export([match_registrations/3]).
-export([register/3]).
-export([registrations/1]).
-export([registrations/2]).
-export([registrations/3]).
-export([unregister/2]).
-export([unregister_all/1]).
%% -export([callees/2]).
%% -export([count_callees/2]).
%% -export([count_registrations/2]).
%% -export([lookup_registration/2]).
%% -export([fetch_registration/2]). % wamp.registration.get




%% =============================================================================
%% API
%% =============================================================================



-spec close_context(juno_context:context()) -> juno_context:context().
close_context(Ctxt) ->
    %% Cleanup callee role registrations
    ok = unregister_all(Ctxt),
    %% Cleanup invocations queue
    cleanup_queue(Ctxt).


%% -----------------------------------------------------------------------------
%% @doc
%% Registers an RPC endpoint.
%% If the registration already exists, it fails with a
%% 'procedure_already_exists' or 'not_authorized' error.
%% @end
%% -----------------------------------------------------------------------------
-spec register(uri(), map(), juno_context:context()) -> 
    {ok, id()} | {error, not_authorized | procedure_already_exists}.
register(<<"juno.", _/binary>>, _, _) ->
    {error, not_authorized};

register(<<"wamp.", _/binary>>, _, _) ->
    {error, not_authorized};

register(ProcUri, Options, Ctxt) ->
    juno_registry:add(registration, ProcUri, Options, Ctxt).


%% -----------------------------------------------------------------------------
%% @doc
%% Unregisters an RPC endpoint.
%% If the registration does not exist, it fails with a 'no_such_registration' or
%% 'not_authorized' error.
%% @end
%% -----------------------------------------------------------------------------
-spec unregister(id(), juno_context:context()) -> 
    ok | {error, not_authorized | not_found}.
unregister(<<"juno.", _/binary>>, _) ->
    % TODO throw a different reason
    {error, not_authorized};

unregister(<<"wamp.", _/binary>>, _) ->
    % TODO throw a different reason
    {error, not_authorized};

unregister(RegId, Ctxt) ->
    %% TODO Shouldn't we restrict this operation to the peer who registered it?
    juno_registry:remove(registration, RegId, Ctxt).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec unregister_all(juno_context:context()) -> ok.
unregister_all(Ctxt) ->
    juno_registry:remove_all(registration, Ctxt).



%% -----------------------------------------------------------------------------
%% @doc
%% Returns the list of registrations for the active session.
%%
%% When called with a juno:context() it is equivalent to calling
%% registrations/2 with the RealmUri and SessionId extracted from the Context.
%% @end
%% -----------------------------------------------------------------------------
-spec registrations(juno_context:context() | juno_registry:continuation()) ->
    [juno_registry:entry()] 
    | {[juno_registry:entry()], juno_registry:continuation()}
    | '$end_of_table'. 
registrations(#{realm_uri := RealmUri, session_id := SessionId}) ->
    registrations(RealmUri, SessionId);

registrations(Cont) ->
    juno_registry:entries(Cont).



%% -----------------------------------------------------------------------------
%% @doc
%% Returns the complete list of registrations matching the RealmUri
%% and SessionId.
%%
%% Use {@link registrations/3} and {@link registrations/1} to limit the
%% number of registrations returned.
%% @end
%% -----------------------------------------------------------------------------
-spec registrations(RealmUri :: uri(), SessionId :: id()) ->
    [juno_registry:entry()].
registrations(RealmUri, SessionId) ->
    juno_registry:entries(registration, RealmUri, SessionId, infinity).


%% -----------------------------------------------------------------------------
%% @doc
%% Returns the complete list of registrations matching the RealmUri
%% and SessionId.
%%
%% Use {@link registrations/3} to limit the number of registrations returned.
%% @end
%% -----------------------------------------------------------------------------
-spec registrations(RealmUri :: uri(), SessionId :: id(), non_neg_integer()) ->
    {[juno_registry:entry()], Cont :: '$end_of_table' | term()}.
registrations(RealmUri, SessionId, Limit) ->
    juno_registry:entries(registration, RealmUri, SessionId, Limit).



%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_registrations(uri(), juno_context:context()) ->
    [juno_registry:entry()].
match_registrations(ProcUri, Ctxt) ->
    case juno_registry:match(registration, ProcUri, Ctxt) of
        {L, '$end_of_table'} -> L;
        '$end_of_table' -> []
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_registrations(uri(), juno_context:context(), map()) ->
    {[juno_registry:entry()], ets:continuation()} | '$end_of_table'.
match_registrations(ProcUri, Ctxt, Opts) ->
    juno_registry:match(registration, ProcUri, Ctxt, Opts).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec match_registrations(juno_registry:continuation()) ->
    {[juno_registry:entry()], juno_registry:continuation()} | '$end_of_table'.
match_registrations(Cont) ->
    ets:select(Cont).




%% -----------------------------------------------------------------------------
%% @doc
%% Throws not_authorized
%% @end
%% -----------------------------------------------------------------------------
-spec invoke(id(), uri(), function(), map(), juno_context:context()) -> ok.
invoke(CallId, ProcUri, UserFun, Opts, Ctxt0) when is_function(UserFun, 3) ->
    #{session_id := SessionId} = Ctxt0,
    Caller = juno_session:pid(SessionId),
    Timeout = timeout(Opts),
    %%  A promise iis used to implement a capability and a feature:
    %% - the capability to match wamp_yiled() or wamp_error() messages
    %%   to the originating wamp_call() and the Caller
    %% - call_timeout feature at the dealer level
    Template = #promise{
        procedure_uri = ProcUri, 
        call_request_id = CallId,
        caller_pid = Caller,
        caller_session_id = SessionId
    },

    Fun = fun(Entry, Ctxt1) ->
        CalleeSessionId = juno_registry:session_id(Entry),
        Callee = juno_session:pid(CalleeSessionId),
        RegId = juno_registry:entry_id(Entry),
        {ok, Id, Ctxt2} = UserFun(RegId, Callee, Ctxt1),
        Promise = Template#promise{
            invocation_request_id = Id,
            callee_session_id = CalleeSessionId,
            callee_pid = Callee
        }, 
        %% We enqueue the promise with a timeout
        ok = enqueue_promise(Id, Promise, Timeout, Ctxt2),
        {ok, Ctxt2}
    end,

    %% We asume that as with pubsub, the _Caller_ should not receive the
    %% invocation even if the _Caller_ is also a _Callee_ registered
    %% for that procedure.
    Regs = match_registrations(ProcUri, Ctxt0, #{exclude => [SessionId]}),
    do_invoke(Regs, Fun, Ctxt0).




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue_invocations(id(), function(), juno_context:context()) -> 
    {ok, juno_context:context()}.
dequeue_invocations(CallId, Fun, Ctxt) when is_function(Fun, 3) ->
    % #{session_id := SessionId} = Ctxt,
    % Caller = juno_session:pid(SessionId),

    case dequeue_promise(call_request_id, CallId, Ctxt) of
        ok ->
            %% Promises for this call were either interrupted by us, 
            %% fulfilled or timed out and garbage collected, we do nothing 
            {ok, Ctxt};
        {ok, timeout} ->
            %% Promises for this call were either interrupted by us or 
            %% timed out or caller died, we do nothing
            {ok, Ctxt};
        {ok, P} ->
            #promise{
                invocation_request_id = ReqId,
                callee_pid = Callee
            } = P,
            {ok, Ctxt1} = Fun(ReqId, Callee, Ctxt),
            %% We iterate until there are no more pending invocation for the
            %% call_request_id == CallId
            dequeue_invocations(CallId, Fun, Ctxt1)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec dequeue_call(id(), function(), juno_context:context()) -> 
    {ok, juno_context:context()}.
dequeue_call(ReqId, Fun, Ctxt) when is_function(Fun, 2) ->
    case dequeue_promise(invocation_request_id, ReqId, Ctxt) of
        ok ->
            %% Promise was fulfilled or timed out and garbage collected,
            %% we do nothing 
            ok;
        {ok, timeout} ->
            %% Promise timed out, we do nothing
            ok;
        {ok, #promise{invocation_request_id = ReqId} = P} ->
            #promise{
                call_request_id = CallId,
                caller_pid = Caller
            } = P,
            Fun(CallId, Caller)
    end.




%% =============================================================================
%% PRIVATE - INVOCATION STRATEGIES (LOAD BALANCING, FAIL OVER, ETC)
%% =============================================================================


%% @private
do_invoke('$end_of_table', _, _) ->
    ok;

do_invoke({L, '$end_of_table'}, Fun, Ctxt) ->
    do_invoke(L, Fun, Ctxt);

do_invoke({L, Cont}, Fun, Ctxt) ->
    ok = do_invoke(Fun, L, Ctxt),
    do_invoke(match_registrations(Cont), Fun, Ctxt);

do_invoke(L, Fun, Ctxt) ->
    Triples = [{
        juno_registry:uri(E),
        maps:get(invoke, juno_registry:options(E), <<"single">>),
        E
    } || E <- L],
    do_invoke(Triples, undefined, Fun, Ctxt).


%% @private
do_invoke([], undefined, _, _) ->
    ok;

do_invoke([{Uri, <<"single">>, E}|T], undefined, Fun, Ctxt0) ->
    {ok, Ctxt1} = apply_strategy(E, Fun, Ctxt0),
    do_invoke(T, {Uri, <<"single">>, []}, Fun, Ctxt1);

do_invoke(
    [{Uri, <<"single">>, _}|T], {Uri, <<"single">>, _} = Last, Fun, Ctxt) ->
    %% We drop subsequent entries for same Uri.
    %% Invoke should match too, otherwise there is an inconsistency
    %% in the registry
    do_invoke(T, Last, Fun, Ctxt);

do_invoke([{Uri, Invoke, E}|T], undefined, Fun, Ctxt) ->
    do_invoke(T, {Uri, Invoke, [E]}, Fun, Ctxt);

do_invoke([{Uri, Invoke, E}|T], {Uri, Invoke, L}, Fun, Ctxt)  ->
    %% We build a list for subsequent entries for same Uri.
    %% Invoke should match too, otherwise there is an inconsistency
    %% in the registry
    do_invoke(T, {Uri, Invoke, [E|L]}, Fun, Ctxt);

do_invoke([{Uri, <<"single">>, E}|T], {_, Invoke, L}, Fun, Ctxt0) ->
    {ok, Ctxt1} = apply_strategy({Invoke, L}, Fun, Ctxt0),
    {ok, Ctxt2} = apply_strategy(E, Fun, Ctxt1),
    do_invoke(T, {Uri, <<"single">>, []}, Fun, Ctxt2);

do_invoke([{Uri, Invoke, E}|T], {_, Invoke, L}, Fun, Ctxt0)  ->
    {ok, Ctxt1} = apply_strategy({Invoke, L}, Fun, Ctxt0),
    %% We build a list for subsequent entries for same Uri.
    do_invoke(T, {Uri, Invoke, [E]}, Fun, Ctxt1).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Implements load balancing and fail over invocation strategies
%% @end
%% -----------------------------------------------------------------------------
-spec apply_strategy(tuple(), function(), juno_context:context()) -> 
    {ok, juno_context:context()}.
apply_strategy({<<"first">>, L}, Fun, Ctxt) ->
    apply_first_available(L, Fun, Ctxt);

apply_strategy({<<"last">>, L}, Fun, Ctxt) ->
    apply_first_available(lists:reverse(L), Fun, Ctxt);

apply_strategy({<<"random">>, L}, Fun, Ctxt) ->
    apply_first_available(shuffle(L), Fun, Ctxt);

apply_strategy({<<"roundrobin">>, L}, Fun, Ctxt) ->
    apply_round_robin(L, Fun, Ctxt);

apply_strategy(Entry, Fun, Ctxt) ->
    Fun(Entry, Ctxt).


%% @private
apply_first_available([], _, Ctxt) ->
    {ok, Ctxt};

apply_first_available([H|T], Fun, Ctxt) ->
    Pid = juno_session:pid(juno_registry:session_id(H)),
    case process_info(Pid) == undefined of
        true ->
            apply_first_available(T, Fun, Ctxt);
        false ->
            Fun(H, Ctxt)
    end.


%% @private
-spec apply_round_robin(list(), function(), juno_context:context()) -> 
    {ok, juno_context:context()}.
apply_round_robin([], _, Ctxt) ->
    {ok, Ctxt};

apply_round_robin([H|_] = L, Fun, Ctxt) ->
    RealmUri = juno_context:realm_uri(Ctxt),
    Uri = juno_registry:uri(H),
    apply_round_robin(get_last_invocation(RealmUri, Uri), L, Fun, Ctxt).


%% @private
apply_round_robin(_, [], _, Ctxt) ->
    {ok, Ctxt};

apply_round_robin(undefined, [H|T], Fun, Ctxt) ->
    Pid = juno_session:pid(juno_registry:session_id(H)),
    case process_info(Pid) of
        undefined ->
            apply_round_robin(undefined, T, Fun, Ctxt);
        _ ->
            ok = update_last_invocation(
                juno_context:realm_uri(Ctxt),
                juno_registry:uri(H),
                juno_registry:id(H)
            ),
            Fun(H, Ctxt)
    end;

apply_round_robin(RegId, L0, Fun, Ctxt) ->
    Folder = fun
        (X, {PreAcc, []}) ->
            case juno_registry:id(X) of
                RegId ->
                    {RegId, PreAcc, [X]};
                _ ->
                    {RegId, [X|PreAcc], []}
            end;
        (X, {Id, PreAcc, PostAcc}) ->
            {Id, PreAcc, [X|PostAcc]}
    end,
    case lists:foldr(Folder, {[], []}, L0) of
        {Pre, []} ->
            apply_round_robin(undefined, Pre, Fun, Ctxt);
        {Pre, [H|T]} ->
            apply_round_robin(undefined, T ++ Pre ++ [H], Fun, Ctxt)
    end.


%% @private
get_last_invocation(RealmUri, Uri) ->
    case ets:lookup(rpc_state_table(RealmUri, Uri), {RealmUri, Uri}) of
        [] -> undefined;
        [Entry] -> Entry
    end.

update_last_invocation(RealmUri, Uri, Val) ->
    Entry = #last_invocation{key = {RealmUri, Uri}, value = Val},
    true = ets:insert(rpc_state_table(RealmUri, Uri), Entry),
    ok.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% A table that persists across calls and maintains the state of the load 
%% balancing of invocations 
%% @end
%% -----------------------------------------------------------------------------
rpc_state_table(RealmUri, Uri) ->
    tuplespace:locate_table(?RPC_STATE_TABLE, {RealmUri, Uri}).



%% =============================================================================
%% PRIVATE: PROMISES
%% =============================================================================



%% @private
-spec enqueue_promise(
    id(), promise(), pos_integer(), juno_context:context()) -> ok.
enqueue_promise(Id, Promise, Timeout, #{realm_uri := Uri}) ->
    #promise{call_request_id = CallId} = Promise,
    Key = {Uri, Id, CallId},
    Opts = #{key => Key, timeout => Timeout},
    tuplespace_queue:enqueue(?INVOCATION_QUEUE, Promise, Opts).


%% @private
dequeue_promise(invocation_request_id, Id, #{realm_uri := Uri}) ->
    dequeue_promise({Uri, Id, '_'});

dequeue_promise(call_request_id, Id, #{realm_uri := Uri}) ->
    dequeue_promise({Uri, '_', Id}).


%% @private
-spec dequeue_promise(tuple()) -> ok | {ok, timeout} | {ok, promise()}.
dequeue_promise(Key) ->
    case tuplespace_queue:dequeue(?INVOCATION_QUEUE, #{key => Key}) of
        empty ->
            %% The promise might have expired so we GC it.
            case tuplespace_queue:remove(?INVOCATION_QUEUE, #{key => Key}) of
                0 -> ok;
                _ -> {ok, timeout}
            end;
        Promise ->
            {ok, Promise}
    end.


%% @private
cleanup_queue(#{realm_uri := Uri, awaiting_call_ids := Set} = Ctxt) ->
    sets:fold(
        fun(Id, Acc) ->
            Key = {Uri, Id},
            ok = tuplespace_queue:remove(?INVOCATION_QUEUE, #{key => Key}),
            juno_context:remove_awaiting_call_id(Acc, Id)
        end,
        Ctxt,
        Set
    );
    
cleanup_queue(Ctxt) ->
    Ctxt.




%% =============================================================================
%% PRIVATE: UTILS
%% =============================================================================




%% @private
timeout(#{timeout := T}) when is_integer(T), T > 0 ->
    T;
timeout(#{timeout := 0}) ->
    infinity;
timeout(_) ->
    juno_config:request_timeout().


%% From https://erlangcentral.org/wiki/index.php/RandomShuffle
shuffle(List) ->
    %% Determine the log n portion then randomize the list.
    randomize(round(math:log(length(List)) + 0.5), List).


%% @private
randomize(1, List) ->
    randomize(List);
randomize(T, List) ->
    lists:foldl(
        fun(_E, Acc) -> randomize(Acc) end, 
        randomize(List), 
        lists:seq(1, (T - 1))).


%% @private
randomize(List) ->
    D = lists:map(fun(A) -> {random:uniform(), A} end, List),
    {_, D1} = lists:unzip(lists:keysort(1, D)),
    D1.
