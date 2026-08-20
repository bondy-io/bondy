%% =============================================================================
%% Regression test for the `bondy_mst_ets_store` ETS access mode.
%%
%% The store advertises `concurrent_writes => true` via its
%% `capabilities/1` callback. That capability is read by
%% `bondy_oplog_sync_session:merge_pages/2`, which short-circuits the
%% gen_server hop and `ets:insert/2`s pages directly from the sync
%% session process. If the underlying ETS table were `protected`
%% instead of `public`, the insert would fail with
%% `{badarg, [{error_info, #{cause => access}}]}` and the sync session
%% would error out before `integrate_peer_root` could run — peer
%% events would never reach the local MST and `bondy_db:read/3` would
%% see only events authored locally.
%%
%% This test asserts the contract directly: open the store, hand its
%% table to a *non-owner* process, and verify the insert succeeds.
%% That is the same access pattern the sync session uses.
%% =============================================================================

-module(bondy_mst_ets_store_concurrent_writes_test).

-include_lib("eunit/include/eunit.hrl").

%% Helpers below construct real `bondy_mst_page` values; the store's
%% `put/2` validates input and rejects bare atoms.
mk_page(Level, Low, List) ->
    bondy_mst_page:new(Level, Low, List).

capabilities_advertises_concurrent_writes_test() ->
    %% If a future refactor accidentally turns off `concurrent_writes`
    %% (or makes it conditional on `persistent`), the sync session's
    %% short-circuit silently disables — and we lose the perf
    %% optimisation. This is the canary for that.
    Store = bondy_mst_ets_store:open(
        sha256,
        [{name, <<"capabilities_test">>}]
    ),
    Caps = bondy_mst_ets_store:capabilities(Store),
    ?assertEqual(true, maps:get(concurrent_writes, Caps, false)),
    ok = bondy_mst_ets_store:destroy(Store).

non_owner_can_insert_into_store_tab_test() ->
    %% The substrate fix that landed for the Jepsen OR-set work made
    %% the store's ETS table `public` unconditionally so the sync
    %% session (running in a different process) could insert pages.
    %% Revert that and this test fails with `badarg cause => access`.
    Store = bondy_mst_ets_store:open(
        sha256,
        [{name, <<"non_owner_test">>}]
    ),
    Page = mk_page(0, undefined, [{<<"k">>, <<"v">>, undefined}]),
    Self = self(),
    Pid = spawn_link(
        fun() ->
            %% Run the insert from a process that did NOT open the
            %% table. Under `protected` ETS this raises `badarg`; under
            %% `public` it succeeds. We forward the outcome back to
            %% the parent.
            Outcome =
                try
                    {_Hash, _T} = bondy_mst_ets_store:put(Store, Page),
                    ok
                catch
                    error:badarg ->
                        {error, badarg};
                    Class:Reason ->
                        {error, {Class, Reason}}
                end,
            Self ! {outcome, Outcome}
        end
    ),
    Outcome =
        receive
            {outcome, O} -> O
        after 1_000 ->
            timeout
        end,
    %% Wait for the worker to exit cleanly so the link teardown is
    %% deterministic.
    _ =
        try
            unlink(Pid)
        catch
            _:_ -> ok
        end,
    _ =
        try
            exit(Pid, kill)
        catch
            _:_ -> ok
        end,
    ok = bondy_mst_ets_store:destroy(Store),
    ?assertEqual(ok, Outcome).

concurrent_writers_do_not_interfere_test() ->
    %% Two non-owner processes putting different pages must both
    %% succeed. `public` ETS allows this; `protected` would deny both.
    Store = bondy_mst_ets_store:open(
        sha256,
        [{name, <<"concurrent_writers_test">>}]
    ),
    Self = self(),
    %% Two distinct sentinels so the hashes differ and both writes
    %% leave a row behind.
    PageA = mk_page(0, undefined, [{<<"a">>, <<"va">>, undefined}]),
    PageB = mk_page(0, undefined, [{<<"b">>, <<"vb">>, undefined}]),
    Workers = [
        spawn_writer(Self, Store, PageA),
        spawn_writer(Self, Store, PageB)
    ],
    Results = [
        receive
            {outcome, Pid, R} -> R
        after 1_000 -> timeout
        end
     || Pid <- Workers
    ],
    ok = bondy_mst_ets_store:destroy(Store),
    ?assertEqual([ok, ok], Results).

%% =============================================================================
%% Helpers
%% =============================================================================

spawn_writer(Parent, Store, Page) ->
    spawn(
        fun() ->
            Outcome =
                try
                    {_Hash, _T} = bondy_mst_ets_store:put(Store, Page),
                    ok
                catch
                    Class:Reason -> {error, {Class, Reason}}
                end,
            Parent ! {outcome, self(), Outcome}
        end
    ).
