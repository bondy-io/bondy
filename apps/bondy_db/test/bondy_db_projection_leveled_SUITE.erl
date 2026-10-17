%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% `bondy_db_projection_leveled:head/4` reads the one subkey the caller's
%% kernel writes. A cell's two subkeys land in one `book_mput/2`, but a read
%% that asks for the value subkey, misses, and then asks for the state subkey
%% sees the state of a cell whose write landed in between, which the value
%% decoder of a `lww_register` cell cannot decode. The last case drives that
%% interleaving: the reader spins on the value column of a cell the writer
%% creates under it and decodes whatever it is first served.

-module(bondy_db_projection_leveled_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(ADAPTER, bondy_db_projection_leveled).
-define(LWW, bondy_oplog_crdt_lww_register).
-define(B, <<"bucket">>).
-define(HLC, 1_000_000).

all() ->
    [
        head_of_a_value_column_cell_is_its_value_column,
        head_of_a_state_only_cell_is_not_found_on_the_value_column,
        head_under_concurrent_creation_is_absent_or_whole
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(bondy_db),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    Dir = filename:join(?config(priv_dir, Config), atom_to_list(Case)),
    ok = filelib:ensure_path(Dir),
    {ok, Sup} = bondy_db_leveled_sup:start_link(),
    {ok, Pid} = bondy_db_leveled_sup:start_bookie(Sup, [
        {root_path, Dir}, {head_only, with_lookup}, {log_level, error}
    ]),
    {ok, H} = ?ADAPTER:open(ns, primary, 0, #{bookie => Pid, root_path => Dir}),
    [{sup, Sup}, {handle, H} | Config].

end_per_testcase(_Case, Config) ->
    ok = bondy_db_leveled_sup:stop(?config(sup, Config)),
    ok.

%% =============================================================================
%% CASES
%% =============================================================================

head_of_a_value_column_cell_is_its_value_column(Config) ->
    H = ?config(handle, Config),
    {StateBytes, ValueBytes} = lww_columns(<<"alice">>),
    ok = ?ADAPTER:put_batch(H, [
        {?B, <<"k">>, value_frame(StateBytes, ValueBytes)}
    ]),
    ?assertEqual(
        {ok, head_wire(ValueBytes)},
        ?ADAPTER:head(H, ?B, <<"k">>, #{value_column => true})
    ),
    ?assertEqual(
        {ok, head_wire(StateBytes)},
        ?ADAPTER:head(H, ?B, <<"k">>, #{value_column => false})
    ).

head_of_a_state_only_cell_is_not_found_on_the_value_column(Config) ->
    H = ?config(handle, Config),
    {StateBytes, _} = lww_columns(<<"alice">>),
    ok = ?ADAPTER:put_batch(H, [{?B, <<"k">>, state_only_frame(StateBytes)}]),
    ?assertEqual(
        not_found, ?ADAPTER:head(H, ?B, <<"k">>, #{value_column => true})
    ),
    ?assertEqual(
        {ok, head_wire(StateBytes)},
        ?ADAPTER:head(H, ?B, <<"k">>, #{value_column => false})
    ),
    ?assertEqual(
        not_found, ?ADAPTER:head(H, ?B, <<"absent">>, #{value_column => false})
    ).

%% Reader and writer race on 300 cells. Whatever the reader is first served on
%% the value column decodes as the written value: an absent cell is
%% `not_found`, never the state column.
head_under_concurrent_creation_is_absent_or_whole(Config) ->
    H = ?config(handle, Config),
    Kernel = {crdt, ?LWW},
    Self = self(),
    lists:foreach(
        fun(I) ->
            K = <<"k", (integer_to_binary(I))/binary>>,
            V = <<"v", (integer_to_binary(I))/binary>>,
            Reader = spawn_link(fun() -> Self ! {first, spin(H, K)} end),
            spin_cpu(rand:uniform(300)),
            {StateBytes, ValueBytes} = lww_columns(V),
            ok = ?ADAPTER:put_batch(H, [
                {?B, K, value_frame(StateBytes, ValueBytes)}
            ]),
            receive
                {first, HeadBytes} ->
                    {?HLC, Bytes} = bondy_oplog_cell_frame:decode_head(
                        HeadBytes
                    ),
                    ?assertEqual(
                        V,
                        bondy_oplog_cell_kernel:decode_value_bytes(
                            Kernel, Bytes
                        )
                    )
            after 5000 ->
                ct:fail({reader_stuck, K, Reader})
            end
        end,
        lists:seq(1, 300)
    ).

%% =============================================================================
%% HELPERS
%% =============================================================================

lww_columns(V) ->
    {?LWW:encode_state({set, V, ?HLC}), term_to_binary(V)}.

value_frame(StateBytes, ValueBytes) ->
    bondy_oplog_cell_frame:encode(?HLC, StateBytes, ValueBytes, false).

state_only_frame(StateBytes) ->
    bondy_oplog_cell_frame:encode(?HLC, StateBytes, undefined, true).

head_wire(Bytes) ->
    <<8:16/big-unsigned, ?HLC:64/big-unsigned, Bytes/binary>>.

spin(H, K) ->
    case ?ADAPTER:head(H, ?B, K, #{value_column => true}) of
        not_found -> spin(H, K);
        {ok, HeadBytes} -> HeadBytes
    end.

spin_cpu(0) -> ok;
spin_cpu(N) -> spin_cpu(N - 1).
