%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_mst_admin_SUITE).
-moduledoc """
Restore refusals of `bondy_mst_admin`: a backup that fails verification is
refused with the reason `verify/1` gives, and nothing is written to the target.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([restore_without_a_manifest_reports_the_verify_error/1]).
-export([restore_of_a_corrupted_backup_reports_the_verify_error/1]).

all() ->
    [
        restore_without_a_manifest_reports_the_verify_error,
        restore_of_a_corrupted_backup_reports_the_verify_error
    ].

%% =============================================================================
%% CASES
%% =============================================================================

%% A directory with no manifest is not a backup. Restore answers the error
%% `verify/1` answers for it and leaves the target empty.
restore_without_a_manifest_reports_the_verify_error(Config) ->
    Backup = dir(Config, "no_manifest"),
    ok = file:write_file(filename:join(Backup, "a.bin"), <<"x">>),
    Target = dir(Config, "no_manifest_target"),
    Expected = bondy_mst_admin:verify(Backup),
    ?assertMatch({error, _}, Expected),
    ?assertEqual(Expected, bondy_mst_admin:restore(Backup, Target)),
    ?assertEqual({ok, []}, file:list_dir(Target)).

%% A backup whose file no longer matches its manifest is refused with the
%% mismatch `verify/1` reports, and nothing is written to the target.
restore_of_a_corrupted_backup_reports_the_verify_error(Config) ->
    Source = dir(Config, "source"),
    ok = file:write_file(filename:join(Source, "a.bin"), <<"hello">>),
    Backup = dir(Config, "corrupted"),
    {ok, _} = bondy_mst_admin:backup(Source, Backup, #{
        allow_nonempty_target => true
    }),
    ok = file:write_file(filename:join(Backup, "a.bin"), <<"HELLO">>),
    Target = dir(Config, "corrupted_target"),
    Expected = bondy_mst_admin:verify(Backup),
    ?assertMatch({error, _}, Expected),
    ?assertEqual(Expected, bondy_mst_admin:restore(Backup, Target)),
    ?assertEqual({ok, []}, file:list_dir(Target)).

%% =============================================================================
%% HELPERS
%% =============================================================================

dir(Config, Name) ->
    Dir = filename:join(?config(priv_dir, Config), Name),
    ok = filelib:ensure_path(Dir),
    Dir.
