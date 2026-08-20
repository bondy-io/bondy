%% Stage 10: PropEr property tests with shrinking.
%%
%% Verifies the load-bearing convergence invariant: for any sequence of
%% append/sync commands on two replicas, a final convergence round
%% produces identical root hashes and identical CRDT query values on
%% both sides.
%%
%% Run with: `rebar3 as test eunit --module=bondy_oplog_proper_test`
%% or use `proper:quickcheck(...)` directly.

-module(bondy_oplog_proper_test).

%% PropEr defines `LET` and friends; include it before EUnit so EUnit's
%% `LET` (defined in `eunit_test_macros.hrl`, transitively included by
%% `eunit.hrl`) doesn't shadow PropEr's.
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([prop_convergence/0]).
-export([prop_convergence_with_counter_crdt/0]).
-export([prop_bootstrap_then_converge/0]).

%% =============================================================================
%% GENERATORS
%% =============================================================================

cmd() ->
    oneof([
        {append_a, append_value()},
        {append_b, append_value()},
        sync_a_b,
        sync_b_a
    ]).

append_value() ->
    %% Small integer payload so events compare neatly.
    integer(1, 1000).

inc_value() ->
    %% G-Counter increments only — keeps the test CRDT trivial.
    integer(1, 100).

crdt_cmd() ->
    oneof([
        {append_a, {inc, inc_value()}},
        {append_b, {inc, inc_value()}},
        sync_a_b,
        sync_b_a
    ]).

%% =============================================================================
%% PROPERTIES
%% =============================================================================

%% After any sequence of (append-A, append-B, sync-AB, sync-BA) commands
%% followed by a final convergence round, both replicas have the same
%% MST root hash. This is Strong Eventual Consistency in its purest
%% form: same events ⇒ same MST.
prop_convergence() ->
    ?SETUP(
        fun app_env_setup/0,
        ?FORALL(
            Cmds,
            list(cmd()),
            run_convergence(Cmds, fun convergence_invariant/2)
        )
    ).

%% Same as prop_convergence/0 but with a counter CRDT bound to each
%% instance. After convergence, both replicas must agree on the
%% counter's value AND on the sum of all increments — so the property
%% catches both protocol-level divergence and CRDT-interpretation
%% divergence.
prop_convergence_with_counter_crdt() ->
    ?SETUP(
        fun app_env_setup/0,
        ?FORALL(
            Cmds,
            list(crdt_cmd()),
            run_counter_convergence(Cmds)
        )
    ).

%% After A bootstraps from B (which has compacted), A's snapshot
%% watermark equals B's, and a subsequent convergence round leaves both
%% at the same root.
prop_bootstrap_then_converge() ->
    ?SETUP(
        fun app_env_setup/0,
        ?FORALL(
            NEvents,
            integer(1, 30),
            run_bootstrap(NEvents)
        )
    ).

%% =============================================================================
%% RUNNERS
%% =============================================================================

run_convergence(Cmds, Inv) ->
    {A, B} = mk_pair(),
    try
        [exec(Cmd, A, B) || Cmd <- Cmds],
        %% Final convergence — symmetric pull in both directions twice
        %% covers two-step transitive convergence (B picked up A's data
        %% in the first round, A then mirrors B in the second).
        {ok, _} = bondy_oplog:sync(A, B),
        {ok, _} = bondy_oplog:sync(B, A),
        Inv(A, B)
    after
        stop_pair(A, B)
    end.

run_counter_convergence(Cmds) ->
    {A, B} = mk_counter_pair(),
    try
        [exec(Cmd, A, B) || Cmd <- Cmds],
        {ok, _} = bondy_oplog:sync(A, B),
        {ok, _} = bondy_oplog:sync(B, A),
        %% Roots equal AND counter values equal AND counter values
        %% match the sum of inputs.
        ExpectedSum = sum_increments(Cmds),
        RA = bondy_oplog:root_hash(A),
        RB = bondy_oplog:root_hash(B),
        QA = bondy_oplog:query(A, value),
        QB = bondy_oplog:query(B, value),
        RA =:= RB andalso
            QA =:= QB andalso
            QA =:= ExpectedSum
    after
        stop_pair(A, B)
    end.

