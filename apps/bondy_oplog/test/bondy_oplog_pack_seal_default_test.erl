%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oplog_pack_seal_default_test).
-moduledoc """
Asserts the durable pack-store seal-threshold default. bondy_oplog overrides
the pack store's own `auto_seal_bytes` default (16 MiB) at the single place it
builds the pack store's open opts (`bondy_oplog_instance:backend_opts/3`), and
the value is operator-tunable via `bondy_oplog_config:pack_auto_seal_bytes/0`.
""".

-include_lib("eunit/include/eunit.hrl").

%% The `db.pack_auto_seal_bytes` schema default, "2MB" as a cuttlefish bytesize.
-define(DEFAULT_BYTES, 2 * 1024 * 1024).

%% =============================================================================
%% CONFIG ACCESSOR
%% =============================================================================

config_default_test() ->
    ok = application:unset_env(bondy_oplog, pack_auto_seal_bytes),
    ?assertEqual(
        ?DEFAULT_BYTES, bondy_oplog_config:pack_auto_seal_bytes()
    ).

config_env_override_test() ->
    ok = application:set_env(bondy_oplog, pack_auto_seal_bytes, 512_000),
    try
        ?assertEqual(512_000, bondy_oplog_config:pack_auto_seal_bytes())
    after
        ok = application:unset_env(bondy_oplog, pack_auto_seal_bytes)
    end.

%% =============================================================================
%% backend_opts/3 WIRING
%% =============================================================================

%% A pack-store instance with no explicit seal threshold inherits the
%% bondy_oplog default rather than the pack store's 16 MiB.
pack_backend_gets_default_test() ->
    ok = application:unset_env(bondy_oplog, pack_auto_seal_bytes),
    Opts = bondy_oplog_instance:backend_opts(
        bondy_mst_pack_store, <<"inst-a">>, #{}
    ),
    ?assertEqual(?DEFAULT_BYTES, maps:get(auto_seal_bytes, Opts)),
    ?assertEqual(<<"inst-a">>, maps:get(instance_id, Opts)).

%% A caller's explicit `backend_options.auto_seal_bytes` always wins.
caller_override_wins_test() ->
    ok = application:unset_env(bondy_oplog, pack_auto_seal_bytes),
    Opts = bondy_oplog_instance:backend_opts(
        bondy_mst_pack_store,
        <<"inst-b">>,
        #{backend_options => #{auto_seal_bytes => 99}}
    ),
    ?assertEqual(99, maps:get(auto_seal_bytes, Opts)).

%% The env override flows through to the instance's pack-store opts.
pack_backend_honours_env_test() ->
    ok = application:set_env(bondy_oplog, pack_auto_seal_bytes, 4_000_000),
    try
        Opts = bondy_oplog_instance:backend_opts(
            bondy_mst_pack_store, <<"inst-c">>, #{}
        ),
        ?assertEqual(4_000_000, maps:get(auto_seal_bytes, Opts))
    after
        ok = application:unset_env(bondy_oplog, pack_auto_seal_bytes)
    end.

%% Non-pack backends are untouched — the seal threshold is meaningless for an
%% in-memory ETS MST and must not appear in its opts.
non_pack_backend_unaffected_test() ->
    Opts = bondy_oplog_instance:backend_opts(ets, <<"inst-d">>, #{}),
    ?assertEqual(error, maps:find(auto_seal_bytes, Opts)).
