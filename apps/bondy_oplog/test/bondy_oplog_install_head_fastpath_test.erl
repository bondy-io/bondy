%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Verifies the HEAD fast-path in `do_install_catalogue_batch/4`:
%%
%%   - In `replace` mode (the only mode after PR-G removed merge-mode)
%%     the installer reads the existing cell via the adapter's optional
%%     `head/3` callback (HLC-only). It must NOT call `get/3` for the
%%     skip-if-older comparison.
%%
%%   - The `not_found` branch (incoming cell has no local twin) must
%%     not touch `get/3` in `replace` mode — `head/3` answers the
%%     question by itself.
%%
%% Uses `bondy_oplog_projection_head_counting` as a counting wrapper
%% around `bondy_oplog_projection_ets`. The wrapper exports `head/3`
%% so `erlang:function_exported(Adapter, head, 3)` returns `true`
%% inside `bondy_oplog_applier:adapter_head_hlc/4`.
%% =============================================================================
-module(bondy_oplog_install_head_fastpath_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).
-define(PA, bondy_oplog_projection_head_counting).

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)]
    ],
    ok.

head_fastpath_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 30, fun replace_mode_uses_head_only/0},
        {timeout, 30, fun replace_mode_new_cell_uses_head/0},
        {timeout, 30, fun replace_mode_skip_older_uses_head/0}
    ]}.

replace_mode_uses_head_only() ->
    %% Setup: instance with counting adapter; pre-insert one cell at
    %% Hlc=5 by writing directly through the adapter. Reset counters
    %% before the install call so we measure only the install path.
    {Id, _NS, _Cache, Handle} = setup_instance(),
    ?PA:put_batch(Handle, [encoded_cell(<<"k1">>, 5, <<"old">>)]),
    ?PA:reset(),
    Cells = [
        encoded_cell(<<"k1">>, 10, <<"newer">>),
        encoded_cell(<<"k2">>, 20, <<"new-key">>)
    ],
    {ok, Counts} = bondy_oplog_instance:install_catalogue_batch(
        Id, {replace, Cells}
    ),
    ?assertEqual(2, maps:get(installed, Counts)),
    ?assertEqual(0, maps:get(skipped, Counts)),
    ?assertEqual(2, ?PA:head_count()),
    ?assertEqual(0, ?PA:get_count()),
    teardown(Id).

replace_mode_new_cell_uses_head() ->
    %% Fresh projection: every install_one_cell hits the `not_found`
    %% branch. `head/3` should still be the chosen reader.
    {Id, _NS, _Cache, _Handle} = setup_instance(),
    ?PA:reset(),
    Cells = [
        encoded_cell(<<"a">>, 1, <<"a">>),
        encoded_cell(<<"b">>, 2, <<"b">>),
        encoded_cell(<<"c">>, 3, <<"c">>)
    ],
    {ok, Counts} = bondy_oplog_instance:install_catalogue_batch(
        Id, {replace, Cells}
    ),
    ?assertEqual(3, maps:get(installed, Counts)),
    ?assertEqual(3, ?PA:head_count()),
    ?assertEqual(0, ?PA:get_count()),
    teardown(Id).

replace_mode_skip_older_uses_head() ->
    %% Replace mode: incoming Hlc is older than existing. The skip
    %% decision is taken from `head/3`'s HLC alone.
    {Id, _NS, _Cache, Handle} = setup_instance(),
    ?PA:put_batch(Handle, [encoded_cell(<<"k1">>, 50, <<"newer">>)]),
    ?PA:reset(),
    Cells = [encoded_cell(<<"k1">>, 10, <<"older">>)],
    {ok, Counts} = bondy_oplog_instance:install_catalogue_batch(
        Id, {replace, Cells}
    ),
    ?assertEqual(0, maps:get(installed, Counts)),
    ?assertEqual(1, maps:get(skipped, Counts)),
    ?assertEqual(1, ?PA:head_count()),
    ?assertEqual(0, ?PA:get_count()),
    teardown(Id).

%% =============================================================================
%% Helpers
%% =============================================================================

setup_instance() ->
    Id = mk_id(),
    NS = ns_of(Id),
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
    {ok, Proj} = ?PA:open(NS, primary, 0, #{}),
    ok = bondy_oplog_core_registry:register(NS, primary, 0, #{
        shard_count => 1,
        cache_adapter => bondy_oplog_cache_ets,
        cache_handle => Cache,
        projection_adapter => ?PA,
        projection_handle => Proj,
        overlay => disabled,
        fold_module => lww_register
    }),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register,
        applier => #{
            cell_apply_target => {NS, primary, 0}
        }
    }),
    {Id, NS, Cache, Proj}.

teardown(Id) ->
    bondy_oplog:stop_instance(Id),
    NS = ns_of(Id),
    [
        bondy_oplog_core_registry:unregister(N, I, S)
     || E <- bondy_oplog_core_registry:list(),
        {N, I, S} <- [bondy_oplog_core_registry:entry_key(E)],
        N =:= NS
    ],
    ok.

encoded_cell(Key, Hlc, Value) ->
    %% LWW-Register `set` state on the wire.
    StateBytes = bondy_oplog_crdt_lww_register:encode_state({set, Value, Hlc}),
    ValueBytes = term_to_binary(Value),
    Frame = bondy_oplog_cell_frame:encode(Hlc, StateBytes, ValueBytes, false),
    {?B, Key, Frame}.

mk_id() ->
    iolist_to_binary([
        "ihf_",
        integer_to_binary(erlang:unique_integer([positive]))
    ]).

ns_of(Id) when is_binary(Id) ->
    binary_to_atom(<<"ns_", Id/binary>>, utf8).
