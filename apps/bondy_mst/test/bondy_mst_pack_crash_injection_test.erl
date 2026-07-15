%% =============================================================================
%% Crash-injection coverage for the staged-root debounce.
%%
%% The pack writer debounces manifest rewrites: `set_root/2` updates the
%% in-memory manifest but only fsyncs the on-disk file when the policy
%% fires (`root_flush_every_records` / `root_flush_every_ms`).
%% `close/1` / `flush/1` / `seal/1` force a final write so clean
%% shutdown is lossless. The crash window is the gap between a
%% `set_root/2` call and the next debounce flush: a hard exit there
%% should leave the on-disk root at the previously persisted value,
%% and a subsequent WAL replay (or any other authoritative `set_root`
%% caller) should be able to bring the on-disk root back to the
%% in-memory value.
%%
%% This module spawns a peer node, drives the store from there, and
%% SIGKILLs the peer between `set_root/2` and any debounce flush. The
%% parent then opens the store directly and verifies both halves.
%%
%% Pack-store QA item #13.
%% =============================================================================

-module(bondy_mst_pack_crash_injection_test).

-include_lib("eunit/include/eunit.hrl").

%% Invoked by the peer via erpc:call/4.
-export([peer_stage_root/4]).

-define(STAGED_TAG, staged_ack).

%% =============================================================================
%% Eunit entry
%% =============================================================================

%% Slightly looser timeout: peer boot + kill -9 + manifest fsyncs.
crash_loses_staged_root_wal_replay_recovers_test_() ->
    {timeout, 60, fun crash_loses_staged_root_wal_replay_recovers/0}.

crash_loses_staged_root_wal_replay_recovers() ->
    process_flag(trap_exit, true),
    {ok, _} = application:ensure_all_started(telemetry),
    ok = ensure_distribution(),
    Dir = mk_tmp_dir(),
    InstId = mk_inst_id(),
    Persisted = sha256(<<"persisted-root">>),
    Staged = sha256(<<"staged-root">>),
    Pages = mk_pages([{k1, v1}, {k2, v2}, {k3, v3}]),
    try
        %% Phase 1 — persist R0 on parent with low threshold so the
        %% set_root call fsyncs immediately. Close cleanly.
        Store0 = bondy_mst_pack_store:open(sha256, #{
            dir => Dir,
            instance_id => InstId,
            root_flush_every_records => 1,
            root_flush_every_ms => infinity
        }),
        Store1 = bondy_mst_pack_store:set_root(Store0, Persisted),
        ok = bondy_mst_pack_store:close(Store1),
        ?assertEqual(Persisted, on_disk_root(Dir)),

        %% Phase 2 — peer reopens the SAME dir with debounce off, appends
        %% synced pages, stages R1, and parks (no close, no flush).
        {ok, Peer, Node} = start_peer(),
        try
            ok = setup_peer(Node),
            PeerOsPid = peer_os_pid(Node),
            ?STAGED_TAG = erpc:call(
                Node,
                ?MODULE,
                peer_stage_root,
                [Dir, InstId, Staged, Pages]
            ),

            %% Phase 3 — kill -9. peer:start_link/1 linked the peer to
            %% us; trap_exit catches the linked exit.
            _ = os:cmd("kill -9 " ++ integer_to_list(PeerOsPid)),
            ok = await_peer_exit(Peer, 5_000)
        after
            catch peer:stop(Peer)
        end,

        %% Phase 4 — verify staged R1 was lost. The on-disk manifest is
        %% still at R0 because no debounce ever fired on the peer.
        ?assertEqual(Persisted, on_disk_root(Dir)),

        %% Phase 5 — simulate WAL replay: reopen, observe R0, write R1
        %% authoritatively, close. The on-disk root catches up.
        Store2 = bondy_mst_pack_store:open(sha256, #{
            dir => Dir,
            instance_id => InstId,
            root_flush_every_records => 1,
            root_flush_every_ms => infinity
        }),
        ?assertEqual(Persisted, bondy_mst_pack_store:get_root(Store2)),
        %% Pages appended before the crash were sync_every_records=1 on
        %% the peer, so they should still be visible.
        lists:foreach(
            fun(Page) ->
                Hash = bondy_mst_page:hash(Page, sha256),
                ?assertEqual(Page, bondy_mst_pack_store:get(Store2, Hash))
            end,
            Pages
        ),
        Store3 = bondy_mst_pack_store:set_root(Store2, Staged),
        ok = bondy_mst_pack_store:close(Store3),
        ?assertEqual(Staged, on_disk_root(Dir))
    after
        rmrf(Dir)
    end.

%% =============================================================================
%% Peer-side entry
%% =============================================================================

