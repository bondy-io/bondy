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
        {ok, Origin} = bondy_oplog_origin:load_or_create(Path),
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
        {ok, O1} = bondy_oplog_origin:load_or_create(Path),
        {ok, O2} = bondy_oplog_origin:load_or_create(Path),
        {ok, O3} = bondy_oplog_origin:load_or_create(Path),
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
        {ok, O1} = bondy_oplog_origin:load_or_create(Path1),
        {ok, O2} = bondy_oplog_origin:load_or_create(Path2),
        ?assertNotEqual(O1, O2)
    after
        rm_rf(Dir)
    end.

%% A file of the wrong size is refused and left as it is: minting over it
%% would orphan every WAL segment written under the persisted origin.
load_or_create_refuses_corruption_test() ->
    Dir = mktemp_dir("origin_lc4_"),
    Path = filename:join(Dir, "origin"),
    try
        ok = filelib:ensure_dir(Path),
        ok = file:write_file(Path, <<"too-short">>),
        ?assertEqual(
            {error, {corrupted, unexpected_size}},
            bondy_oplog_origin:load_or_create(Path)
        ),
        ?assertEqual({ok, <<"too-short">>}, file:read_file(Path))
    after
        rm_rf(Dir)
    end.

%% A read error other than `enoent` is returned and the persisted origin is
%% kept, so a retry once the file is readable again loads the same origin.
load_or_create_keeps_origin_on_read_error_test() ->
    Dir = mktemp_dir("origin_lc6_"),
    Path = filename:join(Dir, "origin"),
    try
        {ok, Origin} = bondy_oplog_origin:load_or_create(Path),
        ok = file:change_mode(Path, 8#000),
        ?assertEqual({error, eacces}, bondy_oplog_origin:load_or_create(Path)),
        ok = file:change_mode(Path, 8#644),
        ?assertEqual({ok, Origin}, bondy_oplog_origin:load_or_create(Path))
    after
        _ = file:change_mode(Path, 8#644),
        rm_rf(Dir)
    end.

%% An origin that could not be persisted is not returned: an instance
%% started with it would write segments that no later start can recover.
load_or_create_fails_when_not_persisted_test() ->
    Dir = mktemp_dir("origin_lc7_"),
    Path = filename:join(Dir, "origin"),
    try
        ok = file:change_mode(Dir, 8#500),
        ?assertMatch({error, _}, bondy_oplog_origin:load_or_create(Path)),
        ?assertNot(filelib:is_regular(Path))
    after
        _ = file:change_mode(Dir, 8#755),
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
        {ok, OriginA} = bondy_oplog_origin:load_or_create(Path),
        %% Simulate "fresh VM, same on-disk state".
        {ok, OriginB} = bondy_oplog_origin:load_or_create(Path),
        ?assertEqual(OriginA, OriginB)
    after
        rm_rf(Dir)
    end.

%% -----------------------------------------------------------------------------
%% default/0 + validate/1 — unchanged behaviour, regression-pinning
%% -----------------------------------------------------------------------------

default_is_stable_within_vm_test() ->
    ?assertEqual(bondy_oplog_origin:default(), bondy_oplog_origin:default()).

%% Clears the cached default and makes the first calls from 16 processes at
%% once, with generation slowed so that every caller has read the empty cache
%% before the first value is written; restores the cached value afterwards so
%% later tests in this VM keep the origin their WAL segments were written with.
concurrent_first_calls_agree_test() ->
    Key = {bondy_oplog_origin, default},
    Saved = persistent_term:get(Key, undefined),
    _ = persistent_term:erase(Key),
    ok = meck:new(bondy_oplog_origin, [passthrough]),
    ok = meck:expect(bondy_oplog_origin, new, fun() ->
        timer:sleep(100),
        meck:passthrough([])
    end),
    try
        Self = self(),
        Go = make_ref(),
        Ps = [
            spawn(fun() ->
                receive
                    Go -> Self ! {origin, self(), bondy_oplog_origin:default()}
                end
            end)
         || _ <- lists:seq(1, 16)
        ],
        _ = [P ! Go || P <- Ps],
        Origins = [
            receive
                {origin, P, O} -> O
            end
         || P <- Ps
        ],
        ?assertEqual([bondy_oplog_origin:default()], lists:usort(Origins))
    after
        _ = meck:unload(bondy_oplog_origin),
        case Saved of
            undefined -> ok;
            _ -> persistent_term:put(Key, Saved)
        end
    end.

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
        "/tmp/" ++ os:getpid(),
        Prefix ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.

rm_rf(Dir) ->
    _ = os:cmd("rm -rf " ++ Dir),
    ok.
