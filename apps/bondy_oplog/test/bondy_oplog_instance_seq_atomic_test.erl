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
        {timeout, 10, fun peer_loopback_foreign_origin_does_not_bump_seq/0}
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

%% =============================================================================
%% Helpers
%% =============================================================================

synth_event(Hlc, Origin, Seq) ->
    K = bondy_oplog_event:key(Hlc, Origin, Seq),
    bondy_oplog_event:new(K, {custom, <<"synth">>}, #{}).

mk_id() ->
    iolist_to_binary([
        "seq_",
        integer_to_binary(erlang:unique_integer([positive]))
    ]).
