%% Stage 10: PropEr property tests with shrinking.
%%
%% Verifies the convergence invariant: for any sequence of append/sync
%% commands on two replicas, a final convergence round produces identical
%% root hashes and identical projections on both sides.
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

%% =============================================================================
%% GENERATORS
%% =============================================================================

cmd() ->
    oneof([
        {append_a, cell_write()},
        {append_b, cell_write()},
        sync_a_b,
        sync_b_a
    ]).

%% A small key space and HLC range, so both replicas write the same cell
%% concurrently, sometimes at the same HLC.
cell_write() ->
    {integer(1, 20), integer(1, 1000)}.

%% =============================================================================
%% PROPERTIES
%% =============================================================================

%% After any sequence of (append-A, append-B, sync-AB, sync-BA) commands
%% followed by a final convergence round, both replicas have the same MST
%% root hash and the same projection, and the projection holds exactly the
%% written cells. Equal roots alone would miss a fold that diverges.
prop_convergence() ->
    ?SETUP(
        fun app_env_setup/0,
        ?FORALL(Cmds, list(cmd()), run_convergence(Cmds))
    ).

%% =============================================================================
%% RUNNERS
%% =============================================================================

run_convergence(Cmds) ->
    {A, B} = mk_pair(),
    try
        [exec(Cmd, A, B) || Cmd <- Cmds],
        %% Final convergence — symmetric pull in both directions twice
        %% covers two-step transitive convergence (B picked up A's data
        %% in the first round, A then mirrors B in the second).
        {ok, _} = bondy_oplog:sync(A, B),
        {ok, _} = bondy_oplog:sync(B, A),
        CellsA = bondy_oplog_test_projection:cells(A),
        bondy_oplog:root_hash(A) =:= bondy_oplog:root_hash(B) andalso
            CellsA =:= bondy_oplog_test_projection:cells(B) andalso
            [K || {K, _, _} <- CellsA] =:= written_keys(Cmds)
    after
        stop_pair(A, B)
    end.

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
    {ok, _} = bondy_oplog_test_projection:start_instance(
        A, distinct_origin_opts()
    ),
    {ok, _} = bondy_oplog_test_projection:start_instance(
        B, distinct_origin_opts()
    ),
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

mk_id(Prefix) ->
    list_to_binary(
        Prefix ++ "_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

exec({append_a, W}, A, _B) ->
    _ = bondy_oplog:append(A, cell_write_op(W, ~"a")),
    ok;
exec({append_b, W}, _A, B) ->
    _ = bondy_oplog:append(B, cell_write_op(W, ~"b")),
    ok;
exec(sync_a_b, A, B) ->
    {ok, _} = bondy_oplog:sync(A, B),
    ok;
exec(sync_b_a, A, B) ->
    {ok, _} = bondy_oplog:sync(B, A),
    ok.

cell_write_op({Key, Hlc}, Side) ->
    {cell_apply, <<>>, cell_key(Key), {set, Hlc, Side}}.

cell_key(Key) ->
    integer_to_binary(Key).

written_keys(Cmds) ->
    lists:usort([
        cell_key(Key)
     || {Append, {Key, _}} <- Cmds,
        Append =:= append_a orelse Append =:= append_b
    ]).