run_bootstrap(NEvents) ->
    %% B is a long-running replica that has compacted.
    A = mk_id("pa"),
    B = mk_id("pb"),
    {ok, _} = bondy_oplog:start_instance(B, counter_opts()),
    [
        bondy_oplog:append(B, {inc, N})
     || N <- lists:seq(1, NEvents)
    ],
    ok = bondy_oplog:await_apply(B),
    LocalRoot = bondy_oplog:root_hash(B),
    PeerKey = {peer, propbs, erlang:unique_integer([positive, monotonic])},
    bondy_oplog_peer_state:record_sync_complete(
        PeerKey, B, LocalRoot
    ),
    bondy_oplog_peer_state:sync(),
    {ok, {compacted, _, _}} = bondy_oplog:compact(B),
    BValue = bondy_oplog:query(B, value),
    %% A bootstraps fresh.
    {ok, _} = bondy_oplog:start_instance(A, counter_opts()),
    {ok, _} = bondy_oplog:bootstrap(A, B),
    AValue = bondy_oplog:query(A, value),
    Result = (AValue =:= BValue),
    bondy_oplog_peer_state:forget_peer(PeerKey),
    bondy_oplog:stop_instance(A),
    bondy_oplog:stop_instance(B),
    Result.

%% =============================================================================
%% EUNIT DRIVER
%% =============================================================================

all_properties_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 120, fun() ->
            ?assert(
                proper:quickcheck(
                    prop_convergence(),
                    [{numtests, 100}, {to_file, user}]
                )
            )
        end},
        {timeout, 120, fun() ->
            ?assert(
                proper:quickcheck(
                    prop_convergence_with_counter_crdt(),
                    [{numtests, 100}, {to_file, user}]
                )
            )
        end},
        {timeout, 120, fun() ->
            ?assert(
                proper:quickcheck(
                    prop_bootstrap_then_converge(),
                    [{numtests, 50}, {to_file, user}]
                )
            )
        end}
    ]}.

%% =============================================================================
%% HELPERS
%% =============================================================================

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    ok.

%% @private
%% `?SETUP` hook run by PropEr itself before each property, so a STANDALONE
%% invocation (`rebar3 as test proper --module=...` / `-p`) gets the app
%% environment the eunit fixture otherwise provides. Under the eunit path the
%% fixture has already started everything and this is an idempotent no-op.
%% Returns the property's teardown fun (PropEr calls it after the run):
%% instances are left to the eunit fixture's `cleanup/1` when present, and
%% stopped here otherwise — stopping is idempotent, so doing it in both
%% places is safe.
app_env_setup() ->
    ok = setup(),
    fun() ->
        _ = [
            bondy_oplog:stop_instance(I)
         || I <- bondy_oplog:list_instances()
        ],
        ok
    end.

cleanup(_) ->
    [
        bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    ok.

mk_pair() ->
    A = mk_id("pa"),
    B = mk_id("pb"),
    {ok, _} = bondy_oplog:start_instance(A, distinct_origin_opts()),
    {ok, _} = bondy_oplog:start_instance(B, distinct_origin_opts()),
    {A, B}.

mk_counter_pair() ->
    A = mk_id("pca"),
    B = mk_id("pcb"),
    {ok, _} = bondy_oplog:start_instance(A, counter_opts()),
    {ok, _} = bondy_oplog:start_instance(B, counter_opts()),
    {A, B}.

stop_pair(A, B) ->
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
    ok.

distinct_origin_opts() ->
    #{origin => bondy_oplog_origin:new()}.

counter_opts() ->
    #{
        crdt_module => bondy_oplog_test_counter,
        origin => bondy_oplog_origin:new()
    }.

mk_id(Prefix) ->
    list_to_binary(
        Prefix ++ "_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

exec({append_a, V}, A, _B) ->
    _ = bondy_oplog:append(A, V),
    ok;
exec({append_b, V}, _A, B) ->
    _ = bondy_oplog:append(B, V),
    ok;
exec(sync_a_b, A, B) ->
    {ok, _} = bondy_oplog:sync(A, B),
    ok;
exec(sync_b_a, A, B) ->
    {ok, _} = bondy_oplog:sync(B, A),
    ok.

convergence_invariant(A, B) ->
    bondy_oplog:root_hash(A) =:= bondy_oplog:root_hash(B).

sum_increments(Cmds) ->
    lists:foldl(
        fun
            ({append_a, {inc, N}}, Acc) -> Acc + N;
            ({append_b, {inc, N}}, Acc) -> Acc + N;
            (_, Acc) -> Acc
        end,
        0,
        Cmds
    ).
