%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% EUnit coverage for the registry ptrie CAS-contention telemetry sink in
%% `bondy_prometheus` (`handle_net_event/4`). Each test drives the event
%% through the handler with the shapes `bondy_registry_ptrie:do_write/3`
%% emits and asserts the corresponding `bondy_metrics` counter moved —
%% these counters are the evidence hook for the registry partition-grain
%% decision (`_design/REGISTRY_PARTITION_GRAIN.md`).
-module(bondy_prometheus_ptrie_cas_test).

-include_lib("eunit/include/eunit.hrl").

ptrie_cas_metrics_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"cas_retry and cas_exhausted counters move", fun cas_counters/0},
        {"malformed measurement does not raise", fun malformed/0}
    ]}.

setup() ->
    {ok, _} = application:ensure_all_started(bondy_metrics),
    _ =
        case bondy_metrics:start_link() of
            {ok, _} -> ok;
            {error, {already_started, _}} -> ok
        end,
    %% The sink labels rows with `bondy_config:node()` →
    %% `partisan_config:get(name)`; seed it so a bare eunit run (no
    %% partisan app) resolves the same name the assertions read back.
    _ =
        try
            partisan_config:set(name, node())
        catch
            _:_ -> ok
        end,
    ok.

cleanup(_) ->
    ok.

cas_counters() ->
    L = #{node => bondy_config:node()},
    Retries0 = ctr(bondy_registry_ptrie_cas_retries_total, L),
    Exhausted0 = ctr(bondy_registry_ptrie_cas_exhausted_total, L),
    ok = bondy_prometheus:handle_net_event(
        [bondy, registry, ptrie, cas_retry], #{count => 1}, #{}, undefined
    ),
    ok = bondy_prometheus:handle_net_event(
        [bondy, registry, ptrie, cas_retry], #{count => 1}, #{}, undefined
    ),
    ok = bondy_prometheus:handle_net_event(
        [bondy, registry, ptrie, cas_exhausted], #{count => 1}, #{}, undefined
    ),
    ?assertEqual(
        Retries0 + 2, ctr(bondy_registry_ptrie_cas_retries_total, L)
    ),
    ?assertEqual(
        Exhausted0 + 1, ctr(bondy_registry_ptrie_cas_exhausted_total, L)
    ).

malformed() ->
    %% The sink is total: a bad measurement map must not raise (telemetry
    %% detaches raising handlers permanently).
    ok = bondy_prometheus:handle_net_event(
        [bondy, registry, ptrie, cas_retry], not_a_map, #{}, undefined
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

ctr(Name, Label) ->
    case bondy_metrics:value(#{name => Name, label => Label}) of
        N when is_integer(N) -> N;
        _ -> 0
    end.
