%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_registry_rib_restart_SUITE).

-compile([nowarn_export_all, export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bondy_db_tables.hrl").

%% =============================================================================
%% WHAT THIS LOCKS
%% =============================================================================
%%
%% `bondy_registry_rib:check/1' compares the node set derivable from ground
%% truth (this node's members table plus its stub store) against the one
%% derivable from the RIB summary cells in its local projection. `[]' is the
%% precondition for routing on summaries.
%%
%% THE INVARIANT: a node that rejoins with an EMPTY local projection, inside
%% an otherwise QUIET cluster, converges back to `check/1 == []'.
%%
%% TRAP — `check/1 == []' IS VACUOUSLY TRUE ON AN EMPTY PROJECTION. With no
%% cells and no stubs nothing can disagree, so a wait on it returns at once
%% and the case passes having asserted nothing. Measured: an early version
%% passed 3/3 with the node wiped, while the companion case proved no merge
%% event had fired at all. Every assertion here therefore waits for cells to
%% be INSTALLED first (`wait_rib_cells/2').
%%
%% TRAP — DO NOT FORCE A SYNC in the post-restart wait. Triggering the sync
%% scheduler would MANUFACTURE the merge events whose absence is the
%% hypothesis, turning a real defect into a green test. The settle loop polls
%% only and lets the cluster run its ordinary AAE cadence.
%%
%% Both RIB tables are `durability => ephemeral', so a restart empties the
%% projection completely and the cells are re-acquired from the peer. Both
%% repair paths — the stub store and `self_heal/4' — are driven by AAE merge
%% events alone, and the catalogue-snapshot bootstrap a fresh replica takes
%% emits none. That is the defect this suite exists to falsify. It is not
%% RIB-specific: the same install path serves every `publish => true' table,
%% but the RIB is where it bites, because its reaction BUILDS the only copy
%% of the stub view rather than invalidating a cache. See
%% `publish_hook_fires_for_bootstrap_installed_cells/1'.
%%
%% ON FAILURE the divergence terms are reported verbatim as
%% `{{Type, Policy, Uri}, #{full_entries := E, rib := A}}'; `A' names the
%% mechanism — the PEER's nodestring means the stub store was never rebuilt,
%% THIS node's means `self_heal/4' never ran on its own resurrected cells.

-define(REALM, <<"com.bondy.rib_restart">>).
-define(PROC_1, <<"com.bondy.rib_restart.proc.one">>).
-define(PROC_2, <<"com.bondy.rib_restart.proc.two">>).
-define(TOPIC_1, <<"com.bondy.rib_restart.topic.one">>).
-define(TOPIC_2, <<"com.bondy.rib_restart.topic.two">>).

%% Peer ports and node NAMES must be unique across the whole CT run: ports
%% collide, and two suites sharing a peer name share its data directory.
-define(N1_PEER_PORT, 18196).
-define(N2_PEER_PORT, 18197).
-define(N1_NAME, bondy_ribrestart1).
-define(N2_NAME, bondy_ribrestart2).
%% `restart_node/4' needs the node's ORIGINAL index from `start_cluster/2'
%% (it selects the port block) and its ORIGINAL ExtraEnv.
-define(N2_IDX, 2).

%% Second case: its own names/ports so it cannot share a data directory with
%% the first.
-define(B1_NAME, bondy_ribboot1).
-define(B2_NAME, bondy_ribboot2).
-define(B1_PEER_PORT, 18198).
-define(B2_PEER_PORT, 18199).
-define(B2_IDX, 2).
-define(BOOT_REALM, <<"com.bondy.rib_restart.boot">>).
-define(PLAIN_REALM, <<"com.bondy.rib_restart.plain">>).
-define(P1_NAME, bondy_ribplain1).
-define(P2_NAME, bondy_ribplain2).
-define(P1_PEER_PORT, 18200).
-define(P2_PEER_PORT, 18201).
-define(P2_IDX, 2).
-define(BOOT_GROUP, <<"rib_restart_boot_group">>).
-define(PROBE, bondy_rib_restart_probe).

-define(CONVERGE_MS, 120000).
%% Post-restart settle budget. Must comfortably exceed several AAE rounds so
%% a green result means "the cluster really did repair itself", not "we did
%% not wait long enough".
-define(SETTLE_MS, 90000).

all() ->
    [
        rib_consistent_after_node_rebuild,
        rib_consistent_after_plain_restart,
        publish_hook_fires_for_bootstrap_installed_cells
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

%% =============================================================================
%% TEST CASE
%% =============================================================================

rib_consistent_after_node_rebuild(Config) ->
    N2Env = [{[partisan, peer_port], ?N2_PEER_PORT}],
    Names = [
        {?N1_NAME, [{[partisan, peer_port], ?N1_PEER_PORT}]},
        {?N2_NAME, N2Env}
    ],
    Nodes = bondy_ct:start_cluster(Names, Config),
    [S1, S2] = Nodes,
    {_, N1, _} = S1,
    {_, N2, _} = S2,

    try
        _ = [push_module(N, ?MODULE) || N <- [N1, N2]],

        ok = erpc:call(N1, ?MODULE, do_create_realm, [?REALM]),
        ok = wait_realm(N2, ?REALM),

        Node1Str = erpc:call(N1, bondy_config, nodestring, []),
        Node2Str = erpc:call(N2, bondy_config, nodestring, []),

        %% Entries on BOTH nodes: each must then carry a stub for the other,
        %% so the restart exercises the peer-cell path AND the own-cell path.
        ok = erpc:call(N1, ?MODULE, do_register, [?REALM, ?PROC_1]),
        ok = erpc:call(N1, ?MODULE, do_subscribe, [?REALM, ?TOPIC_1]),
        ok = erpc:call(N2, ?MODULE, do_register, [?REALM, ?PROC_2]),
        ok = erpc:call(N2, ?MODULE, do_subscribe, [?REALM, ?TOPIC_2]),

        %% Each node must actually SEE the other before the restart means
        %% anything: a node that never learned the peer's cells cannot be
        %% said to have lost them afterwards.
        ok = wait_stub_node(N1, ?REALM, ?TOPIC_2, Node2Str),
        ok = wait_stub_node(N2, ?REALM, ?TOPIC_1, Node1Str),

        %% Precondition: the gate is clean on both nodes. Forcing sync here
        %% is fine — this is setup, not the measurement.
        ok = wait_rib_clean(N1, ?REALM, ?CONVERGE_MS, true),
        ok = wait_rib_clean(N2, ?REALM, ?CONVERGE_MS, true),
        ct:pal("precondition: check/1 == [] on both nodes"),

        %% ---- the event under test -------------------------------------
        %% N2 goes down and returns with an EMPTY projection (see the header
        %% note on why this is wiped rather than merely restarted). The
        %% cluster is quiet: nothing writes a registry entry while it is
        %% away, so no peer cell CHANGES and no merge event is owed to it.
        ok = bondy_ct:stop_node(S2),
        ok = wipe_data_dir(?N2_NAME, Config),
        S2b = bondy_ct:restart_node(S2, ?N2_IDX, N2Env, Config),

        try
            {_, N2b, _} = S2b,
            ok = push_module(N2b, ?MODULE),
            ok = bondy_ct:rejoin(S2b, [S1, S2b], 60000),
            ct:pal("N2 rebuilt and rejoined; settling up to ~pms", [
                ?SETTLE_MS
            ]),

            %% NON-VACUITY GATE (header note 1): the bootstrap must have
            %% installed cells before `check/1' means anything. Without this
            %% the assertion below passes on an empty projection.
            ok = wait_rib_cells(N2b, ?REALM),

            %% THE ASSERTION. Poll only — see the header note.
            ok = wait_rib_clean(N2b, ?REALM, ?SETTLE_MS, false),

            %% The survivor must not have been damaged either.
            ok = wait_rib_clean(N1, ?REALM, ?CONVERGE_MS, false)
        after
            try
                bondy_ct:stop_node(S2b)
            catch
                _:_ -> ok
            end
        end
    after
        try
            bondy_ct:stop_cluster(Nodes)
        catch
            _:_ -> ok
        end
    end.

%% -----------------------------------------------------------------------------
%% THE REPORTED SCENARIO: a PLAIN restart, data directory intact.
%%
%% This is what actually happened on the dev cluster (`bondy2` restarted, and
%% `bondy_registry_rib_divergences` went 0 -> 2 and stayed). The RIB tables
%% are `durability => ephemeral`, so a plain restart empties their projection
%% just as thoroughly as a wipe does — the durable `main` directory surviving
%% is irrelevant to them.
%%
%% It is asserted separately from `rib_consistent_after_node_rebuild/1`
%% because the two differ in what ELSE is empty: here `main` survives, so the
%% node is `pre_bootstrap` only for the registry. Covering the wipe alone
%% would leave the reported scenario untested.
%%
%% Before the fix this was FLAKY, not merely failing: `check/1` is vacuously
%% `[]` on an empty projection, so whether it caught the divergence depended
%% on whether cells had landed yet. The `wait_rib_cells/2` gate below removes
%% that race, and the fix removes the divergence.
%% -----------------------------------------------------------------------------
rib_consistent_after_plain_restart(Config) ->
    N2Env = [{[partisan, peer_port], ?P2_PEER_PORT}],
    Names = [
        {?P1_NAME, [{[partisan, peer_port], ?P1_PEER_PORT}]},
        {?P2_NAME, N2Env}
    ],
    Nodes = bondy_ct:start_cluster(Names, Config),
    [S1, S2] = Nodes,
    {_, N1, _} = S1,
    {_, N2, _} = S2,

    try
        _ = [push_module(N, ?MODULE) || N <- [N1, N2]],
        ok = erpc:call(N1, ?MODULE, do_create_realm, [?PLAIN_REALM]),
        ok = wait_realm(N2, ?PLAIN_REALM),

        ok = erpc:call(N1, ?MODULE, do_register, [?PLAIN_REALM, ?PROC_1]),
        ok = erpc:call(N1, ?MODULE, do_subscribe, [?PLAIN_REALM, ?TOPIC_1]),
        ok = erpc:call(N2, ?MODULE, do_register, [?PLAIN_REALM, ?PROC_2]),
        ok = erpc:call(N2, ?MODULE, do_subscribe, [?PLAIN_REALM, ?TOPIC_2]),

        Node1Str = erpc:call(N1, bondy_config, nodestring, []),
        ok = wait_stub_node(N2, ?PLAIN_REALM, ?TOPIC_1, Node1Str),
        ok = wait_rib_clean(N1, ?PLAIN_REALM, ?CONVERGE_MS, true),
        ok = wait_rib_clean(N2, ?PLAIN_REALM, ?CONVERGE_MS, true),

        %% Plain restart: data directory INTACT, unlike the rebuild case. A
        %% crash-stop: the stale-echo the self-heal must correct is the one
        %% an UNGRACEFUL restart leaves behind (`bondy_registry_rib`
        %% moduledoc).
        ok = bondy_ct:stop_node(S2, halt),
        S2b = bondy_ct:restart_node(S2, ?P2_IDX, N2Env, Config),

        try
            {_, N2b, _} = S2b,
            ok = push_module(N2b, ?MODULE),
            %% Diagnostic only (no assertion): says which path delivered the
            %% RIB cells to the restarted node, which is what distinguishes
            %% "the install never announced" from "the announcement fired but
            %% the rebuild skipped the cells".
            ok = erpc:call(N2b, ?MODULE, do_probe_start, [
                [?BONDY_DB_REGISTRATION_RIB_TAB, ?BONDY_DB_SUBSCRIPTION_RIB_TAB]
            ]),
            ok = bondy_ct:rejoin(S2b, [S1, S2b], 60000),
            ok = wait_rib_cells(N2b, ?PLAIN_REALM),
            ct:pal(
                "plain restart, notifications by table/path: ~p",
                [erpc:call(N2b, ?MODULE, do_probe_counts, [])]
            ),
            ok = wait_rib_clean(N2b, ?PLAIN_REALM, ?SETTLE_MS, false),
            ok = wait_rib_clean(N1, ?PLAIN_REALM, ?CONVERGE_MS, false)
        after
            try
                bondy_ct:stop_node(S2b)
            catch
                _:_ -> ok
            end
        end
    after
        try
            bondy_ct:stop_cluster(Nodes)
        catch
            _:_ -> ok
        end
    end.

%% -----------------------------------------------------------------------------
%% The UNIVERSAL form of the same defect, covering the DURABLE class too.
%%
%% `rib_consistent_after_node_rebuild/1' above shows the consequence on an
%% EPHEMERAL table. This asserts the CAUSE directly, and does so for a durable
%% `publish => true' table (`bondy_realm', `db => main') alongside an ephemeral
%% one (`bondy_registration_rib') — so a RIB-only patch cannot turn it green.
%%
%% It asserts the OBLIGATION (`publish => true' means subscribers get told),
%% never a particular message — see `probe_loop/2'.
%%
%% The node is WIPED, not merely restarted: a plain restart keeps the durable
%% data directory, so `main' is intact and only the ephemeral registry
%% instance bootstraps. Deleting the data dir makes it a fresh `pre_bootstrap'
%% replica for BOTH classes.
%%
%% The probe subscribes BETWEEN start and rejoin. That window is what makes
%% the hook observable at all: the snapshot bootstrap runs at SYNC time, not
%% boot time, so a subscriber installed after the join would report a false
%% negative. For the same reason the test first proves the bootstrap really
%% installed the cells — without that, "no merge events" is vacuously true on
%% a node that simply received nothing.
%%
%% WHY IT CANNOT DEMAND A DELIVERY PATH. The path is timing-dependent (the
%% same scenario delivers a cell by snapshot bootstrap in some runs and
%% op-based merge in others), and attach is a race the testcase cannot win —
%% the survivor auto-dials the restarted node during its boot, before erpc can
%% attach anything, and events delivered before the subscribe do not replay.
%% So each half passes on BASELINE OR NOTIFICATION, which is the contract a
%% `publish => true' subscriber actually has: whatever landed before you
%% attached is in the projection and yours to reconcile, whatever lands after
%% must be announced by either path. `bondy_aae_reactor' survives the same
%% race the same way.
%%
%% The install-path mutation guard — delete `maybe_publish_bootstrap/4' and
%% something must fail — lives in `bondy_oplog_applier_bootstrap_test', which
%% needs no race to be won.
%% -----------------------------------------------------------------------------
publish_hook_fires_for_bootstrap_installed_cells(Config) ->
    N2Env = [{[partisan, peer_port], ?B2_PEER_PORT}],
    Names = [
        {?B1_NAME, [{[partisan, peer_port], ?B1_PEER_PORT}]},
        {?B2_NAME, N2Env}
    ],
    Nodes = bondy_ct:start_cluster(Names, Config),
    [S1, S2] = Nodes,
    {_, N1, _} = S1,
    {_, N2, _} = S2,

    try
        _ = [push_module(N, ?MODULE) || N <- [N1, N2]],

        %% DURABLE publish => true state and EPHEMERAL publish => true
        %% state. The durable carrier is `security_groups`, NOT `bondy_realm`:
        %% MEASURED 2026-08-22, a wiped node's `bondy_realm` never goes
        %% through the catalogue-install path at all, so watching it asserted
        %% a scenario the test never produced. `security_groups` does go
        %% through that path — but only installs, and therefore only
        %% notifies, when it actually HOLDS something, which is why a group
        %% is created here rather than a realm alone.
        ok = erpc:call(N1, ?MODULE, do_create_realm, [?BOOT_REALM]),
        ok = wait_realm(N2, ?BOOT_REALM),
        ok = erpc:call(N1, ?MODULE, do_create_group, [
            ?BOOT_REALM,
            ?BOOT_GROUP
        ]),
        ok = wait_group(N2, ?BOOT_REALM, ?BOOT_GROUP),
        ok = erpc:call(N1, ?MODULE, do_register, [?BOOT_REALM, ?PROC_1]),
        ok = erpc:call(N1, ?MODULE, do_subscribe, [?BOOT_REALM, ?TOPIC_1]),
        Node1Str = erpc:call(N1, bondy_config, nodestring, []),
        ok = wait_stub_node(N2, ?BOOT_REALM, ?TOPIC_1, Node1Str),

        ok = bondy_ct:stop_node(S2),
        ok = wipe_data_dir(?B2_NAME, Config),

        S2b = bondy_ct:restart_node(S2, ?B2_IDX, N2Env, Config),

        try
            {_, N2b, _} = S2b,
            ok = push_module(N2b, ?MODULE),
            ok = erpc:call(N2b, ?MODULE, do_probe_start, [
                [?BONDY_DB_GROUP_TAB, ?BONDY_DB_REGISTRATION_RIB_TAB]
            ]),
            %% ATTACH BASELINE, read AFTER the probe's subscriptions are
            %% placed (`do_probe_start` returns only then). The survivor
            %% auto-dials the restarted node the moment its listener binds —
            %% during boot, before this testcase can attach anything — so an
            %% individual shard MAY have synced already (measured 2026-08-25:
            %% a traced failing run showed the registration shard installed
            %% with no post-attach publish while the subscription shard
            %% announced post-attach). Whatever is visible now is the
            %% reconcile half of the contract; everything that lands later
            %% must be announced.
            BaselineCells = erpc:call(N2b, ?MODULE, do_rib_cell_count, [
                ?BOOT_REALM
            ]),
            BaselineGroup = erpc:call(N2b, ?MODULE, do_group_exists, [
                ?BOOT_REALM, ?BOOT_GROUP
            ]),
            ok = bondy_ct:rejoin(S2b, [S1, S2b], 60000),

            %% Proof the bootstrap installed something, so a zero count below
            %% cannot be vacuous.
            ok = wait_realm(N2b, ?BOOT_REALM),
            ok = wait_group(N2b, ?BOOT_REALM, ?BOOT_GROUP),
            ok = wait_rib_cells(N2b, ?BOOT_REALM),

            %% The cells being VISIBLE does not mean the announcement has
            %% been DELIVERED: the dispatcher fans events out asynchronously,
            %% so a counts read taken the instant `wait_rib_cells/2` returns
            %% can beat an already-emitted event to the probe's mailbox.
            %% Settle until both tables are covered, or a deadline elapses
            %% and the assertion below reports what did (not) arrive.
            Counts = wait_probe_counts(
                N2b,
                [
                    {?BONDY_DB_GROUP_TAB, BaselineGroup},
                    {?BONDY_DB_REGISTRATION_RIB_TAB, BaselineCells > 0}
                ],
                ?SETTLE_MS
            ),
            ct:pal(
                "attach baseline: group=~p rib_cells=~p; notifications on "
                "the bootstrapped node, by table/path: ~p",
                [BaselineGroup, BaselineCells, Counts]
            ),
            Durable = notified(?BONDY_DB_GROUP_TAB, Counts),
            Ephemeral = notified(?BONDY_DB_REGISTRATION_RIB_TAB, Counts),
            %% Both halves assert the CONTRACT a `publish => true` subscriber
            %% actually has — the RULE the 2026-08-22 fix established: state
            %% that arrived before you attached is yours to RECONCILE from
            %% the projection at attach; everything that lands after must be
            %% ANNOUNCED (either path — see the header note). Deleting
            %% `maybe_publish_bootstrap/4` still fails this case whenever
            %% the install lands post-attach (empty baseline, no event);
            %% the deterministic guard on that deletion lives in
            %% `bondy_oplog_applier_bootstrap_test`.
            ?assertEqual(
                #{
                    durable_covered => true,
                    ephemeral_covered => true
                },
                #{
                    durable_covered => Durable > 0 orelse BaselineGroup,
                    ephemeral_covered =>
                        Ephemeral > 0 orelse BaselineCells > 0
                }
            )
        after
            try
                bondy_ct:stop_node(S2b)
            catch
                _:_ -> ok
            end
        end
    after
        try
            bondy_ct:stop_cluster(Nodes)
        catch
            _:_ -> ok
        end
    end.

%% =============================================================================
%% WAITERS (controller side)
%% =============================================================================

%% @private
%% Deletes a peer's data directory so it returns as a fresh `pre_bootstrap'
%% replica for the DURABLE tables too, not just the ephemeral ones. The path
%% is the one `bondy_ct:start_node/5' derives: PrivDir/<node name>.
wipe_data_dir(Name, Config) ->
    PrivDir = proplists:get_value(priv_dir, Config),
    PrivDir =/= undefined orelse error({missing_priv_dir, Config}),
    Dir = filename:join(PrivDir, atom_to_list(Name)),
    case file:del_dir_r(Dir) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, Reason} -> error({cannot_wipe_data_dir, Dir, Reason})
    end.

%% @private
%% Polls until the node's RIB projection actually holds cells for `Realm'.
wait_rib_cells(Node, Realm) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_rib_cells_loop(Node, Realm, Deadline).

%% @private
wait_rib_cells_loop(Node, Realm, Deadline) ->
    N =
        try
            erpc:call(Node, ?MODULE, do_rib_cell_count, [Realm])
        catch
            _:_ -> 0
        end,
    case N > 0 of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    error({rib_cells_never_installed, Node, Realm});
                false ->
                    timer:sleep(500),
                    wait_rib_cells_loop(Node, Realm, Deadline)
            end
    end.

%% @private
%% Polls `check/1' until it is `[]'. `Force' triggers a sync round each
%% iteration — ONLY safe during setup; see the header note on why the
%% post-restart wait must not do it.
wait_rib_clean(Node, Realm, Timeout, Force) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_rib_clean_loop(Node, Realm, Deadline, Force).

%% @private
wait_rib_clean_loop(Node, Realm, Deadline, Force) ->
    ok = maybe_trigger(Node, Force),
    Actual =
        try
            erpc:call(Node, bondy_registry_rib, check, [Realm])
        catch
            C:R -> {'EXIT', {C, R}}
        end,
    case Actual of
        [] ->
            ok;
        Other ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    ct:pal(
                        "RIB divergence on ~p did not clear.~n"
                        "Each term is {{Type, Policy, Uri}, "
                        "#{full_entries := Truth, rib := Summaries}}.~n"
                        "`rib` naming the PEER  => stub store not rebuilt at "
                        "boot.~n"
                        "`rib` naming THIS node => self_heal/4 never ran.~n"
                        "~p",
                        [Node, Other]
                    ),
                    error({rib_divergence, Node, Other});
                false ->
                    timer:sleep(1000),
                    wait_rib_clean_loop(Node, Realm, Deadline, Force)
            end
    end.

%% @private
%% Polls until `Node's stub view names `NodeStr' for `Topic'.
wait_stub_node(Node, Realm, Topic, NodeStr) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    Want = binary_to_atom(NodeStr, utf8),
    wait_stub_node_loop(Node, Realm, Topic, Want, Deadline).

%% @private
wait_stub_node_loop(Node, Realm, Topic, Want, Deadline) ->
    ok = maybe_trigger(Node, true),
    Ns =
        try
            erpc:call(
                Node, bondy_registry_rib, subscription_nodes, [
                    Realm, Topic, #{}
                ]
            )
        catch
            _:_ -> []
        end,
    case lists:member(Want, Ns) of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    error({stub_never_appeared, Node, Topic, Want, Ns});
                false ->
                    timer:sleep(500),
                    wait_stub_node_loop(Node, Realm, Topic, Want, Deadline)
            end
    end.

%% @private
wait_group(Node, Realm, Name) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_group_loop(Node, Realm, Name, Deadline).

%% @private
wait_group_loop(Node, Realm, Name, Deadline) ->
    ok = maybe_trigger(Node, true),
    Exists =
        try
            erpc:call(Node, ?MODULE, do_group_exists, [Realm, Name])
        catch
            _:_ -> false
        end,
    case Exists of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    error({group_never_replicated, Node, Realm, Name});
                false ->
                    timer:sleep(500),
                    wait_group_loop(Node, Realm, Name, Deadline)
            end
    end.

%% @private
wait_realm(Node, Realm) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_realm_loop(Node, Realm, Deadline).

%% @private
wait_realm_loop(Node, Realm, Deadline) ->
    ok = maybe_trigger(Node, true),
    Exists =
        try
            erpc:call(Node, bondy_realm, exists, [Realm])
        catch
            _:_ -> false
        end,
    case Exists of
        true ->
            ok;
        _ ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    error({realm_never_replicated, Node, Realm});
                false ->
                    timer:sleep(500),
                    wait_realm_loop(Node, Realm, Deadline)
            end
    end.

%% @private
%% Forces a sync round. ONLY for setup waits — see the header note on why
%% the post-restart measurement must never do this.
maybe_trigger(_Node, false) ->
    ok;
maybe_trigger(Node, true) ->
    try
        _ = erpc:call(Node, bondy_oplog_sync_scheduler, trigger, []),
        ok
    catch
        _:_ -> ok
    end.

%% @private
push_module(Node, Mod) ->
    {Mod, Bin, File} = code:get_object_code(Mod),
    {module, Mod} = erpc:call(Node, code, load_binary, [Mod, File, Bin]),
    ok.

%% =============================================================================
%% PEER-SIDE HELPERS (run on the cluster nodes via erpc)
%% =============================================================================

%% @private
%% Durable `publish => true` payload. `security_groups` only installs — and
%% therefore only notifies — when it holds rows.
do_create_group(RealmUri, Name) ->
    case
        bondy_rbac_group:add(
            RealmUri, bondy_rbac_group:new(#{name => Name})
        )
    of
        {ok, _} -> ok;
        {error, already_exists} -> ok;
        Other -> error({group_add_failed, Other})
    end.

%% @private
do_group_exists(RealmUri, Name) ->
    case bondy_rbac_group:lookup(RealmUri, Name) of
        {error, not_found} -> false;
        _ -> true
    end.

%% @private
do_create_realm(Uri) ->
    Realm = bondy_realm:create(Uri),
    ok = bondy_realm:disable_security(Realm),
    ok.

%% @private
do_register(Uri, Proc) ->
    Ref = bondy_ref:new(internal, {?MODULE, rib_echo}),
    case bondy_dealer:register(Proc, #{invoke => <<"single">>}, Uri, Ref) of
        {ok, _} -> ok;
        Other -> error({register_failed, Other})
    end.

%% @private
%% The subscriber must be a LIVE process on this node: a process-less
%% callback ref works for registrations, but a subscription whose target is
%% dead can be reaped by registry hygiene between assertions.
do_subscribe(Uri, Topic) ->
    Keeper = spawn(?MODULE, keeper_loop, []),
    Ref = bondy_ref:new(internal, Keeper, bondy_session_id:new()),
    case bondy_registry:add(subscription, Uri, Topic, #{}, Ref) of
        {ok, _, _} -> ok;
        {ok, _} -> ok;
        Other -> error({subscribe_failed, Other})
    end.

%% @private
%% Subscribes to the merge-event namespace of each table and counts the
%% `bondy_oplog_core_merge_event' messages that arrive. Started BEFORE the
%% join so it is listening while the snapshot bootstrap runs.
do_probe_start(Tables) ->
    _ =
        case whereis(?PROBE) of
            undefined ->
                ok;
            Old ->
                exit(Old, kill),
                timer:sleep(100)
        end,
    Deadline = erlang:monotonic_time(millisecond) + 30000,
    NsMap = probe_namespaces(Tables, Deadline),
    Caller = self(),
    Pid = spawn(?MODULE, probe_loop_init, [NsMap, Caller]),
    %% Return only once the subscriptions are PLACED: the caller reads its
    %% attach baseline right after this, and that read is sound only if no
    %% event can slip between it and the subscribe.
    receive
        {probe_ready, Pid} -> ok
    after 10000 ->
        error(probe_subscribe_timeout)
    end,
    true = register(?PROBE, Pid),
    ok.

%% @private
%% The catalogue provisions tables asynchronously after boot; a probe that
%% resolved to an empty namespace set would count zero events for a reason
%% that has nothing to do with the defect.
probe_namespaces(Tables, Deadline) ->
    Resolved = lists:foldl(
        fun(T, Acc) ->
            case bondy_namespace_catalog:table(T) of
                undefined -> Acc;
                Handle -> maps:put(bondy_db:namespace(Handle), T, Acc)
            end
        end,
        #{},
        Tables
    ),
    case maps:size(Resolved) =:= length(Tables) of
        true ->
            Resolved;
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    error({tables_not_provisioned, Tables, Resolved});
                false ->
                    timer:sleep(250),
                    probe_namespaces(Tables, Deadline)
            end
    end.

%% @private
probe_loop_init(NsMap, Caller) ->
    _ = [
        {ok, _} = bondy_oplog_core:subscribe(NS, all)
     || NS <- maps:keys(NsMap)
    ],
    Caller ! {probe_ready, self()},
    probe_loop(NsMap, #{}).

%% @private
%% Counts NOTIFICATIONS, not one specific tag. The question this case asks is
%% "was a subscriber of this table told its projection arrived?", and a
%% snapshot bootstrap answers with `bondy_oplog_core_bootstrap_event' (one per
%% table) while op-based anti-entropy answers with
%% `bondy_oplog_core_merge_event' (one per cell). Either discharges the
%% obligation; counting only the merge tag asserts a particular
%% IMPLEMENTATION rather than the property, and fails a correct fix that chose
%% the other — which is exactly what an earlier version of this case did.
%% Kept separate in the tally so the log still says which path ran.
probe_loop(NsMap, Counts) ->
    receive
        {bondy_oplog_core_merge_event, NS, _Key, _Hlc, _Op, _Old} ->
            probe_loop(NsMap, bump(NsMap, NS, merge, Counts));
        {bondy_oplog_core_bootstrap_event, NS, _Bucket} ->
            probe_loop(NsMap, bump(NsMap, NS, bootstrap, Counts));
        {bondy_oplog_core_event, _NS, _Key, _Hlc, _Op} ->
            %% Local write — neither a merge nor a bootstrap.
            probe_loop(NsMap, Counts);
        {counts, From} ->
            From ! {probe_counts, Counts},
            probe_loop(NsMap, Counts);
        _Other ->
            probe_loop(NsMap, Counts)
    end.

%% @private
bump(NsMap, NS, Kind, Counts) ->
    Table = maps:get(NS, NsMap, NS),
    Inner0 = maps:get(Table, Counts, #{merge => 0, bootstrap => 0}),
    Inner = maps:update_with(Kind, fun(C) -> C + 1 end, 1, Inner0),
    maps:put(Table, Inner, Counts).

%% @private
%% Total notifications for `Table', whichever path delivered them.
notified(Table, Counts) ->
    Inner = maps:get(Table, Counts, #{}),
    maps:get(merge, Inner, 0) + maps:get(bootstrap, Inner, 0).

%% @private
%% Polls the probe until every `{Table, BaselineCovered}' is covered — by its
%% attach baseline or by a notification — or the deadline lapses, in which
%% case the LAST counts read are returned and the caller's assertion reports
%% what did (not) arrive.
wait_probe_counts(Node, Tables, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_probe_counts_loop(Node, Tables, Deadline).

%% @private
wait_probe_counts_loop(Node, Tables, Deadline) ->
    Counts = erpc:call(Node, ?MODULE, do_probe_counts, []),
    AllCovered = lists:all(
        fun({T, Baseline}) -> Baseline orelse notified(T, Counts) > 0 end,
        Tables
    ),
    Expired = erlang:monotonic_time(millisecond) > Deadline,
    case AllCovered orelse Expired of
        true ->
            Counts;
        false ->
            timer:sleep(500),
            wait_probe_counts_loop(Node, Tables, Deadline)
    end.

%% @private
do_probe_counts() ->
    case whereis(?PROBE) of
        undefined ->
            error(probe_not_running);
        Pid ->
            Pid ! {counts, self()},
            receive
                {probe_counts, Counts} -> Counts
            after 10000 -> error(probe_timeout)
            end
    end.

%% @private
do_rib_cell_count(Realm) ->
    case bondy_namespace_catalog:table(?BONDY_DB_REGISTRATION_RIB_TAB) of
        undefined ->
            0;
        Table ->
            case bondy_db:list(Table, Realm) of
                {ok, Rows} -> length(Rows);
                _ -> 0
            end
    end.

%% @private
keeper_loop() ->
    receive
        stop -> ok
    end.

%% The dynamic-callback convention: {ok, Details, Args, KWArgs} -> RESULT.
rib_echo() ->
    {ok, #{}, [<<"pong">>], #{}}.

rib_echo(_) ->
    rib_echo().

rib_echo(_, _) ->
    rib_echo().
