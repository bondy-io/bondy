%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Regression tests for the local-Seq atomic recovery on the three
%% paths that install events into a fresh / post-crash MST:
%%
%%   1. WAL-replay fast batch — `install_fast_events/2` (PR-J1).
%%   2. WAL-replay slow batch — `install_local_safe/4` via the slow
%%      branch of `install_local_batch/2` (PR-J2).
%%   3. Peer loopback — `do_append_remote/2` when a peer ships our
%%      own events back (PR-J2).
%%
%% On kill+restart, `bondy_oplog_instance:init/1` opens an empty
%% (ETS-backed) MST and seeds the SeqRef atomic from
%% `max_local_seq(MST, Origin)`. With an empty MST this returns
%% `undefined`, so SeqRef stays at 0 (or `seq_seed`).
%%
%% Pre-PR-J1, `install_fast_events/2` updated
%% `#state.max_local_installed_seq` but **not** the SeqRef atomic, so
%% a concurrent local `append_fast/3` mid-replay would allocate a
%% colliding seq for a value that already lives in the WAL.
%%
%% PR-J2 closes the same gap on the slow batch and peer-loopback
%% paths by centralising the bump in `install_event/5` (the shared
%% install hook used by both paths). The fast batch path retains its
%% end-of-batch bump for efficiency.
%% =============================================================================
-module(bondy_oplog_instance_seq_atomic_test).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

seq_atomic_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 10, fun install_local_batch_bumps_seq_atomic/0},
        {timeout, 10, fun synthetic_replay_below_current_seq_is_noop/0},
        {timeout, 10, fun peer_loopback_local_origin_bumps_seq_atomic/0},
        {timeout, 10, fun peer_loopback_foreign_origin_does_not_bump_seq/0},
        {timeout, 30, fun burned_range_is_backfilled_locally/0},
        {timeout, 30, fun fills_cross_sync_and_unpark_the_prefix_hold/0}
    ]}.

