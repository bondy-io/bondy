%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_listener_wamp_api).
-moduledoc """
`bondy_wamp_api` implementation exposing listener suspend and resume as WAMP
procedures, so a node can be taken out of rotation and put back without
restarting it or editing its configuration.

Suspending stops a listener accepting new connections and leaves established
ones alone, which is what makes this a drain rather than a stop: use
`bondy.listener.suspend`, wait for the sessions to finish, and the node has left
rotation without dropping work. Nothing here stops a listener — that is
`bondy_app`'s shutdown path.

Both procedures take a PHASE rather than a listener name, because that is the
grain `bondy_listener_manager` suspends at and the grain the distinction matters
at: `early` carries `/ping`, `/ready` and `/metrics`. Suspending `all` therefore
takes liveness and readiness down with everything else, and an orchestrator
watching those will read the node as dead and hard-kill it. It is accepted
because an operator may legitimately want it, and logged for the same reason.
""".
-behaviour(bondy_wamp_api).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_uris.hrl").

-export([handle_call/3]).

%% =============================================================================
%% API
%% =============================================================================

-spec handle_call(
    Proc :: uri(), M :: bondy_wamp_message:call(), Ctxt :: bondy_context:t()
) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined
    )}
    | {reply, wamp_result() | wamp_error()}.

handle_call(?BONDY_LISTENER_SUSPEND, #call{} = M, Ctxt) ->
    apply_to_phase(M, Ctxt, suspend);
handle_call(?BONDY_LISTENER_RESUME, #call{} = M, Ctxt) ->
    apply_to_phase(M, Ctxt, resume);
handle_call(_, #call{} = M, _) ->
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% The two procedures differ only in which manager function runs, so the argument
%% decoding, the error reply and the log record are shared rather than written
%% twice.
apply_to_phase(#call{} = M, Ctxt, Op) ->
    %% `validate_admin_call_args/3`, not `validate_call_args/3`: both read the
    %% first positional argument as a realm URI and both let a master-realm
    %% caller through with the arguments untouched, but the non-admin one ALSO
    %% admits a caller whose own realm URI equals that argument. Whether this
    %% node accepts connections is not a per-realm decision, so the master realm
    %% is the only place it can be made.
    [Arg] = bondy_wamp_api_utils:validate_admin_call_args(M, Ctxt, 1),
    case phase(Arg) of
        error ->
            {reply, invalid_phase_error(M, Arg)};
        Phase ->
            ok = bondy_listener_manager:Op(Phase),
            %% An operator changing whether this node accepts connections leaves
            %% no other trace: the manager does not log, and a suspended
            %% listener looks identical to one that was never started.
            ?LOG_NOTICE(#{
                description =>
                    "Listener phase suspended or resumed through the admin API",
                operation => Op,
                phase => Phase
            }),
            {reply, bondy_wamp_message:result(M#call.request_id, #{}, [])}
    end.

%% @private
%% Total, and the only binary-to-phase decode there is.
%%
%% NOT `binary_to_existing_atom/1`, which the neighbouring API modules use for a
%% listener name: it raises `badarg` for a name no atom table entry matches, and a
%% raise here reports to the caller as an internal error rather than as the bad
%% argument it is. It would also admit any atom that happens to exist in the VM —
%% `listeners`, say — which `bondy_listener_manager:in_phase/1` then answers with
%% the empty list, reporting success for having suspended nothing.
%%
%% These three names are the members of `bondy_listener_manager:phase()`. Erlang
%% cannot derive one from the other, so a phase added there has to be added here.
phase(~"early") -> early;
phase(~"normal") -> normal;
phase(~"all") -> all;
phase(_) -> error.

%% @private
invalid_phase_error(#call{} = M, Value) ->
    Error = bondy_error:new(invalid_argument, #{
        message => ~"Unknown listener phase.",
        description =>
            ~"The phase must be one of \"early\", \"normal\" or \"all\".",
        details => #{phase => Value}
    }),
    bondy_wamp_api_utils:error(Error, M).
