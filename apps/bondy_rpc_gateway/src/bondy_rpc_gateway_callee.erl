%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rpc_gateway_callee).

-moduledoc """
A WAMP Callee that registers procedures for a single service/realm pair.

Spawned by `bondy_rpc_gateway_callee_sup` (one instance per service per
realm). On startup, obtains a session ID, reads the service configuration,
and registers each procedure with the Dealer via
`bondy_dealer:register/4` using an internal callback reference pointing
to `bondy_rpc_gateway_callee_handler:handle_wamp_call`.

## Registration

Each procedure is registered with:

```erlang
MF = {bondy_rpc_gateway_callee_handler, handle_wamp_call},
Ref = bondy_ref:new(internal, MF, SessionId),
Opts = #{match => ~"exact", callback_args => [FullProcConf]},
bondy_dealer:register(ProcUri, Opts, RealmUri, Ref).
```

A registration that fails is logged and skipped — the callee continues
with the remaining procedures rather than crashing. Crashing here would
cascade through `rest_for_one` under any transient failure (e.g. realm
not yet up), and the failure modes that matter (missing realm, duplicate
URI, bad config) are permanent: a retry would not help them.

## Cleanup

The callee opens a WAMP session via `bondy_session_manager:open/3` in
`init/1`, which sets up a process monitor on the callee. When the callee
exits (for any reason — crash, supervisor shutdown, rest_for_one cascade)
the session manager's `'DOWN'` handler fires
`bondy_router:flush(RealmUri, SessionRef)`, which in turn calls
`bondy_dealer:flush/2` and `bondy_registry:remove_all/5` keyed by
`SessionId`. All registrations carrying this callee's `SessionId` —
including the WAMP-level user procedures we register here — are removed.

This is what allows the callee to be safely restarted by the supervisor:
the new incarnation mints a fresh `SessionId` and re-registers the same
URIs without colliding with stale entries from the prior incarnation.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_rpc_gateway.hrl").

-record(state, {
    service             ::  map(),
    realm_uri           ::  uri(),
    session_id          ::  binary() | undefined,
    poolname            ::  atom(),
    registrations       ::  #{
        binary() => {term(), binary(), #rpc_gateway_proc_conf{}}
    }
}).


-export([start_link/3]).

%% gen_server callbacks
-export([init/1]).
-export([handle_continue/2]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).




%% ===================================================================
%% Public API
%% ===================================================================

-doc "Start a callee for the given realm, service, and HTTP pool.".
-spec start_link(uri(), map(), atom()) -> {ok, pid()} | {error, term()}.

start_link(RealmUri, Service, PoolName) ->
    Args = [RealmUri, Service, PoolName],
    gen_server:start_link(?MODULE, Args, []).


%% ===================================================================
%% gen_server callbacks
%% ===================================================================

-doc false.
init([RealmUri, Service, PoolName]) ->
    SessionId = bondy_session_id:new(),
    ServiceName = maps:get(name, Service),
    %% Open a WAMP session so that bondy_session_manager monitors this
    %% process and triggers registry cleanup on exit. Without this, a
    %% restarted callee would collide with its previous incarnation's
    %% orphan registrations and silently fail to register procedures.
    SessionOpts = #{
        type => internal,
        roles => #{callee => #{}},
        agent => <<"bondy_rpc_gateway_callee">>,
        is_anonymous => true
    },
    try bondy_session_manager:open(SessionId, RealmUri, SessionOpts) of
        {ok, _Session} ->
            State = #state{
                realm_uri = RealmUri,
                service = Service,
                session_id = SessionId,
                poolname = PoolName,
                registrations = #{}
            },
            {ok, State, {continue, register_procedures}};
        {error, Reason} ->
            ?LOG_ERROR(#{
                description =>
                    "Failed to open WAMP session for RPC gateway callee. "
                    "Procedures for this service/realm will not be "
                    "registered.",
                realm => RealmUri,
                service => ServiceName,
                reason => Reason
            }),
            {stop, {shutdown, {session_open_failed, Reason}}}
    catch
        Class:CatchReason:Stack ->
            ?LOG_ERROR(#{
                description =>
                    "Exception while opening WAMP session for RPC "
                    "gateway callee. Procedures for this service/realm "
                    "will not be registered.",
                realm => RealmUri,
                service => ServiceName,
                class => Class,
                reason => CatchReason,
                stacktrace => Stack
            }),
            {stop, {shutdown, {session_open_failed, CatchReason}}}
    end.

-doc false.
handle_continue(register_procedures, #state{} = State) ->
    Registrations = register_procedures(State),
    {noreply, State#state{registrations = Registrations}}.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-doc false.
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info(_Info, State) ->
    {noreply, State}.

-doc false.
terminate(_Reason, #state{}) ->
    ok.


%% =============================================================================
%% PRIVATE
%% =============================================================================


register_procedures(State) ->
    #state{
        service = ServiceConf,
        poolname = PoolName,
        session_id = SessionId
    } = State,

    #{
        name := ServiceName,
        base_url := BaseUrl,
        auth_mod := AuthMod,
        auth_conf := AuthConf0
    } = ServiceConf,

    Timeout = maps:get(timeout, ServiceConf, ?DEFAULT_TIMEOUT),
    Retries = maps:get(retries, ServiceConf, ?DEFAULT_RETRIES),

    %% Thread the per-service pool name into AuthConf so token-fetch
    %% requests (issued by the auth module) share the service's TLS and
    %% connection-pool configuration with the procedure's HTTP requests.
    AuthConf = AuthConf0#{pool => PoolName},

    %% Eagerly merge resolved secrets at registration time so the hot path
    %% does not pay the cost on every WAMP call. If secrets are still
    %% pending, register with un-merged AuthConf and `vars_resolved =
    %% false`; the handler falls back to a per-call merge keyed on the
    %% manager's readiness ETS until this callee is recycled by the
    %% supervisor for some unrelated reason.
    SecretVars =
        case bondy_rpc_gateway_manager:service_readiness(ServiceName) of
            {ok, Vars} -> Vars;
            {error, not_ready} -> not_ready
        end,

    Procedures = maps:get(procedures, ServiceConf, #{}),

    maps:fold(
        fun(_ProcName, ProcConf, Acc) ->
            Base = build_proc_conf(
                ProcConf, ServiceName, BaseUrl, AuthMod, AuthConf,
                Timeout, Retries, PoolName
            ),
            FullProcConf = case SecretVars of
                not_ready ->
                    Base;
                _ ->
                    bondy_rpc_gateway_callee_handler:apply_secrets(
                        Base, SecretVars
                    )
            end,
            register_one(FullProcConf, SessionId, Acc)
        end,
        #{},
        Procedures
    ).


%% @private
%% Builds the record with `vars_resolved = false`. Caller is responsible
%% for delegating to `bondy_rpc_gateway_callee_handler:apply_secrets/2`
%% when secrets are available, which flips the flag and merges the vars.
build_proc_conf(ProcConf, ServiceName, BaseUrl, AuthMod, AuthConf,
                Timeout, Retries, PoolName) ->
    #{uri := ProcUri, realm := RealmUri} = ProcConf,
    Method = maps:get(method, ProcConf, get),
    Path = maps:get(path, ProcConf, ~"/"),
    PathVars = bondy_rpc_gateway_callee_handler:extract_path_vars(Path),
    #rpc_gateway_proc_conf{
        service_name = ServiceName,
        base_url = BaseUrl,
        auth_mod = AuthMod,
        auth_conf = AuthConf,
        timeout = Timeout,
        retries = Retries,
        pool = PoolName,
        method = Method,
        path = Path,
        path_vars = PathVars,
        uri = ProcUri,
        realm = RealmUri,
        vars_resolved = false
    }.


%% @private
register_one(#rpc_gateway_proc_conf{
        uri = ProcUri,
        realm = RealmUri,
        service_name = ServiceName,
        method = Method,
        path = Path
    } = FullProcConf, SessionId, Acc) ->
    MF = {bondy_rpc_gateway_callee_handler, handle_wamp_call},
    Ref = bondy_ref:new(internal, MF, SessionId),
    Opts = #{
        match => ~"exact",
        callback_args => [FullProcConf]
    },
    case bondy_dealer:register(ProcUri, Opts, RealmUri, Ref) of
        {ok, RegId} ->
            ?LOG_INFO(#{
                description => "WAMP procedure registered",
                procedure => ProcUri,
                realm => RealmUri,
                service => ServiceName,
                method => Method,
                path => Path
            }),
            Acc#{ProcUri => {RegId, RealmUri, FullProcConf}};
        {error, Reason} ->
            ?LOG_ERROR(#{
                description => "Failed to register WAMP procedure, skipping",
                procedure => ProcUri,
                realm => RealmUri,
                service => ServiceName,
                reason => Reason
            }),
            Acc
    end.


