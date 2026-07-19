%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Bounds the AAE sync session's per-round memory: a session pulls at most
%% `bondy_oplog_config:aae_pages_per_round/0` pages per round
%% (`aae_max_pages_in_flight ÷ aae_max_concurrency`), NOT the whole missing set.
%% This is what makes AAE's peak memory independent of dataset size and of how
%% many sessions run concurrently. Here we pin a tiny node-wide budget (2 pages
%% / round) and prove a 300-event sync still converges — over many bounded
%% rounds, with no single `get_pages` round exceeding the cap.
%% =============================================================================

-module(bondy_oplog_sync_bounded_batch_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    bondy_oplog_sync_scheduler:set_dispatch(undefined),
    bondy_oplog_gc_scheduler:set_trigger(undefined),
    %% Snapshot the AAE budget env so the test can pin it and restore.
    {
        application:get_env(bondy_oplog, aae_max_concurrency),
        application:get_env(bondy_oplog, aae_max_pages_in_flight)
    }.

cleanup({PrevConc, PrevPages}) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    restore(aae_max_concurrency, PrevConc),
    restore(aae_max_pages_in_flight, PrevPages),
    ok.

restore(Key, undefined) -> application:unset_env(bondy_oplog, Key);
restore(Key, {ok, V}) -> application:set_env(bondy_oplog, Key, V).

bounded_batch_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        {timeout, 60, fun bounded_batch_converges/0}
    end}.

bounded_batch_converges() ->
    %% Tiny node-wide budget → 2 pages per round.
    application:set_env(bondy_oplog, aae_max_concurrency, 1),
    application:set_env(bondy_oplog, aae_max_pages_in_flight, 2),
    ?assertEqual(2, bondy_oplog_config:aae_pages_per_round()),

    A = mk_inst(),
    B = mk_inst(),
    {ok, _} = bondy_oplog:start_instance(A, originated_opts()),
    {ok, _} = bondy_oplog:start_instance(B, originated_opts()),
    %% Enough events that B's MST holds many pages (>> 2) → many bounded rounds.
    [bondy_oplog:append(B, {b, N}) || N <- lists:seq(1, 300)],

    %% Capture every {get_pages, Batch} the session issues.
    Tab = ets:new(get_pages_batches, [public, bag]),
    meck:new(bondy_oplog_transport_inline, [passthrough]),
    %% Both request shapes are captured: the reciprocal 4-tuple the session
    %% now sends, and the legacy 2-tuple retained for mixed-version clusters.
    meck:expect(
        bondy_oplog_transport_inline,
        request,
        fun
            (Peer, Inst, {get_pages, Batch} = Req, Opts) ->
                true = ets:insert(Tab, {sz, length(Batch)}),
                meck:passthrough([Peer, Inst, Req, Opts]);
            (Peer, Inst, {get_pages, _Self, _Root, Batch} = Req, Opts) ->
                true = ets:insert(Tab, {sz, length(Batch)}),
                meck:passthrough([Peer, Inst, Req, Opts]);
            (Peer, Inst, Req, Opts) ->
                meck:passthrough([Peer, Inst, Req, Opts])
        end
    ),

    Result = bondy_oplog:sync(A, B),
    meck:unload(bondy_oplog_transport_inline),
    ?assertMatch({ok, _}, Result),

    %% Converged: A now holds every page reachable from B's current root.
    ?assertEqual(
        [],
        bondy_oplog_instance:missing_set(A, bondy_oplog:root_hash(B))
    ),

    Sizes = ets:select(Tab, [{{sz, '$1'}, [], ['$1']}]),
    ets:delete(Tab),
    ?assert(Sizes =/= []),

    %% BOUNDED: no round pulled more than the per-round cap.
    Max = lists:max(Sizes),
    ?assert(
        Max =< 2,
        lists:flatten(
            io_lib:format("a get_pages round pulled ~p pages (cap 2)", [Max])
        )
    ),
    %% Genuinely bounded → it needed many rounds (one unbounded round would
    %% have pulled the whole tree at once).
    ?assert(length(Sizes) > 1),
    ok.

mk_inst() ->
    list_to_binary(
        "bbsync_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

originated_opts() ->
    #{origin => bondy_oplog_origin:new()}.
