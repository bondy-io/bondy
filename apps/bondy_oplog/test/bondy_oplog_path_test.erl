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

%% =============================================================================
%% storage_path/3 — instance ids that cannot be a safe directory
%%
%% `storage_path/3` joins the id straight into a filesystem path, so an id that
%% is not a well-formed relative path is either unrepresentable or escapes the
%% base directory. Measured before this was validated:
%%
%%   <<"inst-",233>>     ensure_path -> {error, eilseq}
%%                       (`file:native_name_encoding()` is utf8)
%%   <<"main",0,"4">>    ensure_path -> {error, badarg}
%%   <<"/etc/escaped">>  storage_path -> an ABSOLUTE path outside the base
%%   <<"../../pwned">>   ensure_path -> ok, and the directory is created
%%                       OUTSIDE the base entirely (verified on disk)
%%
%% The first two surface as an opaque errno from `filelib` several frames from
%% the cause; the last two silently leave the data directory. Refusing the id
%% at the one function that maps an id to a path removes all four.
%% =============================================================================

reject(Id) ->
    lists:foreach(
        fun(Layout) ->
            ?assertError(
                {invalid_instance_id, Id, _},
                bondy_oplog_path:storage_path(Id, <<"/data">>, Layout)
            )
        end,
        [flat, sharded]
    ).

storage_path_rejects_non_utf8_id_test() ->
    reject(<<"inst-", 233>>),
    reject(<<200, 201, 202>>).

storage_path_rejects_nul_byte_id_test() ->
    reject(<<"main", 0, "4">>).

%% The escape. `filename:join/1` does not resolve `..`, so the id decides
%% where the directory lands.
storage_path_rejects_traversal_id_test() ->
    reject(<<"../../pwned">>),
    reject(<<"main/../../pwned">>),
    reject(<<"..">>).

storage_path_rejects_absolute_id_test() ->
    reject(<<"/etc/escaped">>),
    reject(<<"/">>).

storage_path_rejects_empty_id_test() ->
    reject(<<>>).

storage_path_rejects_dot_segment_id_test() ->
    reject(<<".">>),
    reject(<<"main/./4">>).

%% Injectivity: `main//4`, `main/4/` and `main/4` all name the SAME directory,
%% so accepting them would let three distinct ids share one instance's WAL and
%% MST.
storage_path_rejects_aliasing_ids_test() ->
    reject(<<"main//4">>),
    reject(<<"main/4/">>),
    reject(<<"/main/4">>).

%% The control: every id shape a real node produces must still be accepted,
%% and must still land under the base.
storage_path_accepts_production_ids_test() ->
    lists:foreach(
        fun(Id) ->
            lists:foreach(
                fun(Layout) ->
                    P = unicode:characters_to_binary(
                        bondy_oplog_path:storage_path(Id, <<"/data">>, Layout)
                    ),
                    ?assertMatch(<<"/data/", _/binary>>, P)
                end,
                [flat, sharded]
            )
        end,
        prod_ids() ++ [<<"hello">>, <<"a">>, <<"main-4">>, <<"caf", 195, 169>>]
    ).

%% The property the validation exists to give: an accepted id always yields a
%% directory that can actually be created, and that lives under the base.
accepted_ids_are_creatable_and_confined_test() ->
    Base = mk_tmp(),
    try
        lists:foreach(
            fun(Id) ->
                P = bondy_oplog_path:storage_path(Id, Base, sharded),
                ?assertEqual({Id, ok}, {Id, filelib:ensure_path(P)}),
                Resolved = unicode:characters_to_binary(P),
                ?assertMatch({Id, <<_/binary>>}, {Id, Resolved}),
                ?assert(
                    binary:longest_common_prefix([Resolved, Base]) =:=
                        byte_size(Base)
                )
            end,
            prod_ids() ++ [<<"caf", 195, 169>>]
        )
    after
        rm_tmp(Base)
    end.

%% =============================================================================
%% Per-instance internal layout
%%
%% `wal` and `origin` are subdirectories an instance creates INSIDE its own
%% directory when they are not configured elsewhere. This module owns both
%% names, so consumers (`bondy_oplog_instance_sup`) never restate them as
%% literals and cannot drift from the layout the moduledoc claims.
%% =============================================================================

internal_dirs_are_under_the_instance_dir_test() ->
    D = bondy_oplog_path:storage_path(<<"main-4">>, <<"/data">>, flat),
    ?assertEqual(
        <<"/data/main-4/wal">>,
        unicode:characters_to_binary(bondy_oplog_path:wal_dir(D))
    ),
    ?assertEqual(
        <<"/data/main-4/origin">>,
        unicode:characters_to_binary(bondy_oplog_path:origin_dir(D))
    ).

%% =============================================================================
%% Fixtures
%% =============================================================================

%% The four id shapes a real node produces
%% (`bondy_db:encode_instance_id/2,3`) — each one a single component, with
%% `-` between the parts.
prod_ids() ->
    [<<"main-0">>, <<"main-4">>, <<"main-realm-7">>, <<"main-idx-3">>].

