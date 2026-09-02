%% =============================================================================
%% EUnit + PropEr suite for `bondy_mst_pack_manifest`. Covers:
%%
%% 1. Pure encode/decode round-trip; field setters; required-field
%%    validation; per-field type rejection.
%% 2. File-level read/write with atomic-rename durability:
%%    - fresh manifest survives write + reopen,
%%    - subsequent writes replace the prior state,
%%    - a tmp file left behind by a partial write does NOT affect
%%      the read (the live `manifest` file is authoritative),
%%    - a write that fails before rename leaves the prior manifest
%%      intact.
%% 3. PropEr round-trip over arbitrary manifest contents.
%% =============================================================================

-module(bondy_mst_pack_manifest_test).

%% PropEr defines `LET` and friends; include it before EUnit so EUnit's
%% `LET` doesn't shadow PropEr's.
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("bondy_mst_pack.hrl").

-define(HASH_LEN, ?BONDY_MST_PACK_HASH_BYTES).

%% =============================================================================
%% Fixture helpers
%% =============================================================================

mktemp_dir() ->
    Base = filename:join(
        [
            "/tmp",
            io_lib:format(
                "bondy_mst_pack_manifest_test_~p_~p",
                [
                    erlang:system_time(microsecond),
                    erlang:unique_integer([positive])
                ]
            )
        ]
    ),
    Dir = lists:flatten(Base),
    ok = filelib:ensure_path(Dir),
    Dir.

rmrf(Dir) ->
    _ = file:del_dir_r(Dir),
    ok.

with_tmp_dir(Fun) ->
    Dir = mktemp_dir(),
    try
        Fun(Dir)
    after
        rmrf(Dir)
    end.

sample() ->
    bondy_mst_pack_manifest:new(<<"test-instance">>, sha256).

%% =============================================================================
%% Pure encode/decode round-trip
%% =============================================================================

fresh_manifest_has_sane_defaults_test() ->
    M = sample(),
    ?assertEqual(<<"test-instance">>, bondy_mst_pack_manifest:instance_id(M)),
    ?assertEqual(sha256, bondy_mst_pack_manifest:hash_algo(M)),
    ?assertEqual(undefined, bondy_mst_pack_manifest:current_root(M)),
    ?assertEqual([], bondy_mst_pack_manifest:sealed_packs(M)),
    ?assertEqual(0, bondy_mst_pack_manifest:deleted_through(M)),
    ?assertEqual(absent, bondy_mst_pack_manifest:incoming_pack(M)),
    ?assertEqual(1, bondy_mst_pack_manifest:manifest_version(M)).

encode_produces_consultable_terms_test() ->
    M = sample(),
    Bin = bondy_mst_pack_manifest:encode(M),
    %% Round-trip via consult-string semantics.
    {ok, Terms} = bin_to_terms(Bin),
    {ok, M2} = bondy_mst_pack_manifest:decode(Terms),
    ?assertEqual(M, M2).

%% `current_root` is a raw sha256: any of its 32 bytes may land in
%% 160..255. If the encoder renders such a binary as a printable latin-1
%% string (`~p` does; `~tw` does not) the bytes go to disk verbatim and
%% `file:consult/1` -- which decodes UTF-8 -- rejects the file with
%% `{Line, file_io_server, invalid_unicode}`, which brings down every
%% replica of the shard. Each root below is a falsifier for that defect:
%% every one of them fails under `~p` and survives under `~tw`.
%%
%% This is the case `prop_encode_decode_roundtrip` cannot be relied on to
%% reach: uniformly random 32-byte roots trip it only ~0.04% of the time
%% (measured 21/50000), so at `numtests` 50 it would essentially never
%% fire. These roots make it deterministic.
high_byte_roots() ->
    [
        %% a full 32 bytes drawn from the latin-1 printable high range
        list_to_binary(lists:seq(160, 191)),
        list_to_binary(lists:seq(224, 255)),
        %% one high byte embedded in an otherwise ASCII root
        <<"0123456789abcdef0123456789abcde", 233>>,
        <<233, "0123456789abcdef0123456789abcde">>,
        %% a valid UTF-8 two-byte sequence: not a read failure but a
        %% silent value change under `~p` (consult folds it to one
        %% codepoint), so it pins byte-fidelity, not just readability
        <<"0123456789abcdef0123456789abc", 195, 169, "f">>,
        %% NBSP, the low edge of the printable high range
        <<160:8, 0:248>>
    ].

