%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Unit tests for strategy-aware shard routing (AR-2 / AR-3): the pure
%% `bondy_db:shard_for/3` decision and its `aggregate_root/2` extractor,
%% pinning the co-location invariant that makes an atomic per-subject batch
%% possible — a subject's record (`identity`) and its grants / sources
%% (`leading_col` composite keys) hash to the SAME shard, while distinct
%% subjects spread across shards.
%%
%% Pure routing logic — no shards, no Bookies, no Partisan. `shard_for/3` and
%% `aggregate_root/2` are exposed under `-ifdef(TEST)`.
%% =============================================================================

-module(bondy_db_shard_routing_test).

-include_lib("eunit/include/eunit.hrl").

-define(SC, 16).
-define(REALM, <<"com.example.tenant1">>).

%% A synthetic aggregate-strategy table for a given aggregate-root extractor.
%% These are the only fields `shard_for/3` reads for the `aggregate` / `realm`
%% strategies (the `entity` strategy additionally needs a real topology, which
%% the 112 catalogue/db eunit tests already exercise via the default).
agg_table(AggregateRoot) ->
    #{
        shard_count => ?SC,
        partition_strategy => aggregate,
        aggregate_root => AggregateRoot
    }.

realm_table(Depth) ->
    #{
        shard_count => ?SC,
        partition_strategy => realm,
        realm_prefix_depth => Depth
    }.

%% A grant / source composite key as bondy_rbac / bondy_rbac_source build it:
%% the subject as a type-tagged leading column, a 0x00 separator, then the
%% deterministic term_to_binary of the rest.
composite_key(Subject, Rest) ->
    <<
        (bondy_oplog_index_key:encode_col(Subject))/binary,
        0,
        (term_to_binary(Rest, [deterministic]))/binary
    >>.

%% =============================================================================
%% aggregate_root/2
%% =============================================================================

aggregate_root_identity_test() ->
    ?assertEqual(<<"alice">>, bondy_db:aggregate_root(identity, <<"alice">>)).

aggregate_root_leading_col_decodes_subject_test() ->
    %% A grant key { "alice", Resource } decodes back to the plain subject the
    %% user record is keyed by — the exact term equality co-location relies on.
    GrantKey = composite_key(<<"alice">>, {any, all}),
    ?assertEqual(
        <<"alice">>, bondy_db:aggregate_root(leading_col, GrantKey)
    ).

aggregate_root_leading_col_atom_subject_test() ->
    %% Reserved atom roles (`all` / `anonymous`) round-trip too.
    Key = composite_key(all, {<<"r">>, prefix}),
    ?assertEqual(all, bondy_db:aggregate_root(leading_col, Key)).

aggregate_root_leading_col_no_separator_test() ->
    %% Defensive: a non-composite key under a leading_col table falls back to
    %% the whole key (0x00-free encode_col output has no separator to split on).
    NoSep = <<1, 2, 3, 4>>,
    ?assertEqual(NoSep, bondy_db:aggregate_root(leading_col, NoSep)).

aggregate_root_second_col_forward_test() ->
    %% A forward membership cell `[<<"f">>, User, Group]` routes by its SECOND
    %% column (the user), skipping the band marker, so it co-locates with the
    %% user record (keyed by the plain user term).
    FwdKey = bondy_oplog_index_key:encode_tuple(
        [<<"f">>, <<"alice">>, <<"admins">>]
    ),
    ?assertEqual(<<"alice">>, bondy_db:aggregate_root(second_col, FwdKey)).

aggregate_root_second_col_reverse_test() ->
    %% A reverse membership cell `[<<"r">>, Group, User]` routes by the group.
    RevKey = bondy_oplog_index_key:encode_tuple(
        [<<"r">>, <<"admins">>, <<"alice">>]
    ),
    ?assertEqual(<<"admins">>, bondy_db:aggregate_root(second_col, RevKey)).

aggregate_root_second_col_band_prefix_test() ->
    %% A two-column band prefix `[<<"f">>, User]` (no trailing column) still
    %% yields the entity — the second column runs to the end of the key.
    Prefix = bondy_oplog_index_key:encode_tuple([<<"f">>, <<"alice">>]),
    ?assertEqual(<<"alice">>, bondy_db:aggregate_root(second_col, Prefix)).

%% =============================================================================
%% Co-location (aggregate strategy)
%% =============================================================================

