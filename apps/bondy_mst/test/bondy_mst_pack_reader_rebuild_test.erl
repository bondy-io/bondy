%% =============================================================================
%% Regression coverage for self-healing `.idx` rebuild on
%% `bondy_mst_pack_reader:open/1`. The read-only reader was a
%% PR-PS-4 carry-over: the store self-healed but the reader bubbled
%% up the original error. Both surfaces now share
%% `bondy_mst_pack_sealed_view:open/3`, so the reader inherits the
%% rebuild path. This module asserts that.
%%
%% Pack-store QA #4 sub-bullet (PR-PS-4 carry-over).
%% =============================================================================

-module(bondy_mst_pack_reader_rebuild_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

%% =============================================================================
%% Helpers
%% =============================================================================

mk_tmp_dir() ->
    Base = lists:flatten(
        io_lib:format(
            "/tmp/bondy_mst_pack_reader_rebuild_test_~p_~p",
            [
                erlang:system_time(microsecond),
                erlang:unique_integer([positive])
            ]
        )
    ),
    ok = filelib:ensure_path(Base),
    Base.

rmrf(Dir) ->
    _ = file:del_dir_r(Dir),
    ok.

mk_instance_id() ->
    list_to_binary(
        "reader_rebuild_test_" ++
            integer_to_list(erlang:unique_integer([positive]))
    ).

open_pack_store(Dir, InstanceId) ->
    bondy_mst_pack_store:open(
        sha256,
        #{
            dir => Dir,
            instance_id => InstanceId,
            auto_seal_records => infinity,
            auto_seal_bytes => infinity
        }
    ).

mk_page(K, V) ->
    bondy_mst_page:new(0, undefined, [{K, V, undefined}]).

%% Seed N pages, seal once, close the store. Returns
%% {Dir, InstanceId, PackId, [{Hash, Page}]}.
seed_and_seal(N) ->
    Dir = mk_tmp_dir(),
    InstanceId = mk_instance_id(),
    S0 = open_pack_store(Dir, InstanceId),
    {S1, HashPages} = lists:foldl(
        fun(I, {S, Acc}) ->
            K = list_to_binary("k" ++ integer_to_list(I)),
            V = list_to_binary("v" ++ integer_to_list(I)),
            P = mk_page(K, V),
            {H, S2} = bondy_mst_pack_store:put(S, P),
            {S2, [{H, P} | Acc]}
        end,
        {S0, []},
        lists:seq(1, N)
    ),
    {ok, S2} = bondy_mst_pack_store:seal(S1),
    [PackId] = bondy_mst_pack_store:sealed_pack_ids(S2),
    ok = bondy_mst_pack_store:close(S2),
    {Dir, InstanceId, PackId, lists:reverse(HashPages)}.

idx_path(Dir, PackId) ->
    bondy_mst_pack_paths:sealed_idx_path(Dir, PackId).

is_regular(Path) -> filelib:is_regular(Path).

%% Wraps the body in a per-test handler that captures all
%% idx_rebuild telemetry events into the test's mailbox.
with_telemetry(Fun) ->
    {ok, _} = application:ensure_all_started(telemetry),
    %% Drain any telemetry messages left in the mailbox by an earlier
    %% test in the same eunit process — eunit doesn't isolate
    %% mailboxes between cases.
    drain_telemetry(),
    Self = self(),
    HandlerId = {?MODULE, erlang:unique_integer([positive])},
    Events = [[bondy_mst, page_store, idx_rebuild]],
    ok = telemetry:attach_many(
        HandlerId,
        Events,
        fun(E, M, Meta, _Cfg) -> Self ! {telemetry, E, M, Meta} end,
        #{}
    ),
    try
        Fun()
    after
        telemetry:detach(HandlerId)
    end.

drain_telemetry() ->
    receive
        {telemetry, _, _, _} -> drain_telemetry()
    after 0 -> ok
    end.

recv_rebuild_event() ->
    receive
        {telemetry, [bondy_mst, page_store, idx_rebuild], M, Meta} ->
            {M, Meta}
    after 100 -> none
    end.

%% =============================================================================
%% Tests
%% =============================================================================

reader_rebuilds_missing_idx_test_() ->
    {timeout, 30, fun reader_rebuilds_missing_idx/0}.

reader_rebuilds_missing_idx() ->
    with_telemetry(fun() ->
        {Dir, _InstanceId, PackId, HashPages} = seed_and_seal(5),
        try
            IdxPath = idx_path(Dir, PackId),
            ?assert(is_regular(IdxPath)),
            ok = prim_file:delete(IdxPath),
            ?assertNot(is_regular(IdxPath)),
            %% Open via the read-only reader. Rebuild fires; reader
            %% sees a working sealed view; every page is gettable.
            {ok, R} = bondy_mst_pack_reader:open(Dir),
            ?assertEqual([PackId], bondy_mst_pack_reader:sealed_pack_ids(R)),
            %% Reader returns raw page bytes (the encoded form on disk),
            %% not the bondy_mst_page record. Just confirm every hash
            %% resolves — content equivalence is covered exhaustively
            %% in bondy_mst_pack_idx_rebuild_test.
            lists:foreach(
                fun({H, _P}) ->
                    ?assertMatch(
                        {ok, B} when is_binary(B),
                        bondy_mst_pack_reader:get(R, H)
                    )
                end,
                HashPages
            ),
            ok = bondy_mst_pack_reader:close(R),
            %% The .idx is back on disk after the rebuild.
            ?assert(is_regular(IdxPath)),
            %% Telemetry: exactly one `enoent` rebuild event.
            {_M, Meta} = recv_rebuild_event(),
            ?assertEqual(ok, maps:get(result, Meta)),
            ?assertEqual(enoent, maps:get(trigger, Meta)),
            ?assertEqual(PackId, maps:get(pack_id, Meta))
        after
            rmrf(Dir)
        end
    end).

reader_clean_open_emits_no_event_test_() ->
    {timeout, 30, fun reader_clean_open_emits_no_event/0}.

reader_clean_open_emits_no_event() ->
    with_telemetry(fun() ->
        {Dir, _InstanceId, _PackId, _HashPages} = seed_and_seal(3),
        try
            {ok, R} = bondy_mst_pack_reader:open(Dir),
            ok = bondy_mst_pack_reader:close(R),
            ?assertEqual(none, recv_rebuild_event())
        after
            rmrf(Dir)
        end
    end).
