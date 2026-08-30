%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_listener_api_SUITE).

-moduledoc """
The `bondy.listener.*` WAMP surface.

Everything is driven through `bondy_wamp_api:handle_call/3`, the same entry point
the dealer uses, so the dispatcher's prefix chain is exercised rather than
assumed.

The case that matters is `suspending_normal_refuses_new_connections`: the other
cases check that a bad argument is refused, and only that one establishes that
the procedure does the thing its name claims. It binds nothing of its own — it
suspends the phase the running node's own client listeners are in, connects a
real socket before and after, and restores the node in an `after` block whatever
happens, because a suite that leaves `normal` suspended breaks every suite that
runs after it in the same VM.

**What is NOT covered.** The `early` phase is never suspended here. It carries
`/ping`, `/ready` and `/metrics`, and suspending it inside a CT run would make
the node look dead to anything watching those. That the phase argument reaches
`bondy_listener_manager:suspend/1` unchanged is covered by `all` and `normal`;
that `early` selects the early listeners is `in_phase/1`'s behaviour, which
`bondy_listener_SUITE:drain_spares_the_early_phase` covers directly.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_uris.hrl").
-include("bondy.hrl").

-compile([export_all, nowarn_export_all]).

-define(REALM, ~"com.listener.api.test").

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        %% Dispatch
        unknown_listener_procedure_is_reported,
        %% Arguments
        suspend_rejects_an_unknown_phase,
        resume_rejects_an_unknown_phase,
        suspend_rejects_a_non_binary_phase,
        too_many_arguments_is_reported,
        no_arguments_is_refused_rather_than_defaulted,
        %% Authorization
        a_non_master_realm_is_refused,
        %% Effect
        suspending_normal_refuses_new_connections,
        resume_is_idempotent
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    _ = bondy_realm:create(?REALM),
    ok = bondy_realm:disable_security(bondy_realm:fetch(?REALM)),
    [
        %% The master realm is the DEFAULT context here, not the exception:
        %% whether this node accepts connections is not a per-realm decision, so
        %% every case but `a_non_master_realm_is_refused` calls as an operator.
        {ctxt, bondy_context:local_context(?MASTER_REALM_URI)},
        {realm_ctxt, bondy_context:local_context(?REALM)}
        | Config
    ].

end_per_suite(_Config) ->
    %% Defensive: no case is supposed to leave a phase suspended, and each
    %% restores its own, but a listener left unable to accept would surface as an
    %% unrelated failure in whatever suite ran next.
    ok = bondy_listener_manager:resume(all),
    ok.

%% =============================================================================
%% DISPATCH
%% =============================================================================

unknown_listener_procedure_is_reported(Config) ->
    E = call_error(~"bondy.listener.does_not_exist", [], Config),
    ?assertEqual(?WAMP_NO_SUCH_PROCEDURE, E#error.error_uri).

%% =============================================================================
%% ARGUMENTS
%% =============================================================================

-doc """
A phase this node has no concept of is refused and NAMED.

`bondy_listener_manager:in_phase/1` answers `[]` for an unrecognised phase, so
without this the procedure would report success having suspended nothing — the
worst of the three possible outcomes, since the operator would believe the node
was out of rotation.
""".
suspend_rejects_an_unknown_phase(Config) ->
    E = call_error(?BONDY_LISTENER_SUSPEND, [~"bogus"], Config),
    ?assertEqual(?WAMP_INVALID_ARGUMENT, E#error.error_uri).

resume_rejects_an_unknown_phase(Config) ->
    E = call_error(?BONDY_LISTENER_RESUME, [~"bogus"], Config),
    ?assertEqual(?WAMP_INVALID_ARGUMENT, E#error.error_uri).

-doc """
A non-binary argument is refused the same way, not by raising.

The decode is `binary_to_existing_atom/1`-free for this reason: an integer or a
map reaching it would raise `badarg` inside the dealer's call, which reports as
an internal error rather than as the caller's mistake that it is.
""".
suspend_rejects_a_non_binary_phase(Config) ->
    E = call_error(?BONDY_LISTENER_SUSPEND, [42], Config),
    ?assertEqual(?WAMP_INVALID_ARGUMENT, E#error.error_uri).

too_many_arguments_is_reported(Config) ->
    E = call_error(?BONDY_LISTENER_SUSPEND, [~"normal", extra], Config),
    ?assertEqual(?WAMP_INVALID_ARGUMENT, E#error.error_uri).

-doc """
A call with no arguments is refused on ARITY.

It did not used to be. `bondy_wamp_api_utils:validate_admin_call_args/3` reads
the first positional argument as a realm URI and SUBSTITUTES the caller's realm
when it is missing, so a no-argument call reached `phase/1` carrying
`com.leapsight.bondy` and was refused only because `phase/1` is total. The
procedure now uses `admin_call_args/3`, which checks the count and nothing
else, so the refusal names the real fault. Both refusals report
`?WAMP_INVALID_ARGUMENT`, which is why this assertion did not change and why
the comment had to.
""".
no_arguments_is_refused_rather_than_defaulted(Config) ->
    E = call_error(?BONDY_LISTENER_SUSPEND, [], Config),
    ?assertEqual(?WAMP_INVALID_ARGUMENT, E#error.error_uri).

%% =============================================================================
%% AUTHORIZATION
%% =============================================================================

-doc """
A caller in an ordinary realm cannot suspend the node's listeners.