install_local_batch_bumps_seq_atomic() ->
    %% Fresh instance: SeqRef seeded to 0. Cast a synthetic batch
    %% with seqs 1..5 (mimicking a WAL replay rebuilding the MST
    %% after restart). The next `append/2` must see seq=6 — pre-fix
    %% it would see seq=1 and collide with the replayed event.
    Id = mk_id(),
    Origin = bondy_oplog_origin:default(),
    {ok, _} = bondy_oplog:start_instance(Id, #{origin => Origin}),
    Pid = bondy_oplog_registry:instance_pid(Id),

    Events = [
        synth_event(N * 10, Origin, N)
     || N <- lists:seq(1, 5)
    ],
    ok = gen_server:cast(Pid, {install_local_batch, Events}),
    ok = bondy_oplog:await_apply(Id),

    %% New local append. Pre-fix this would allocate seq=1 (the
    %% SeqRef atomic stayed at 0). Post-fix it must allocate seq=6.
    NewKey = bondy_oplog:append(Id, {custom, <<"new">>}),
    ?assertEqual(6, bondy_oplog_event:key_seq(NewKey)),

    bondy_oplog:stop_instance(Id).

peer_loopback_local_origin_bumps_seq_atomic() ->
    %% Simulate a peer shipping back an event we issued ourselves
    %% (Origin == self). Fresh instance: SeqRef seeded to 0. Drive the
    %% `install_remote` call directly with a synthetic event at
    %% seq=7. Pre-PR-J2, install_event left SeqRef at 0; the next
    %% append_fast would allocate seq=1, colliding with no event but
    %% out of order with the peer-shipped seq=7. Post-fix, the next
    %% local append must skip past the loopback seq.
    Id = mk_id(),
    Origin = bondy_oplog_origin:default(),
    {ok, _} = bondy_oplog:start_instance(Id, #{origin => Origin}),
    Pid = bondy_oplog_registry:instance_pid(Id),

    Synthetic = synth_event(70, Origin, 7),
    ok = gen_server:call(Pid, {install_remote, Synthetic}),

    NewKey = bondy_oplog:append(Id, {custom, <<"new">>}),
    ?assert(bondy_oplog_event:key_seq(NewKey) > 7),

    bondy_oplog:stop_instance(Id).

peer_loopback_foreign_origin_does_not_bump_seq() ->
    %% Symmetric check: a peer event whose Origin is NOT this instance
    %% must NOT bump our SeqRef. The fix is origin-gated and should
    %% leave foreign-origin events alone (their seq lives in the
    %% peer's own counter, not ours).
    Id = mk_id(),
    Origin = bondy_oplog_origin:default(),
    {ok, _} = bondy_oplog:start_instance(Id, #{origin => Origin}),
    Pid = bondy_oplog_registry:instance_pid(Id),

    %% Force a distinct origin so install_event takes the no-op branch.
    PeerOrigin = <<"peer_origin_for_test">>,
    true = PeerOrigin =/= Origin,
    Synthetic = synth_event(70, PeerOrigin, 42),
    ok = gen_server:call(Pid, {install_remote, Synthetic}),

    %% Next local append must still be seq=1 — foreign-origin install
    %% did not advance our counter.
    NewKey = bondy_oplog:append(Id, {custom, <<"new">>}),
    ?assertEqual(1, bondy_oplog_event:key_seq(NewKey)),
    ?assertEqual(Origin, bondy_oplog_event:key_origin(NewKey)),

    bondy_oplog:stop_instance(Id).

synthetic_replay_below_current_seq_is_noop() ->
    %% Append two local events naturally (allocate seqs 1, 2). Then
    %% cast a "replay" of seqs 1..2 again — the bump should be a
    %% no-op because the atomic is already at 2. Subsequent append
    %% must still allocate seq=3.
    Id = mk_id(),
    Origin = bondy_oplog_origin:default(),
    {ok, _} = bondy_oplog:start_instance(Id, #{origin => Origin}),
    _ = bondy_oplog:append(Id, {custom, <<"a">>}),
    _ = bondy_oplog:append(Id, {custom, <<"b">>}),
    ok = bondy_oplog:await_apply(Id),

    Pid = bondy_oplog_registry:instance_pid(Id),
    Events = [
        synth_event(N * 10, Origin, N)
     || N <- lists:seq(1, 2)
    ],
    ok = gen_server:cast(Pid, {install_local_batch, Events}),
    ok = bondy_oplog:await_apply(Id),

    NewKey = bondy_oplog:append(Id, {custom, <<"c">>}),
    ?assertEqual(3, bondy_oplog_event:key_seq(NewKey)),

    bondy_oplog:stop_instance(Id).

burned_range_is_backfilled_locally() ->
    %% A burned seq range (reserved, WAL-rejected, overtaken before it
    %% could be returned) must be backfilled with `seq_fill` no-op
    %% events: durably appended, installed into the MST, counted in the
    %% applied frontier, and absent from the projection.
    {Id, Origin, NS, Cache, Proj} = start_cell_instance(),
    [
        bondy_oplog:append(Id, {cell_apply, <<>>, key_n(N), {set, N, val_n(N)}})
     || N <- lists:seq(1, 3)
    ],
    _ = barrier(Id),
    ?assertEqual(3, maps:get(Origin, bondy_oplog_registry:frontier(Id))),

    %% Reserve the doomed range 4..5 exactly as a rejected batch would
    %% have, then land the overtaking reservation (a real append, seq 6)
    %% that makes the range unreturnable.
    #{seq := SeqRef} = bondy_oplog_registry:fast_path(Id),
    5 = atomics:add_get(SeqRef, 1, 2),
    K6 = bondy_oplog:append(
        Id, {cell_apply, <<>>, key_n(6), {set, 6, val_n(6)}}
    ),
    ?assertEqual(6, bondy_oplog_event:key_seq(K6)),

    %% Trigger the backfill through the same message the burn site
    %% (`release_seq_range/3`) sends, and watch its telemetry land.
    Self = self(),
    Ref = make_ref(),
    HandlerId = {?MODULE, Ref},
    ok = telemetry:attach(
        HandlerId,
        [bondy_oplog, instance, seq_filled],
        fun(_E, Meas, Meta, _) -> Self ! {Ref, Meas, Meta} end,
        undefined
    ),
    try
        Pid = bondy_oplog_registry:instance_pid(Id),
        ok = gen_server:cast(Pid, {fill_burned_seqs, 4, 5, 0}),
        receive
            {Ref, #{count := Count}, #{instance_id := Id}} ->
                ?assertEqual(2, Count)
        after 5000 ->
            error(seq_filled_telemetry_timeout)
        end
    after
        telemetry:detach(HandlerId)
    end,
    %% The WAL → applier → install pipeline behind the fill is async
    %% (the telemetry fires at durable append, before the drain), so
    %% wait for the install rather than barrier once.
    %%
    %% The log then carries 6 events (3 cells + overtaker + 2 fills),
    %% the frontier witnesses the whole contiguous run, and the fills
    %% left no trace in the projection.
    ok = wait_until(fun() -> bondy_oplog:size(Id) =:= 6 end),
    ok = wait_until(fun() ->
        maps:get(Origin, bondy_oplog_registry:frontier(Id), 0) =:= 6
    end),
    ?assertEqual({val_n(6), 6}, bondy_oplog_core:read(NS, primary, key_n(6))),
    stop_cell_instance(Id, NS, Cache, Proj).

fills_cross_sync_and_unpark_the_prefix_hold() ->
    %% The reason fills exist: without them a peer's prefix hold parks
    %% forever at a burned seq (4 here), capping the pulled frontier at
    %% 3 until a rebootstrap. With the fills in A's tree the peer folds
    %% a contiguous 1..6 and its frontier for A's origin reaches 6.
    {A, OriginA, NsA, CacheA, ProjA} = start_cell_instance(),
    {B, _OriginB, NsB, CacheB, ProjB} = start_cell_instance(),
    [
        bondy_oplog:append(A, {cell_apply, <<>>, key_n(N), {set, N, val_n(N)}})
     || N <- lists:seq(1, 3)
    ],
    #{seq := SeqRef} = bondy_oplog_registry:fast_path(A),
    5 = atomics:add_get(SeqRef, 1, 2),
    K6 = bondy_oplog:append(
        A, {cell_apply, <<>>, key_n(6), {set, 6, val_n(6)}}
    ),
    ?assertEqual(6, bondy_oplog_event:key_seq(K6)),
    PidA = bondy_oplog_registry:instance_pid(A),
    ok = gen_server:cast(PidA, {fill_burned_seqs, 4, 5, 0}),
    ok = wait_until(fun() -> bondy_oplog:size(A) =:= 6 end),

    %% B pulls A's whole tree; the fold runs under the shipped default
    %% (prefix_hold on).
    {ok, _} = bondy_oplog:sync(B, A),
    _ = barrier(B),
    ?assertEqual(6, maps:get(OriginA, bondy_oplog_registry:frontier(B))),
    ?assertEqual({val_n(3), 3}, bondy_oplog_core:read(NsB, primary, key_n(3))),
    stop_cell_instance(A, NsA, CacheA, ProjA),
    stop_cell_instance(B, NsB, CacheB, ProjB).

%% =============================================================================
%% Helpers
%% =============================================================================

synth_event(Hlc, Origin, Seq) ->
    K = bondy_oplog_event:key(Hlc, Origin, Seq),
    bondy_oplog_event:new(K, {custom, <<"synth">>}, #{}).

key_n(N) ->
    <<"k", (integer_to_binary(N))/binary>>.

val_n(N) ->
    <<"v", (integer_to_binary(N))/binary>>.

%% A cell-apply instance over a fresh `(NS, primary, 0)` ETS shard with
%% its own origin — the applied frontier is only tracked on the
%% cell-apply paths, which the seq-fill tests assert against.
start_cell_instance() ->
    Id = mk_id(),
    NS = binary_to_atom(<<"ns_", Id/binary>>, utf8),
    Origin = bondy_oplog_origin:new(),
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
    {ok, Proj} = bondy_oplog_projection_ets:open(NS, primary, 0, #{}),
    ok = bondy_oplog_core_registry:register(NS, primary, 0, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => bondy_oplog_projection_ets,
        projection_handle => Proj,
        fold_module => lww_register,
        overlay => disabled
    }),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        origin => Origin,
        fold_module => lww_register,
        applier => #{cell_apply_target => {NS, primary, 0}}
    }),
    {Id, Origin, NS, Cache, Proj}.

stop_cell_instance(Id, NS, Cache, Proj) ->
    ok = bondy_oplog:stop_instance(Id),
    ok = bondy_oplog_core_registry:unregister(NS, primary, 0),
    ok = bondy_oplog_projection_ets:close(Proj),
    ok = bondy_oplog_cache_ets:close(Cache),
    ok.

%% Synchronous barrier through the applier mailbox (see the identical
%% helper in `bondy_oplog_applier_cell_apply_test`).
barrier(Id) ->
    bondy_oplog:projection(Id).

%% Polls `Fun` until true, 50ms steps, 5s deadline. The seq-fill
%% pipeline is asynchronous end to end (cast -> WAL append -> applier
%% drain -> MST install), so single-shot barriers can overtake it.
wait_until(Fun) ->
    wait_until(Fun, 100).

wait_until(_Fun, 0) ->
    error(wait_until_timeout);
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_until(Fun, N - 1)
    end.

mk_id() ->
    iolist_to_binary([
        "seq_",
        integer_to_binary(erlang:unique_integer([positive]))
    ]).