encode_survives_high_byte_roots_test_() ->
    [
        {
            lists:flatten(io_lib:format("root ~w", [Root])),
            fun() ->
                M = bondy_mst_pack_manifest:with_current_root(sample(), Root),
                Bin = bondy_mst_pack_manifest:encode(M),
                ?assertMatch({ok, _}, bin_to_terms(Bin)),
                {ok, Terms} = bin_to_terms(Bin),
                {ok, M2} = bondy_mst_pack_manifest:decode(Terms),
                %% byte-for-byte, not merely readable
                ?assertEqual(Root, bondy_mst_pack_manifest:current_root(M2)),
                ?assertEqual(M, M2)
            end
        }
     || Root <- high_byte_roots()
    ].

%% The same defect, exercised through the real on-disk write/read pair
%% rather than the pure codec.
write_read_survives_high_byte_root_test_() ->
    [
        {
            lists:flatten(io_lib:format("disk root ~w", [Root])),
            fun() ->
                with_tmp_dir(fun(Dir) ->
                    M = bondy_mst_pack_manifest:with_current_root(
                        sample(), Root
                    ),
                    ?assertEqual(ok, bondy_mst_pack_manifest:write(Dir, M)),
                    ?assertEqual(
                        {ok, M}, bondy_mst_pack_manifest:read(Dir)
                    )
                end)
            end
        }
     || Root <- high_byte_roots()
    ].

decode_rejects_missing_required_field_test() ->
    Terms = [
        {manifest_version, 1},
        %% no instance_id
        {hash_algo, sha256},
        {current_root, undefined},
        {sealed_packs, []}
    ],
    ?assertEqual(
        {error, {missing_field, instance_id}},
        bondy_mst_pack_manifest:decode(Terms)
    ).

decode_rejects_bad_hash_algo_test() ->
    Terms = base_terms() ++ [{hash_algo, md5}],
    ?assertEqual(
        {error, {bad_hash_algo, md5}},
        bondy_mst_pack_manifest:decode(Terms)
    ).

decode_rejects_bad_current_root_test() ->
    Terms = override_terms(base_terms(), current_root, <<"too short">>),
    ?assertEqual(
        {error, {bad_current_root, <<"too short">>}},
        bondy_mst_pack_manifest:decode(Terms)
    ).

decode_rejects_non_ascending_sealed_packs_test() ->
    Terms = override_terms(base_terms(), sealed_packs, [1, 3, 2]),
    ?assertEqual(
        {error, {bad_sealed_packs, [1, 3, 2]}},
        bondy_mst_pack_manifest:decode(Terms)
    ).

decode_accepts_empty_sealed_packs_test() ->
    Terms = base_terms(),
    ?assertMatch({ok, _}, bondy_mst_pack_manifest:decode(Terms)).

decode_tolerates_unknown_field_test() ->
    Terms = base_terms() ++ [{some_future_field, [1, 2, 3]}],
    ?assertMatch({ok, _}, bondy_mst_pack_manifest:decode(Terms)).

decode_rejects_non_proplist_test() ->
    Terms = [{manifest_version, 1}, banana, {instance_id, <<"x">>}],
    ?assertEqual(
        {error, not_proplist},
        bondy_mst_pack_manifest:decode(Terms)
    ).

%% =============================================================================
%% Setters
%% =============================================================================

with_current_root_test() ->
    M0 = sample(),
    Root = crypto:hash(sha256, <<"root">>),
    M1 = bondy_mst_pack_manifest:with_current_root(M0, Root),
    ?assertEqual(Root, bondy_mst_pack_manifest:current_root(M1)),
    M2 = bondy_mst_pack_manifest:with_current_root(M1, undefined),
    ?assertEqual(undefined, bondy_mst_pack_manifest:current_root(M2)).

add_sealed_pack_appends_in_order_test() ->
    M0 = sample(),
    M1 = bondy_mst_pack_manifest:add_sealed_pack(M0, 0),
    M2 = bondy_mst_pack_manifest:add_sealed_pack(M1, 1),
    M3 = bondy_mst_pack_manifest:add_sealed_pack(M2, 42),
    ?assertEqual([0, 1, 42], bondy_mst_pack_manifest:sealed_packs(M3)).

add_sealed_pack_rejects_non_monotone_test() ->
    M0 = sample(),
    M1 = bondy_mst_pack_manifest:add_sealed_pack(M0, 5),
    ?assertError(
        {non_monotone_pack_id, 3, 5},
        bondy_mst_pack_manifest:add_sealed_pack(M1, 3)
    ).

remove_sealed_packs_advances_watermark_test() ->
    M0 = lists:foldl(
        fun(I, Acc) -> bondy_mst_pack_manifest:add_sealed_pack(Acc, I) end,
        sample(),
        [0, 1, 2, 3, 4]
    ),
    M1 = bondy_mst_pack_manifest:remove_sealed_packs(M0, [0, 1, 2]),
    ?assertEqual([3, 4], bondy_mst_pack_manifest:sealed_packs(M1)),
    ?assertEqual(2, bondy_mst_pack_manifest:deleted_through(M1)).

