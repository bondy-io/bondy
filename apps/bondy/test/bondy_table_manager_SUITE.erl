%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_table_manager_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).


all() ->
    [
        add_anonymous_creates_table,
        add_anonymous_rejects_duplicate_key,
        get_or_create_anonymous_is_idempotent,
        lookup_anonymous_returns_error_for_missing_key,
        delete_anonymous_removes_table_and_registry,
        delete_anonymous_returns_false_for_missing_key,
        get_or_create_named_is_idempotent,
        anonymous_table_has_no_registered_name,
        anonymous_table_strips_named_table_from_opts,
        anonymous_table_survives_caller_death
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Config.


end_per_suite(Config) ->
    {save_config, Config}.


init_per_testcase(_TestCase, Config) ->
    Config.


end_per_testcase(_TestCase, _Config) ->
    ok.



%% =============================================================================
%% TEST CASES
%% =============================================================================



add_anonymous_creates_table(_Config) ->
    Key = {?MODULE, add_anon, erlang:unique_integer([positive])},
    {ok, Tab} = bondy_table_manager:add_anonymous(Key, [set, public]),

    %% The returned identifier is an opaque TID, not an atom
    ?assert(is_reference(Tab) orelse is_integer(Tab)),

    %% Table is usable
    true = ets:insert(Tab, {hello, world}),
    ?assertEqual([{hello, world}], ets:lookup(Tab, hello)),

    %% Registry contains the mapping
    ?assertEqual({ok, Tab}, bondy_table_manager:lookup_anonymous(Key)),

    %% Cleanup
    true = bondy_table_manager:delete_anonymous(Key).


add_anonymous_rejects_duplicate_key(_Config) ->
    Key = {?MODULE, dup_key, erlang:unique_integer([positive])},
    {ok, _} = bondy_table_manager:add_anonymous(Key, [set, public]),

    ?assertEqual(
        {error, already_exists},
        bondy_table_manager:add_anonymous(Key, [set, public])
    ),

    true = bondy_table_manager:delete_anonymous(Key).


get_or_create_anonymous_is_idempotent(_Config) ->
    Key = {?MODULE, idempotent, erlang:unique_integer([positive])},

    {ok, Tab1} = bondy_table_manager:get_or_create_anonymous(
        Key, [ordered_set, public]
    ),
    {ok, Tab2} = bondy_table_manager:get_or_create_anonymous(
        Key, [ordered_set, public]
    ),

    %% Second call returns the SAME table identifier
    ?assertEqual(Tab1, Tab2),

    %% Data persists across the idempotent call
    true = ets:insert(Tab1, {persist, check}),
    ?assertEqual([{persist, check}], ets:lookup(Tab2, persist)),

    true = bondy_table_manager:delete_anonymous(Key).


lookup_anonymous_returns_error_for_missing_key(_Config) ->
    Key = {?MODULE, missing, erlang:unique_integer([positive])},
    ?assertEqual(error, bondy_table_manager:lookup_anonymous(Key)).


delete_anonymous_removes_table_and_registry(_Config) ->
    Key = {?MODULE, del, erlang:unique_integer([positive])},
    {ok, Tab} = bondy_table_manager:add_anonymous(Key, [set, public]),

    %% Table is alive
    ?assertNotEqual(undefined, ets:info(Tab, size)),

    true = bondy_table_manager:delete_anonymous(Key),

    %% Registry entry is gone
    ?assertEqual(error, bondy_table_manager:lookup_anonymous(Key)),

    %% Underlying ETS table is gone
    ?assertEqual(undefined, ets:info(Tab, size)).


delete_anonymous_returns_false_for_missing_key(_Config) ->
    Key = {?MODULE, del_missing, erlang:unique_integer([positive])},
    ?assertEqual(false, bondy_table_manager:delete_anonymous(Key)).


get_or_create_named_is_idempotent(_Config) ->
    Name = list_to_atom(
        "bondy_tm_test_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),

    {ok, T1} = bondy_table_manager:get_or_create(Name, [set, public, named_table]),
    {ok, T2} = bondy_table_manager:get_or_create(Name, [set, public, named_table]),

    ?assertEqual(T1, T2),
    ?assertEqual(Name, T1),

    true = bondy_table_manager:delete(Name).


anonymous_table_has_no_registered_name(_Config) ->
    %% A named table appears in `ets:info(Tab, named_table)' as true. An
    %% anonymous table must report false — this is the property that
    %% guarantees no atom was allocated for this table.
    Key = {?MODULE, unnamed, erlang:unique_integer([positive])},
    {ok, Tab} = bondy_table_manager:add_anonymous(Key, [set, public]),
    ?assertEqual(false, ets:info(Tab, named_table)),
    true = bondy_table_manager:delete_anonymous(Key).


anonymous_table_strips_named_table_from_opts(_Config) ->
    %% Callers may reuse the same opts list they pass to named variants.
    %% The anonymous API must defensively strip `named_table' so that
    %% `ets:new/2' does not try to register an atom name.
    Key = {?MODULE, strip, erlang:unique_integer([positive])},
    {ok, Tab} = bondy_table_manager:add_anonymous(
        Key,
        [ordered_set, public, named_table, {read_concurrency, true}]
    ),
    ?assertEqual(false, ets:info(Tab, named_table)),
    ?assertEqual(ordered_set, ets:info(Tab, type)),
    true = bondy_table_manager:delete_anonymous(Key).


anonymous_table_survives_caller_death(_Config) ->
    %% Anonymous tables are owned by bondy_table_manager, not the caller.
    %% Killing the caller must leave the table alive and the registry
    %% entry intact. This is the property that lets
    %% bondy_transport_queue_manager crash without losing queues.
    Parent = self(),
    Key = {?MODULE, survival, erlang:unique_integer([positive])},

    Pid = spawn(fun() ->
        {ok, Tab} = bondy_table_manager:get_or_create_anonymous(
            Key, [set, public]
        ),
        true = ets:insert(Tab, {alive, yes}),
        Parent ! {ok, Tab},
        %% Wait to be killed
        receive die -> ok end
    end),

    Tab = receive {ok, T} -> T after 2000 -> error(timeout) end,

    %% Kill the caller
    MRef = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', MRef, process, Pid, _} -> ok after 1000 -> error(timeout) end,

    %% Table and registry must still be intact
    ?assertEqual({ok, Tab}, bondy_table_manager:lookup_anonymous(Key)),
    ?assertEqual([{alive, yes}], ets:lookup(Tab, alive)),

    true = bondy_table_manager:delete_anonymous(Key).
