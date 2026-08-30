%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_api_arity_SUITE).

-moduledoc """
The ratchet for `bondy_wamp_api_utils`'s two validator families.

A `bondy.*` procedure whose first positional argument is NOT a realm must
refuse a call that is one argument short. The realm-first validators do the
opposite by design: they COMPLETE such a call with the caller's own realm URI,
so for a procedure taking an id the id silently becomes
`<<"com.leapsight.bondy">>` and the call answers about the wrong thing instead
of erroring. `bondy.realm.create()` with no arguments reached
`bondy_realm:create/1` with the master realm's URI as its specification.

Which family each procedure reached is READ OUT of the compiled abstract code
rather than listed here, so migrating a procedure puts it under this check
automatically and nobody has to remember to add it. The scan is borrowed from
`bondy_task_catalogue_test` rather than written again — two scanners over the
same abstract code drift, and the one that drifts goes quiet instead of
failing.

A Common Test suite rather than eunit because the assertion DISPATCHES: it
needs `bondy_context:local_context/1`, which needs a booted node.

WHAT THIS DOES NOT CHECK: that each procedure is in the RIGHT family. Nothing
in the code says whether a given first argument is meant to be a realm, so the
assignment is a judgement made at the call site. What is checked is that the
assignment has the consequence it claims.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").

-compile([nowarn_export_all, export_all]).

all() ->
    [
        the_scan_read_both_families,
        the_no_realm_set_is_the_declared_one,
        a_short_call_to_a_no_realm_procedure_is_refused
    ].

%% Every `bondy.*` procedure whose first positional argument is NOT a realm,
%% with the number of positional arguments it takes.
%%
%% DECLARED here rather than read from the scan, and that is the whole point.
%% The family a procedure belongs to is read out of its own code, so a
%% procedure moved BACK to a realm-first validator would silently leave a
%% scanned set and stop being checked — the regression would remove its own
%% detector. Compared against the scan below, and used as the input to the
%% short-call case, a move in either direction fails here first.
declared_no_realm() ->
    [
        {~"bondy.alarm.catalogue", 0},
        {~"bondy.alarm.get", 1},
        {~"bondy.alarm.history", 0},
        {~"bondy.alarm.list", 0},
        {~"bondy.backup.create", 1},
        {~"bondy.backup.restore", 1},
        {~"bondy.backup.status", 1},
        {~"bondy.cert_manager.get_client_auth", 1},
        {~"bondy.cert_manager.get_server_cert_info", 1},
        {~"bondy.cert_manager.reload_cacerts", 0},
        {~"bondy.cert_manager.rotate_all", 0},
        {~"bondy.cert_manager.rotate_listener", 1},
        {~"bondy.cert_manager.set_client_auth", 2},
        {~"bondy.cluster.connections", 0},
        {~"bondy.cluster.leave", 1},
        {~"bondy.export.create", 1},
        {~"bondy.export.import", 1},
        {~"bondy.export.status", 1},
        {~"bondy.http_gateway.api.delete", 1},
        {~"bondy.http_gateway.api.get", 1},
        {~"bondy.http_gateway.api.list", 0},
        {~"bondy.http_gateway.api.load", 1},
        {~"bondy.interface.delete", 1},
        {~"bondy.interface.get", 1},
        {~"bondy.interface.list", 0},
        {~"bondy.interface.load", 1},
        {~"bondy.listener.resume", 1},
        {~"bondy.listener.suspend", 1},
        {~"bondy.mcp.overlay.delete", 1},
        {~"bondy.mcp.overlay.get", 1},
        {~"bondy.mcp.overlay.list", 0},
        {~"bondy.mcp.overlay.load", 1},
        {~"bondy.mcp.overlay.suggested", 0},
        {~"bondy.realm.create", 1},
        {~"bondy.router.bridge.add", 1},
        {~"bondy.router.bridge.check_spec", 1},
        {~"bondy.router.bridge.get", 1},
        {~"bondy.router.bridge.list", 0},
        {~"bondy.router.bridge.remove", 1},
        {~"bondy.router.bridge.start", 1},
        {~"bondy.router.bridge.status", 0},
        {~"bondy.router.bridge.stop", 1},
        {~"bondy.task.catalogue", 0},
        {~"bondy.task.describe", 1}
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    [{scan, bondy_task_catalogue_test:scan()} | Config].

end_per_suite(Config) ->
    {save_config, Config}.

%% The vacuity guard, and the two families fail differently: with no `no_realm`
%% entries the check below has nothing to drive, and with no `realm` entries
%% the scan has stopped reading the OTHER family, so the assignment it reports
%% cannot be trusted either.
the_scan_read_both_families(Config) ->
    #{validators := V} = ?config(scan, Config),
    NoRealm = [U || U := no_realm <- V],
    Realm = [U || U := realm <- V],
    ?assert(
        length(NoRealm) >= 25,
        lists:flatten(
            io_lib:format("only ~p no_realm procedures found", [
                length(NoRealm)
            ])
        )
    ),
    ?assert(
        length(Realm) >= 40,
        lists:flatten(
            io_lib:format("only ~p realm procedures found", [length(Realm)])
        )
    ).

%% Moving a procedure between the two families is a judgement about what its
%% first argument means, so it is made once, deliberately, and recorded. This
%% case is what makes the recording mandatory in both directions.
the_no_realm_set_is_the_declared_one(Config) ->
    #{validators := V, arities := Arities} = ?config(scan, Config),
    Scanned = lists:sort([{U, maps:get(U, Arities, 0)} || U := no_realm <- V]),
    Declared = lists:sort(declared_no_realm()),
    ?assertEqual(
        [], Scanned -- Declared, "these procedures are no_realm but undeclared"
    ),
    ?assertEqual(
        [], Declared -- Scanned, "these are declared no_realm but are not"
    ).

%% Driven from the DECLARED list, not the scanned one — see
%% `declared_no_realm/0`.
%%
%% Driven from the MASTER realm, which is the case that goes wrong quietly:
%% from any other realm the short call is refused for a realm mismatch anyway,
%% so a suite that only ever called from a tenant realm would see nothing.
%%
%% The assertion is `did not reply a #result{}` rather than a particular error,
%% because the point is that the call does not ANSWER. A procedure that errors
%% for its own reasons — an id it cannot parse — still satisfies it, and that
%% is honest: what must not happen is a successful reply computed from a realm
%% URI the caller never sent.
a_short_call_to_a_no_realm_procedure_is_refused(_Config) ->
    Ctxt = bondy_context:local_context(?MASTER_REALM_URI),
    Answered = [
        {Uri, called_with, N - 1}
     || {Uri, N} <- declared_no_realm(),
        N >= 1,
        answers(Uri, N - 1, Ctxt)
    ],
    ?assertEqual([], Answered),
    %% Vacuity guard: a declaration reduced to the zero-argument procedures
    %% would leave nothing to drive.
    ?assert(length([x || {_, N} <- declared_no_realm(), N >= 1]) >= 20).

%% @private
%% Through `bondy_wamp_api:handle_call/2`, so the dispatch clause under test is
%% the one that actually serves the URI. `undefined` arguments are enough: no
%% procedure here should reach its own argument decoding, and one that does and
%% crashes is still not answering.
answers(Uri, N, Ctxt) ->
    Args = lists:duplicate(N, undefined),
    M = bondy_wamp_message:call(1, #{}, Uri, Args),
    try bondy_wamp_api:handle_call(M, Ctxt) of
        {reply, #result{}} -> true;
        _ -> false
    catch
        _:_ -> false
    end.
