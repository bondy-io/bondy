%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rbac_proper_SUITE).
-moduledoc """
Property-based tests for the RBAC subsystem.

Uses PropEr to verify invariants of pure/deterministic RBAC functions:
is_reserved_name, normalise_name, group topsort, externalize_grant,
and grant/revoke symmetry.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("proper/include/proper.hrl").

-include("bondy_security.hrl").

-compile([nowarn_export_all, export_all]).

-define(NUMTESTS, 100).


all() ->
    [
        %% Pure property tests (no Bondy needed)
        prop_reserved_names_complete,
        prop_normalise_name_idempotent,
        prop_normalise_name_lowercase,
        prop_topsort_preserves_elements,
        prop_topsort_respects_order,
        prop_externalize_grant_has_required_keys,

        %% Integration property tests (need Bondy)
        prop_grant_revoke_symmetry,
        prop_grant_accumulates_permissions
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Config.


end_per_suite(Config) ->
    {save_config, Config}.



%% =============================================================================
%% GENERATORS
%% =============================================================================



%% @private
groupname() ->
    ?LET(
        Parts,
        non_empty(list(oneof([
            binary(4),
            elements([<<"svc">>, <<"admin">>, <<"ops">>, <<"dev">>])
        ]))),
        iolist_to_binary(lists:join(<<".">>, Parts))
    ).


%% @private
permission() ->
    elements([
        <<"wamp.call">>,
        <<"wamp.register">>,
        <<"wamp.unregister">>,
        <<"wamp.subscribe">>,
        <<"wamp.unsubscribe">>,
        <<"wamp.cancel">>,
        <<"wamp.publish">>
    ]).


%% @private
permissions() ->
    non_empty(list(permission())).


%% @private
match_strategy() ->
    elements([<<"exact">>, <<"prefix">>]).


%% @private
valid_uri_for_strategy(<<"exact">>) ->
    ?LET(
        Parts,
        vector(3, binary(4)),
        iolist_to_binary(lists:join(<<".">>, Parts))
    );

valid_uri_for_strategy(<<"prefix">>) ->
    ?LET(
        Parts,
        non_empty(list(binary(4))),
        <<(iolist_to_binary(lists:join(<<".">>, Parts)))/binary, ".">>
    ).


%% @private
dag_groups() ->
    %% Generate a DAG of groups: a -> b -> c -> d (linear chain)
    %% This avoids cycles.
    ?LET(
        N,
        range(2, 6),
        begin
            Names = [
                iolist_to_binary(["g_", integer_to_binary(I)])
                || I <- lists:seq(1, N)
            ],
            [
                begin
                    Parents = case I of
                        1 -> [];
                        _ ->
                            %% Each group can be a member of any earlier group
                            [lists:nth(I - 1, Names)]
                    end,
                    bondy_rbac_group:new(#{
                        name => lists:nth(I, Names),
                        groups => Parents,
                        meta => #{}
                    })
                end
                || I <- lists:seq(1, N)
            ]
        end
    ).



%% =============================================================================
%% PURE PROPERTY TESTS
%% =============================================================================



prop_reserved_names_complete(_) ->
    Reserved = [all, anonymous, any, on, to, from],
    ReservedBins = [atom_to_binary(A) || A <- Reserved],

    %% All known reserved names return true
    lists:foreach(
        fun(Name) ->
            ?assert(bondy_rbac:is_reserved_name(Name))
        end,
        Reserved ++ ReservedBins
    ),

    %% Random alphanumeric binaries that aren't reserved return false
    Prop = ?FORALL(
        Bin,
        ?SUCHTHAT(
            B,
            non_empty(binary()),
            not lists:member(B, ReservedBins)
        ),
        begin
            try
                not bondy_rbac:is_reserved_name(Bin)
            catch
                %% binary_to_existing_atom may fail for non-existing atoms,
                %% which is fine — those aren't reserved
                error:invalid_name -> true
            end
        end
    ),
    ?assert(proper:quickcheck(Prop, [quiet, {numtests, ?NUMTESTS}])).


prop_normalise_name_idempotent(_) ->
    Prop = ?FORALL(
        Bin,
        non_empty(binary()),
        begin
            try
                N1 = bondy_rbac:normalise_name(Bin),
                N2 = bondy_rbac:normalise_name(N1),
                N1 =:= N2
            catch
                _:_ -> true
            end
        end
    ),
    ?assert(proper:quickcheck(Prop, [quiet, {numtests, ?NUMTESTS}])).


prop_normalise_name_lowercase(_) ->
    Prop = ?FORALL(
        Bin,
        non_empty(binary()),
        begin
            try
                Normalised = bondy_rbac:normalise_name(Bin),
                %% Result should equal its own casefold
                Normalised =:= string:casefold(Normalised)
            catch
                _:_ -> true
            end
        end
    ),
    ?assert(proper:quickcheck(Prop, [quiet, {numtests, ?NUMTESTS}])).


prop_topsort_preserves_elements(_) ->
    Prop = ?FORALL(
        Groups,
        dag_groups(),
        begin
            Sorted = bondy_rbac_group:topsort(Groups),
            InputNames = lists:sort(
                [bondy_rbac_group:name(G) || G <- Groups]
            ),
            SortedNames = lists:sort(
                [bondy_rbac_group:name(G) || G <- Sorted]
            ),
            InputNames =:= SortedNames
        end
    ),
    ?assert(proper:quickcheck(Prop, [quiet, {numtests, ?NUMTESTS}])).


prop_topsort_respects_order(_) ->
    %% For a linear chain g_1 <- g_2 <- g_3 ... the topsort must place
    %% g_1 before g_2, g_2 before g_3, etc.
    Prop = ?FORALL(
        Groups,
        dag_groups(),
        begin
            Sorted = bondy_rbac_group:topsort(Groups),
            SortedNames = [bondy_rbac_group:name(G) || G <- Sorted],
            Indices = maps:from_list(
                lists:zip(SortedNames, lists:seq(1, length(SortedNames)))
            ),
            %% For each group, its parent (if any) must appear earlier
            lists:all(
                fun(Group) ->
                    Name = bondy_rbac_group:name(Group),
                    Parents = bondy_rbac_group:groups(Group),
                    lists:all(
                        fun(Parent) ->
                            case maps:find(Parent, Indices) of
                                {ok, ParentIdx} ->
                                    maps:get(Name, Indices) > ParentIdx;
                                error ->
                                    %% Parent not in the input list (external dep)
                                    true
                            end
                        end,
                        Parents
                    )
                end,
                Groups
            )
        end
    ),
    ?assert(proper:quickcheck(Prop, [quiet, {numtests, ?NUMTESTS}])).


prop_externalize_grant_has_required_keys(_) ->
    Prop = ?FORALL(
        {Strategy, Perms},
        {match_strategy(), permissions()},
        begin
            Uri = <<"com.test.prop">>,
            Grant = {{Uri, Strategy}, lists:usort(Perms)},
            Ext = bondy_rbac:externalize_grant(Grant),
            maps:is_key(<<"resource">>, Ext)
                andalso maps:is_key(<<"permissions">>, Ext)
                andalso is_map(maps:get(<<"resource">>, Ext))
                andalso is_list(maps:get(<<"permissions">>, Ext))
        end
    ),
    ?assert(proper:quickcheck(Prop, [quiet, {numtests, ?NUMTESTS}])).



%% =============================================================================
%% INTEGRATION PROPERTY TESTS
%% =============================================================================



prop_grant_revoke_symmetry(_) ->
    Prop = ?FORALL(
        {Strategy, Perms},
        {match_strategy(), permissions()},
        begin
            UniquePerms = lists:usort(Perms),
            Uri = make_realm_uri(<<"sym">>),
            GroupName = <<"sym_group">>,
            Username = <<"sym_user">>,

            _ = bondy_realm:create(#{
                uri => Uri,
                security_enabled => true,
                authmethods => [?TRUST_AUTH],
                groups => [#{name => GroupName}],
                users => [#{username => Username, groups => [GroupName]}]
            }),

            ResourceUri = case Strategy of
                <<"exact">> -> <<"com.sym.exact.test">>;
                <<"prefix">> -> <<"com.sym.prefix.">>
            end,
            TestUri = case Strategy of
                <<"exact">> -> <<"com.sym.exact.test">>;
                <<"prefix">> -> <<"com.sym.prefix.foo">>
            end,

            GrantData = #{
                <<"permissions">> => UniquePerms,
                <<"uri">> => ResourceUri,
                <<"match">> => Strategy,
                <<"roles">> => [GroupName]
            },

            %% Grant
            ok = bondy_rbac:grant(Uri, GrantData),

            C1 = bondy_rbac:get_context(Uri, Username),
            GrantedOk = lists:all(
                fun(Perm) ->
                    try
                        ok = bondy_rbac:authorize(Perm, TestUri, C1),
                        true
                    catch
                        error:{not_authorized, _} -> false
                    end
                end,
                UniquePerms
            ),

            %% Revoke
            ok = bondy_rbac:revoke(Uri, GrantData),

            C2 = bondy_rbac:get_context(Uri, Username),
            AllRevoked = lists:all(
                fun(Perm) ->
                    try
                        bondy_rbac:authorize(Perm, TestUri, C2),
                        false
                    catch
                        error:{not_authorized, _} -> true
                    end
                end,
                UniquePerms
            ),

            GrantedOk andalso AllRevoked
        end
    ),
    ?assert(proper:quickcheck(Prop, [quiet, {numtests, 20}])).


prop_grant_accumulates_permissions(_) ->
    Prop = ?FORALL(
        {Perms1, Perms2},
        {permissions(), permissions()},
        begin
            P1 = lists:usort(Perms1),
            P2 = lists:usort(Perms2),
            Expected = lists:usort(P1 ++ P2),

            Uri = make_realm_uri(<<"acc">>),
            GroupName = <<"acc_group">>,
            Username = <<"acc_user">>,

            _ = bondy_realm:create(#{
                uri => Uri,
                security_enabled => true,
                authmethods => [?TRUST_AUTH],
                groups => [#{name => GroupName}],
                users => [#{username => Username, groups => [GroupName]}]
            }),

            GrantBase = #{
                <<"uri">> => <<"com.acc.">>,
                <<"match">> => <<"prefix">>,
                <<"roles">> => [GroupName]
            },

            ok = bondy_rbac:grant(Uri, GrantBase#{<<"permissions">> => P1}),
            ok = bondy_rbac:grant(Uri, GrantBase#{<<"permissions">> => P2}),

            C = bondy_rbac:get_context(Uri, Username),
            lists:all(
                fun(Perm) ->
                    try
                        ok = bondy_rbac:authorize(
                            Perm, <<"com.acc.test">>, C
                        ),
                        true
                    catch
                        error:{not_authorized, _} -> false
                    end
                end,
                Expected
            )
        end
    ),
    ?assert(proper:quickcheck(Prop, [quiet, {numtests, 20}])).



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
make_realm_uri(Prefix) ->
    N = erlang:unique_integer([positive]),
    <<"com.test.proper.", Prefix/binary, ".",
      (integer_to_binary(N))/binary>>.