Load-bearing, and it is why the module uses
`bondy_wamp_api_utils:admin_call_args/3`. The realm-first validators read the
first positional argument as a realm URI, and the non-admin one lets a caller
through when its OWN realm URI equals that argument — so under
`validate_call_args/3` a realm named `com.example.normal` could have suspended
every listener on the node, the phase argument occupying the realm-URI slot
being what made that reachable. `admin_call_args/3` removes the coincidence
rather than relying on the phase never colliding with a realm name.
""".
a_non_master_realm_is_refused(Config) ->
    Ctxt = ?config(realm_ctxt, Config),
    E =
        try handle(?BONDY_LISTENER_SUSPEND, [~"normal"], Ctxt) of
            {reply, #error{} = Err} -> Err;
            Other -> ct:fail({expected_error, Other})
        catch
            error:#error{} = Err -> Err
        end,
    ?assertEqual(?WAMP_NOT_AUTHORIZED, E#error.error_uri),

    %% And it did not take effect anyway: the listener still accepts.
    Port = ranch:get_port(a_normal_phase_tcp_listener()),
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary], 5000),
    ok = gen_tcp:close(Sock).

%% =============================================================================
%% EFFECT
%% =============================================================================

-doc """
Suspend closes the listen socket, resume reopens it, and a connection
established in between is untouched.

The established connection is the half that makes this a drain rather than a
stop: an operator taking a node out of rotation needs the in-flight work to
finish. `bondy_listener_manager:stop/1` is the other operation and this must not
behave like it.
""".
suspending_normal_refuses_new_connections(Config) ->
    Name = a_normal_phase_tcp_listener(),
    Port = ranch:get_port(Name),

    %% Accepting to begin with, so a later `econnrefused` means the suspend did
    %% it rather than the listener never having been up.
    {ok, Before} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary], 5000),

    try
        {ok, #result{}} = call_ok(?BONDY_LISTENER_SUSPEND, [~"normal"], Config),

        ?assertEqual(
            {error, econnrefused},
            gen_tcp:connect({127, 0, 0, 1}, Port, [binary], 5000)
        ),

        %% The established connection is still there. Asserted by USING it —
        %% `inet:port/1` on a closed socket answers `{error, einval}`, so this
        %% distinguishes "still open" from "closed but not yet reaped".
        ?assertMatch({ok, _}, inet:peername(Before)),

        {ok, #result{}} = call_ok(?BONDY_LISTENER_RESUME, [~"normal"], Config),

        {ok, After} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary], 5000),
        ok = gen_tcp:close(After)
    after
        ok = gen_tcp:close(Before),
        ok = bondy_listener_manager:resume(normal)
    end.

-doc """
Resuming a phase that is already accepting is not an error.

`ranch:resume_listener/1` on a running listener answers `ok`, so an operator
retrying a resume — the obvious thing to do after a failed suspend — does not
get an error telling them something is wrong when nothing is.
""".
resume_is_idempotent(Config) ->
    {ok, #result{}} = call_ok(?BONDY_LISTENER_RESUME, [~"normal"], Config),
    {ok, #result{}} = call_ok(?BONDY_LISTENER_RESUME, [~"normal"], Config).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Discovered rather than hardcoded: this suite asserts on the API, not on
%% `bondy_ct`'s inventory, and a port written here would go stale silently the
%% next time that inventory changes.
a_normal_phase_tcp_listener() ->
    Candidates = [
        Name
     || #{name := Name, start_phase := normal, bind := {port, _}} <-
            bondy_listener_manager:listeners()
    ],
    case Candidates of
        [Name | _] -> Name;
        [] -> ct:fail(no_normal_phase_tcp_listener)
    end.

%% @private
%% Through the dispatcher rather than straight to `bondy_listener_wamp_api`, so
%% the prefix clause in `bondy_wamp_api` is covered by every case here.
handle(Proc, Args, Ctxt) ->
    M = bondy_wamp_message:call(1, #{}, Proc, Args),
    bondy_wamp_api:handle_call(M, Ctxt).

%% @private
call_ok(Proc, Args, Config) ->
    case handle(Proc, Args, ?config(ctxt, Config)) of
        {reply, #result{} = R} -> {ok, R};
        Other -> ct:fail({expected_result, Other})
    end.

%% @private
%% An arity or authorization failure is thrown rather than returned, because
%% `bondy_wamp_api_utils` reports those by raising. Both shapes are accepted so
%% a case does not have to know which one its procedure produces.
call_error(Proc, Args, Config) ->
    Ctxt = ?config(ctxt, Config),
    try handle(Proc, Args, Ctxt) of
        {reply, #error{} = E} -> E;
        Other -> ct:fail({expected_error, Other})
    catch
        error:#error{} = E -> E
    end.