%% Runs on the peer node. Opens the store with the manifest debounce
%% effectively disabled, appends synced pages, stages a new root, and
%% intentionally returns without closing or flushing. The store stays
%% open in the peer's process tree until the parent SIGKILLs the VM.
peer_stage_root(Dir, InstId, StagedRoot, Pages) ->
    Store0 = bondy_mst_pack_store:open(sha256, #{
        dir => Dir,
        instance_id => InstId,
        %% Manifest debounce off so set_root/2 never fsyncs.
        root_flush_every_records => infinity,
        root_flush_every_ms => infinity,
        %% Append path fully synced so post-crash reopen sees the pages.
        sync_every_records => 1,
        sync_every_ms => infinity,
        %% Auto-seal off — a seal would force a manifest rewrite.
        auto_seal_records => infinity,
        auto_seal_bytes => infinity
    }),
    Store1 = lists:foldl(
        fun(Page, Acc) ->
            {_Hash, Acc1} = bondy_mst_pack_store:put(Acc, Page),
            Acc1
        end,
        Store0,
        Pages
    ),
    _Store2 = bondy_mst_pack_store:set_root(Store1, StagedRoot),
    %% Leak the store deliberately. The parent SIGKILLs the BEAM next.
    ?STAGED_TAG.

%% =============================================================================
%% Distribution + peer plumbing
%% =============================================================================

ensure_distribution() ->
    case net_kernel:get_state() of
        #{started := no} ->
            %% Longnames `@127.0.0.1` to match the peer's host (see
            %% start_peer/0). A shortnames controller plus a `@127.0.0.1`
            %% peer name is rejected with `nodistribution`. OTP 28 dropped
            %% the legacy list form `net_kernel:start([Name, longnames])`,
            %% so use start/2.
            Name = list_to_atom(
                "bondymst_crash_" ++
                    integer_to_list(os:system_time(microsecond)) ++
                    "@127.0.0.1"
            ),
            {ok, _} = net_kernel:start(Name, #{name_domain => longnames}),
            true = erlang:set_cookie(node(), bondymsttestcookie),
            ok;
        _ ->
            ok
    end.

start_peer() ->
    Name = list_to_atom(
        "bondymst_crash_peer_" ++
            integer_to_list(os:system_time(microsecond))
    ),
    Cookie = atom_to_list(erlang:get_cookie()),
    PeerOpts = #{
        name => Name,
        host => "127.0.0.1",
        connection => standard_io,
        args => ["-setcookie", Cookie, "-pa" | code:get_path()]
    },
    peer:start_link(PeerOpts).

setup_peer(Node) ->
    %% `telemetry` is started explicitly because the bondy_mst put path
    %% emits events; without it the peer logs
    %% "Failed to lookup telemetry handlers" warnings. Wait for the
    %% backing ETS table to exist before returning so subsequent puts
    %% don't race the supervisor.
    {ok, _} = erpc:call(Node, application, ensure_all_started, [telemetry]),
    {ok, _} = erpc:call(Node, application, ensure_all_started, [bondy_mst]),
    ok = wait_for_telemetry_table(Node, 50),
    {Mod, Bin, File} = code:get_object_code(?MODULE),
    {module, Mod} = erpc:call(Node, code, load_binary, [Mod, File, Bin]),
    ok.

wait_for_telemetry_table(_Node, 0) ->
    %% Cosmetic only — proceed even if the table never showed up.
    ok;
wait_for_telemetry_table(Node, N) ->
    case erpc:call(Node, ets, whereis, [telemetry_handler_table]) of
        undefined ->
            timer:sleep(20),
            wait_for_telemetry_table(Node, N - 1);
        _Tid ->
            ok
    end.

peer_os_pid(Node) ->
    list_to_integer(erpc:call(Node, os, getpid, [])).

await_peer_exit(Peer, TimeoutMs) ->
    receive
        {'EXIT', Peer, _Reason} -> ok
    after TimeoutMs ->
        %% Belt-and-braces: peer:stop will reap any zombie state.
        catch peer:stop(Peer),
        ok
    end.

%% =============================================================================
%% Misc helpers
%% =============================================================================

mk_tmp_dir() ->
    Base = filename:join(
        [
            "/tmp",
            io_lib:format(
                "bondy_mst_pack_crash_injection_~p_~p",
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

mk_inst_id() ->
    iolist_to_binary(
        io_lib:format("crash-inj-~p", [erlang:unique_integer([positive])])
    ).

sha256(Bin) ->
    crypto:hash(sha256, Bin).

mk_pages(KVs) ->
    [bondy_mst_page:new(0, undefined, [{K, V, undefined}]) || {K, V} <- KVs].

on_disk_root(Dir) ->
    {ok, M} = bondy_mst_pack_manifest:read(Dir),
    bondy_mst_pack_manifest:current_root(M).
