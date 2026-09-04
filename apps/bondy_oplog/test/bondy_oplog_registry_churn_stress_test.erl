%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Oplog-level concurrent stress hunt for the own-root page loss (Fly s16,
%% s25: `registry/*` shards referencing pages absent from their ephemeral ETS
%% page table).
%%
%% The MST layer has been isolated and certified separately: the serialized op
%% mix is property-checked (`bondy_mst_gc_reachability_proper_test`) and the
%% concurrent topologies are pinned
%% (`bondy_mst_ets_concurrent_stress_test`), which is where three real
%% page-deleting defects were found. This module hunts the layer ABOVE, by
%% reproducing what makes a `registry/*` shard different from every other
%% instance — because the fault has only ever appeared there:
%%
%%   - fused + ephemeral + ETS backend + mem WAL (`bondy_namespace_catalog`)
%%   - `mst_retention` — a LOCAL truncate path no other namespace enables,
%%     which fires on its own cadence rather than at a peer-confirmed frontier
%%   - violent write churn (subscribe/register storms), and in both field
%%     occurrences a session CLOSE STORM at load-end
%%   - a genuine cross-process writer: `bondy_oplog_sync_session:merge_pages/2`
%%     inserts pulled pages DIRECTLY from the session process (it is
%%     capability-gated on `concurrent_writes`, which the ETS store advertises
%%     `true`), racing the instance's own compaction
%%
%% INVARIANT, asserted continuously by a dedicated watcher: the instance's own
%% root is servable (`diagnose_root`). On a violation the test reports the
%% gc-abort ring's CLASSIFICATION (`deleted` ⇒ a page a live root needs was
%% removed — store layer; `tombstoned`/`transient` ⇒ the miss came from the
%% walk), so a failure names the layer rather than merely detecting the fault.
%%
%% THE DEFECT THIS LOCKS: `put_batch/2` published a root referencing pages it
%% never copied into the receiver's store, because it built the donor tree on
%% a volatile map store and discarded it after the merge. Fixed in
%% `bondy_mst:copy_subtree/3'; the reasoning lives there.
%%
%% METHOD, load-bearing: the fault is a RACE, so a single run proves nothing
%% in either direction. `campaign/2' runs the matrix N times per cell and
%% reports FAILURE RATES — use it for every ablation, never a single run.
%% Beware also that the instrument can suppress the phenomenon: recording
%% swept hashes in `persistent_term' (a global scan per collection) dropped
%% the reproduction rate from ~45% to 7%.
%%
%% THIS MODULE IS THE REGRESSION LOCK. Four attempts to reproduce the fault at
%% the pure `bondy_mst' level failed — uniform-random, hash-ordered and
%% append-monotonic keys, and much larger receivers, all stayed green with the
%% fix reverted — so a `bondy_mst'-only test would have been vacuous coverage.
%% Until someone finds the minimal shape, this harness is the only thing that
%% catches this class. Do not weaken its oracle, and re-run it via `campaign/2'
%% when touching merge, split, truncate or the collector.
%% =============================================================================

-module(bondy_oplog_registry_churn_stress_test).

-include_lib("eunit/include/eunit.hrl").

%% ABLATION CAMPAIGN (invoked explicitly, not by the eunit gate)
-export([campaign/0]).
-export([campaign/1]).
-export([campaign/2]).
-export([default_matrix/0]).

-define(B, <<>>).
-define(DURATION_MS, 12_000).
-define(STORM_SETTLE_MS, 2_000).
-define(WRITERS, 4).
-define(KEYSPACE, 400).

%% The full-fidelity configuration: every factor present, as production has it.
faithful() ->
    #{
        inject => true,
        pin => true,
        compact => true,
        retention => true,
        storm => true,
        writers => ?WRITERS,
        duration_ms => ?DURATION_MS
    }.

%% =============================================================================
%% ENTRY POINTS
%% =============================================================================

%% The reproducer. One run of the faithful configuration, asserted.
registry_churn_test_() ->
    {timeout, 180, fun() ->
        R = run_scenario(faithful()),
        report_run(R),
        ?assertEqual([], lists:sublist(maps:get(violations, R), 3)),
        %% Any abort is the tripwire firing: the sweep refused because the
        %% root was already unservable. Even with no reader violation that is
        %% a reportable event — and its classification is the diagnosis.
        ?assertEqual(
            [],
            [
                A
             || #{classification := Cl} = A <- maps:get(aborts, R),
                Cl =/= transient
            ]
        )
    end}.

