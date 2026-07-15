%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_origin_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

%% -----------------------------------------------------------------------------
%% load_or_create/1
%% -----------------------------------------------------------------------------

load_or_create_first_call_persists_test() ->
    Dir = mktemp_dir("origin_lc1_"),
    Path = filename:join(Dir, "origin"),
    try
        ?assertNot(filelib:is_regular(Path)),
        Origin = bondy_oplog_origin:load_or_create(Path),
        ?assertEqual(?BONDY_OPLOG_ORIGIN_BYTES, byte_size(Origin)),
        ?assert(filelib:is_regular(Path)),
        {ok, Bin} = file:read_file(Path),
        ?assertEqual(Origin, Bin)
    after
        rm_rf(Dir)
    end.

load_or_create_idempotent_test() ->
    Dir = mktemp_dir("origin_lc2_"),
    Path = filename:join(Dir, "origin"),
    try
        O1 = bondy_oplog_origin:load_or_create(Path),
        O2 = bondy_oplog_origin:load_or_create(Path),
        O3 = bondy_oplog_origin:load_or_create(Path),
        ?assertEqual(O1, O2),
        ?assertEqual(O2, O3)
    after
        rm_rf(Dir)
    end.

load_or_create_distinct_paths_test() ->
    %% Different paths produce different origins. Guards against a
    %% regression where `load_or_create/1` accidentally aliases all
    %% lookups onto the same file.
    Dir = mktemp_dir("origin_lc3_"),
    Path1 = filename:join(Dir, "a.origin"),
    Path2 = filename:join(Dir, "b.origin"),
    try
        O1 = bondy_oplog_origin:load_or_create(Path1),
        O2 = bondy_oplog_origin:load_or_create(Path2),
        ?assertNotEqual(O1, O2)
    after
        rm_rf(Dir)
    end.

load_or_create_regenerates_on_corruption_test() ->
    %% A truncated/oversized file is treated as corruption and a fresh
    %% origin is minted + persisted. The pre-existing bytes are not
    %% returned to the caller.
    Dir = mktemp_dir("origin_lc4_"),
    Path = filename:join(Dir, "origin"),
    try
        ok = filelib:ensure_dir(Path),
        ok = file:write_file(Path, <<"too-short">>),
        Origin = bondy_oplog_origin:load_or_create(Path),
        ?assertEqual(?BONDY_OPLOG_ORIGIN_BYTES, byte_size(Origin)),
        ?assertNotEqual(<<"too-short">>, Origin),
        {ok, Bin} = file:read_file(Path),
        ?assertEqual(Origin, Bin)
    after
        rm_rf(Dir)
    end.

load_or_create_survives_simulated_restart_test() ->
    %% This is the key behavioural invariant that motivated the change:
    %% if a caller wipes its in-memory state and re-runs `load_or_create`
    %% pointing at the same on-disk path, it gets the SAME origin back.
    %% That is what makes WAL recovery accept its own segments after a
    %% kill+restart.
    Dir = mktemp_dir("origin_lc5_"),
    Path = filename:join(Dir, "origin"),
    try
        OriginA = bondy_oplog_origin:load_or_create(Path),
        %% Simulate "fresh VM, same on-disk state".
        OriginB = bondy_oplog_origin:load_or_create(Path),
        ?assertEqual(OriginA, OriginB)
    after
        rm_rf(Dir)
    end.

%% -----------------------------------------------------------------------------
%% default/0 + validate/1 — unchanged behaviour, regression-pinning
%% -----------------------------------------------------------------------------

default_is_stable_within_vm_test() ->
    ?assertEqual(bondy_oplog_origin:default(), bondy_oplog_origin:default()).

new_is_fresh_each_call_test() ->
    ?assertNotEqual(bondy_oplog_origin:new(), bondy_oplog_origin:new()).

validate_test_() ->
    [
        ?_assertEqual(ok, bondy_oplog_origin:validate(<<1, 2, 3>>)),
        ?_assertEqual(
            {error, invalid_origin},
            bondy_oplog_origin:validate(<<>>)
        ),
        ?_assertEqual(
            {error, invalid_origin},
            bondy_oplog_origin:validate(not_a_binary)
        )
    ].

%% -----------------------------------------------------------------------------
%% helpers
%% -----------------------------------------------------------------------------

mktemp_dir(Prefix) ->
    Base = filename:join(
        "/tmp",
        Prefix ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.

rm_rf(Dir) ->
    _ = os:cmd("rm -rf " ++ Dir),
    ok.