remove_sealed_packs_idempotent_on_unknown_ids_test() ->
    M0 = bondy_mst_pack_manifest:add_sealed_pack(sample(), 7),
    M1 = bondy_mst_pack_manifest:remove_sealed_packs(M0, [99]),
    ?assertEqual([7], bondy_mst_pack_manifest:sealed_packs(M1)),
    %% deleted_through still advances; this is the documented
    %% semantics (caller may pass a closed set).
    ?assertEqual(99, bondy_mst_pack_manifest:deleted_through(M1)).

with_incoming_pack_test() ->
    M = sample(),
    M1 = bondy_mst_pack_manifest:with_incoming_pack(M, present),
    ?assertEqual(present, bondy_mst_pack_manifest:incoming_pack(M1)),
    M2 = bondy_mst_pack_manifest:with_incoming_pack(M1, absent),
    ?assertEqual(absent, bondy_mst_pack_manifest:incoming_pack(M2)).

%% =============================================================================
%% File-level read/write
%% =============================================================================

write_then_read_round_trip_test() ->
    with_tmp_dir(fun(Dir) ->
        M0 = bondy_mst_pack_manifest:add_sealed_pack(sample(), 42),
        M1 = bondy_mst_pack_manifest:with_current_root(
            M0, crypto:hash(sha256, <<"r">>)
        ),
        ?assertEqual(ok, bondy_mst_pack_manifest:write(Dir, M1)),
        {ok, M2} = bondy_mst_pack_manifest:read(Dir),
        ?assertEqual(M1, M2)
    end).

%% A manifest that exists but cannot be used is reported with its path.
%% `read/1` is the single door every caller goes through
%% (`bondy_mst_pack_writer`, `bondy_mst_pack_recovery`,
%% `bondy_mst_pack_reader`), so classifying here is what stops the three of
%% them reporting the same condition three different ways — the raise an
%% operator sees is otherwise a bare `{4, file_io_server, invalid_unicode}`
%% naming neither the instance nor the file.
read_unreadable_file_names_the_path_test() ->
    with_tmp_dir(fun(Dir) ->
        Path = bondy_mst_pack_manifest:path(Dir),
        %% invalid UTF-8: exactly what the `~p` encoder used to write
        ok = file:write_file(
            Path, <<"{manifest_version, 1}.\n{x, \"", 233, "\"}.\n">>
        ),
        ?assertMatch(
            {error, {unreadable, Path, _}},
            bondy_mst_pack_manifest:read(Dir)
        )
    end).

%% A file that consults cleanly but fails `decode/1` is equally unusable and
%% must be classified the same way, not leak a bare parse error.
read_undecodable_file_names_the_path_test() ->
    with_tmp_dir(fun(Dir) ->
        Path = bondy_mst_pack_manifest:path(Dir),
        ok = file:write_file(Path, <<"{manifest_version, 1}.\n">>),
        ?assertMatch(
            {error, {unreadable, Path, _}},
            bondy_mst_pack_manifest:read(Dir)
        )
    end).

%% The control that keeps the classification from swallowing the one error
%% callers branch on: `enoent` means a FRESH instance, and
%% `bondy_mst_pack_writer:load_or_create_manifest/3` creates a manifest on it.
%% Wrapping it would turn every first open into a hard failure.
read_missing_file_returns_error_test() ->
    with_tmp_dir(fun(Dir) ->
        ?assertMatch({error, enoent}, bondy_mst_pack_manifest:read(Dir))
    end).

write_then_overwrite_test() ->
    with_tmp_dir(fun(Dir) ->
        M0 = sample(),
        ok = bondy_mst_pack_manifest:write(Dir, M0),
        M1 = bondy_mst_pack_manifest:add_sealed_pack(M0, 100),
        ok = bondy_mst_pack_manifest:write(Dir, M1),
        {ok, Read} = bondy_mst_pack_manifest:read(Dir),
        ?assertEqual([100], bondy_mst_pack_manifest:sealed_packs(Read))
    end).

read_ignores_stale_tmp_file_test() ->
    %% A pre-existing manifest.tmp from a prior interrupted write
    %% must not contaminate the read — the live `manifest` file is
    %% authoritative.
    with_tmp_dir(fun(Dir) ->
        M = sample(),
        ok = bondy_mst_pack_manifest:write(Dir, M),
        %% Drop an orphan tmp with bogus contents.
        TmpPath = bondy_mst_pack_manifest:tmp_path(Dir),
        ok = file:write_file(TmpPath, <<"garbage that won't parse\n">>),
        {ok, Read} = bondy_mst_pack_manifest:read(Dir),
        ?assertEqual(M, Read)
    end).

