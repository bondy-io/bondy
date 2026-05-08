%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rpc_gateway_callee_lifecycle_SUITE).

-moduledoc """
Validates the integration between `bondy_rpc_gateway_callee` and bondy's
session/registry infrastructure.

Exercises the lifecycle invariant that callees open a WAMP session via
`bondy_session_manager:open/3` so the session manager monitors the callee
process and triggers registry cleanup on exit. Without this, a restarted
callee would collide with its previous incarnation's orphan registrations
and silently fail to register procedures.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM_URI, <<"com.example.test.callee_lifecycle">>).
-define(WAIT_MS, 5_000).


all() ->
    [
        callee_opens_session,
        callee_registers_procedure,
        callee_death_cleans_registry,
        callee_restart_can_re_register,
        session_open_failure_stops_callee
    ].


init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    ok = ensure_realm(?REALM_URI),
    [{realm_uri, ?REALM_URI} | Config].


end_per_suite(Config) ->
    {save_config, Config}.



%% =============================================================================
%% TEST CASES
%% =============================================================================



callee_opens_session(Config) ->
    RealmUri = ?config(realm_uri, Config),
    ProcUri = <<"com.example.test.proc.opens_session">>,
    Pid = start_callee(RealmUri, ProcUri),
    SessionId = session_id_for_proc(RealmUri, ProcUri),
    ?assertMatch({ok, _}, bondy_session:lookup(SessionId)),
    stop_callee(Pid).


callee_registers_procedure(Config) ->
    RealmUri = ?config(realm_uri, Config),
    ProcUri = <<"com.example.test.proc.registers">>,
    Pid = start_callee(RealmUri, ProcUri),
    Entries = bondy_registry:match(registration, RealmUri, ProcUri),
    ?assertMatch([_ | _], Entries),
    stop_callee(Pid).


callee_death_cleans_registry(Config) ->
    RealmUri = ?config(realm_uri, Config),
    ProcUri = <<"com.example.test.proc.death_cleans">>,
    Pid = start_callee(RealmUri, ProcUri),
    SessionId = session_id_for_proc(RealmUri, ProcUri),
    ?assertMatch({ok, _}, bondy_session:lookup(SessionId)),
    ?assertMatch(
        [_ | _], bondy_registry:match(registration, RealmUri, ProcUri)
    ),

    ok = kill_and_wait(Pid),

    %% session_manager's DOWN handler is async; poll until it fires the
    %% bondy_router:flush → bondy_dealer:flush → registry remove_all chain.
    %% NOTE: the DOWN handler does NOT call bondy_session:close/2 — that
    %% is only invoked from the explicit close cast path. The session ETS
    %% entry therefore lingers after a brutal exit; what matters for the
    %% orphan-registration concern is registry cleanup, which IS done.
    ok = wait_until(
        fun() ->
            bondy_registry:match(registration, RealmUri, ProcUri) =:= []
        end,
        ?WAIT_MS,
        "registration was not cleaned after callee death"
    ).


callee_restart_can_re_register(Config) ->
    RealmUri = ?config(realm_uri, Config),
    ProcUri = <<"com.example.test.proc.restart">>,

    Pid1 = start_callee(RealmUri, ProcUri),
    SessionId1 = session_id_for_proc(RealmUri, ProcUri),

    ok = kill_and_wait(Pid1),
    ok = wait_until(
        fun() ->
            bondy_registry:match(registration, RealmUri, ProcUri) =:= []
        end,
        ?WAIT_MS,
        "registration was not cleaned after callee death"
    ),

    %% New callee with same realm/procedure must register cleanly. If the
    %% old session's orphan registration had survived, this would receive
    %% {error, already_exists} from the dealer and the new SessionId would
    %% have NO entries.
    Pid2 = start_callee(RealmUri, ProcUri),
    SessionId2 = session_id_for_proc(RealmUri, ProcUri),
    ?assertNotEqual(SessionId1, SessionId2),
    ?assertMatch(
        [_ | _], bondy_registry:match(registration, RealmUri, ProcUri)
    ),
    stop_callee(Pid2).


session_open_failure_stops_callee(_Config) ->
    %% A non-existent realm makes bondy_session:new/3 raise inside
    %% bondy_session_manager:open/3. The callee init catches it and stops
    %% with {shutdown, {session_open_failed, _}} — clean stop, no restart
    %% under transient supervision.
    BadRealm = <<"com.example.does.not.exist.callee_lifecycle">>,
    process_flag(trap_exit, true),
    Result = bondy_rpc_gateway_callee:start_link(
        BadRealm, make_service(BadRealm, <<"com.example.bad.proc">>), test_pool
    ),
    ?assertMatch({error, {shutdown, {session_open_failed, _}}}, Result),
    %% Drain any propagated EXIT for cleanliness
    receive {'EXIT', _, _} -> ok after 100 -> ok end.



%% =============================================================================
%% HELPERS
%% =============================================================================



ensure_realm(RealmUri) ->
    case bondy_realm:lookup(RealmUri) of
        {error, not_found} ->
            _ = bondy_realm:create(#{
                uri => RealmUri,
                description => <<"Test realm for RPC gateway callee">>,
                security_enabled => false
            }),
            ok;

        {ok, _} ->
            ok
    end.


make_service(RealmUri, ProcUri) ->
    #{
        name => <<"test_service">>,
        base_url => <<"http://localhost:9999">>,
        auth_mod => bondy_rpc_gateway_auth_generic,
        auth_conf => #{},
        procedures => #{
            <<"proc1">> => #{
                uri => ProcUri,
                realm => RealmUri,
                method => get,
                path => <<"/test">>
            }
        }
    }.


start_callee(RealmUri, ProcUri) ->
    Service = make_service(RealmUri, ProcUri),
    {ok, Pid} = bondy_rpc_gateway_callee:start_link(
        RealmUri, Service, test_pool
    ),
    %% Unlink so that subsequent kills don't propagate to the test process,
    %% and so that a clean shutdown of the callee in stop_callee/1 doesn't
    %% take us down with it.
    true = unlink(Pid),
    %% Procedure registration happens in handle_continue; wait until the
    %% registry sees it before returning so callers can read it.
    ok = wait_until(
        fun() ->
            bondy_registry:match(registration, RealmUri, ProcUri) =/= []
        end,
        ?WAIT_MS,
        "callee did not register procedure"
    ),
    Pid.


stop_callee(Pid) when is_pid(Pid) ->
    kill_and_wait(Pid).


kill_and_wait(Pid) ->
    MonRef = monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', MonRef, process, _, _} -> ok
    after ?WAIT_MS ->
        ct:fail({timeout_waiting_for_exit, Pid})
    end.


session_id_for_proc(RealmUri, ProcUri) ->
    case bondy_registry:match(registration, RealmUri, ProcUri) of
        [Entry | _] ->
            bondy_registry_entry:session_id(Entry);
        [] ->
            ct:fail({no_registration, ProcUri})
    end.


wait_until(Pred, Deadline, Msg) when Deadline =< 0 ->
    ct:fail({timeout, Msg, Pred});

wait_until(Pred, Deadline, Msg) ->
    case Pred() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_until(Pred, Deadline - 50, Msg)
    end.