mk_tmp() ->
    D = filename:join(
        "/tmp",
        "bondy_oplog_path_test_" ++
            integer_to_list(erlang:system_time(microsecond)) ++
            "_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_path(D),
    unicode:characters_to_binary(D).

rm_tmp(D) ->
    _ = file:del_dir_r(unicode:characters_to_list(D)),
    ok.

%% =============================================================================
%% An instance id names ONE directory component
%%
%% `bondy_db` joins id components with `-`, not `/`, and `/` is refused here.
%% That is what keeps the id/path mapping invertible by arithmetic: the id IS
%% the directory name, so nothing has to encode or decode it, and
%% `filename:dirname/1` on an instance directory strips the instance and
%% nothing else.
%%
%% The alternative — allowing `/` and percent-escaping it — also works, but
%% costs an encode/decode pair, an injectivity obligation, and directory names
%% like `main%2F4`. Forbidding one character in a name we generate is cheaper.
%% =============================================================================

storage_path_puts_the_id_in_one_component_test() ->
    lists:foreach(
        fun(Id) ->
            Flat = unicode:characters_to_binary(
                bondy_oplog_path:storage_path(Id, <<"/data">>, flat)
            ),
            %% dirname strips exactly the instance
            ?assertEqual(<<"/data">>, filename:dirname(Flat)),
            ?assertEqual(Id, filename:basename(Flat)),
            Sharded = unicode:characters_to_binary(
                bondy_oplog_path:storage_path(Id, <<"/data">>, sharded)
            ),
            ?assertEqual(Id, filename:basename(Sharded)),
            ?assertMatch(
                <<"/data/", _:2/binary, "/", _:4/binary>>,
                filename:dirname(Sharded)
            )
        end,
        prod_ids()
    ).

%% A `-` inside a component is ordinary text, not a delimiter: nothing parses
%% an instance id back into its parts, so `-` needs no escaping either.
ids_with_hyphens_are_ordinary_test() ->
    lists:foreach(
        fun(Id) ->
            P = unicode:characters_to_binary(
                bondy_oplog_path:storage_path(Id, <<"/data">>, flat)
            ),
            ?assertEqual(Id, filename:basename(P))
        end,
        [<<"inst-a">>, <<"codec-test">>, <<"ghost-instance-id">>, <<"a-b-c-d">>]
    ).

%% =============================================================================
%% Consumers that do path arithmetic on an instance directory
%%
%% `bondy_oplog_instance:resolve_checkpoint_backend/3` derives a parent
%% directory with `filename:dirname(InstanceDir)` and hands it to
%% `bondy_oplog_compaction_checkpoint_file`, which re-appends the id. While the
%% id nested, `dirname/1` stripped a segment of the ID rather than the instance
%% component, and the re-append then DOUBLED it:
%%
%%   id main/realm/7 -> instance   /data/d4/d4bd/main/realm/7
%%                      checkpoint /data/d4/d4bd/main/realm/main/realm/7/...
%%
%% Now that an id names ONE component, `dirname/1` strips exactly the instance
%% and the checkpoint lands inside the instance's own directory, which is what
%% the caller meant.
%% =============================================================================

checkpoint_dir_lands_inside_the_instance_dir_test_() ->
    {foreach, fun mk_tmp/0, fun rm_tmp/1, [
        fun(Base) ->
            {lists:flatten(io_lib:format("~s ~s", [Id, Layout])), fun() ->
                Opts = #{storage_path => Base, path_layout => Layout},
                %% The production pair, not a re-statement of it: the
                %% instance derives the checkpoint backend and its `path`
                %% option, and the file backend derives the file from that.
                {Mod, CkptOpts} =
                    bondy_oplog_instance:resolve_checkpoint_backend(
                        Id, Opts, #{}
                    ),
                ?assertEqual(bondy_oplog_compaction_checkpoint_file, Mod),
                {ok, St} = Mod:init(Id, CkptOpts),
                ok = Mod:put_checkpoint(St, {watermark, 1}, #{}),
                %% Where the file actually landed, from the disk.
                InstanceDir = unicode:characters_to_binary(
                    bondy_oplog_path:instance_dir(Id, Base, Opts)
                ),
                Expected = filename:join(InstanceDir, <<"checkpoint.etf">>),
                ?assert(filelib:is_regular(Expected)),
                %% ...and nowhere else under the base: one file, inside
                %% the instance's own directory.
                Found = filelib:wildcard(
                    unicode:characters_to_list(
                        filename:join(Base, <<"**/checkpoint.etf">>)
                    )
                ),
                ?assertEqual(
                    [unicode:characters_to_list(Expected)], Found
                ),
                ok = Mod:close(St)
            end}
        end
     || Id <- prod_ids(), Layout <- [flat, sharded]
    ]}.

%% The rule is exported so the library can apply it at admission
%% (`bondy_oplog_instance_dyn_sup:start_instance/2`), where it covers the
%% directories that never pass through `storage_path/3` — an explicit
%% `wal_dir`, the `/tmp` WAL default. That path is pinned by
%% `bondy_oplog_lifecycle_test`; this pins the function's own contract: `ok`
%% for every production id, the same reason `storage_path/3` raises for the
%% rest.
validate_instance_id_is_the_rule_storage_path_applies_test() ->
    lists:foreach(
        fun(Id) ->
            ?assertEqual(
                {Id, ok}, {Id, bondy_oplog_path:validate_instance_id(Id)}
            )
        end,
        prod_ids()
    ),
    lists:foreach(
        fun({Id, Reason}) ->
            ?assertError(
                {invalid_instance_id, Id, Reason},
                bondy_oplog_path:validate_instance_id(Id)
            ),
            ?assertError(
                {invalid_instance_id, Id, Reason},
                bondy_oplog_path:storage_path(Id, <<"/data">>, flat)
            )
        end,
        [
            {<<"main/4">>, separator},
            {<<"/etc/x">>, separator},
            {<<"../../pwned">>, separator},
            {<<"..">>, relative},
            {<<".">>, relative},
            {<<>>, empty},
            {<<"a", 0, "b">>, nul_byte},
            {<<"inst-", 233>>, not_utf8}
        ]
    ).
