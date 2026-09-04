%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_aae_cluster_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_security.hrl").

-compile([nowarn_export_all, export_all]).

%% A 3-node Partisan cluster with bondy_db anti-entropy (`db.aae') enabled.
%% Each node runs the full bondy_router stack with all client listeners
%% disabled and an isolated data dir / Partisan port (see
%% `bondy_ct:start_cluster/2'). These tests write through `bondy_db' on one
%% node and assert the value converges on the others via the periodic sync
%% scheduler over the Partisan transport — i.e. the production AAE path, not a
%% hand-called `bondy_oplog:sync/3'.

-define(NODE_NAMES, [bondy1, bondy2, bondy3]).
%% A per-realm durable main table (band = realm URI, exercises G-1 realm
%% folding) and a global-band durable main table (band = <<>>).
-define(USERS_TABLE, security_users).
-define(BRIDGE_TABLE, bondy_bridge_relay).
-define(REALM_TABLE, bondy_realm).
-define(MEMBER_TABLE, security_group_members).
-define(REALM, <<"com.bondy.aae_cluster">>).
%% How long to wait for a write to propagate across the cluster. Generous so
%% the convergence assertions stay robust under the accumulated load of the
%% full suite (the periodic sync scheduler slows as more namespaces sync, and
%% each added test compounds it — a fixed ceiling that is comfortable for a
%% lightly-loaded cluster becomes marginal as the suite grows).
-define(CONVERGE_MS, 120000).

all() ->
    [
        per_realm_write_converges,
        global_band_write_converges,
        concurrent_writes_full_convergence,
        merge_event_fires_on_remote_write,
        realm_merge_event_fires_on_remote_write,
        grant_merge_event_fires_on_remote_write,
        concurrent_membership_adds_both_survive,
        stale_peer_rejoin_durable_converges,
        rib_summary_converges_to_stub,
        rib_read_mode_cross_node_call,
        rib_stub_pubsub_cross_node,
        rib_write_mode_cluster,
        rib_retry_reroutes_to_live_node,
        meta_event_demand_visible_cross_node,
        remote_user_delete_closes_peer_sessions,
        token_version_rejected_cross_node,
        %% Last: they plant cells carrying a runtime-minted atom, and
        %% nothing may depend on suite state after them.
        runtime_atom_value_sync_measured,
        runtime_atom_cell_read_after_restart_measured
    ].

suite() ->
    [{timetrap, {minutes, 10}}].

init_per_suite(Config) ->
    Nodes = bondy_ct:start_cluster(?NODE_NAMES, Config),
    %% The peer-side read/write helpers below run on the cluster nodes, so make
    %% this module loadable there.
    _ = [push_module(Node, ?MODULE) || {_, Node, _} <- Nodes],
    [{cluster, Nodes} | Config].

end_per_suite(Config) ->
    ok = bondy_ct:stop_cluster(?config(cluster, Config)),
    Config.

%% =============================================================================
%% TESTS
%% =============================================================================

%% Write a per-realm `security_users' entry on node 1; it must appear on
%% nodes 2 and 3 via background AAE.
per_realm_write_converges(Config) ->
    [N1, N2, N3] = nodes_of(Config),
    Key = <<"alice">>,
    Val = #{username => Key, marker => <<"per_realm">>},

    ok = apply_on(N1, ?USERS_TABLE, ?REALM, Key, Val),
    ?assertMatch({ok, {Val, _}}, read_on(N1, ?USERS_TABLE, ?REALM, Key)),

    ok = wait_converge(N2, ?USERS_TABLE, ?REALM, Key, Val),
    ok = wait_converge(N3, ?USERS_TABLE, ?REALM, Key, Val).

%% Write a global-band (<<>>) `bondy_bridge_relay' entry on node 2; it must
%% appear on nodes 1 and 3 — covers the const-band addressing path and a
%% different originating node.
global_band_write_converges(Config) ->
    [N1, N2, N3] = nodes_of(Config),
    Key = <<"bridge_a">>,
    Val = #{name => Key, marker => <<"global_band">>},

    ok = apply_on(N2, ?BRIDGE_TABLE, <<>>, Key, Val),
    ?assertMatch({ok, {Val, _}}, read_on(N2, ?BRIDGE_TABLE, <<>>, Key)),

    ok = wait_converge(N1, ?BRIDGE_TABLE, <<>>, Key, Val),
    ok = wait_converge(N3, ?BRIDGE_TABLE, <<>>, Key, Val).

%% Two distinct keys written on two different nodes must both be visible on
%% all three after AAE — bidirectional, full convergence.
concurrent_writes_full_convergence(Config) ->
    [N1, N2, N3] = nodes_of(Config),
    K1 = <<"conc_from_n1">>,
    V1 = #{username => K1, marker => <<"n1">>},
    K3 = <<"conc_from_n3">>,
    V3 = #{username => K3, marker => <<"n3">>},

    ok = apply_on(N1, ?USERS_TABLE, ?REALM, K1, V1),
    ok = apply_on(N3, ?USERS_TABLE, ?REALM, K3, V3),

    [
        begin
            ok = wait_converge(N, ?USERS_TABLE, ?REALM, K1, V1),
            ok = wait_converge(N, ?USERS_TABLE, ?REALM, K3, V3)
        end
     || N <- [N1, N2, N3]
    ],
    ok.

%% The merge-side reactor hook (bondy_oplog_core:publish_merge/4) must fire on
%% node 2 when anti-entropy merges a write authored on node 1, and must NOT fire
%% for node 2's own local writes. A collector process on node 2 subscribes to
%% the security_users namespace and records the events it receives.
merge_event_fires_on_remote_write(Config) ->
    [N1, N2, _N3] = nodes_of(Config),
    NS = erpc:call(N2, ?MODULE, do_namespace, [?USERS_TABLE]),
    ok = erpc:call(N2, ?MODULE, start_collector, [NS]),

    %% Remote write on node 1 → converges on node 2 AND delivers a merge event.
    RKey = <<"merge_hook_remote">>,
    RVal = #{username => RKey, marker => <<"merge_hook">>},
    ok = apply_on(N1, ?USERS_TABLE, ?REALM, RKey, RVal),
    ok = wait_converge(N2, ?USERS_TABLE, ?REALM, RKey, RVal),
    ok = wait_for_merge_event(N2, RKey, 15000),

    %% A purely local write on node 2 must NOT produce a merge event for its
    %% key (it fires a plain local event instead).
    LKey = <<"merge_hook_local_only">>,
    LVal = #{username => LKey, marker => <<"local">>},
    ok = apply_on(N2, ?USERS_TABLE, ?REALM, LKey, LVal),
    %% Give any (erroneous) merge event time to arrive before we assert absence.
    timer:sleep(1500),
    Events = erpc:call(N2, ?MODULE, collector_drain, []),
    Merges = [
        K
     || {bondy_oplog_core_merge_event, _, K, _, _, _} <- Events,
        binary:match(K, LKey) =/= nomatch
    ],
    ?assertEqual([], Merges),
    ok.

%% The merge hook must also fire for a global-band (<<>>) `publish => true' table
%% — here `bondy_realm', whose folded cell key is `<<0, Uri>>'. This is the path
%% the realm-delete reactor (`bondy_aae_reactor') consumes; the per-realm
%% security_users test above only covers the folded-band path.
realm_merge_event_fires_on_remote_write(Config) ->
    [N1, N2, _N3] = nodes_of(Config),
    NS = erpc:call(N2, ?MODULE, do_namespace, [?REALM_TABLE]),
    ok = erpc:call(N2, ?MODULE, start_collector, [NS]),

    Uri = <<"com.bondy.aae_realm_merge">>,
    Val = #{uri => Uri, marker => <<"realm_merge">>},
    ok = apply_on(N1, ?REALM_TABLE, <<>>, Uri, Val),
    ok = wait_converge(N2, ?REALM_TABLE, <<>>, Uri, Val),
    %% The collector records the merge event whose folded key `<<0, Uri>>'
    %% carries the realm URI as a substring.
    ok = wait_for_merge_event(N2, Uri, 15000),
    ok.

%% A grant table (`security_user_grants') now carries `publish => true', so a
%% peer's grant write must deliver a merge event on node 2 — the path
%% `bondy_aae_reactor' consumes to drive the §9.5 realm-wide RBAC-context
%% invalidation. Like security_users it is realm-banded, so the folded cell key
%% is `<<Realm, 0, EncGrantKey>>'; we match the delivered event on the grant key.
grant_merge_event_fires_on_remote_write(Config) ->
    [N1, N2, _N3] = nodes_of(Config),
    Table = security_user_grants,
    NS = erpc:call(N2, ?MODULE, do_namespace, [Table]),
    ok = erpc:call(N2, ?MODULE, start_collector, [NS]),

    GKey = <<"grant_merge_remote">>,
    GVal = #{resource => <<"uri.res">>, permissions => [<<"wamp.call">>]},
    ok = apply_on(N1, Table, ?REALM, GKey, GVal),
    ok = wait_converge(N2, Table, ?REALM, GKey, GVal),
    ok = wait_for_merge_event(N2, GKey, 15000),
    ok.

%% Group membership is cell-per-fact, add-wins (`security_group_members`, the
%% `ew_flag` relation). Two adds of the SAME user to DIFFERENT groups, authored
%% independently on two different nodes, must BOTH survive on all three after
%% AAE — the lost update a whole-record `user.groups` lww would suffer (one
%% node's `[g_a]` clobbering the other's `[g_b]`) is structurally impossible,
%% because each `(user, group)` fact is its own cell. The remote merge also
%% delivers the merge event that drives the §9.5 `react_member` RBAC-context
%% invalidation.
concurrent_membership_adds_both_survive(Config) ->
    [N1, N2, N3] = nodes_of(Config),
    Uri = <<"com.bondy.aae_member">>,
    User = <<"mem_user">>,

    NS = erpc:call(N2, ?MODULE, do_namespace, [?MEMBER_TABLE]),
    ok = erpc:call(N2, ?MODULE, start_collector, [NS]),

    %% Realm with two groups + the user (no groups) on node 1; converge the
    %% realm, user and groups to the other nodes so a local add can validate the
    %% group there.
    ok = erpc:call(
        N1, ?MODULE, do_create_member_realm, [Uri, User, [<<"g_a">>, <<"g_b">>]]
    ),
    [ok = wait_member_converge(N, Uri, User, []) || N <- [N2, N3]],
    [ok = wait_groups_exist(N, Uri, [<<"g_a">>, <<"g_b">>]) || N <- [N2, N3]],

    %% Independent adds on two different nodes — different facts, no overwrite.
    ok = erpc:call(N1, ?MODULE, do_add_member, [Uri, User, <<"g_a">>]),
    ok = erpc:call(N2, ?MODULE, do_add_member, [Uri, User, <<"g_b">>]),

    %% Both facts converge everywhere.
    [
        ok = wait_member_converge(N, Uri, User, [<<"g_a">>, <<"g_b">>])
     || N <- [N1, N2, N3]
    ],

    %% The membership fact authored on node 1 merged on node 2 and fired a merge
    %% event (the reverse-band cell key carries the group name as a substring).
    ok = wait_for_merge_event(N2, <<"g_a">>, 15000),
    ok.

%% The registry RIB dual-write across nodes: a registration on node 1 writes
%% node 1's summary cell, the cell rides AAE to node 2 whose merge reactor
%% compiles it into a stub; the unregister clears the cell and the stub
%% follows. The `check/1` consistency gate (full-entry view vs summary view)
%% holds on both nodes once converged.
rib_summary_converges_to_stub(Config) ->
    [N1, N2, _N3] = nodes_of(Config),
    Uri = <<"com.bondy.aae_rib">>,
    Proc = <<"com.example.aae_rib_proc">>,

    ok = erpc:call(N1, ?MODULE, do_create_simple_realm, [Uri]),
    ok = erpc:call(N1, ?MODULE, do_add_registration, [Uri, Proc]),
    N1Str = erpc:call(N1, bondy_config, nodestring, []),

    %% Stage 1 — the owner wrote its own summary cell (the recompute is a
    %% cast to the partition server, so poll).
    ok = wait_rib_cell(N1, Uri, Proc, N1Str),

    %% Stage 2 — the cell rode AAE into N2's projection.
    ok = wait_rib_cell(N2, Uri, Proc, N1Str),

    %% Stage 3 — N2's merge reactor compiled it into a stub.
    ok = wait_rib_stub_count(N2, Uri, Proc, N1Str, 1),

    %% The dual-write consistency gate holds on both nodes once converged.
    ok = wait_rib_check_empty(N1, Uri),
    ok = wait_rib_check_empty(N2, Uri),

    %% The unregister clears the cell; the stub follows.
    ok = erpc:call(N1, ?MODULE, do_remove_registration, [Uri, Proc]),
    ok = wait_rib_stub_count(N2, Uri, Proc, N1Str, 0),
    ok = wait_rib_check_empty(N2, Uri),
    ok.

%% The full RIB cross-node routing loop, end to end: a callee registered on
%% node 1, a CALL made on node 2. Node 2 discovers the callee from the STUB
%% view (its summary converged via AAE), forwards the CALL node-addressed,
%% node 1 completes the selection among its live local registrations
%% (owner-side completion), applies the callback, and the RESULT rides the
%% promise reverse path back to node 2's caller.
rib_read_mode_cross_node_call(Config) ->
    [N1, N2, _N3] = nodes_of(Config),
    Uri = <<"com.bondy.aae_ribcall">>,
    Proc = <<"com.example.aae_rib_echo">>,

    ok = erpc:call(N1, ?MODULE, do_create_open_realm, [Uri]),
    ok = erpc:call(N1, ?MODULE, do_register_echo, [Uri, Proc]),
    N1Str = erpc:call(N1, bondy_config, nodestring, []),

    %% Discovery source is the stub view — wait for it.
    ok = wait_rib_stub_count(N2, Uri, Proc, N1Str, 1),

    ?assertMatch(
        #result{args = [<<"pong">>]},
        erpc:call(N2, ?MODULE, do_rib_call, [Uri, Proc])
    ).

%% The broker's cross-node event forwarding on the RIB: remote subscriber
%% NODES are discovered from the subscription stubs (one relayed PUBLISH per
%% node; the receiving node matches and delivers locally). The prefix
%% subscription is the load-bearing case — with routing on stubs the
%% publishing node's local match is restricted to local subscribers, so only
%% the stub view can name node 1.
rib_stub_pubsub_cross_node(Config) ->
    [N1, N2, _N3] = nodes_of(Config),
    Uri = <<"com.bondy.aae_ribpub">>,
    TopicA = <<"com.example.ribpub.alpha">>,
    Prefix = <<"com.example.ribpub.pfx.">>,
    TopicB = <<"com.example.ribpub.pfx.beta">>,

    ok = erpc:call(N1, ?MODULE, do_create_open_realm, [Uri]),
    ok = erpc:call(N1, ?MODULE, do_start_event_probe, [
        Uri,
        [
            {TopicA, #{match => ?EXACT_MATCH}},
            {Prefix, #{match => ?PREFIX_MATCH}}
        ]
    ]),

    %% N2 discovers N1 as a subscriber node for both topics via stubs.
    ok = wait_rib_sub_node(N2, Uri, TopicA, N1),
    ok = wait_rib_sub_node(N2, Uri, TopicB, N1),

    ok = erpc:call(N2, ?MODULE, do_rib_publish, [Uri, TopicA, [<<"a">>]]),
    ok = erpc:call(N2, ?MODULE, do_rib_publish, [Uri, TopicB, [<<"b">>]]),
    ok = wait_probe_args(N1, [<<"a">>, <<"b">>]).

%% RIB routing end to end, on a dedicated 2-node cluster: full entries never
%% enter bondy_db — the replicated full-entry tables stay EMPTY on every
%% node — yet cross-node calls and publications route on the summary cells
%% alone, and the consistency gate holds.
rib_write_mode_cluster(Config) ->
    %% Distinct names and Partisan ports — the suite's main cluster occupies
    %% bondy1..3 on 18087..18089.
    Names = [
        {bondy_w1, [
            {[partisan, peer_port], 18190}
        ]},
        {bondy_w2, [
            {[partisan, peer_port], 18191}
        ]}
    ],
    Nodes = bondy_ct:start_cluster(Names, Config),
    [W1, W2] = [Node || {_, Node, _} <- Nodes],
    try
        _ = [push_module(N, ?MODULE) || N <- [W1, W2]],

        Uri = <<"com.bondy.aae_ribwrite">>,
        Proc = <<"com.example.ribwrite.echo">>,
        TopicA = <<"com.example.ribwrite.alpha">>,
        Prefix = <<"com.example.ribwrite.pfx.">>,
        TopicB = <<"com.example.ribwrite.pfx.beta">>,

        ok = erpc:call(W1, ?MODULE, do_create_open_realm, [Uri]),
        %% The realm itself replicates via the durable main DB — wait for it
        %% on W2 before opening a session there.
        ok = wait_realm(W2, Uri),

        ok = erpc:call(W1, ?MODULE, do_register_echo, [Uri, Proc]),
        ok = erpc:call(W1, ?MODULE, do_start_event_probe, [
            Uri,
            [
                {TopicA, #{match => ?EXACT_MATCH}},
                {Prefix, #{match => ?PREFIX_MATCH}}
            ]
        ]),
        W1Str = erpc:call(W1, bondy_config, nodestring, []),

        %% The summaries replicate...
        ok = wait_rib_stub_count(W2, Uri, Proc, W1Str, 1),
        ok = wait_rib_sub_node(W2, Uri, TopicA, W1),
        ok = wait_rib_sub_node(W2, Uri, TopicB, W1),

        %% Write mode: entries live in the owner's local ETS only — there is no
        %% full-entry bondy_db table left to hold anything anywhere, so the
        %% property is now structurally true rather than empirically observed.

        %% Cross-node CALL on summaries alone.
        ?assertMatch(
            #result{args = [<<"pong">>]},
            erpc:call(W2, ?MODULE, do_rib_call, [Uri, Proc])
        ),

        %% Cross-node pub/sub on summaries alone.
        ok = erpc:call(W2, ?MODULE, do_rib_publish, [Uri, TopicA, [<<"a">>]]),
        ok = erpc:call(W2, ?MODULE, do_rib_publish, [Uri, TopicB, [<<"b">>]]),
        ok = wait_probe_args(W1, [<<"a">>, <<"b">>]),

        %% The write-mode consistency gate: cells match the members table
        %% (own) and the stub store (peers) on both nodes.
        ok = wait_rib_check_empty(W1, Uri),
        ok = wait_rib_check_empty(W2, Uri)
    after
        ok = bondy_ct:stop_cluster(Nodes)
    end.

%% Bounded pre-invocation retry end to end: node 2 (read mode) is fed a
%% STALE stub naming node 3 — which has NO registration — with `earliest`
%% biased so the `single` policy deterministically routes the first leg
%% there. Node 3's owner-side completion misses (pre-invocation, marked),
%% node 2 retries excluding node 3, selects node 1's live stub, and the
%% call completes. One CALL, one delivered invocation.
rib_retry_reroutes_to_live_node(Config) ->
    [N1, N2, N3] = nodes_of(Config),
    Uri = <<"com.bondy.aae_ribretry">>,
    Proc = <<"com.example.ribretry.echo">>,

    ok = erpc:call(N1, ?MODULE, do_create_open_realm, [Uri]),
    ok = erpc:call(N1, ?MODULE, do_register_echo, [Uri, Proc]),
    N1Str = erpc:call(N1, bondy_config, nodestring, []),
    N3Str = erpc:call(N3, bondy_config, nodestring, []),

    %% The live stub converges normally...
    ok = wait_rib_stub_count(N2, Uri, Proc, N1Str, 1),

    %% ...then a stale one is planted directly in N2's stub store, with an
    %% `earliest` no real registration can beat, so `single` (min earliest)
    %% must pick N3 first.
    StaleKey = term_to_binary({Uri, ?EXACT_MATCH, Proc, N3Str}),
    Stale = #{
        invoke => ?INVOKE_SINGLE, count => 1, earliest => 1, latest => 1
    },
    ok = erpc:call(
        N2, bondy_registry_rib, on_remote_set, [registration, StaleKey, Stale]
    ),

    try
        ?assertMatch(
            #result{args = [<<"pong">>]},
            erpc:call(N2, ?MODULE, do_rib_call, [
                Uri, Proc, #{'_routing_max_candidates' => 2}
            ])
        )
    after
        ok = erpc:call(
            N2, bondy_registry_rib, on_remote_clear, [registration, StaleKey]
        )
    end.

%% The meta-event demand predicate (bondy_registry:has_matches/3, see
%% METRICS_GAP_ANALYSIS.md Part III) must see REMOTE meta-topic subscribers:
%% a subscription created on node 1 makes the predicate true on node 2 once
%% the registry converges, so a registry operation on node 2 still publishes
%% its meta event when the only observer lives on node 1. And it must flip
%% back to false when the subscription is removed.
meta_event_demand_visible_cross_node(Config) ->
    [N1, N2 | _] = nodes_of(Config),
    Uri = <<"com.bondy.aae_meta_demand">>,
    Meta = <<"wamp.subscription.on_subscribe">>,

    ok = erpc:call(N1, ?MODULE, do_create_simple_realm, [Uri]),
    ?assertEqual(
        false,
        erpc:call(N1, bondy_registry, has_matches, [subscription, Uri, Meta])
    ),

    ok = erpc:call(N1, ?MODULE, do_add_meta_subscription, [Uri, Meta]),
    ?assertEqual(
        true,
        erpc:call(N1, bondy_registry, has_matches, [subscription, Uri, Meta])
    ),
    ok = wait_has_matches(N2, Uri, Meta, true),

    ok = erpc:call(N1, ?MODULE, do_remove_meta_subscription, [Uri, Meta]),
    ok = wait_has_matches(N1, Uri, Meta, false),
    ok = wait_has_matches(N2, Uri, Meta, false),
    ok.

%% react_user fires cross-node on a real user DELETE (STORAGE_ARCHITECTURE §9.5):
%% a user removed on node 1 must drive node 2's merge reactor to close that user's
%% local sessions (`bondy.user.deleted`). The delete arrives as bondy_db's
%% short-form `clear` op, so this guards the reactor against the wire op-shape the
%% unit test cannot observe. We record the close call on node 2 — the actual
%% teardown is `bondy_session_manager`'s job, covered elsewhere; the point here is
%% that the remote merge reaches `react_user` with the right realm + user.
remote_user_delete_closes_peer_sessions(Config) ->
    [N1, N2, _N3] = nodes_of(Config),
    Uri = <<"com.bondy.aae_userdel">>,
    User = <<"victim">>,

    %% Realm + user on node 1.
    ok = erpc:call(N1, ?MODULE, do_create_user_realm, [Uri, User]),

    %% Record close_sessions on node 2, then converge the user there.
    ok = erpc:call(N2, ?MODULE, do_arm_close_recorder, []),
    try
        ok = wait_user_exists(N2, Uri, User),
        %% Delete on node 1 → the `clear` rides AAE → node 2's react_user closes
        %% the user's sessions for the realm (recorded here).
        ok = erpc:call(N1, ?MODULE, do_delete_user, [Uri, User]),
        ok = wait_close_recorded(N2, Uri, User)
    after
        ok = erpc:call(N2, ?MODULE, do_disarm_close_recorder, [])
    end.

%% The revocation zookie across nodes (STORAGE_ARCHITECTURE §9.2/§9.3): a JWT
%% minted on node 1 authenticates on node 2 once the realm/user converge AND the
%% AE fence is fresh; after a credential change on node 1 bumps the user cell's
%% token_version and that bump converges, node 2 REJECTS the now-stale token.
token_version_rejected_cross_node(Config) ->
    [N1, N2, _N3] = nodes_of(Config),
    Uri = <<"com.bondy.tv_cluster">>,
    User = <<"tv_user">>,
    Pass = <<"tv_pass_123">>,

    %% A FINITE MaxLag exercises the real AE freshness fence: with the per-round
    %% heartbeat wired (each instance's primary shard keys published as
    %% `ae_targets`, freshened by `bump_ae_on_sync` every successful round), a
    %% healthy node's low-churn security shards stay fresh, so the fence passes —
    %% the "N2 authenticates" assertions below are a positive proof of that. 5s
    %% gives ample margin over the 500ms sync tick under CT load; the production
    %% default is 1s. (The stale-refusal path is covered single-node in
    %% bondy_auth_oauth2_SUITE.)
    [ok = erpc:call(N, ?MODULE, do_set_max_lag, [5000]) || N <- [N1, N2]],

    %% Create the realm + user authoritatively on node 1.
    ok = erpc:call(N1, ?MODULE, do_create_auth_realm, [Uri, User, Pass]),

    %% token_version observed by node 1 == node 2 (the user cell converged with
    %% its origin HLC preserved).
    {ok, TV0} = erpc:call(N1, bondy_rbac_user, token_version, [Uri, User]),
    ok = wait_token_version(N2, Uri, User, TV0),

    %% Node 2 must now be able to issue + authenticate its own token (realm +
    %% source converged, fence fresh). Diagnose loudly if not.
    Diag = erpc:call(N2, ?MODULE, do_diag, [Uri, User]),
    ct:pal("node2 self-auth diagnosis: ~p", [Diag]),
    ?assertMatch(#{auth := {ok, _, _}}, Diag),

    %% Mint a JWT on node 1 (embeds tv = TV0) and authenticate it on node 2.
    JWT = erpc:call(N1, ?MODULE, do_issue_jwt, [Uri, User]),
    ?assertMatch(
        {ok, _, _}, erpc:call(N2, ?MODULE, do_authenticate, [Uri, User, JWT])
    ),

    %% Change the password on node 1 → the user cell is rewritten with a higher
    %% HLC, so token_version advances.
    ok = erpc:call(
        N1, bondy_rbac_user, change_password, [Uri, User, <<"new_pass_456">>]
    ),
    {ok, TV1} = erpc:call(N1, bondy_rbac_user, token_version, [Uri, User]),
    ?assert(TV1 > TV0),

    %% Wait for the bump to converge to node 2.
    ok = wait_token_version(N2, Uri, User, TV1),

    %% Node 2 now REJECTS the old JWT: its embedded tv (TV0) no longer matches
    %% the user's current token_version (TV1) — the Zanzibar new-enemy guard.
    ?assertEqual(
        {error, oauth2_invalid_grant},
        erpc:call(N2, ?MODULE, do_authenticate, [Uri, User, JWT])
    ),
    ok.

%% Stale-peer rejoin on the DURABLE path.
%%
%% A peer silent past `peer_timeout_ms` stops pinning the stability frontier,
%% so durable truncation on the survivor proceeds WITHOUT its confirmation —
%% deliberately, or one dead node would pin every shard forever. What this
%% case checks is that rejoining is still lossless in BOTH directions:
%%
%%   - the survivor truncated history the returning node never saw, so that
%%     range cannot arrive by page-sync and must come via catalogue install
%%     + rederive;
%%   - the returning node's OWN writes, made while isolated, live only in its
%%     own MST and must flow back to the survivor.
%%
%% The second half is the one that would fail silently: a rejoin that only
%% pulled would look perfectly healthy on the returning node while its unique
%% rows had vanished from the cluster.
%%
%% The node restarts onto ITS OWN DATA DIRECTORY (`bondy_ct:restart_node/3`
%% keys the dir on the node name), so this is a rejoin and not a fresh-peer
%% bootstrap wearing the same name.
stale_peer_rejoin_durable_converges(Config) ->
    Names = [
        {bondy_r1, [{[partisan, peer_port], 18194}]},
        {bondy_r2, [{[partisan, peer_port], 18195}]}
    ],
    Nodes = bondy_ct:start_cluster(Names, Config),
    [S1, S2] = Nodes,
    {_, R1, _} = S1,
    {_, R2, _} = S2,
    try
        _ = [push_module(N, ?MODULE) || N <- [R1, R2]],

        %% Shrink the recency window so "silent past peer_timeout_ms" is
        %% seconds rather than the 30s default.
        _ = [
            erpc:call(N, application, set_env, [
                bondy_oplog, peer_timeout_ms, 2000
            ])
         || N <- [R1, R2]
        ],

        Shared = <<"rejoin_shared">>,
        SharedV = #{username => Shared, marker => <<"before_split">>},
        ok = apply_on(R1, ?USERS_TABLE, ?REALM, Shared, SharedV),
        ok = wait_converge(R2, ?USERS_TABLE, ?REALM, Shared, SharedV),

        %% R2 writes a row of its own and then goes down before it can sync.
        %% Stopping its dispatch first is what makes the row genuinely unique
        %% to R2's MST rather than a race we happened to win.
        _ = erpc:call(R2, bondy_oplog_sync_scheduler, set_dispatch, [undefined]),
        Only2 = <<"rejoin_only_on_r2">>,
        Only2V = #{username => Only2, marker => <<"written_while_isolated">>},
        ok = apply_on(R2, ?USERS_TABLE, ?REALM, Only2, Only2V),
        ?assertMatch(
            {ok, {Only2V, _}}, read_on(R2, ?USERS_TABLE, ?REALM, Only2)
        ),

        ok = bondy_ct:stop_node(S2),

        %% R1 keeps writing while R2 is gone, then outlives the recency window
        %% and compacts — truncating durable history R2 never saw.
        Only1 = <<"rejoin_written_while_down">>,
        Only1V = #{username => Only1, marker => <<"survivor_only">>},
        ok = apply_on(R1, ?USERS_TABLE, ?REALM, Only1, Only1V),
        timer:sleep(3000),
        _ = erpc:call(R1, ?MODULE, do_compact_all, []),

        %% R2 returns on its own data directory and rejoins.
        S2b = bondy_ct:restart_node(
            S2, 2, [{[partisan, peer_port], 18195}], Config
        ),
        %% `Nodes` still names the peer that was stopped above, so the outer
        %% `after` cannot reach the restarted one. Left running it outlives the
        %% suite, holding its peer port and retrying AAE against a node that is
        %% gone for the rest of the CT run.
        try
            {_, R2b, _} = S2b,
            ok = push_module(R2b, ?MODULE),
            ok = bondy_ct:rejoin(S2b, [S1, S2b], 60000),
            _ = erpc:call(R2b, application, set_env, [
                bondy_oplog, peer_timeout_ms, 2000
            ]),

            %% Direction 1: the returning node catches up on everything,
            %% including the range the survivor truncated.
            ok = wait_converge(R2b, ?USERS_TABLE, ?REALM, Shared, SharedV),
            ok = wait_converge(R2b, ?USERS_TABLE, ?REALM, Only1, Only1V),

            %% Direction 2: the returning node's isolated write flows BACK.
            ok = wait_converge(R1, ?USERS_TABLE, ?REALM, Only2, Only2V)
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

%% V1 of _plans/2026-08-28-safe-decode-atom-interning-review.md — MEASURED
%% 2026-08-28. A peer cell whose VALUE carries an atom absent from the
%% reader's atom table syncs CLEANLY: the sync protocol ships events as
%% Erlang TERMS (`bondy_oplog_event` op is `term()`, pages ride
%% `partisan_gen_server:call`), so Partisan's plain message decode interns
%% the atom on the reader BEFORE any bondy_oplog code runs. The CRDT
%% decode seats sit downstream of that interning and never see wire
%% bytes — their input is local projection frames (the restart case
%% below pins that half).
%%
%% The probe atom is minted at runtime ON the writer only
%% (`list_to_atom/1` over a string), so no module literal pool — including
%% this pushed suite module's — can have interned it on the reader; the
%% controller ships only the string, and Bondy replication is
%% Partisan-only (`connect_disterl => false`), so the only route to the
%% reader's atom table is the AAE sync itself.
runtime_atom_value_sync_measured(Config) ->
    [N1, N2, _N3] = nodes_of(Config),
    ProbeStr =
        "ct_probe_" ++ integer_to_list(erlang:unique_integer([positive])),
    ?assertEqual(false, erpc:call(N2, ?MODULE, do_atom_exists, [ProbeStr])),

    %% Relay the reader's error-level logs to the controller (capped — a
    %% runaway merge-retry loop must fill a counter, not our mailbox).
    ok = erpc:call(N2, ?MODULE, do_attach_error_relay, [self()]),
    try
        Key = <<"atom_probe">>,
        ok = erpc:call(
            N1,
            ?MODULE,
            do_apply_runtime_atom_value,
            [?USERS_TABLE, ?REALM, Key, ProbeStr]
        ),
        %% The writer's own projection holds it — its applier decodes the
        %% op after the mint, so the atom exists locally.
        ?assertMatch(
            {ok, {#{marker := _}, _}}, read_on(N1, ?USERS_TABLE, ?REALM, Key)
        ),

        %% Control written AFTER the probe, same table/band.
        CKey = <<"atom_probe_control">>,
        CVal = #{username => CKey, marker => <<"control">>},
        ok = apply_on(N1, ?USERS_TABLE, ?REALM, CKey, CVal),
        ControlOutcome =
            try wait_converge(N2, ?USERS_TABLE, ?REALM, CKey, CVal) of
                ok -> converged
            catch
                error:{converge_timeout, _, _, _, _, Last} ->
                    {timeout, Last}
            end,

        %% Extra forced pull rounds on the reader so per-round re-ship /
        %% re-fail behaviour becomes visible in the log record.
        ok = lists:foreach(
            fun(_) ->
                _ =
                    try
                        erpc:call(N2, bondy_oplog_sync_scheduler, trigger, [])
                    catch
                        _:_ -> ok
                    end,
                timer:sleep(500)
            end,
            lists:seq(1, 6)
        ),

        ProbeRead =
            try
                read_on(N2, ?USERS_TABLE, ?REALM, Key)
            catch
                C:R -> {'EXIT', {C, R}}
            end,
        AtomOnReader = erpc:call(N2, ?MODULE, do_atom_exists, [ProbeStr]),
        Logs = drain_peer_logs([]),
        ct:pal(
            "V1 MEASUREMENT~n"
            "  control cell: ~p~n"
            "  probe cell read on reader: ~p~n"
            "  probe atom interned on reader: ~p~n"
            "  reader error logs (~b, capped at 30):~n~p",
            [ControlOutcome, ProbeRead, AtomOnReader, length(Logs), Logs]
        ),

        %% The measured behaviour, pinned: the probe cell converged and is
        %% readable on the reader, the transport interned the peer's
        %% runtime atom, and no cell was skipped by the applier (the
        %% cell_apply catch never fired — its log says "skipped").
        ?assertEqual(converged, ControlOutcome),
        ?assertMatch({ok, {#{marker := M}, _}} when is_atom(M), ProbeRead),
        ?assertEqual(true, AtomOnReader),
        SkipLogs = [
            E
         || E <- Logs,
            string:find(lists:flatten(io_lib:format("~p", [E])), "skipped") =/=
                nomatch
        ],
        ?assertEqual([], SkipLogs),
        ok
    after
        ok = erpc:call(N2, ?MODULE, do_detach_error_relay, [])
    end.

%% V1b — the persisted half of the V1 measurement, on a dedicated 2-node
%% cluster. After the probe cell (runtime atom in its value) converges to
%% the reader and the reader COMPACTS — removing the probe EVENT from the
%% durable log, so boot replay cannot re-intern its atom — the reader
%% restarts on its own data directory with a fresh atom table. The only
%% remaining copy of the value is the projection frame; the pinned
%% contract is that its plain own-bytes decode
%% (`bondy_oplog_cell_kernel:decode_value_bytes/2`) returns the value and
%% re-interns the atom. The restarted reader deliberately does NOT rejoin
%% — a live sync round would re-ship the event as a term and the
%% transport would re-intern the atom, masking what the frame decode does
%% on its own.
runtime_atom_cell_read_after_restart_measured(Config) ->
    Names = [
        {bondy_v1, [{[partisan, peer_port], 18197}]},
        {bondy_v2, [{[partisan, peer_port], 18198}]}
    ],
    Nodes = bondy_ct:start_cluster(Names, Config),
    [S1, S2] = Nodes,
    {_, W, _} = S1,
    {_, R0, _} = S2,
    try
        _ = [push_module(N, ?MODULE) || N <- [W, R0]],
        ProbeStr =
            "ct_probe_" ++ integer_to_list(erlang:unique_integer([positive])),
        Key = <<"atom_probe_restart">>,
        ok = erpc:call(
            W,
            ?MODULE,
            do_apply_runtime_atom_value,
            [?USERS_TABLE, ?REALM, Key, ProbeStr]
        ),
        %% Live sync interns + applies on the reader (the V1 measurement).
        ok = wait_until(
            fun() ->
                _ =
                    try
                        erpc:call(R0, bondy_oplog_sync_scheduler, trigger, [])
                    catch
                        _:_ -> ok
                    end,
                case read_on(R0, ?USERS_TABLE, ?REALM, Key) of
                    {ok, {#{marker := M}, _}} -> atom_to_list(M) =:= ProbeStr;
                    _ -> false
                end
            end,
            ?CONVERGE_MS
        ),

        %% Compact the reader so the probe event leaves the durable log.
        %% Compaction needs the writer to have confirmed the reader's
        %% root, which a fixed sleep does not guarantee — and an event still
        %% in the live tree is decoded by the boot itself (measured: the
        %% failing runs were exactly those whose main-DB instances held live
        %% events after boot). So the PREMISE is waited for: the reader's
        %% main-DB instances hold no live event.
        _ = [
            erpc:call(N, application, set_env, [
                bondy_oplog, peer_timeout_ms, 2000
            ])
         || N <- [W, R0]
        ],
        ok = wait_until(
            fun() ->
                _ =
                    try
                        erpc:call(W, bondy_oplog_sync_scheduler, trigger, [])
                    catch
                        _:_ -> ok
                    end,
                _ = erpc:call(R0, ?MODULE, do_compact_all, []),
                erpc:call(R0, ?MODULE, do_main_live_events, []) =:= 0
            end,
            ?CONVERGE_MS
        ),

        %% The writer never compacted, so its live tree still holds the
        %% probe event, and the restarted reader keeps its persisted
        %% membership: a sync round right after its boot ships the event
        %% back as a term (measured: the reader's tree held it again, size 1,
        %% before the probe ran) and the transport interns the atom. The
        %% writer goes down first, so there is no round to race.
        %%
        %% Each mechanism alone failed this case ~1 run in 3 (2026-09-04);
        %% with both closed, 8/8.
        ok = bondy_ct:stop_node(S1),
        ok = bondy_ct:stop_node(S2),
        S2b = bondy_ct:restart_node(
            S2, 2, [{[partisan, peer_port], 18198}], Config
        ),
        try
            {_, Rb, _} = S2b,
            ok = push_module(Rb, ?MODULE),
            AtomAfterBoot = erpc:call(Rb, ?MODULE, do_atom_exists, [ProbeStr]),
            ColdRead =
                try
                    read_on(Rb, ?USERS_TABLE, ?REALM, Key)
                catch
                    C:R -> {'EXIT', {C, R}}
                end,
            AtomAfterRead = erpc:call(Rb, ?MODULE, do_atom_exists, [ProbeStr]),
            ct:pal(
                "V1b (post-restart)~n"
                "  atom interned after boot: ~p~n"
                "  cold read: ~p~n"
                "  atom interned after read: ~p",
                [AtomAfterBoot, ColdRead, AtomAfterRead]
            ),
            %% The F-4 contract, pinned: boot replay did not re-intern
            %% (the event was compacted away), yet the cold read of the
            %% node's own projection frame DECODES — plainly, per the C-2
            %% own-bytes rule — returning the value and re-interning its
            %% atom. Before F-4 this read raised `badarg` out of
            %% `binary_to_term(_, [safe])` at
            %% `bondy_oplog_cell_kernel:decode_value_bytes/2` (measured
            %% 2026-08-28; this case is the fix's falsifier).
            ?assertEqual(false, AtomAfterBoot),
            ?assertMatch({ok, {#{marker := M}, _}} when is_atom(M), ColdRead),
            ?assertEqual(true, AtomAfterRead),
            ok
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
%% CONTROLLER-SIDE HELPERS
%% =============================================================================

%% @private
nodes_of(Config) ->
    [Node || {_, Node, _} <- ?config(cluster, Config)].

%% @private
%% Retries `Fun` (which returns a boolean, or may raise) until it yields `true`
%% or the deadline passes. Nudges the sync scheduler is the caller's job inside
%% `Fun` where needed.
wait_until(Fun, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_until_loop(Fun, Deadline).

%% @private
wait_until_loop(Fun, Deadline) ->
    Ok =
        try Fun() of
            true -> true;
            _ -> false
        catch
            _:_ -> false
        end,
    case Ok of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    error(wait_until_timeout);
                false ->
                    timer:sleep(250),
                    wait_until_loop(Fun, Deadline)
            end
    end.

%% @private
%% Polls `Node` until its `token_version` for the user equals `Expected`,
%% forcing a sync tick each round.
wait_token_version(Node, Uri, User, Expected) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_token_version_loop(Node, Uri, User, Expected, Deadline).

%% @private
wait_token_version_loop(Node, Uri, User, Expected, Deadline) ->
    _ =
        try
            erpc:call(Node, bondy_oplog_sync_scheduler, trigger, [])
        catch
            _:_ -> ok
        end,
    Actual =
        try
            erpc:call(Node, bondy_rbac_user, token_version, [Uri, User])
        catch
            C:R -> {'EXIT', {C, R}}
        end,
    case Actual of
        {ok, Expected} ->
            ok;
        Other ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    error({token_version_timeout, Node, User, Expected, Other});
                false ->
                    timer:sleep(250),
                    wait_token_version_loop(Node, Uri, User, Expected, Deadline)
            end
    end.

%% @private
%% Polls `Node` until the user's derived group set (read from the membership
%% relation) equals `Expected` (sorted), forcing a sync tick each round.
wait_member_converge(Node, Uri, User, Expected) ->
    Sorted = lists:sort(Expected),
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_until_eq(
        fun() -> erpc:call(Node, ?MODULE, do_member_groups, [Uri, User]) end,
        Sorted,
        Node,
        Deadline
    ).

%% @private
%% Polls `Node` until every group in `Groups` exists in the realm (replicated
%% via AAE), forcing a sync tick each round.
wait_groups_exist(Node, Uri, Groups) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_until_eq(
        fun() -> erpc:call(Node, ?MODULE, do_groups_exist, [Uri, Groups]) end,
        true,
        Node,
        Deadline
    ).

%% @private
wait_until_eq(Fun, Expected, Node, Deadline) ->
    _ =
        try
            erpc:call(Node, bondy_oplog_sync_scheduler, trigger, [])
        catch
            _:_ -> ok
        end,
    Actual =
        try
            Fun()
        catch
            C:R -> {'EXIT', {C, R}}
        end,
    case Actual of
        Expected ->
            ok;
        Other ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    error({wait_eq_timeout, Node, Expected, Other});
                false ->
                    timer:sleep(250),
                    wait_until_eq(Fun, Expected, Node, Deadline)
            end
    end.

%% @private
%% Polls `Node` until the user exists locally (replicated via AAE), forcing a sync
%% tick each round.
wait_user_exists(Node, Uri, User) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_until_eq(
        fun() -> erpc:call(Node, ?MODULE, do_user_exists, [Uri, User]) end,
        true,
        Node,
        Deadline
    ).

%% @private
%% Polls `Node` until its merge reactor has called `close_sessions` for the user
%% (i.e. a peer's user delete drove the §9.5 reaction here), forcing a sync tick
%% each round.
wait_close_recorded(Node, Uri, User) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_until_eq(
        fun() -> erpc:call(Node, ?MODULE, do_close_recorded, [Uri, User]) end,
        true,
        Node,
        Deadline
    ).

%% @private
%% Polls `Node` until its routing trie holds exactly `Count` registrations
%% matching the procedure (the merge reactor having converged), forcing a sync
%% tick each round.
wait_reg_count(Node, Uri, Proc, Count) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_until_eq(
        fun() -> erpc:call(Node, ?MODULE, do_reg_count, [Uri, Proc]) end,
        Count,
        Node,
        Deadline
    ).

%% @private
%% Polls until `Node's local projection holds `Owner's registration summary
%% cell.
wait_rib_cell(Node, Uri, Proc, Owner) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_until_eq(
        fun() ->
            erpc:call(Node, ?MODULE, do_has_rib_cell, [Uri, Proc, Owner])
        end,
        true,
        Node,
        Deadline
    ).

%% @private
do_has_rib_cell(Uri, Proc, Owner) ->
    Table = bondy_namespace_catalog:table(bondy_registration_rib),
    Key = term_to_binary({Uri, <<"exact">>, Proc, Owner}),
    case bondy_db:read(Table, Uri, Key) of
        {ok, _} -> true;
        _ -> false
    end.

%% @private
%% Polls until `Node' holds `Count' stubs for `Owner's registration summary.
wait_rib_stub_count(Node, Uri, Proc, Owner, Count) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_until_eq(
        fun() ->
            Stubs = erpc:call(
                Node,
                bondy_registry_rib,
                stub_nodes,
                [registration, Uri, <<"exact">>, Proc]
            ),
            length([N || {N, _} <- Stubs, N =:= Owner])
        end,
        Count,
        Node,
        Deadline
    ).

%% @private
%% Polls until `Node's stub view names `SubNode' as a subscriber node for
%% `Topic' (any match policy).
wait_rib_sub_node(Node, Uri, Topic, SubNode) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_until_eq(
        fun() ->
            Ns = erpc:call(
                Node,
                bondy_registry_rib,
                subscription_nodes,
                [Uri, Topic, #{}]
            ),
            lists:member(SubNode, Ns)
        end,
        true,
        Node,
        Deadline
    ).

%% @private
%% Polls `Node's event probe until every element of `Args' has arrived as
%% the single positional argument of a delivered EVENT.
wait_probe_args(Node, Args) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_until_eq(
        fun() ->
            Seen = [
                A
             || #event{args = [A]} <-
                    erpc:call(Node, ?MODULE, do_probe_drain, [])
            ],
            [] =:= Args -- Seen
        end,
        true,
        Node,
        Deadline
    ).

%% @private
%% Polls until the realm has replicated to `Node' (rides the durable main
%% DB, a different AAE lane than the registry).
wait_realm(Node, Uri) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_until_eq(
        fun() -> erpc:call(Node, ?MODULE, do_has_realm, [Uri]) end,
        true,
        Node,
        Deadline
    ).

%% @private
%% Polls until `Node's RIB summary view agrees with its full-entry view for
%% the realm (`bondy_registry_rib:check/1` returns []).
wait_rib_check_empty(Node, Uri) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_until_eq(
        fun() -> erpc:call(Node, bondy_registry_rib, check, [Uri]) end,
        [],
        Node,
        Deadline
    ).

%% @private
apply_on(Node, Table, Band, Key, Val) ->
    erpc:call(Node, ?MODULE, do_apply, [Table, Band, Key, Val]).

%% @private
read_on(Node, Table, Band, Key) ->
    erpc:call(Node, ?MODULE, do_read, [Table, Band, Key]).

%% @private
%% Polls `Node' until its local read of `Key' returns `Expected', forcing a
%% sync tick each round so we don't merely wait on the periodic timer.
wait_converge(Node, Table, Band, Key, Expected) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_converge_loop(Node, Table, Band, Key, Expected, Deadline).

%% @private
wait_converge_loop(Node, Table, Band, Key, Expected, Deadline) ->
    %% Nudge the scheduler on the reading node to pull now.
    _ =
        try
            erpc:call(Node, bondy_oplog_sync_scheduler, trigger, [])
        catch
            _:_ -> ok
        end,
    case read_on(Node, Table, Band, Key) of
        {ok, {Expected, _Hlc}} ->
            ok;
        Other ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    error({converge_timeout, Node, Table, Band, Key, Other});
                false ->
                    timer:sleep(250),
                    wait_converge_loop(
                        Node, Table, Band, Key, Expected, Deadline
                    )
            end
    end.

%% @private
%% Polls `Node`'s collector until it has recorded a merge event whose key
%% carries `Username` (the cell key is the G-1 realm-folded `<<Realm,0,User>>`,
%% so we match on substring rather than equality).
wait_for_merge_event(Node, Username, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_merge_event_loop(Node, Username, Deadline).

%% @private
wait_for_merge_event_loop(Node, Username, Deadline) ->
    Events = erpc:call(Node, ?MODULE, collector_drain, []),
    Found = [
        K
     || {bondy_oplog_core_merge_event, _NS, K, _Hlc, _Op, _Old} <- Events,
        binary:match(K, Username) =/= nomatch
    ],
    case Found of
        [_ | _] ->
            ok;
        [] ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    error({no_merge_event, Node, Username, Events});
                false ->
                    timer:sleep(250),
                    wait_for_merge_event_loop(Node, Username, Deadline)
            end
    end.

%% @private
%% Drains relayed peer log events until the mailbox stays quiet for 1s.
drain_peer_logs(Acc) ->
    receive
        {peer_log, _Node, E} -> drain_peer_logs([E | Acc])
    after 1000 ->
        lists:reverse(Acc)
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
do_apply(Table, Band, Key, Val) ->
    Tab = table_handle(Table),
    bondy_db:apply(Tab, Band, Key, {set, Val}).

%% @private
do_read(Table, Band, Key) ->
    Tab = table_handle(Table),
    bondy_db:read(Tab, Band, Key).

%% @private
table_handle(Table) ->
    case bondy_namespace_catalog:table(Table) of
        undefined -> error({table_not_provisioned, Table});
        Tab -> Tab
    end.

%% @private
do_namespace(Table) ->
    bondy_db:namespace(table_handle(Table)).

%% @private
do_create_simple_realm(Uri) ->
    _ = bondy_realm:create(Uri),
    ok.

%% @private
%% A realm with security disabled, so an anonymous local context can CALL.
do_create_open_realm(Uri) ->
    Realm = bondy_realm:create(Uri),
    ok = bondy_realm:disable_security(Realm),
    ok.

%% @private
%% Register the echo callback on THIS node.
do_register_echo(Uri, Proc) ->
    Ref = bondy_ref:new(internal, {?MODULE, rib_echo}),
    case bondy_dealer:register(Proc, #{invoke => <<"single">>}, Uri, Ref) of
        {ok, _} -> ok;
        Other -> error({register_failed, Other})
    end.

%% The dynamic-callback convention: {ok, Details, Args, KWArgs} -> RESULT.
rib_echo() ->
    {ok, #{}, [<<"pong">>], #{}}.

rib_echo(_) ->
    rib_echo().

rib_echo(_, _) ->
    rib_echo().

%% @private
%% Make a CALL from THIS node using a minimal anonymous local context whose
%% caller ref targets this process; returns the WAMP response message.
do_rib_call(RealmUri, Proc) ->
    do_rib_call(RealmUri, Proc, #{}).

%% @private
%% As `do_rib_call/2` with CALL options — going through the message
%% constructor, so bondy extensions (e.g. `routing_max_candidates`) also
%% exercise the options validation.
do_rib_call(RealmUri, Proc, CallOpts) ->
    Peer = {{127, 0, 0, 1}, 10999},
    Session = bondy_session:new(RealmUri, #{
        peer => Peer,
        authid => <<"rib">>,
        authmethod => ?WAMP_ANON_AUTH,
        is_anonymous => true,
        security_enabled => false,
        authroles => [<<"anonymous">>],
        roles => #{caller => #{}}
    }),
    Ctxt = bondy_context:new(Peer, {ws, text, json}, #{session => Session}),
    Call = bondy_wamp_message:call(1, CallOpts, Proc),
    ok = bondy_dealer:forward(Call, Ctxt),
    receive
        {'$bondy_request', _, _, M} -> M
    after 30000 ->
        timeout
    end.

%% @private
%% Publish from THIS node using a minimal anonymous local context (like
%% `do_rib_call/2` but for the broker path).
do_rib_publish(RealmUri, Topic, Args) ->
    Peer = {{127, 0, 0, 1}, 10998},
    Session = bondy_session:new(RealmUri, #{
        peer => Peer,
        authid => <<"ribpub">>,
        authmethod => ?WAMP_ANON_AUTH,
        is_anonymous => true,
        security_enabled => false,
        authroles => [<<"anonymous">>],
        roles => #{publisher => #{}}
    }),
    Ctxt = bondy_context:new(Peer, {ws, text, json}, #{session => Session}),
    Publish = bondy_wamp_message:publish(1, #{}, Topic, Args),
    ok = bondy_broker:forward(Publish, Ctxt).

%% @private
%% Spawns a long-lived event probe on THIS node, registered as
%% `rib_event_probe': one internal subscriber ref carrying the probe pid,
%% subscribed to each `{Topic, Opts}'. Records every EVENT it is delivered.
do_start_event_probe(RealmUri, Subscriptions) ->
    Parent = self(),
    Pid = spawn(fun() -> probe_init(RealmUri, Subscriptions, Parent) end),
    receive
        {Pid, ready} -> ok
    after 5000 ->
        error(probe_start_timeout)
    end,
    %% Re-register if a previous test left one behind.
    try
        unregister(rib_event_probe)
    catch
        _:_ -> ok
    end,
    true = register(rib_event_probe, Pid),
    ok.

%% @private
probe_init(RealmUri, Subscriptions, Parent) ->
    %% A STORED session backs the subscriptions: the registry requires a
    %% session id on the subscribe path, and the owner self-clean sweep
    %% reaps entries whose session cannot be looked up — this probe must
    %% outlive several convergence waits.
    Session0 = bondy_session:new(RealmUri, #{
        peer => {{127, 0, 0, 1}, 10997},
        authid => <<"ribprobe">>,
        authmethod => ?WAMP_ANON_AUTH,
        is_anonymous => true,
        security_enabled => false,
        authroles => [<<"anonymous">>],
        roles => #{subscriber => #{}}
    }),
    {ok, Session} = bondy_session:store(Session0),
    Ref = bondy_ref:new(internal, self(), bondy_session:id(Session)),
    _ = [
        case bondy_registry:add(subscription, RealmUri, Topic, Opts, Ref) of
            {ok, _, _} -> ok;
            {ok, _} -> ok;
            Other -> error({subscription_add_failed, Other})
        end
     || {Topic, Opts} <- Subscriptions
    ],
    Parent ! {self(), ready},
    probe_loop([]).

%% @private
probe_loop(Acc) ->
    receive
        {get, From} ->
            From ! {rib_event_probe_events, lists:reverse(Acc)},
            probe_loop(Acc);
        {'$bondy_request', _, _, #event{} = E} ->
            probe_loop([E | Acc]);
        _Other ->
            probe_loop(Acc)
    end.

%% @private
do_probe_drain() ->
    rib_event_probe ! {get, self()},
    receive
        {rib_event_probe_events, Events} -> Events
    after 5000 ->
        error(probe_drain_timeout)
    end.

%% @private
do_has_realm(Uri) ->
    case bondy_realm:lookup(Uri) of
        {ok, _} -> true;
        _ -> false
    end.

%% @private
%% Add a callback registration owned by THIS node for `Proc`. A callback ref is
%% node-bound and process-independent, so the entry survives the erpc worker
%% exiting and is seen as remote (owner = this node) on the other nodes.
do_add_registration(Uri, Proc) ->
    Ref = bondy_ref:new(internal, {bondy_wamp_api, resolve}),
    Opts = #{match => <<"exact">>, invoke => <<"single">>},
    case bondy_registry:add(registration, Uri, Proc, Opts, Ref) of
        {ok, _, _} -> ok;
        {ok, _} -> ok;
        Other -> error({registration_add_failed, Other})
    end.

%% @private
do_remove_registration(Uri, Proc) ->
    case do_reg_entries(Uri, Proc) of
        [Entry | _] -> bondy_registry:remove(Entry);
        [] -> ok
    end,
    ok.

%% @private
do_reg_count(Uri, Proc) ->
    length(do_reg_entries(Uri, Proc)).

%% @private
do_owner_node(Uri, Proc) ->
    case do_reg_entries(Uri, Proc) of
        [Entry | _] -> bondy_registry_entry:node(Entry);
        [] -> undefined
    end.

%% @private
do_reg_entries(Uri, Proc) ->
    case bondy_registry:match(registration, Uri, Proc) of
        L when is_list(L) -> L;
        {L, _Cont} when is_list(L) -> L;
        _ -> []
    end.

%% @private
wait_has_matches(Node, Uri, Topic, Expected) ->
    %% This case runs late in a heavy suite where the periodic sync
    %% scheduler has slowed (see the ?CONVERGE_MS note), so give the
    %% cross-node registry convergence a doubled budget rather than share
    %% the ceiling that is already documented as marginal at this depth.
    Deadline = erlang:monotonic_time(millisecond) + 2 * ?CONVERGE_MS,
    wait_until_eq(
        fun() ->
            erpc:call(Node, bondy_registry, has_matches, [
                subscription, Uri, Topic
            ])
        end,
        Expected,
        Node,
        Deadline
    ).

%% @private
%% The subscriber must be a LIVE process on this node: a process-less
%% callback ref works for registrations but a subscription without a
%% live target can be reaped by registry hygiene between assertions
%% (observed as a full-suite-only flake). The keeper simply outlives the
%% erpc worker.
do_add_meta_subscription(Uri, Topic) ->
    Keeper = spawn(?MODULE, keeper_loop, []),
    Ref = bondy_ref:new(internal, Keeper, bondy_session_id:new()),
    case bondy_registry:add(subscription, Uri, Topic, #{}, Ref) of
        {ok, _, _} -> ok;
        {ok, _} -> ok;
        Other -> error({subscription_add_failed, Other})
    end.

%% @private
%% Tolerant of an already-reaped entry: the subscription is backed by a
%% fabricated session id, so registry hygiene may reap it after the
%% cross-node assertion has already observed it. Either way the
%% subsequent `wait_has_matches(_, false)` confirms the removed state
%% converges.
do_remove_meta_subscription(Uri, Topic) ->
    case bondy_registry:match(subscription, Uri, Topic) of
        {[Entry | _], _Nodes} -> bondy_registry:remove(Entry);
        _ -> ok
    end.

%% @private
%% Long-lived subscriber target for do_add_meta_subscription/2.
keeper_loop() ->
    receive
        stop -> ok
    end.

%% @private
do_create_user_realm(Uri, User) ->
    _ = bondy_realm:create(#{
        uri => Uri,
        description => <<"user-delete cluster test realm">>,
        security_enabled => true,
        authmethods => [?PASSWORD_AUTH],
        users => [
            #{username => User, password => <<"victim_pass_123">>, groups => []}
        ]
    }),
    ok.

%% @private
do_delete_user(Uri, User) ->
    bondy_rbac_user:remove(Uri, User).

%% @private
do_user_exists(Uri, User) ->
    case bondy_rbac_user:lookup(Uri, User) of
        {ok, _} -> true;
        _ -> false
    end.

%% @private
%% Override `close_sessions/3` on this node so a reactor call is recorded (and
%% has no side effect — there is no live session). `no_link` keeps the mock
%% installed after the erpc worker that armed it exits.
do_arm_close_recorder() ->
    _ =
        try
            meck:unload(bondy_rbac_user)
        catch
            _:_ -> ok
        end,
    ok = meck:new(bondy_rbac_user, [passthrough, no_link]),
    ok = meck:expect(bondy_rbac_user, close_sessions, fun(_, _, _) -> ok end),
    ok.

%% @private
do_close_recorded(Uri, User) ->
    meck:called(bondy_rbac_user, close_sessions, [Uri, User, '_']).

%% @private
do_disarm_close_recorder() ->
    _ =
        try
            meck:unload(bondy_rbac_user)
        catch
            _:_ -> ok
        end,
    ok.

%% @private
do_create_member_realm(Uri, User, Groups) ->
    _ = bondy_realm:create(#{
        uri => Uri,
        description => <<"membership cluster test realm">>,
        security_enabled => true,
        authmethods => [?PASSWORD_AUTH],
        groups => [#{name => G} || G <- Groups],
        users => [
            #{username => User, password => <<"mem_pass_123">>, groups => []}
        ]
    }),
    ok.

%% @private
do_add_member(Uri, User, Group) ->
    bondy_rbac_user:add_group(Uri, User, Group).

%% @private
%% The user's derived groups (from the membership relation), sorted; or the
%% lookup error when the user has not converged yet.
do_member_groups(Uri, User) ->
    case bondy_rbac_user:lookup(Uri, User) of
        {ok, U} -> lists:sort(bondy_rbac_user:groups(U));
        Other -> Other
    end.

%% @private
do_groups_exist(Uri, Groups) ->
    lists:all(fun(G) -> bondy_rbac_group:exists(Uri, G) end, Groups).

%% @private
do_set_max_lag(Ms) ->
    application:set_env(bondy_router, auth_max_lag, Ms).

%% @private
do_create_auth_realm(Uri, User, Pass) ->
    _ = bondy_realm:create(#{
        uri => Uri,
        description => <<"token_version cluster test realm">>,
        security_enabled => true,
        authmethods => [?WAMP_OAUTH2_AUTH, ?PASSWORD_AUTH],
        users => [#{username => User, password => Pass, groups => []}],
        grants => [
            #{
                permissions => [<<"wamp.call">>],
                uri => <<"">>,
                match => <<"prefix">>,
                roles => [User]
            }
        ],
        sources => [
            #{
                usernames => [User],
                authmethod => ?WAMP_OAUTH2_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    }),
    ok.

%% @private
%% Diagnostic snapshot of this node's readiness to issue + authenticate for the
%% user: whether the realm/user converged, and the raw issue/authenticate
%% results (exceptions captured as terms).
do_diag(Uri, User) ->
    RealmFound =
        try bondy_realm:lookup(Uri) of
            {ok, _} -> true;
            Other -> Other
        catch
            C0:R0 -> {'EXIT', {C0, R0}}
        end,
    TV =
        try
            bondy_rbac_user:token_version(Uri, User)
        catch
            C1:R1 -> {'EXIT', {C1, R1}}
        end,
    Issue =
        try do_issue_jwt(Uri, User) of
            J when is_binary(J) -> {ok, J}
        catch
            C:R -> {issue_error, C, R}
        end,
    Auth =
        case Issue of
            {ok, JWT} ->
                try
                    do_authenticate(Uri, User, JWT)
                catch
                    _:_ -> ok
                end;
            _ ->
                not_issued
        end,
    #{
        realm => RealmFound,
        tv => TV,
        issue_ok => element(1, Issue),
        auth => Auth
    }.

%% @private
do_issue_jwt(Uri, User) ->
    SessionId = bondy_session_id:new(),
    {ok, Ctxt} = bondy_auth:init(SessionId, Uri, User, [], {127, 0, 0, 1}),
    {ok, Token} = bondy_oauth_token:issue(password, Ctxt, #{}),
    {ok, {JWT, _}} = bondy_oauth_token:to_access_token(Token),
    JWT.

%% @private
do_authenticate(Uri, User, JWT) ->
    SessionId = bondy_session_id:new(),
    {ok, Ctxt} = bondy_auth:init(SessionId, Uri, User, [], {127, 0, 0, 1}),
    bondy_auth:authenticate(?WAMP_OAUTH2_AUTH, JWT, #{}, Ctxt).

%% @private
%% Spawns a long-lived collector on this node subscribed to `NS`, registered as
%% `merge_collector`, recording every dispatcher event it receives. Returns once
%% the subscription is in place (so a subsequent remote write can't race it).
start_collector(NS) ->
    Parent = self(),
    Pid = spawn(fun() -> collector_init(NS, Parent) end),
    receive
        {Pid, ready} -> ok
    after 5000 ->
        error(collector_start_timeout)
    end,
    %% Re-register if a previous test left one behind.
    try
        unregister(merge_collector)
    catch
        _:_ -> ok
    end,
    true = register(merge_collector, Pid),
    ok.

%% @private
collector_init(NS, Parent) ->
    {ok, _Ref} = bondy_oplog_core:subscribe(NS, all),
    Parent ! {self(), ready},
    collector_loop([]).

%% @private
collector_loop(Acc) ->
    receive
        {get, From} ->
            From ! {merge_collector_events, lists:reverse(Acc)},
            collector_loop(Acc);
        {bondy_oplog_core_merge_event, _, _, _, _, _} = E ->
            collector_loop([E | Acc]);
        {bondy_oplog_core_event, _, _, _, _} = E ->
            collector_loop([E | Acc]);
        _Other ->
            collector_loop(Acc)
    end.

%% @private
collector_drain() ->
    merge_collector ! {get, self()},
    receive
        {merge_collector_events, Events} -> Events
    after 5000 ->
        error(collector_drain_timeout)
    end.

%% @private
%% Builds the probe value ON this node: the atom is minted here and nowhere
%% else, so it exists only in this VM's atom table when the write happens.
do_apply_runtime_atom_value(Table, Band, Key, ProbeStr) ->
    Atom = list_to_atom(ProbeStr),
    do_apply(Table, Band, Key, #{username => Key, marker => Atom}).

%% @private
%% `list_to_existing_atom/1` probes the atom table without interning.
do_atom_exists(Str) ->
    try
        _ = list_to_existing_atom(Str),
        true
    catch
        error:badarg -> false
    end.

%% @private
%% Attaches this module as a logger handler relaying error-level events to
%% `To`, capped at 30 (the budget atomics counter lives on THIS node).
do_attach_error_relay(To) ->
    Counter = atomics:new(1, []),
    logger:add_handler(aae_atom_probe_relay, ?MODULE, #{
        level => error,
        config => #{to => To, budget => Counter}
    }).

%% @private
do_detach_error_relay() ->
    logger:remove_handler(aae_atom_probe_relay).

%% Logger handler callback (see `do_attach_error_relay/1`).
log(LogEvent, #{config := #{to := To, budget := Counter}}) ->
    case atomics:add_get(Counter, 1, 1) =< 30 of
        true -> To ! {peer_log, node(), LogEvent};
        false -> ok
    end,
    ok.

%% @private
%% Runs a compaction cycle on every oplog instance of this node, so durable
%% truncation actually happens instead of waiting on the scheduler's cadence.
%% Live (uncompacted) events across the node's main-DB instances.
do_main_live_events() ->
    Main = bondy_namespace_catalog:main_db_name(),
    lists:sum([
        bondy_oplog:size(I)
     || I <- bondy_oplog:list_instances(), bondy_oplog:db_of(I) =:= Main
    ]).

do_compact_all() ->
    _ = [
        try
            bondy_oplog_instance:compact(I, [])
        catch
            _:_ -> ok
        end
     || I <- bondy_oplog:list_instances()
    ],
    ok.