user_grant_source_colocate_test() ->
    %% The whole point of AR-2: alice's user record + her grants + her sources
    %% all land on one shard, so a token_version bump + grant write is one
    %% atomic per-shard batch (#73).
    UserT = agg_table(identity),
    GrantT = agg_table(leading_col),
    SourceT = agg_table(leading_col),

    UserKey = <<"alice">>,
    GrantKey = composite_key(<<"alice">>, {{<<"uri">>, exact}, [<<"call">>]}),
    SourceKey = composite_key(<<"alice">>, {{0, 0, 0, 0, 0}, password}),

    UserShard = bondy_db:shard_for(UserT, ?REALM, UserKey),
    ?assertEqual(UserShard, bondy_db:shard_for(GrantT, ?REALM, GrantKey)),
    ?assertEqual(UserShard, bondy_db:shard_for(SourceT, ?REALM, SourceKey)).

membership_colocates_with_entity_test() ->
    %% Membership cells co-locate with their leading entity: a user's FORWARD
    %% cells land on the user record's shard (so the hot auth-path group join
    %% and a list page's group join are single-shard), a group's REVERSE cells
    %% land on the group record's shard (so "members of a group" is single-shard).
    UserT = agg_table(identity),
    MemberT = agg_table(second_col),

    UserShard = bondy_db:shard_for(UserT, ?REALM, <<"alice">>),
    GroupShard = bondy_db:shard_for(UserT, ?REALM, <<"admins">>),
    FwdKey = bondy_oplog_index_key:encode_tuple(
        [<<"f">>, <<"alice">>, <<"admins">>]
    ),
    RevKey = bondy_oplog_index_key:encode_tuple(
        [<<"r">>, <<"admins">>, <<"alice">>]
    ),
    ?assertEqual(UserShard, bondy_db:shard_for(MemberT, ?REALM, FwdKey)),
    ?assertEqual(GroupShard, bondy_db:shard_for(MemberT, ?REALM, RevKey)).

distinct_subjects_spread_test() ->
    %% Distinct subjects must spread across more than one shard (else a single
    %% realm would serialise on one core — the failure aggregate-sharding
    %% exists to avoid). Deterministic (phash2), so not flaky.
    UserT = agg_table(identity),
    Subjects = [
        list_to_binary("user_" ++ integer_to_list(N))
     || N <- lists:seq(1, 100)
    ],
    Shards = lists:usort(
        [bondy_db:shard_for(UserT, ?REALM, S) || S <- Subjects]
    ),
    ?assert(length(Shards) > 1).

realm_is_part_of_aggregate_shard_test() ->
    %% The same subject in two realms is NOT forced onto one shard — the realm
    %% is part of the aggregate hash key, preserving realm separation at the
    %% shard level. (We can't assert inequality for one pair without risking a
    %% hash collision, so assert that across realms the same subject spreads.)
    UserT = agg_table(identity),
    Realms = [
        list_to_binary("com.example.r" ++ integer_to_list(N))
     || N <- lists:seq(1, 100)
    ],
    Shards = lists:usort(
        [bondy_db:shard_for(UserT, R, <<"alice">>) || R <- Realms]
    ),
    ?assert(length(Shards) > 1).

%% =============================================================================
%% realm strategy
%% =============================================================================

realm_strategy_one_shard_per_realm_test() ->
    %% Every key in a realm routes to the same shard regardless of the key.
    T = realm_table(1),
    S = bondy_db:shard_for(T, ?REALM, <<"k1">>),
    ?assertEqual(S, bondy_db:shard_for(T, ?REALM, <<"k2">>)),
    ?assertEqual(S, bondy_db:shard_for(T, ?REALM, <<"anything">>)).

realm_strategy_prefix_depth_groups_realms_test() ->
    %% depth = 1 groups realms by their first dotted component.
    T = realm_table(1),
    S = bondy_db:shard_for(T, <<"com.a.x">>, <<"k">>),
    ?assertEqual(S, bondy_db:shard_for(T, <<"com.b.y">>, <<"k">>)),
    ?assertEqual(S, bondy_db:shard_for(T, <<"com">>, <<"k">>)).

realm_strategy_deep_prefix_separates_test() ->
    %% A depth >= the segment count uses the whole realm, so two realms that
    %% differ only in a deep segment can land on different shards. Asserted
    %% statistically (deterministic) to avoid a single-pair collision flake.
    T = realm_table(5),
    Realms = [
        list_to_binary("com.example.app." ++ integer_to_list(N))
     || N <- lists:seq(1, 100)
    ],
    Shards = lists:usort([bondy_db:shard_for(T, R, <<"k">>) || R <- Realms]),
    ?assert(length(Shards) > 1).
