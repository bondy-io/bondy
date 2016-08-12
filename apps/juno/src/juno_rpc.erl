%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

-module(juno_rpc).
-include_lib("wamp/include/wamp.hrl").
-include("juno.hrl").

-define(DEFAULT_LIMIT, 1000).
-define(INVOCATION_QUEUE, invocations).
-define(RPC_STATE_TABLE, rpc_state).

-record(last_call, {
    key     ::  {uri(), uri()},
    value   ::  id()
}).

-export([call/6]).
-export([close_context/1]).
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
close_context(Ctxt0) ->
    %% Cleanup invocations queue
    Ctxt1 = cleanup_queue(Ctxt0),
    %% Cleanup callee role registrations
    ok = unregister_all(Ctxt1),
    Ctxt1.


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
%% Throws not_authorized
%% @end
%% -----------------------------------------------------------------------------
-spec call(id(), uri(), map(), list(), map(), juno_context:context()) -> ok.
call(ReqId, ?JUNO_USER_ADD, _Opts, _Args, _Payload, Ctxt) ->
    %% @TODO
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

call(ReqId, ?JUNO_USER_DELETE, _Opts, _Args, _Payload, Ctxt) ->
    %% @TODO
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

call(ReqId, ?JUNO_USER_LIST, _Opts, _Args, _Payload, Ctxt) ->
    %% @TODO
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

call(ReqId, ?JUNO_USER_LOOKUP, _Opts, _Args, _Payload, Ctxt) ->
    %% @TODO
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

call(ReqId, ?JUNO_USER_UPDATE, _Opts, _Args, _Payload, Ctxt) ->
    %% @TODO
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

call(ReqId, ?JUNO_GROUP_ADD, _Opts, _Args, _Payload, Ctxt) ->
    %% @TODO
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

call(ReqId, ?JUNO_GROUP_DELETE, _Opts, _Args, _Payload, Ctxt) ->
    %% @TODO
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

call(ReqId, ?JUNO_GROUP_LIST, _Opts, _Args, _Payload, Ctxt) ->
    %% @TODO
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

call(ReqId, ?JUNO_GROUP_LOOKUP, _Opts, _Args, _Payload, Ctxt) ->
    %% @TODO
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

call(ReqId, ?JUNO_GROUP_UPDATE, _Opts, _Args, _Payload, Ctxt) ->
    %% @TODO
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

call(ReqId, ?JUNO_SOURCE_ADD, _Opts, _Args, _Payload, Ctxt) ->
    %% @TODO
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

call(ReqId, ?JUNO_SOURCE_DELETE, _Opts, _Args, _Payload, Ctxt) ->
    %% @TODO
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

call(ReqId, ?JUNO_SOURCE_LIST, _Opts, _Args, _Payload, Ctxt) ->
    %% @TODO
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

call(ReqId, ?JUNO_SOURCE_LOOKUP, _Opts, _Args, _Payload, Ctxt) ->
    %% @TODO
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

call(ReqId, <<"wamp.registration.list">>, _Opts, _Args, _Payload, Ctxt) ->
    Res = #{
        <<"exact">> => [], % @TODO
        <<"prefix">> => [], % @TODO
        <<"wildcard">> => [] % @TODO
    },
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

call(ReqId, <<"wamp.registration.lookup">>, _Opts, _Args, _Payload, Ctxt) ->
    %% @TODO
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

call(ReqId, <<"wamp.registration.match">>, _Opts, _Args, _Payload, Ctxt) ->
    %% @TODO
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

call(ReqId, <<"wamp.registration.get">>, _Opts, _Args, _Payload, Ctxt) ->
    %% @TODO
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

call(
    ReqId, <<"wamp.registration.list_callees">>, _Opts, _Args, _Payload, Ctxt) ->
    %% @TODO
    Res = #{},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