-doc """
Ablation campaign. Runs a matrix of configurations, `Reps` repetitions each,
inside a single BEAM, and reports the FAILURE RATE per cell.

This is the only sound way to attribute the fault to a factor: it fires on a
fraction of runs, so comparing single runs compares samples of a coin flip,
not configurations. Call it directly from a shell:

    rebar3 as test eunit --module=bondy_oplog_registry_churn_stress_test

runs only the assertion above; the campaign is invoked explicitly, e.g.

    bondy_oplog_registry_churn_stress_test:campaign(10).
""".
campaign() ->
    campaign(10).

campaign(Reps) ->
    campaign(Reps, default_matrix()).

campaign(Reps, Matrix) ->
    {ok, _} = application:ensure_all_started(bondy_db),
    Results = [
        {Name, tally(Name, Cfg, Reps)}
     || {Name, Cfg} <- Matrix
    ],
    report_campaign(Reps, Results),
    Results.

%% Each cell removes exactly ONE factor from the faithful configuration, so a
%% rate drop is attributable. `baseline` is the control and must be re-measured
%% in the same session as the ablations — the rate is machine- and
%% load-dependent, so a rate from an earlier session is not a valid control.
default_matrix() ->
    F = faithful(),
    [
        {baseline, F},
        {no_inject, F#{inject := false}},
        {no_pin, F#{pin := false}},
        {no_compact, F#{compact := false}},
        {no_retention, F#{retention := false}},
        {no_storm, F#{storm := false}}
    ].

tally(Name, Cfg, Reps) ->
    lists:foldl(
        fun(I, #{fired := F, runs := N} = Acc) ->
            R = run_scenario(Cfg),
            Fired = maps:get(violations, R) =/= [],
            Aborts = maps:get(aborts, R),
            ?debugFmt(
                "  ~p rep ~p/~p: ~s (~p violations, ~p gc calls, ~p aborts ~p)",
                [
                    Name,
                    I,
                    Reps,
                    case Fired of
                        true -> "FIRED";
                        false -> "clean"
                    end,
                    length(maps:get(violations, R)),
                    maps:get(gc_calls, R),
                    length(Aborts),
                    [
                        {
                            maps:get(reason, A, aborted),
                            maps:get(classification, A)
                        }
                     || A <- Aborts
                    ]
                ]
            ),
            Acc#{
                fired := F +
                    (case Fired of
                        true -> 1;
                        false -> 0
                    end),
                runs := N + 1,
                samples := [first_sample(R) | maps:get(samples, Acc)]
            }
        end,
        #{fired => 0, runs => 0, samples => []},
        lists:seq(1, Reps)
    ).

first_sample(#{violations := []}) ->
    clean;
first_sample(#{violations := Vs}) ->
    {unservable, D, Heal} = lists:last(Vs),
    maps:merge(
        maps:with(
            [missing, tombstoned, absent, live, unknown, regression, origin], D
        ),
        maps:with([healed], Heal)
    ).

%% =============================================================================
%% SCENARIO
%% =============================================================================

run_scenario(Cfg) ->
    {ok, _} = application:ensure_all_started(bondy_db),
    %% Make the collector self-check: without this a sweep that deletes a live
    %% page is indistinguishable after the fact from one that did not, because
    %% a concurrent writer can re-create a content-identical page and heal the
    %% hole before the next observation.
    ok = application:set_env(bondy_mst, verify_gc, true),
    ok = application:set_env(bondy_mst, trace_swept, true),
    ok = bondy_mst:forget_gc_aborts(),
    ok = bondy_mst:forget_swept(),
    %% The schedulers drive their own compaction/sync on live instances; this
    %% test drives both explicitly so the phases are deterministic.
    _ =
        try
            bondy_oplog_gc_scheduler:set_trigger(undefined)
        catch
            _:_ -> ok
        end,
    _ =
        try
            bondy_oplog_sync_scheduler:set_dispatch(undefined)
        catch
            _:_ -> ok
        end,

    InstId = mk_id(),
    NS = ns_of(InstId),
    {C, P} = register_shard(NS),
    {ok, _} = open_registry_like_instance(InstId, NS, Cfg),

    Ctl = ets:new(ctl, [public, set]),
    true = ets:insert(Ctl, {stop, false}),
    true = ets:insert(Ctl, {violations, []}),
    %% Count collections. "The self-check never fired" only means something if
    %% the collector actually RAN — otherwise the result is vacuous.
    true = ets:insert(Ctl, {gc_calls, 0}),
    HandlerId = {?MODULE, Ctl},
    ok = telemetry:attach(
        HandlerId,
        [bondy_mst, gc, stop],
        fun(_E, _M, _Meta, Tab) -> ets:update_counter(Tab, gc_calls, 1) end,
        Ctl
    ),

    Workers =
        [
            spawn_monitor(fun() -> writer(Ctl, InstId, N) end)
         || N <- lists:seq(1, maps:get(writers, Cfg))
        ] ++
            optional(
                maps:get(compact, Cfg),
                fun() -> compactor(Ctl, InstId) end
            ) ++
            optional(
                maps:get(inject, Cfg),
                fun() -> page_injector(Ctl, InstId, Cfg) end
            ) ++
            [spawn_monitor(fun() -> watcher(Ctl, InstId) end)],

    %% Steady churn, then the close storm both field occurrences ended in.
    timer:sleep(maps:get(duration_ms, Cfg)),
    maps:get(storm, Cfg) andalso close_storm(InstId),
    timer:sleep(?STORM_SETTLE_MS),

    true = ets:insert(Ctl, {stop, true}),
    await(Workers),

    Violations = ets:lookup_element(Ctl, violations, 2),
    Aborts = bondy_mst:gc_aborts(),
    GcCalls = ets:lookup_element(Ctl, gc_calls, 2),
    _ = telemetry:detach(HandlerId),
    ets:delete(Ctl),

    ok = bondy_oplog:stop_instance(InstId),
    close_shard(C, P),
    _ =
        try
            bondy_oplog_core_registry:unregister(NS, primary, 0)
        catch
            _:_ -> ok
        end,

    #{
        violations => Violations,
        aborts => Aborts,
        gc_calls => GcCalls,
        config => Cfg
    }.

optional(true, Fun) ->
    [spawn_monitor(Fun)];
optional(false, _) ->
    [].

%% =============================================================================
%% WORKERS
%% =============================================================================

%% Registry write churn: each writer appends cell_apply events through the
%% caller-side fast path, which is what a subscribe/register storm does.
writer(Ctl, InstId, N) ->
    rand:seed(exsss, {N, N * 7, N * 13}),
    writer_loop(Ctl, InstId).

writer_loop(Ctl, InstId) ->
    case stopped(Ctl) of
        true ->
            ok;
        false ->
            Key = key(),
            _ =
                try
                    bondy_oplog:append(
                        InstId, {cell_apply, ?B, Key, {set, seq(), Key}}
                    )
                catch
                    _:_ -> ok
                end,
            writer_loop(Ctl, InstId)
    end.

%% The instance's own compaction cycle — the ONLY sweeper, running where
%% production runs it (a call into the instance gen_server).
compactor(Ctl, InstId) ->
    case stopped(Ctl) of
        true ->
            ok;
        false ->
            _ =
                try
                    bondy_oplog_instance:compact(InstId, [])
                catch
                    _:_ -> ok
                end,
            timer:sleep(25),
            compactor(Ctl, InstId)
    end.

%% The cross-process writer that production really has: a sync session
%% inserting pulled peer pages DIRECTLY into the shared ETS store, racing the
%% compactor above. Mirrors `bondy_oplog_sync_session:merge_pages/2`'s
%% capability-gated fast path, including pinning the peer root first.
page_injector(Ctl, InstId, Cfg) ->
    case stopped(Ctl) of
        true ->
            ok;
        false ->
            %% Only lifecycle races are tolerated here — a crash in the
            %% injector itself must surface, not be swallowed into a silently
            %% ablated run.
            _ =
                try
                    inject_peer_pages(InstId, Cfg)
                catch
                    exit:{noproc, _} -> ok;
                    exit:{normal, _} -> ok
                end,
            timer:sleep(15),
            page_injector(Ctl, InstId, Cfg)
    end.

inject_peer_pages(InstId, Cfg) ->
    PeerT0 = bondy_mst:new(#{
        store => bondy_mst_ets_store,
        store_opts => #{name => <<"peer_sim">>},
        merger => fun(_K, V, V) -> V end
    }),
    try
        PeerT = lists:foldl(
            fun(_, Acc) ->
                K = bondy_oplog_event:key(
                    rand:uniform(1000000), <<"peerorigin">>, rand:uniform(1000)
                ),
                bondy_mst:put(Acc, K, 1)
            end,
            PeerT0,
            lists:seq(1, 12)
        ),
        PeerRoot = bondy_mst:root(PeerT),
        _ =
            maps:get(pin, Cfg) andalso
                try
                    bondy_oplog_instance:pin_peer_root(InstId, PeerRoot)
                catch
                    _:_ -> ok
                end,
        case bondy_oplog_registry:mst(InstId) of
            undefined ->
                ok;
            MST ->
                Pages = lists:reverse(
                    bondy_mst:fold_pages(
                        PeerT,
                        fun({_H, Pg}, Acc) -> [Pg | Acc] end,
                        [],
                        #{root => PeerRoot}
                    )
                ),
                %% Direct insert from THIS process — the production path.
                lists:foreach(
                    fun(Pg) -> {_, _} = bondy_mst:put_page(MST, Pg) end,
                    Pages
                ),
                ok
        end
    after
        try
            bondy_mst:destroy(PeerT0)
        catch
            _:_ -> ok
        end
    end.

%% The oracle. `diagnose_root` is exactly what was run by hand on the broken
%% s16 node, so a violation here IS the field signature.
watcher(Ctl, InstId) ->
    watcher(Ctl, InstId, []).

watcher(Ctl, InstId, History) ->
    case stopped(Ctl) of
        true ->
            ok;
        false ->
            History1 =
                try bondy_oplog_instance:diagnose_root(InstId) of
                    #{servable := false, root := R} = D ->
                        %% Follow the violation rather than just counting it:
                        %% the hole heals between collections, and HOW it
                        %% heals is the diagnosis.
                        %% Were the pages this root is missing ones a
                        %% collector reclaimed? If so the root was derived
                        %% from a base the collector had already moved past;
                        %% if not, they were never stored at all.
                        Swept = bondy_mst:recent_swept(),
                        Absent = maps:get(sample_absent, D, []),
                        Heal = trace_heal(InstId, D),
                        record(Ctl, {
                            unservable,
                            D#{
                                regression => regression(R, History),
                                origin =>
                                    case Absent -- Swept of
                                        Absent -> never_stored;
                                        [] -> all_swept_by_gc;
                                        _ -> partly_swept_by_gc
                                    end
                            },
                            Heal
                        }),
                        [R | History];
                    #{root := R} ->
                        [R | History];
                    _ ->
                        History
                catch
                    _:_ -> History
                end,
            timer:sleep(5),
            watcher(Ctl, InstId, History1)
    end.

%% Was this root already installed EARLIER, with a different root in between?
%% That is the signature of the instance reverting to a stale MST value: the
%% collector swept for a newer root, and the caller then went back to an older
%% one whose pages are now gone. Distinguishes that from a root the writer is
%% publishing for the first time in a damaged state.
regression(_Root, []) ->
    no_history;
regression(Root, History) ->
    case lists:member(Root, History) of
        false ->
            %% Never seen before: this root was published damaged.
            first_publication;
        true ->
            %% Seen before. If anything else was installed in between, the
            %% instance moved BACKWARD to it.
            [Latest | _] = History,
            case Latest of
                Root -> unchanged_since_last_sample;
                _ -> reverted_to_older_root
            end
    end.

%% Samples the instance until the violation clears, classifying HOW it cleared:
%%
%%   `root_advanced`  — a later root is servable while the offending root is
%%                      not. The writer moved on; the root we caught was
%%                      already superseded when we read it.
%%   `pages_returned` — the SAME root became servable. The pages were
%%                      re-inserted, which under content addressing happens
%%                      whenever an equivalent subtree is rebuilt.
%%   `persisted`      — still unservable when we gave up: real, lasting damage.
trace_heal(InstId, #{root := Root0}) ->
    trace_heal(InstId, Root0, 20).

trace_heal(_InstId, _Root0, 0) ->
    #{healed => persisted};
trace_heal(InstId, Root0, N) ->
    timer:sleep(10),
    try bondy_oplog_instance:diagnose_root(InstId) of
        #{servable := true, root := Root0} ->
            #{healed => pages_returned, after_samples => 20 - N + 1};
        #{servable := true, root := Other} ->
            #{
                healed => root_advanced,
                after_samples => 20 - N + 1,
                from => Root0,
                to => Other
            };
        _ ->
            trace_heal(InstId, Root0, N - 1)
    catch
        _:_ -> trace_heal(InstId, Root0, N - 1)
    end.

%% Mass close: the phase both field occurrences ended in. Models the session
%% close storm as a burst of removals across the keyspace.
close_storm(InstId) ->
    lists:foreach(
        fun(K) ->
            _ =
                try
                    bondy_oplog:append(
                        InstId, {cell_apply, ?B, K, {clear, seq()}}
                    )
                catch
                    _:_ -> ok
                end
        end,
        [integer_to_binary(I) || I <- lists:seq(1, ?KEYSPACE)]
    ).

%% =============================================================================
%% REPORTING
%% =============================================================================

report_run(#{violations := [], aborts := []}) ->
    ok;
report_run(#{violations := Violations, aborts := Aborts}) ->
    ?debugFmt(
        "~n=== registry churn stress ===~nviolations: ~p~ngc aborts: ~p~n",
        [lists:sublist(Violations, 3), Aborts]
    ).

report_campaign(Reps, Results) ->
    Lines = [
        io_lib:format(
            "  ~-14s ~2w/~-2w  ~5.1f%   ~p~n",
            [Name, F, N, 100.0 * F / N, dedupe_samples(S)]
        )
     || {Name, #{fired := F, runs := N, samples := S}} <- Results
    ],
    ?debugFmt(
        "~n=== ablation campaign (~p reps/cell) ===~n"
        "  ~-14s fired    rate    samples~n~s",
        [Reps, "config", Lines]
    ).

dedupe_samples(Samples) ->
    lists:usort([S || S <- Samples, S =/= clean]).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% Mirrors `bondy_namespace_catalog`'s registry namespace: fused, ephemeral,
%% ETS backend, mem WAL, plus the retention policy no other namespace enables.
open_registry_like_instance(InstId, NS, Cfg) ->
    Base = #{
        origin => bondy_oplog_origin:new(),
        fold_module => lww_register,
        backend => ets,
        wal_backend => mem,
        durability => ephemeral,
        fused => true,
        seed => true,
        applier => #{cell_apply_target => {NS, primary, 0}}
    },
    Opts =
        case maps:get(retention, Cfg) of
            true ->
                %% Aggressive on purpose: the registry's own policy is 30s/50k,
                %% which would never fire inside a test. Same code path,
                %% compressed.
                Base#{mst_retention => #{max_age_ms => 200, max_events => 150}};
            false ->
                Base
        end,
    bondy_oplog:start_instance(InstId, Opts).

await(Workers) ->
    lists:foreach(
        fun({Pid, Ref}) ->
            receive
                {'DOWN', Ref, process, Pid, _} -> ok
            after 60_000 -> exit(Pid, kill)
            end
        end,
        Workers
    ).

stopped(Ctl) ->
    try
        ets:lookup_element(Ctl, stop, 2)
    catch
        _:_ -> true
    end.

record(Ctl, V) ->
    Old = ets:lookup_element(Ctl, violations, 2),
    true = ets:insert(Ctl, {violations, [V | Old]}),
    ok.

seq() ->
    erlang:unique_integer([positive, monotonic]).

key() ->
    integer_to_binary(rand:uniform(?KEYSPACE)).

mk_id() ->
    iolist_to_binary([
        "regchurn_", integer_to_binary(erlang:unique_integer([positive]))
    ]).

ns_of(InstId) ->
    binary_to_atom(<<"ns_", InstId/binary>>, utf8).

register_shard(NS) ->
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
    {Cache, Proj}.

close_shard(Cache, Proj) ->
    try
        bondy_oplog_projection_ets:close(Proj)
    catch
        _:_ -> ok
    end,
    try
        bondy_oplog_cache_ets:close(Cache)
    catch
        _:_ -> ok
    end,
    ok.
