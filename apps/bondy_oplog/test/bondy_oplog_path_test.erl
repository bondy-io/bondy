%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_path_test).

-include_lib("eunit/include/eunit.hrl").

layout_defaults_to_sharded_test() ->
    ?assertEqual(sharded, bondy_oplog_path:layout(#{})).

layout_reads_explicit_value_test() ->
    ?assertEqual(flat, bondy_oplog_path:layout(#{path_layout => flat})),
    ?assertEqual(sharded, bondy_oplog_path:layout(#{path_layout => sharded})).

layout_rejects_unknown_value_test() ->
    ?assertError(
        {invalid_path_layout, bananas},
        bondy_oplog_path:layout(#{path_layout => bananas})
    ).

flat_storage_path_test() ->
    Path = bondy_oplog_path:storage_path(<<"hello">>, <<"/data">>, flat),
    ?assertEqual(
        <<"/data/hello">>, unicode:characters_to_binary(Path)
    ).

sharded_storage_path_test() ->
    %% sha256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e...
    Path = bondy_oplog_path:storage_path(<<"hello">>, <<"/data">>, sharded),
    ?assertEqual(
        <<"/data/2c/2cf2/hello">>, unicode:characters_to_binary(Path)
    ).

instance_dir_resolves_layout_from_opts_test() ->
    Sharded = bondy_oplog_path:instance_dir(<<"hello">>, <<"/data">>, #{}),
    ?assertEqual(
        <<"/data/2c/2cf2/hello">>, unicode:characters_to_binary(Sharded)
    ),
    Flat = bondy_oplog_path:instance_dir(
        <<"hello">>, <<"/data">>, #{path_layout => flat}
    ),
    ?assertEqual(<<"/data/hello">>, unicode:characters_to_binary(Flat)).
