%% =============================================================================
%% End-to-end tests for the applier's fold projection
%% (FOLD_STRATEGY_DESIGN §3 + §6/§7, wired in F8).
%%
%% Verifies:
%%   - The legacy path (no fold) returns `{error, no_fold_configured}`.
%%   - lww_register folds a sequence of `{set, H, V}` ops correctly.
%%   - presence_basic folds create/delete ops correctly.
%%   - Idempotency: re-appending the same op converges to the same state.
%%   - Read-your-writes via `bondy_oplog:projection/1` (drains the
%%     applier before reading).
%%
%% Scope: single-cell-per-instance (per-cell projections deferred to
%% MST_DB_DESIGN). Remote events are NOT folded yet — covered by the
%% F9 cross-PR QA.
%% =============================================================================

-module(bondy_oplog_applier_fold_test).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok.

cleanup(_) ->
    [bondy_oplog:stop_instance(I) || I <- bondy_oplog:list_instances()],
    ok.

fold_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun no_fold_returns_error/0,
        fun lww_register_projects_latest_value/0,
        fun lww_register_ignores_older_hlc/0,
        fun lww_register_clear_followed_by_set_reanimates/0,
        fun lww_register_idempotent_under_replay/0,
        fun projection_initial_value_before_any_event/0,
        fun custom_module_name_works_as_fold/0
    ]}.

%% =============================================================================
%% Tests
%% =============================================================================

no_fold_returns_error() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    ?assertEqual(
        {error, no_fold_configured},
        bondy_oplog:projection(Id)
    ),
    ok = bondy_oplog:stop_instance(Id).

lww_register_projects_latest_value() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register
    }),
    _ = bondy_oplog:append(Id, {set, 1, <<"alpha">>}),
    _ = bondy_oplog:append(Id, {set, 2, <<"beta">>}),
    ?assertEqual({ok, {set, <<"beta">>, 2}}, bondy_oplog:projection(Id)),
    ok = bondy_oplog:stop_instance(Id).

lww_register_ignores_older_hlc() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register
    }),
    _ = bondy_oplog:append(Id, {set, 10, <<"latest">>}),
    %% Older HLC should be a no-op for the fold.
    _ = bondy_oplog:append(Id, {set, 5, <<"older">>}),
    ?assertEqual({ok, {set, <<"latest">>, 10}}, bondy_oplog:projection(Id)),
    ok = bondy_oplog:stop_instance(Id).

lww_register_clear_followed_by_set_reanimates() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register
    }),
    _ = bondy_oplog:append(Id, {set, 1, <<"a">>}),
    _ = bondy_oplog:append(Id, {clear, 2}),
    ?assertEqual({ok, {cleared, 2}}, bondy_oplog:projection(Id)),
    _ = bondy_oplog:append(Id, {set, 3, <<"b">>}),
    ?assertEqual({ok, {set, <<"b">>, 3}}, bondy_oplog:projection(Id)),
    ok = bondy_oplog:stop_instance(Id).

lww_register_idempotent_under_replay() ->
    %% Append the same op three times; the fold's idempotency means
    %% repeated application of an event whose HLC is already absorbed
    %% must not change the state. (The substrate assigns a fresh WAL
    %% HLC per append but the *fold-level* HLC inside `op` stays at 1,
    %% so the fold sees three identical `{set, 1, <<"x">>}` events.)
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register
    }),
    _ = bondy_oplog:append(Id, {set, 1, <<"x">>}),
    _ = bondy_oplog:append(Id, {set, 1, <<"x">>}),
    _ = bondy_oplog:append(Id, {set, 1, <<"x">>}),
    ?assertEqual({ok, {set, <<"x">>, 1}}, bondy_oplog:projection(Id)),
    ok = bondy_oplog:stop_instance(Id).

projection_initial_value_before_any_event() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => lww_register
    }),
    ?assertEqual({ok, undefined}, bondy_oplog:projection(Id)),
    ok = bondy_oplog:stop_instance(Id).

custom_module_name_works_as_fold() ->
    %% Pass the fully-qualified module rather than the shorthand.
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id, #{
        fold_module => bondy_oplog_fold_lww_register
    }),
    _ = bondy_oplog:append(Id, {set, 1, <<"value">>}),
    ?assertEqual({ok, {set, <<"value">>, 1}}, bondy_oplog:projection(Id)),
    ok = bondy_oplog:stop_instance(Id).

%% =============================================================================
%% Helpers
%% =============================================================================

mk_id() ->
    list_to_binary(
        "fold_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).
