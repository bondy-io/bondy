%% Stage 11: stateful PropEr model.
%%
%% Models a pair of replicas A and B as a state machine:
%%
%%   - State tracks the expected counter value at each replica.
%%   - Commands are append_a, append_b, sync_a_b, sync_b_a, compact_a,
%%     compact_b, query_a, query_b.
%%   - Postconditions verify that query commands return the model's
%%     expected value — catches divergence the moment it appears,
%%     not at the end of a long sequence.
%%
%% On failure, PropEr shrinks the command list to a minimal trace.
%% This is the diagnostic win over the stateless properties:
%% deterministic + minimal reproducer.

-module(bondy_oplog_statem_test).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([prop_replica_pair/0]).

%% PropEr statem callbacks
-export([initial_state/0]).
-export([command/1]).
-export([precondition/2]).
-export([postcondition/3]).
-export([next_state/3]).

%% Commands invoked symbolically by PropEr
-export([append_a/2]).
-export([append_b/2]).
-export([sync_a_b/2]).
-export([sync_b_a/2]).
-export([compact_a/3]).
-export([compact_b/3]).
-export([query_a/1]).
-export([query_b/1]).

%% =============================================================================
%% MODEL STATE
%% =============================================================================
%%
%% `events` :: #{event_id() => Inc :: integer()}.
%% `a_seen`, `b_seen` :: sets:set(event_id()).
%%
%% A's expected counter value = sum of Inc for ids in `a_seen`.
%% Same for B.
%%
%% No HLC / event-key modeling — those are implementation details. The
%% model only tracks "which appends each replica has observed".
%% =============================================================================

-record(model, {
    next_id = 1 :: pos_integer(),
    events = #{} :: #{pos_integer() => integer()},
    a_seen = sets:new() :: sets:set(pos_integer()),
    b_seen = sets:new() :: sets:set(pos_integer()),
    a_compacted = false :: boolean(),
    b_compacted = false :: boolean(),
    %% Live identifiers re-bound every test run (set by the property
    %% before generating commands). Symbolic in the model, real
    %% binaries at runtime.
    a = undefined :: term(),
    b = undefined :: term()
}).

%% =============================================================================
%% PROPERTY
%% =============================================================================

prop_replica_pair() ->
    ?FORALL(
        Cmds,
        more_commands(3, commands(?MODULE)),
        begin
            {A, B} = setup(),
            try
                {History, FinalState, Result} =
                    run_commands(?MODULE, Cmds, [{a, A}, {b, B}]),
                ?WHENFAIL(
                    io:format(
                        user,
                        "History: ~p~nFinalState: ~p~nResult: ~p~n",
                        [History, FinalState, Result]
                    ),
                    aggregate(command_names(Cmds), Result =:= ok)
                )
            after
                cleanup(A, B)
            end
        end
    ).

%% =============================================================================
%% PROPER STATEM CALLBACKS
%% =============================================================================

%% A and B are bound to PropEr symbolic vars; `proper_statem:run_commands/3`
%% resolves
%% them at execution time from the Env list. Commands carry these
%% vars verbatim — the model never sees the real binaries.
initial_state() ->
    #model{a = {var, a}, b = {var, b}}.

