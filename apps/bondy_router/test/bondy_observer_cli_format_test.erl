%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Regression tests for the observer_cli plugin API contract.
%%
%% observer_cli's plugin behaviour (v6+) requires MAP-shaped callback returns:
%% `sheet_header/0` → `#{columns, default_sort}`, `sheet_body/1` and
%% `attributes/1` → `#{rows, state}`. A legacy list header or `{Rows, State}`
%% tuple crashes plugin init with `{plugin_api_error, ...}` (the failure this
%% guards against). These run each Bondy plugin's callbacks — and the launcher's
%% plugin config — through observer_cli's OWN compat normalizers, i.e. the exact
%% validation `observer_cli:start_plugin/0` performs, so a regression to the
%% legacy shape fails here rather than at a live console.
-module(bondy_observer_cli_format_test).

-include_lib("eunit/include/eunit.hrl").

-define(PLUGINS, [bondy_observer_cli_cluster, bondy_observer_cli_sync]).

sheet_header_is_columns_map_test_() ->
    [
        {atom_to_list(M), fun() ->
            #{columns := Cols, default_sort := Sort} =
                observer_cli_plugin_compat:normalize_sheet_header(
                    M:sheet_header()
                ),
            Ids = [Id || #{id := Id} <- Cols],
            ?assert(is_list(Cols) andalso Cols =/= []),
            ?assert(lists:member(Sort, Ids))
        end}
     || M <- ?PLUGINS
    ].

sheet_body_is_rows_state_map_test_() ->
    [
        {atom_to_list(M), fun() ->
            ?assertMatch(
                #{rows := _, state := my_state},
                observer_cli_plugin_compat:normalize_sheet_body(
                    M:sheet_body(my_state)
                )
            )
        end}
     || M <- ?PLUGINS
    ].

attributes_is_rows_state_map_test_() ->
    [
        {atom_to_list(M), fun() ->
            ?assertMatch(
                #{rows := _, state := my_state},
                observer_cli_plugin_compat:normalize_attributes(
                    M:attributes(my_state)
                )
            )
        end}
     || M <- ?PLUGINS
    ].

%% The full config migration observer_cli runs at plugin init: each launcher
%% plugin spec + its header must migrate without a plugin_api_error (the sort
%% field must reference a real column id).
launcher_plugin_config_migrates_test() ->
    _ = [
        begin
            #{module := Module} = Spec,
            _ = observer_cli_plugin_compat:migrate_config(
                Spec, Module:sheet_header()
            )
        end
     || Spec <- bondy_observer_cli:plugins()
    ],
    ok.
