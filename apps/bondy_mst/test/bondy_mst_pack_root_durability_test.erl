%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Durability-ordering coverage for the pack writer's staged-root flush.
%%
%% A content-addressed MST is only crash-safe if the root is made durable
%% AFTER every page it references. `bondy_mst_pack_writer:flush/1` honours
%% that ("pages-then-root"): it calls `flush_incoming/1` before
%% `flush_pending_root/1`. But the *debounced* root write reached from
%% `set_root/2` (and the dirty-root branch of `seal/1`) goes straight to
%% `do_flush_root/1`, which rewrites the manifest WITHOUT first datasyncing
%% `incoming.pack`. The append path only datasyncs on its own
%% `sync_every_records`/`sync_every_ms` schedule, so the root can become
%% durable while the pages it references are still unsynced in
%% `incoming.pack`.
%%
%% On a power loss / OS crash the unsynced tail of `incoming.pack` is lost
%% and `bondy_mst_pack_recovery` truncates the trailing records, but the
%% manifest root survives — leaving a root that references pages present on
%% no replica. That is exactly the production AAE signature: a node
%% advertises an MST root whose pages it then cannot serve
%% (`peer_returned_empty_pages`), and local reads silently drop the
%% subtree.
%%
%% The existing `bondy_mst_pack_crash_injection_test` only exercises the
%% SAFE direction (pages eager via `sync_every_records => 1`, root lazy via
%% `root_flush_every_records => infinity` — so the root lags the pages).
%% These tests cover the dangerous inverse.
-module(bondy_mst_pack_root_durability_test).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% EUnit
%% =============================================================================

root_durability_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(bondy_mst),
            ok
        end,
        fun(_) -> ok end, [
            {timeout, 30, fun eager_set_root_syncs_pages_first/0},
            {timeout, 30, fun crash_after_eager_root_keeps_root_servable/0}
        ]}.

%% The invariant: once `set_root/2` makes the root durable, there must be
%% no unsynced pages left in `incoming.pack` — otherwise the root depends
%% on bytes a crash can still lose.
eager_set_root_syncs_pages_first() ->
    with_tmp_dir(fun(Dir) ->
        S0 = bondy_mst_pack_store:open(sha256, store_opts(Dir)),
        Leaf = bondy_mst_page:new(0, undefined, [{k1, v1, undefined}]),
        {LeafHash, S1} = bondy_mst_pack_store:put(S0, Leaf),
        Top = bondy_mst_page:new(1, LeafHash, [{k2, v2, undefined}]),
        {TopHash, S2} = bondy_mst_pack_store:put(S1, Top),

        %% Pages are buffered in incoming.pack but not datasync'd
        %% (sync_every_records => infinity).
        ?assert(writer_unsynced(S2) > 0),

        %% Make the root durable (root_flush_every_records => 1 fires the
        %% debounce immediately). The pages it references MUST be durable
        %% too, i.e. nothing left unsynced.
        S3 = bondy_mst_pack_store:set_root(S2, TopHash),
        ?assertEqual(0, writer_unsynced(S3)),

        _ = (catch bondy_mst_pack_store:close(S3)),
        ok
    end).

%% End-to-end proof: stage a root eagerly while its pages are unsynced,
%% simulate a crash by dropping the unsynced tail of incoming.pack (what
%% `bondy_mst_pack_recovery` does on reopen), reopen, and assert the
%% surviving root is fully servable.
crash_after_eager_root_keeps_root_servable() ->
    with_tmp_dir(fun(Dir) ->
        Opts = store_opts(Dir),
        Path = filename:join(Dir, "incoming.pack"),

        S0 = bondy_mst_pack_store:open(sha256, Opts),

        %% Wave A — durable baseline. Flush forces pages-then-root.
        LeafA = bondy_mst_page:new(0, undefined, [{a1, v, undefined}]),
        {LeafAH, S1} = bondy_mst_pack_store:put(S0, LeafA),
        TopA = bondy_mst_page:new(1, LeafAH, [{a2, v, undefined}]),
        {TopAH, S2} = bondy_mst_pack_store:put(S1, TopA),
        S3 = bondy_mst_pack_store:set_root(S2, TopAH),
        {ok, S4} = bondy_mst_pack_store:flush(S3),
        ?assertEqual(0, writer_unsynced(S4)),
        SyncedSize = filelib:file_size(Path),

        %% Wave B — appended after the last sync. set_root stages a NEW
        %% root that references wave-B pages.
        LeafB = bondy_mst_page:new(0, undefined, [{b1, v, undefined}]),
        {LeafBH, S5} = bondy_mst_pack_store:put(S4, LeafB),
        TopB = bondy_mst_page:new(1, LeafBH, [{b2, v, undefined}]),
        {TopBH, S6} = bondy_mst_pack_store:put(S5, TopB),
        S7 = bondy_mst_pack_store:set_root(S6, TopBH),

        %% Faithful crash model: datasync'd bytes survive, unsynced bytes
        %% are lost. If the writer left wave B unsynced, the durable file
        %% ends at SyncedSize; otherwise everything is durable.
        TruncateTo =
            case writer_unsynced(S7) of
                0 -> filelib:file_size(Path);
                _ -> SyncedSize
            end,
        ok = truncate_file(Path, TruncateTo),
        %% Abandon S7 WITHOUT closing — close/1 would flush and defeat the
        %% crash simulation.

        %% Reopen (runs recovery) and assert the committed root is fully
        %% servable: every page reachable from it is present.
        R0 = bondy_mst_pack_store:open(sha256, Opts),
        Root = bondy_mst_pack_store:get_root(R0),
        ?assert(is_binary(Root)),
        Missing = lists:sort(
            sets:to_list(
                normalise(bondy_mst_pack_store:missing_set(R0, Root))
            )
        ),
        ?assertEqual([], Missing),
        ok = bondy_mst_pack_store:close(R0)
    end).

%% =============================================================================
%% Helpers
%% =============================================================================

%% @private
%% Root eager, pages and seals lazy — the configuration that makes the
%% root durable ahead of the pages it references.
store_opts(Dir) ->
    #{
        dir => Dir,
        instance_id => <<"root-durability-test">>,
        root_flush_every_records => 1,
        root_flush_every_ms => infinity,
        sync_every_records => infinity,
        sync_every_ms => infinity,
        auto_seal_records => infinity,
        auto_seal_bytes => infinity
    }.

%% @private
%% The pack store keeps its writer in the first record field.
writer_unsynced(Store) ->
    bondy_mst_pack_writer:unsynced_count(element(2, Store)).

%% @private
truncate_file(Path, Size) ->
    {ok, Fd} = file:open(Path, [read, write, binary, raw]),
    try
        {ok, _} = file:position(Fd, Size),
        ok = file:truncate(Fd)
    after
        ok = file:close(Fd)
    end.

%% @private
normalise(L) when is_list(L) -> sets:from_list(L, [{version, 2}]);
normalise(S) -> S.

%% @private
mktemp_dir() ->
    Base = filename:join([
        "/tmp",
        lists:flatten(
            io_lib:format(
                "bondy_mst_pack_root_durability_~p_~p",
                [
                    erlang:system_time(microsecond),
                    erlang:unique_integer([positive])
                ]
            )
        )
    ]),
    ok = filelib:ensure_path(Base),
    Base.

%% @private
with_tmp_dir(Fun) ->
    Dir = mktemp_dir(),
    try
        Fun(Dir)
    after
        _ = file:del_dir_r(Dir)
    end.
