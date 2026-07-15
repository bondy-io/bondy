%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Regression tests for the pack-store telemetry events specified by
%% `_design/latest/MST_PAGE_STORE_DESIGN.md` §13. Covers the four
%% currently-implemented events:
%%
%%   [bondy_mst, page_store, put]            — every successful put
%%   [bondy_mst, page_store, get]            — every get (hit or miss)
%%   [bondy_mst, page_store, seal_incoming]  — every non-noop seal
%%   [bondy_mst, page_store, gc]             — every gc/2 call
%%
%% The `recovery` event in design §13 is deferred until the dedicated
%% recovery module (QA item #1) lands; there is no current code path
%% that performs a recovery.
%%
%% Each test wraps its body in `with_telemetry/1`, which attaches a
%% handler that forwards events to the calling process via
%% `self() ! {telemetry, ...}`. Handler is detached + mailbox drained
%% in the `after` clause, so test isolation is per-function.
%% Setup-in-a-separate-process (eunit `{foreach, ...}`) does not work
%% here because the handler captures `self()` at attach time, and a
%% different test process would never see the messages.
%% =============================================================================
-module(bondy_mst_pack_store_telemetry_test).

-include_lib("eunit/include/eunit.hrl").

-define(EVENTS, [
    [bondy_mst, page_store, put],
    [bondy_mst, page_store, get],
    [bondy_mst, page_store, seal_incoming],
    [bondy_mst, page_store, gc]
]).

%% =============================================================================
%% Wrapper — attach handler, run test body, detach, drain
%% =============================================================================

with_telemetry(Fun) ->
    {ok, _} = application:ensure_all_started(telemetry),
    HandlerId = make_ref(),
    Self = self(),
    ok = telemetry:attach_many(
        HandlerId,
        ?EVENTS,
        fun(Event, Measurements, Metadata, _Cfg) ->
            Self ! {telemetry, Event, Measurements, Metadata}
        end,
        []
    ),
    try
        Fun()
    after
        ok = telemetry:detach(HandlerId),
        drain()
    end.

drain() ->
    receive
        {telemetry, _, _, _} -> drain()
    after 0 -> ok
    end.

%% Receive one matching event with a 1 s timeout.
recv_event(Event) ->
    receive
        {telemetry, Event, M, D} -> {M, D}
    after 1_000 ->
        erlang:error({timeout, Event, mailbox_dump()})
    end.

mailbox_dump() ->
    {messages, Msgs} = erlang:process_info(self(), messages),
    Msgs.

%% =============================================================================
%% Fixture helpers
%% =============================================================================

mk_tmp_dir() ->
    Base = lists:flatten(
        io_lib:format(
            "/tmp/bondy_mst_pack_store_telemetry_test_~p_~p",
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

open_store(Dir) ->
    InstanceId = list_to_binary(
        "telemetry_test_" ++
            integer_to_list(erlang:unique_integer([positive]))
    ),
    Store = bondy_mst_store:open(
        bondy_mst_pack_store,
        sha256,
        #{
            dir => Dir,
            instance_id => InstanceId,
            %% Disable auto-seal so each test controls when seal happens.
            auto_seal_records => infinity,
            auto_seal_bytes => infinity
        }
    ),
    {Store, InstanceId}.

mk_page(Level, Low, List) ->
    bondy_mst_page:new(Level, Low, List).

%% `bondy_mst_store:open/3` returns a wrapper record; the pack-store
%% extension API (`seal/1`, `gc/2`, `info/1`) operates on the inner
%% backend state.
extract(Store) ->
    {bondy_mst_store, bondy_mst_pack_store, Inner, _Tx} = Store,
    Inner.

wrap(Inner) ->
    {bondy_mst_store, bondy_mst_pack_store, Inner, false}.

%% =============================================================================
%% put
%% =============================================================================

put_event_basic_test() ->
    with_telemetry(fun() ->
        Dir = mk_tmp_dir(),
        try
            {S, InstanceId} = open_store(Dir),
            Page = mk_page(0, undefined, [{<<"k">>, <<"v">>, undefined}]),
            {_H, S1} = bondy_mst_store:put(S, Page),
            {M, D} = recv_event([bondy_mst, page_store, put]),
            ?assertMatch(#{instance_id := InstanceId}, D),
            ?assertEqual(false, maps:get(content_hit, M)),
            ?assert(maps:get(page_bytes, M) > 0),
            ?assert(maps:get(duration_us, M) >= 0),
            ok = bondy_mst_store:close(S1)
        after
            rmrf(Dir)
        end
    end).

put_event_content_hit_test() ->
    with_telemetry(fun() ->
        Dir = mk_tmp_dir(),
        try
            {S, _} = open_store(Dir),
            Page = mk_page(0, undefined, [{<<"k">>, <<"v">>, undefined}]),
            {_H, S1} = bondy_mst_store:put(S, Page),
            {M1, _} = recv_event([bondy_mst, page_store, put]),
            ?assertEqual(false, maps:get(content_hit, M1)),
            {_, S2} = bondy_mst_store:put(S1, Page),
            {M2, _} = recv_event([bondy_mst, page_store, put]),
            ?assertEqual(true, maps:get(content_hit, M2)),
            ok = bondy_mst_store:close(S2)
        after
            rmrf(Dir)
        end
    end).

%% =============================================================================
%% get
%% =============================================================================

get_event_pending_source_test() ->
    with_telemetry(fun() ->
        Dir = mk_tmp_dir(),
        try
            {S, _} = open_store(Dir),
            Page = mk_page(0, undefined, [{<<"k">>, <<"v">>, undefined}]),
            {H, S1} = bondy_mst_store:put(S, Page),
            _ = recv_event([bondy_mst, page_store, put]),
            _Page = bondy_mst_store:get(S1, H),
            {M, _} = recv_event([bondy_mst, page_store, get]),
            ?assertEqual(pending, maps:get(source, M)),
            ?assert(maps:get(page_bytes, M) > 0),
            ok = bondy_mst_store:close(S1)
        after
            rmrf(Dir)
        end
    end).

get_event_sealed_source_test() ->
    with_telemetry(fun() ->
        Dir = mk_tmp_dir(),
        try
            {S, _} = open_store(Dir),
            Page = mk_page(0, undefined, [{<<"k">>, <<"v">>, undefined}]),
            {H, S1} = bondy_mst_store:put(S, Page),
            _ = recv_event([bondy_mst, page_store, put]),
            {ok, S2} = bondy_mst_pack_store:seal(extract(S1)),
            _ = recv_event([bondy_mst, page_store, seal_incoming]),
            S2W = wrap(S2),
            _Page = bondy_mst_store:get(S2W, H),
            {M, _} = recv_event([bondy_mst, page_store, get]),
            ?assertMatch({sealed_pack, _}, maps:get(source, M)),
            ?assert(maps:get(page_bytes, M) > 0),
            ok = bondy_mst_store:close(S2W)
        after
            rmrf(Dir)
        end
    end).

get_event_cold_miss_test() ->
    with_telemetry(fun() ->
        Dir = mk_tmp_dir(),
        try
            {S, _} = open_store(Dir),
            Ghost = crypto:hash(sha256, <<"never-existed">>),
            undefined = bondy_mst_store:get(S, Ghost),
            {M, _} = recv_event([bondy_mst, page_store, get]),
            ?assertEqual(cold_miss, maps:get(source, M)),
            ?assertEqual(0, maps:get(page_bytes, M)),
            ok = bondy_mst_store:close(S)
        after
            rmrf(Dir)
        end
    end).

get_event_tombstoned_still_served_test() ->
    %% A tombstoned page whose bytes are still present is served on get (the
    %% `free_set` is a GC/enumeration hint, not a read mask). The page is in
    %% the writer's pending buffer, so the telemetry source is `pending`.
    with_telemetry(fun() ->
        Dir = mk_tmp_dir(),
        try
            {S, _} = open_store(Dir),
            Page = mk_page(0, undefined, [{<<"k">>, <<"v">>, undefined}]),
            {H, S1} = bondy_mst_store:put(S, Page),
            _ = recv_event([bondy_mst, page_store, put]),
            S2 = bondy_mst_store:delete(S1, H),
            Page = bondy_mst_store:get(S2, H),
            {M, _} = recv_event([bondy_mst, page_store, get]),
            ?assertEqual(pending, maps:get(source, M)),
            ?assert(maps:get(page_bytes, M) > 0),
            ok = bondy_mst_store:close(S2)
        after
            rmrf(Dir)
        end
    end).

%% =============================================================================
%% seal_incoming
%% =============================================================================

seal_event_carries_record_count_and_bytes_test() ->
    with_telemetry(fun() ->
        Dir = mk_tmp_dir(),
        try
            {S, InstanceId} = open_store(Dir),
            S1 = lists:foldl(
                fun(N, Acc) ->
                    Key = integer_to_binary(N),
                    Page = mk_page(0, undefined, [{Key, Key, undefined}]),
                    {_, Acc1} = bondy_mst_store:put(Acc, Page),
                    _ = recv_event([bondy_mst, page_store, put]),
                    Acc1
                end,
                S,
                lists:seq(1, 3)
            ),
            {ok, S2} = bondy_mst_pack_store:seal(extract(S1)),
            {M, D} = recv_event([bondy_mst, page_store, seal_incoming]),
            ?assertEqual(3, maps:get(record_count, M)),
            ?assert(maps:get(pack_bytes, M) > 0),
            ?assert(maps:get(duration_us, M) >= 0),
            ?assertMatch(
                #{
                    instance_id := InstanceId,
                    new_pack_id := _
                },
                D
            ),
            ok = bondy_mst_store:close(wrap(S2))
        after
            rmrf(Dir)
        end
    end).

seal_noop_emits_no_event_test() ->
    with_telemetry(fun() ->
        Dir = mk_tmp_dir(),
        try
            {S, _} = open_store(Dir),
            {ok, S1} = bondy_mst_pack_store:seal(extract(S)),
            receive
                {telemetry, [bondy_mst, page_store, seal_incoming], _, _} ->
                    erlang:error(unexpected_seal_event)
            after 200 -> ok
            end,
            ok = bondy_mst_store:close(wrap(S1))
        after
            rmrf(Dir)
        end
    end).

%% =============================================================================
%% gc
%% =============================================================================

gc_event_noop_when_nothing_sealed_test() ->
    with_telemetry(fun() ->
        Dir = mk_tmp_dir(),
        try
            {S, _} = open_store(Dir),
            {_S1, Meta} = bondy_mst_pack_store:gc(extract(S), []),
            ?assertEqual(false, maps:get(compacted, Meta)),
            {M, D} = recv_event([bondy_mst, page_store, gc]),
            ?assertEqual(0, maps:get(pages_kept, M)),
            ?assertEqual(0, maps:get(pages_dropped, M)),
            ?assertEqual(0, maps:get(packs_retired, M)),
            ?assertEqual(0, maps:get(packs_created, M)),
            ?assertEqual(0, maps:get(bytes_freed, M)),
            ?assertEqual(noop, maps:get(reason, D)),
            ok = bondy_mst_store:close(S)
        after
            rmrf(Dir)
        end
    end).

gc_event_compacted_test() ->
    with_telemetry(fun() ->
        Dir = mk_tmp_dir(),
        try
            {S, _} = open_store(Dir),
            P1 = mk_page(0, undefined, [{<<"a">>, <<"a">>, undefined}]),
            P2 = mk_page(0, undefined, [{<<"b">>, <<"b">>, undefined}]),
            {_, S1} = bondy_mst_store:put(S, P1),
            _ = recv_event([bondy_mst, page_store, put]),
            {ok, S2} = bondy_mst_pack_store:seal(extract(S1)),
            _ = recv_event([bondy_mst, page_store, seal_incoming]),
            {_, S3} = bondy_mst_store:put(wrap(S2), P2),
            _ = recv_event([bondy_mst, page_store, put]),
            {ok, S4} = bondy_mst_pack_store:seal(extract(S3)),
            _ = recv_event([bondy_mst, page_store, seal_incoming]),
            {_, Meta} = bondy_mst_pack_store:gc(S4, []),
            {M, D} = recv_event([bondy_mst, page_store, gc]),
            ?assertEqual(true, maps:get(compacted, Meta)),
            ?assertEqual(0, maps:get(pages_kept, M)),
            ?assertEqual(2, maps:get(pages_dropped, M)),
            ?assertEqual(2, maps:get(packs_retired, M)),
            ?assertEqual(0, maps:get(packs_created, M)),
            ?assert(maps:get(bytes_freed, M) > 0),
            ?assertEqual(compacted, maps:get(reason, D)),
            ok
        after
            rmrf(Dir)
        end
    end).

%% =============================================================================
%% info/1 gauges
%% =============================================================================

info_gauges_consistent_with_state_test() ->
    with_telemetry(fun() ->
        Dir = mk_tmp_dir(),
        try
            {S, InstanceId} = open_store(Dir),
            S1 = lists:foldl(
                fun(N, Acc) ->
                    Key = integer_to_binary(N),
                    Page = mk_page(0, undefined, [{Key, Key, undefined}]),
                    {_, Acc1} = bondy_mst_store:put(Acc, Page),
                    _ = recv_event([bondy_mst, page_store, put]),
                    Acc1
                end,
                S,
                lists:seq(1, 4)
            ),
            Info0 = bondy_mst_pack_store:info(extract(S1)),
            ?assertEqual(InstanceId, maps:get(instance_id, Info0)),
            ?assertEqual(0, maps:get(live_pack_count, Info0)),
            ?assertEqual(4, maps:get(pending_record_count, Info0)),
            ?assertEqual(0, maps:get(bytes_total, Info0)),
            %% pending_bytes mirrors the on-disk incoming.pack size
            %% (header + per-record headers + bodies). Non-zero
            %% whenever pending_record_count is non-zero.
            ?assert(maps:get(pending_bytes, Info0) > 0),
            {ok, S2} = bondy_mst_pack_store:seal(extract(S1)),
            _ = recv_event([bondy_mst, page_store, seal_incoming]),
            Info1 = bondy_mst_pack_store:info(S2),
            ?assertEqual(1, maps:get(live_pack_count, Info1)),
            ?assertEqual(0, maps:get(pending_record_count, Info1)),
            %% Post-seal: pending_bytes drops back to 0 (incoming.pack
            %% is recreated lazily on the next append).
            ?assertEqual(0, maps:get(pending_bytes, Info1)),
            ?assert(maps:get(bytes_total, Info1) > 0),
            ok = bondy_mst_store:close(wrap(S2))
        after
            rmrf(Dir)
        end
    end).