call(
    ReqId, <<"wamp.registration.count_callees">>, _Opts, _Args, _Payload, Ctxt) ->
    %% @TODO
    Res = #{count => 0},
    M = wamp_message:result(ReqId, #{}, [], Res),
    juno:send(M, Ctxt);

call(ReqId, ProcUri, Opts, Args, ArgMap, Ctxt) ->
    #{session_id := SessionId} = Ctxt,
    Caller = juno_session:pid(SessionId),
    Call = #{
        caller_pid => Caller,
        session_id => SessionId,
        call_request_id => ReqId
    },
    %% TODO
    Details = #{},

    Fun = fun(Entry, Ctxt0) ->
        Id = wamp_id:new(global),
        %% We enqueue the call request i.e. a form of promise.
        {ok, Ctxt1} = enqueue(
            {Id, Caller},
            Call#{invocation_request_id => Id}, 
            timeout(Opts),
            Ctxt0
        ),
        Callee = juno_session:pid(juno_registry:session_id(Entry)),
        Callee ! wamp_message:invocation(
            Id, juno_registry:entry_id(Entry), Details, Args, ArgMap),
        {ok, Ctxt1}
    end,

    %% We asume that as with pubsub, the _Caller_ should not receive the
    %% invocation even if the _Caller_ is also a _Callee_ registered
    %% for that procedure.
    Regs = match_registrations(ProcUri, Ctxt, #{exclude => [SessionId]}),
    do_call(Regs, Fun, Ctxt).


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



%% =============================================================================
%% PRIVATE - LOAD BALANCING
%% =============================================================================


%% @private
do_call('$end_of_table', _, _) ->
    ok;

do_call({L, '$end_of_table'}, Fun, Ctxt) ->
    do_call(L, Fun, Ctxt);

do_call({L, Cont}, Fun, Ctxt) ->
    ok = do_call(Fun, L, Ctxt),
    do_call(match_registrations(Cont), Fun, Ctxt);

do_call(L, Fun, Ctxt) ->
    Triples = [{
        juno_registry:uri(E),
        maps:get(invoke, juno_registry:options(E), <<"single">>),
        E
    } || E <- L],
    do_call(Triples, undefined, Fun, Ctxt).


%% @private
do_call([], undefined, _, _) ->
    ok;

do_call([{Uri, <<"single">>, E}|T], undefined, Fun, Ctxt0) ->
    {ok, Ctxt1} = send(E, Fun, Ctxt0),
    do_call(T, {Uri, <<"single">>, []}, Fun, Ctxt1);

do_call([{Uri, <<"single">>, _}|T], {Uri, <<"single">>, _} = Last, Fun, Ctxt) ->
    %% We drop subsequent entries for same Uri.
    %% Invoke should match too, otherwise there is an inconsistency
    %% in the registry
    do_call(T, Last, Fun, Ctxt);

do_call([{Uri, Invoke, E}|T], undefined, Fun, Ctxt) ->
    do_call(T, {Uri, Invoke, [E]}, Fun, Ctxt);

do_call([{Uri, Invoke, E}|T], {Uri, Invoke, L}, Fun, Ctxt)  ->
    %% We build a list for subsequent entries for same Uri.
    %% Invoke should match too, otherwise there is an inconsistency
    %% in the registry
    do_call(T, {Uri, Invoke, [E|L]}, Fun, Ctxt);

do_call([{Uri, <<"single">>, E}|T], {_, Invoke, L}, Fun, Ctxt0) ->
    {ok, Ctxt1} = send({Invoke, L}, Fun, Ctxt0),
    {ok, Ctxt2} = send(E, Fun, Ctxt1),
    do_call(T, {Uri, <<"single">>, []}, Fun, Ctxt2);

do_call([{Uri, Invoke, E}|T], {_, Invoke, L}, Fun, Ctxt0)  ->
    {ok, Ctxt1} = send({Invoke, L}, Fun, Ctxt0),
    %% We build a list for subsequent entries for same Uri.
    do_call(T, {Uri, Invoke, [E]}, Fun, Ctxt1).


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Implements load balancing and fail over invocation strategies
%% @end
%% -----------------------------------------------------------------------------
-spec send(tuple(), function(), juno_context:context()) -> 
    {ok, juno_context:context()}.
send({<<"first">>, L}, Fun, Ctxt) ->
    send_first_available(L, Fun, Ctxt);

send({<<"last">>, L}, Fun, Ctxt) ->
    send_first_available(lists:reverse(L), Fun, Ctxt);

send({<<"random">>, L}, Fun, Ctxt) ->
    send_first_available(shuffle(L), Fun, Ctxt);

send({<<"roundrobin">>, L}, Fun, Ctxt) ->
    send_round_robin(L, Fun, Ctxt);

send(Entry, Fun, Ctxt) ->
    Fun(Entry, Ctxt).


%% @private
send_first_available([], _, Ctxt) ->
    {ok, Ctxt};

send_first_available([H|T], Fun, Ctxt) ->
    Pid = juno_session:pid(juno_registry:session_id(H)),
    case process_info(Pid) == undefined of
        true ->
            send_first_available(T, Fun, Ctxt);
        false ->
            Fun(H, Ctxt)
    end.


%% @private
-spec send_round_robin(list(), function(), juno_context:context()) -> 
    {ok, juno_context:context()}.
send_round_robin([], _, Ctxt) ->
    {ok, Ctxt};

send_round_robin([H|_] = L, Fun, Ctxt) ->
    RealmUri = juno_context:realm_uri(Ctxt),
    Uri = juno_registry:uri(H),
    send_round_robin(get_last_call(RealmUri, Uri), L, Fun, Ctxt).


%% @private
send_round_robin(_, [], _, Ctxt) ->
    {ok, Ctxt};

send_round_robin(undefined, [H|T], Fun, Ctxt) ->
    Pid = juno_session:pid(juno_registry:session_id(H)),
    case process_info(Pid) of
        undefined ->
            send_round_robin(undefined, T, Fun, Ctxt);
        _ ->
            ok = update_last_call(
                juno_context:realm_uri(Ctxt),
                juno_registry:uri(H),
                juno_registry:id(H)
            ),
            Fun(H, Ctxt)
    end;

send_round_robin(RegId, L0, Fun, Ctxt) ->
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
            send_round_robin(undefined, Pre, Fun, Ctxt);
        {Pre, [H|T]} ->
            send_round_robin(undefined, T ++ Pre ++ [H], Fun, Ctxt)
    end.


%% @private
get_last_call(RealmUri, Uri) ->
    case ets:lookup(rpc_state_table(RealmUri, Uri), {RealmUri, Uri}) of
        [] -> undefined;
        [Entry] -> Entry
    end.

update_last_call(RealmUri, Uri, Val) ->
    Entry = #last_call{key = {RealmUri, Uri}, value = Val},
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
%% PRIVATE
%% =============================================================================



%% @private
enqueue(Key, Call, Timeout, Ctxt0) ->
    Opts = #{key => Key, timeout => Timeout},
    ok = tuplespace_queue:enqueue(?INVOCATION_QUEUE, Call, Opts),
    Ctxt1 = juno_context:add_awaiting_call_id(Ctxt0, Key),
    {ok, Ctxt1}.


% @private
% dequeue(Id, Ctxt) ->
%     case tuplespace_queue:dequeue(?INVOCATION_QUEUE, #{key => Id}) of
%         empty ->
%             {ok, Ctxt};
%         Val ->
%             {ok, Val, Ctxt}
%     end.

%% @private
cleanup_queue(Ctxt) ->
    lists:foldl(
        fun(Id, Acc) ->
            ok = tuplespace_queue:remove(?INVOCATION_QUEUE, #{key => Id}),
            juno_context:remove_awaiting_call_id(Acc, Id)
        end,
        Ctxt,
        juno_context:awaiting_call_ids(Ctxt)
    ).


    


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
