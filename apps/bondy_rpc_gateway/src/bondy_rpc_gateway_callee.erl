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
MF = {bondy_rpc_gateway_callee_handler, handle_call},
Ref = bondy_ref:new(internal, MF, SessionId),
Opts = #{match => ~"exact", callback_args => [FullProcConf]},
bondy_dealer:register(ProcUri, Opts, RealmUri, Ref).
```

Where `FullProcConf` merges procedure-level fields (uri, realm, method,
path) with parent service fields (service_name, base_url, auth_mod,
auth_conf, timeout, retries, pool).

## Cleanup

Registrations are auto-cleaned by the dealer when the ref's session is
invalidated.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-record(state, {
    service             ::  map(),
    realm_uri           ::  uri(),
    session_id          ::  binary() | undefined,
    poolname            ::  atom(),
    registrations       ::  #{binary() => {term(), binary(), map()}}
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

    State = #state{
        realm_uri = RealmUri,
        service = Service,
        session_id = SessionId,
        poolname = PoolName,
        registrations = #{}
    },
    {ok, State, {continue, register_procedures}}.

-doc false.
handle_continue(register_procedures, #state{} = State) ->
    Registrations = register_procedures(State, #{}),
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



register_procedures(State, Acc) ->
    #state{
        service = ServiceConf,
        poolname = PoolName,
        session_id = SessionId
    } = State,

    #{
        name := ServiceName,
        base_url := BaseUrl,
        auth_mod := AuthMod,
        auth_conf := AuthConf
    } = ServiceConf,

    Timeout = maps:get(timeout, ServiceConf, 30000),
    Retries = maps:get(retries, ServiceConf, 3),

    Procedures = maps:get(procedures, ServiceConf, #{}),

    maps:fold(
        fun(_ProcName, ProcConf, InnerAcc) ->
            #{
                uri := ProcUri,
                realm := RealmUri
            } = ProcConf,

            Method = maps:get(method, ProcConf, get),
            Path = maps:get(path, ProcConf, ~"/"),

            FullProcConf = #{
                service_name => ServiceName,
                base_url => BaseUrl,
                auth_mod => AuthMod,
                auth_conf => AuthConf,
                timeout => Timeout,
                retries => Retries,
                pool => PoolName,
                method => Method,
                path => Path,
                uri => ProcUri,
                realm => RealmUri
            },

            MF = {bondy_rpc_gateway_callee_handler, handle_call},
            Ref = bondy_ref:new(internal, MF, SessionId),
            Opts = #{
                match => ~"exact",
                callback_args => [FullProcConf]
            },

            case bondy_dealer:register(ProcUri, Opts, RealmUri, Ref) of
                {ok, RegId} ->
                    ?LOG_INFO(#{
                        msg => ~"WAMP procedure registered",
                        procedure => ProcUri,
                        realm => RealmUri,
                        service => ServiceName,
                        method => Method,
                        path => Path
                    }),
                    InnerAcc#{
                        ProcUri => {RegId, RealmUri, FullProcConf}
                    };
                {error, Reason} ->
                    ?LOG_ERROR(#{
                        msg => ~"Failed to register WAMP procedure",
                        procedure => ProcUri,
                        realm => RealmUri,
                        service => ServiceName,
                        reason => Reason
                    }),
                    error({registration_failed, ProcUri, Reason})
            end
        end,
        Acc,
        Procedures
    ).
