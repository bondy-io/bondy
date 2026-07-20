%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_aae_cluster_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bondy_security.hrl").

-compile([nowarn_export_all, export_all]).

%% A 3-node Partisan cluster with bondy_db anti-entropy (`oplog.aae') enabled.
%% Each node runs the full bondy_router stack with all client listeners
%% disabled and an isolated data dir / Partisan port (see
%% `bondy_ct:start_cluster/2'). These tests write through `bondy_db' on one
%% node and assert the value converges on the others via the periodic sync
%% scheduler over the Partisan transport — i.e. the production AAE path, not a
%% hand-called `bondy_oplog:sync/3'.

-define(NODE_NAMES, [bondy1, bondy2, bondy3]).
%% A per-realm durable core table (band = realm URI, exercises G-1 realm
%% folding) and a global-band durable core table (band = <<>>).
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
        registry_registration_converges_and_presence,
        remote_user_delete_closes_peer_sessions,
        token_version_rejected_cross_node
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

%% The registry presence machine end-to-end (STORAGE_ARCHITECTURE §9.6). The
%% `registry` is an EPHEMERAL, memory-topology bondy_db DB; this is the only test
%% that exercises AAE over that topology (the others use the durable `core`).
%%
%% A registration authored on node 1 must:
%%   1. converge into nodes 2 & 3's ROUTING TRIE (the materialised view the merge
%%      reactor maintains, separate from the projection AAE merges into) — i.e. a
%%      peer learns it can route to node 1's callee;
%%   2. be MASKED on node 2 when node 1 is seen down (presence SUSPEND) and
%%      RESTORED when it returns (presence RESUME) — without node 1 re-asserting,
%%      which is what makes a partition heal transparent to a connected client;
%%   3. be removed cluster-wide when node 1 DELETEs it (the `clear` rides AAE and
%%      every peer's merge reactor drops it from its trie).
registry_registration_converges_and_presence(Config) ->
    [N1, N2, N3] = nodes_of(Config),
    Uri = <<"com.bondy.aae_registry">>,
    Proc = <<"com.example.aae_proc">>,

    %% Realm authored on node 1, converged everywhere (registrations are scoped to
    %% it; the realm rides the durable core).
    ok = erpc:call(N1, ?MODULE, do_create_simple_realm, [Uri]),

    %% A registration on node 1 must appear in every node's trie (1 match each).
    ok = erpc:call(N1, ?MODULE, do_add_registration, [Uri, Proc]),
    ?assertEqual(1, erpc:call(N1, ?MODULE, do_reg_count, [Uri, Proc])),
    [ok = wait_reg_count(N, Uri, Proc, 1) || N <- [N2, N3]],

    %% Presence SUSPEND: tell node 2 that node 1 is down → its entry is masked
    %% (out of the routing trie), retained for a RESUME.
    Owner = erpc:call(N2, ?MODULE, do_owner_node, [Uri, Proc]),
    ?assert(Owner =/= undefined andalso Owner =/= node()),
    ok = erpc:call(N2, ?MODULE, do_signal, [{nodedown, Owner}]),
    ok = wait_reg_count(N2, Uri, Proc, 0),

    %% Presence RESUME: node 1 returns → node 2 unmasks it back into the trie,
    %% WITHOUT node 1 re-asserting (node 1 was never told anything).
    ok = erpc:call(N2, ?MODULE, do_signal, [{nodeup, Owner}]),
    ok = wait_reg_count(N2, Uri, Proc, 1),

    %% DELETE on node 1 converges: the `clear` rides AAE and every peer's merge
    %% reactor drops it from its trie.
    ok = erpc:call(N1, ?MODULE, do_remove_registration, [Uri, Proc]),
    [ok = wait_reg_count(N, Uri, Proc, 0) || N <- [N1, N2, N3]],
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
    _ = catch erpc:call(Node, bondy_oplog_sync_scheduler, trigger, []),
    case catch erpc:call(Node, bondy_rbac_user, token_version, [Uri, User]) of
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
    _ = catch erpc:call(Node, bondy_oplog_sync_scheduler, trigger, []),
    case catch Fun() of
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
%% matching the procedure (the merge reactor / presence machine having
%% converged), forcing a sync tick each round.
wait_reg_count(Node, Uri, Proc, Count) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CONVERGE_MS,
    wait_until_eq(
        fun() -> erpc:call(Node, ?MODULE, do_reg_count, [Uri, Proc]) end,
        Count,
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
    _ = catch erpc:call(Node, bondy_oplog_sync_scheduler, trigger, []),
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
%% Deliver a synthetic Partisan membership event to this node's registry server
%% (the presence SUSPEND / RESUME seam, normally fed by `partisan:monitor_nodes`).
do_signal(Msg) ->
    bondy_registry ! Msg,
    ok.

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
    _ = (catch meck:unload(bondy_rbac_user)),
    ok = meck:new(bondy_rbac_user, [passthrough, no_link]),
    ok = meck:expect(bondy_rbac_user, close_sessions, fun(_, _, _) -> ok end),
    ok.

%% @private
do_close_recorded(Uri, User) ->
    meck:called(bondy_rbac_user, close_sessions, [Uri, User, '_']).

%% @private
do_disarm_close_recorder() ->
    _ = (catch meck:unload(bondy_rbac_user)),
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
        case catch bondy_realm:lookup(Uri) of
            {ok, _} -> true;
            Other -> Other
        end,
    TV = catch bondy_rbac_user:token_version(Uri, User),
    Issue =
        try do_issue_jwt(Uri, User) of
            J when is_binary(J) -> {ok, J}
        catch
            C:R -> {issue_error, C, R}
        end,
    Auth =
        case Issue of
            {ok, JWT} -> catch do_authenticate(Uri, User, JWT);
            _ -> not_issued
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
    catch unregister(merge_collector),
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
