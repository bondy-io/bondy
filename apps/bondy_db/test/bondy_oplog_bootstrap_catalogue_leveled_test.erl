%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% End-to-end test for `bondy_oplog_sync_session:bootstrap_catalogue/3`
%% against the **leveled** projection adapter on both replicas.
%%
%% Where the ETS-backed e2e test (`bondy_oplog_bootstrap_catalogue_test`)
%% exercises the orchestration logic, this test pins the wire shape
%% against the production storage backend: leveled's range-scan
%% behaviour, V2 frame round-trip, and the adapter's `get/put_batch`
%% pair under the bootstrap install path.
%%
%% Verifies:
%%   - Fresh local replica with a leveled adapter bootstraps every cell
%%     from a leveled-backed peer in `replace` mode.
%%   - Post-bootstrap high-water on local matches the peer's
%%     session-start watermark.
%%   - Local frames are byte-identical to the peer frames (proof that
%%     the V2 frame round-trip through leveled is lossless).
%% =============================================================================
-module(bondy_oplog_bootstrap_catalogue_leveled_test).

-include_lib("eunit/include/eunit.hrl").

-define(B, <<>>).
-define(PA, bondy_db_projection_leveled).

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

leveled_bootstrap_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 30, fun fresh_replica_bootstraps_via_leveled/0}
    ]}.

fresh_replica_bootstraps_via_leveled() ->
    Dir1 = make_tempdir(),
    Dir2 = make_tempdir(),
    %% head_only=with_lookup is required by bondy_db_projection_leveled.
    BookOpts = fun(D) ->
        [
            {root_path, D},
            {cache_size, 2000},
            {max_journalsize, 100_000_000},
            {sync_strategy, none},
            {head_only, with_lookup}
        ]
    end,
    {ok, B1} = leveled_bookie:book_start(BookOpts(Dir1)),
    {ok, B2} = leveled_bookie:book_start(BookOpts(Dir2)),
    try
        {Peer, PeerEntry} = setup_instance_with_leveled(B1),
        {Local, LocalEntry} = setup_instance_with_leveled(B2),

        Cells = [
            {<<"alpha">>, 10, <<"a">>},
            {<<"beta">>, 25, <<"b">>},
            {<<"gamma">>, 5, <<"c">>},
            {<<"delta">>, 17, <<"d">>},
            {<<"epsilon">>, 33, <<"e">>}
        ],

        [
            bondy_oplog:append(Peer, {cell_apply, ?B, K, {set, Hlc, V}})
         || {K, Hlc, V} <- Cells
        ],
        _ = bondy_oplog:projection(Peer),

        %% Pre-bootstrap state.
        ?assertMatch({ok, 33}, high_water_for(PeerEntry)),
        ?assertMatch({ok, no_watermark}, high_water_for(LocalEntry)),

        ?assertMatch(
            {ok, _Root},
            bondy_oplog_sync_session:bootstrap_catalogue(
                Local, Peer, #{}
            )
        ),

        %% Post-bootstrap state.
        ?assertMatch({ok, 33}, high_water_for(LocalEntry)),

        %% Each cell's frame is byte-identical between peer and local.
        PA = ?PA,
        PeerH = bondy_oplog_core_registry:entry_projection_handle(PeerEntry),
        LocalH = bondy_oplog_core_registry:entry_projection_handle(LocalEntry),
        [
            begin
                {ok, PFrame} = PA:get(PeerH, ?B, K),
                {ok, LFrame} = PA:get(LocalH, ?B, K),
                ?assertEqual(PFrame, LFrame)
            end
         || {K, _, _} <- Cells
        ]
    after
        ok = leveled_bookie:book_close(B1),
        ok = leveled_bookie:book_close(B2),
        rmrf(Dir1),
        rmrf(Dir2)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

setup_instance_with_leveled(BookiePid) ->
    Id = mk_id(),
    NS = ns_of(Id),
    {ok, Proj} = ?PA:open(NS, primary, 0, #{bookie => BookiePid}),
    {ok, Cache} = bondy_oplog_cache_ets:init(NS, primary, 0, #{}),
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
    {ok, Entry} = bondy_oplog_core_registry:lookup(NS, primary, 0),
    {Id, Entry}.

high_water_for(Entry) ->
    Ref = bondy_oplog_core_registry:entry_high_water_ref(Entry),
    bondy_oplog_high_water:read(Ref).

mk_id() ->
    iolist_to_binary([
        "btl_",
        integer_to_binary(erlang:unique_integer([positive]))
    ]).

ns_of(Id) when is_binary(Id) ->
    binary_to_atom(<<"ns_", Id/binary>>, utf8).

make_tempdir() ->
    Base = filename:join([
        "/tmp/" ++ os:getpid(),
        "bondy_mst_bootstrap_catalogue_leveled_test",
        integer_to_list(erlang:unique_integer([positive, monotonic]))
    ]),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.

rmrf(Dir) ->
    case file:del_dir_r(Dir) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, _} -> ok
    end.