command(#model{a = A, b = B} = S) ->
    Pool = base_commands(S, A, B),
    oneof(Pool).

base_commands(S, A, B) ->
    Always = [
        {call, ?MODULE, append_a, [A, integer(1, 100)]},
        {call, ?MODULE, append_b, [B, integer(1, 100)]},
        {call, ?MODULE, sync_a_b, [A, B]},
        {call, ?MODULE, sync_b_a, [A, B]},
        {call, ?MODULE, query_a, [A]},
        {call, ?MODULE, query_b, [B]}
    ],
    Always ++ compact_commands(S, A, B).

compact_commands(#model{} = S, A, B) ->
    %% Only generate compaction when peer_state would yield a non-empty
    %% set of confirmed peer roots. Rule: A can compact after at least
    %% one sync round in either direction has happened.
    case any_sync_recorded(S) of
        false ->
            [];
        true ->
            [
                {call, ?MODULE, compact_a, [A, B, S]},
                {call, ?MODULE, compact_b, [A, B, S]}
            ]
    end.

precondition(_S, _Call) ->
    true.

postcondition(#model{} = S, {call, _M, query_a, _}, ActualValue) ->
    Expected = expected_value(S, a),
    Expected =:= ActualValue;
postcondition(#model{} = S, {call, _M, query_b, _}, ActualValue) ->
    Expected = expected_value(S, b),
    Expected =:= ActualValue;
postcondition(_S, _Call, _Result) ->
    true.

next_state(#model{} = S, _Result, {call, _, append_a, [_A, V]}) ->
    Id = S#model.next_id,
    S#model{
        next_id = Id + 1,
        events = (S#model.events)#{Id => V},
        a_seen = sets:add_element(Id, S#model.a_seen)
    };
next_state(#model{} = S, _Result, {call, _, append_b, [_B, V]}) ->
    Id = S#model.next_id,
    S#model{
        next_id = Id + 1,
        events = (S#model.events)#{Id => V},
        b_seen = sets:add_element(Id, S#model.b_seen)
    };
next_state(#model{} = S, _Result, {call, _, sync_a_b, _}) ->
    %% A pulls from B: A learns whatever B has.
    S#model{a_seen = sets:union(S#model.a_seen, S#model.b_seen)};
next_state(#model{} = S, _Result, {call, _, sync_b_a, _}) ->
    %% B pulls from A.
    S#model{b_seen = sets:union(S#model.a_seen, S#model.b_seen)};
next_state(#model{} = S, _Result, {call, _, compact_a, _}) ->
    S#model{a_compacted = true};
next_state(#model{} = S, _Result, {call, _, compact_b, _}) ->
    S#model{b_compacted = true};
next_state(S, _Result, _Call) ->
    S.

%% =============================================================================
%% COMMANDS (executed against the live system)
%% =============================================================================

append_a(A, V) ->
    _ = bondy_oplog:append(A, {inc, V}),
    ok.

append_b(B, V) ->
    _ = bondy_oplog:append(B, {inc, V}),
    ok.

sync_a_b(A, B) ->
    {ok, _} = bondy_oplog:sync(A, B),
    ok.

sync_b_a(A, B) ->
    {ok, _} = bondy_oplog:sync(B, A),
    ok.

%% Compact A. Requires a peer_state entry; we synthesise one for B.
compact_a(A, B, _S) ->
    BRoot = bondy_oplog:root_hash(B),
    case BRoot of
        undefined ->
            %% B has no events; nothing to confirm. Treat compact as
            %% no-op so the postcondition stays trivially true.
            ok;
        _ ->
            PeerKey = {peer, statem_b, A},
            bondy_oplog_peer_state:record_sync_complete(
                PeerKey, A, BRoot
            ),
            bondy_oplog_peer_state:sync(),
            _ = bondy_oplog:compact(A),
            ok
    end.

compact_b(A, B, _S) ->
    ARoot = bondy_oplog:root_hash(A),
    case ARoot of
        undefined ->
            ok;
        _ ->
            PeerKey = {peer, statem_a, B},
            bondy_oplog_peer_state:record_sync_complete(
                PeerKey, B, ARoot
            ),
            bondy_oplog_peer_state:sync(),
            _ = bondy_oplog:compact(B),
            ok
    end.

query_a(A) ->
    bondy_oplog:query(A, value).

query_b(B) ->
    bondy_oplog:query(B, value).

%% =============================================================================
%% MODEL HELPERS
%% =============================================================================

expected_value(#model{events = Events, a_seen = Seen}, a) ->
    sum_seen(Events, Seen);
expected_value(#model{events = Events, b_seen = Seen}, b) ->
    sum_seen(Events, Seen).

sum_seen(Events, Seen) ->
    sets:fold(
        fun(Id, Acc) -> Acc + maps:get(Id, Events) end,
        0,
        Seen
    ).

any_sync_recorded(#model{events = Events, a_seen = ASeen, b_seen = BSeen}) ->
    %% Heuristic: at least one event has been seen by both replicas.
    case maps:size(Events) of
        0 -> false;
        _ -> sets:size(sets:intersection(ASeen, BSeen)) > 0
    end.

%% =============================================================================
%% EUNIT DRIVER
%% =============================================================================

statem_test_() ->
    {setup, fun setup_app/0, fun cleanup_app/1, [
        {timeout, 240, fun() ->
            ?assert(
                proper:quickcheck(
                    prop_replica_pair(),
                    [{numtests, 100}, {to_file, user}]
                )
            )
        end}
    ]}.

setup_app() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

cleanup_app(_) ->
    [
        bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    %% Forget any synthetic peer-state entries we left behind.
    [
        bondy_oplog_peer_state:forget_peer({peer, statem_a, I})
     || I <- bondy_oplog:list_instances()
    ],
    [
        bondy_oplog_peer_state:forget_peer({peer, statem_b, I})
     || I <- bondy_oplog:list_instances()
    ],
    ok.

%% =============================================================================
%% PER-RUN SETUP
%% =============================================================================

setup() ->
    A = mk_id("sa"),
    B = mk_id("sb"),
    {ok, _} = bondy_oplog:start_instance(A, opts()),
    {ok, _} = bondy_oplog:start_instance(B, opts()),
    {A, B}.

cleanup(A, B) ->
    try
        bondy_oplog:stop_instance(A)
    catch
        _:_ -> ok
    end,
    try
        bondy_oplog:stop_instance(B)
    catch
        _:_ -> ok
    end,
    bondy_oplog_peer_state:forget_peer({peer, statem_a, B}),
    bondy_oplog_peer_state:forget_peer({peer, statem_b, A}),
    ok.

opts() ->
    #{
        crdt_module => bondy_oplog_test_counter,
        origin => bondy_oplog_origin:new()
    }.

mk_id(Prefix) ->
    list_to_binary(
        Prefix ++ "_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).