write_to_missing_dir_returns_error_test() ->
    %% No directory creation in `write/2`; the caller owns the
    %% per-instance directory bootstrap.
    ?assertMatch(
        {error, _},
        bondy_mst_pack_manifest:write(
            "/nonexistent/path/that/should/not/exist",
            sample()
        )
    ).

path_helpers_test() ->
    Dir = "/var/lib/bondy/mst/inst-1",
    ?assertEqual(
        filename:join(Dir, "manifest"),
        bondy_mst_pack_manifest:path(Dir)
    ),
    ?assertEqual(
        filename:join(Dir, "manifest.tmp"),
        bondy_mst_pack_manifest:tmp_path(Dir)
    ).

%% =============================================================================
%% PropEr round-trip
%% =============================================================================

proper_manifest_test_() ->
    Opts = [{numtests, 50}, {to_file, user}],
    [
        {timeout, 30,
            ?_assert(proper:quickcheck(prop_encode_decode_roundtrip(), Opts))}
    ].

prop_encode_decode_roundtrip() ->
    ?FORALL(
        M,
        manifest_gen(),
        begin
            Bin = bondy_mst_pack_manifest:encode(M),
            {ok, Terms} = bin_to_terms(Bin),
            case bondy_mst_pack_manifest:decode(Terms) of
                {ok, M} ->
                    true;
                Other ->
                    io:format("decode mismatch ~p~n", [Other]),
                    false
            end
        end
    ).

manifest_gen() ->
    ?LET(
        {Inst, Root, Packs, Incoming, Compacted},
        {
            ?LET(N, choose(1, 16), binary(N)),
            oneof([
                undefined,
                %% Roots drawn only from the latin-1 printable high range.
                %% Uniform `binary(32)` reaches this region ~0.04% of the
                %% time, so without this branch the property is blind to
                %% the encoder defect that `encode_survives_high_byte_
                %% roots_test_` pins.
                ?LET(
                    Bytes,
                    vector(?HASH_LEN, choose(160, 255)),
                    list_to_binary(Bytes)
                ),
                ?LET(B, binary(?HASH_LEN), B)
            ]),
            ?LET(
                L,
                choose(0, 8),
                ?LET(
                    Bases,
                    vector(L, choose(0, 1000)),
                    strict_ascending(Bases)
                )
            ),
            oneof([present, absent]),
            non_neg_integer()
        },
        begin
            M0 = bondy_mst_pack_manifest:new(Inst, sha256),
            M1 = bondy_mst_pack_manifest:with_current_root(M0, Root),
            M2 = bondy_mst_pack_manifest:with_incoming_pack(M1, Incoming),
            M3 = lists:foldl(
                fun(P, Acc) ->
                    bondy_mst_pack_manifest:add_sealed_pack(Acc, P)
                end,
                M2,
                Packs
            ),
            %% Stamp a deterministic time so the generator doesn't
            %% depend on the wall clock.
            bondy_mst_pack_manifest:with_last_compacted_at(M3, Compacted)
        end
    ).

%% @private  Coerce a list of non-negative integers into a strictly
%%           ascending list by sorting + dedup + advancing duplicates.
strict_ascending([]) ->
    [];
strict_ascending(L) ->
    Sorted = lists:sort(L),
    dedup_advance(Sorted, -1, []).

dedup_advance([], _, Acc) ->
    lists:reverse(Acc);
dedup_advance([H | T], Prev, Acc) when H > Prev ->
    dedup_advance(T, H, [H | Acc]);
dedup_advance([_ | T], Prev, Acc) ->
    dedup_advance(T, Prev + 1, [Prev + 1 | Acc]).

%% =============================================================================
%% Helpers
%% =============================================================================

base_terms() ->
    [
        {manifest_version, 1},
        {instance_id, <<"test-instance">>},
        {hash_algo, sha256},
        {current_root, undefined},
        {sealed_packs, []}
    ].

override_terms(Terms, Key, Value) ->
    lists:keystore(Key, 1, Terms, {Key, Value}).

%% @private  Parse an encoded manifest back into terms through the real
%%           production path: bytes on disk, read by `file:consult/1`.
%%
%%           This MUST go through disk. A previous version of this helper
%%           used `binary_to_list/1` + `erl_scan:string/1`, which applies
%%           latin-1 semantics and therefore accepted byte sequences that
%%           `file:consult/1` -- which decodes UTF-8 -- rejects with
%%           `{Line, file_io_server, invalid_unicode}`. That divergence hid
%%           a `~p` encoder defect that bricked every replica of a shard in
%%           production (see `format_term/1` in the module under test).
bin_to_terms(Bin) ->
    Dir = mktemp_dir(),
    try
        Path = filename:join(Dir, "encoded.terms"),
        ok = file:write_file(Path, Bin),
        file:consult(Path)
    after
        rmrf(Dir)
    end.
