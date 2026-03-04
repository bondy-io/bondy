%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rpc_gateway_manager).

-moduledoc """
On startup:
1. reads service configuration from the application environment,
2. initiates secret resolution per service
3. Groups service procedures by realm and spawns a `bondy_rpc_gateway_callee` per service/realm

## Resilient Secret Resolution
Services with `auth_conf.secrets` are registered immediately (even before
secrets are resolved). Secret resolution is attempted at startup and
retried indefinitely with exponential backoff via `bondy_retry` if the
external provider is unreachable.

## Callee readiness
A callee is ready when secrets have been resolved. Per-callee readiness is
tracked in the `?READINESS_TAB` ets table:

| Entry | Meaning |
|-------|---------|
| No entry | Service has no secrets — always ready |
| `{ServiceName, not_ready}` | Secrets not yet resolved |
| `{ServiceName, {ready, ResolvedVars}}` | Secrets resolved |


Each Callee WAMP handler checks the service readiness by calling `get_secrets/2`
at call time and returns `bondy.error.bad_gateway` for not_ready services.

""".

-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-define(READINESS_TAB, ?MODULE).
-define(RETRY_OPTS, #{
    deadline => 0,
    max_retries => 1 bsl 62,
    backoff_enabled => true,
    backoff_min => 5000,
    backoff_max => 300000,
    backoff_type => jitter
}).

-record(state, {
    services = []    ::  list(),
    service_poolnames = #{} ::  #{binary() => atom()},
    pending_secrets = #{}   ::  #{binary() => {map(), bondy_retry:t()}}
}).


%% API
-export([start_link/0]).
-export([services/0]).
-export([get_secrets/1]).


%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([handle_continue/2]).
-export([handle_call/3]).
-export([handle_cast/2]).

%% =============================================================================
%% API
%% =============================================================================



-doc "Start the manager, registered locally. Called by the supervisor.".
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "Return all configured services.".
-spec services() -> [map()].
services() ->
    gen_server:call(?MODULE, services, 10000).


-doc """
Returns `{ok, Vars}` where `Vars` is a mapping of secret vars to their resolved
values (if they have been resolved).
Otherwise, returns `{error, not_ready}`.
""".
-spec get_secrets(binary()) -> {ok, map()} | {error, not_ready}.

get_secrets(ServiceName) ->
    try ets:lookup(?READINESS_TAB, ServiceName) of
        [] ->
            {ok, #{}};

        [{_, {ready, Vars}}] ->
            {ok, Vars};

        [{_, not_ready}] ->
            {error, not_ready}
    catch
        error:badarg ->
            {error, not_ready}
    end.


%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================


-doc false.
init([]) ->
    Services = application:get_env(bondy_rpc_gateway, services, []),
    ets:new(?READINESS_TAB, [
        named_table, protected, set, {read_concurrency, true}
    ]),
    State = #state{services = Services},
    {ok, State, {continue, resolve_secrets}}.

-doc false.
handle_continue(resolve_secrets, #state{services = []} = State) ->
    %% No Services defined
    {noreply, State};

handle_continue(resolve_secrets, State0) ->
    {Services, PendingSecrets0} = resolve_secrets(State0#state.services),
    PendingSecrets = schedule_retries(PendingSecrets0),
    State = State0#state{
        services = Services,
        pending_secrets = PendingSecrets
    },
    {noreply, State, {continue, start_pools}};

handle_continue(start_pools, State0) ->
    {ok, PoolMapping} = start_http_pools(State0#state.services),
    State = State0#state{service_poolnames = PoolMapping},
    {noreply, State, {continue, start_callees}};

handle_continue(start_callees, State) ->
    lists:foreach(
        fun({RealmUri, Service, PoolName}) ->
            bondy_rpc_gateway_callee_sup:start_callee(
                RealmUri, Service, PoolName
            )
        end,
        callee_params(State)
    ),
    {noreply, State}.


-doc false.
handle_call(services, _From, State) ->
    Res = State#state.services,
    {reply, Res, State};

handle_call(callees, _From, State) ->
    %% TODO
    Res = [],
    {reply, Res, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-doc false.
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info(
    {timeout, _Ref, {resolve_secrets, ServiceName}},
    #state{pending_secrets = Pending} = State
) ->
    case maps:find(ServiceName, Pending) of
        {ok, {SecretsSpec, RetryState}} ->
            case bondy_rpc_gateway_secret_resolver:resolve_service_secrets(
                SecretsSpec, ServiceName
            ) of
                {ok, ResolvedVars} ->
                    ets:insert(
                        ?READINESS_TAB,
                        {ServiceName, {ready, ResolvedVars}}
                    ),
                    ?LOG_INFO(#{
                        msg => <<"Secrets resolved for service">>,
                        service => ServiceName
                    }),
                    Pending1 = maps:remove(ServiceName, Pending),
                    {noreply, State#state{pending_secrets = Pending1}};
                {error, Reason} ->
                    ?LOG_WARNING(#{
                        msg => <<"Secret resolution retry failed">>,
                        service => ServiceName,
                        reason => Reason
                    }),
                    case bondy_retry:fail(RetryState) of
                        {Time, NewRetry} when is_integer(Time) ->
                            bondy_retry:fire(NewRetry),
                            Pending1 = Pending#{
                                ServiceName := {SecretsSpec, NewRetry}
                            },
                            {noreply, State#state{
                                pending_secrets = Pending1
                            }};
                        {max_retries, _NewRetry} ->
                            ?LOG_ERROR(#{
                                msg => <<"Max retries reached for secret "
                                         "resolution">>,
                                service => ServiceName
                            }),
                            {noreply, State}
                    end
            end;
        error ->
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

-doc false.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


-doc false.
terminate(_Reason, #state{}) ->
    ok.



%% =============================================================================
%% PRIVATE
%% =============================================================================


resolve_secrets(Services) ->
    lists:foldl(
        fun(Service, {SvcAcc, PendAcc}) ->
            case resolve_service_secret(Service) of
                {ok, CleanedService} ->
                    {[CleanedService | SvcAcc], PendAcc};

                {not_ready, CleanedService, ServiceName, SecretsSpec} ->
                    RetryState = bondy_retry:init(
                        {resolve_secrets, ServiceName}, ?RETRY_OPTS
                    ),
                    {
                        [CleanedService | SvcAcc],
                        PendAcc#{ServiceName => {SecretsSpec, RetryState}}
                    }
            end
        end,
        {[], #{}},
        Services
    ).

resolve_service_secret(
    #{name := Name, auth_conf := #{secrets := SecretsSpec} = AuthConf} = Service
) ->
    AuthConf1 = maps:remove(secrets, AuthConf),
    CleanedService = Service#{auth_conf => AuthConf1},
    Result = bondy_rpc_gateway_secret_resolver:resolve_service_secrets(
        SecretsSpec, Name
    ),

    case Result of
        {ok, ResolvedVars} ->
            ets:insert(?READINESS_TAB, {Name, {ready, ResolvedVars}}),
            ?LOG_INFO(#{
                msg => <<"Secrets resolved for service at startup">>,
                service => Name
            }),
            {ok, CleanedService};

        {error, Reason} ->
            ets:insert(?READINESS_TAB, {Name, not_ready}),
            ?LOG_WARNING(#{
                msg => ~"Secret resolution failed at startup, will retry in background",
                service => Name,
                reason => Reason
            }),
            {not_ready, CleanedService, Name, SecretsSpec}
    end;

resolve_service_secret(Service) ->
    {ok, Service}.


schedule_retries(PendingSecrets) ->
    maps:map(
        fun(_ServiceName, {SecretsSpec, RetryState}) ->
            {_Time, RetryState1} = bondy_retry:fail(RetryState),
            bondy_retry:fire(RetryState1),
            {SecretsSpec, RetryState1}
        end,
        PendingSecrets
    ).

start_http_pools(Services) ->
    Map = lists:foldl(
        fun(#{name := ServiceName} = ServiceConf, Acc) ->
            PoolName = pool_name(ServiceName),
            Endpoint = maps:get(base_url, ServiceConf),
            PoolOpts = maps:get(pool, ServiceConf, #{}),
            bondy_rpc_gateway_http_pool_sup:start_pool(
                PoolName, Endpoint, PoolOpts
            ),
            Acc#{ServiceName => PoolName}
        end,
        #{},
        Services
    ),
    {ok, Map}.

pool_name(ServiceName) ->
    binary_to_atom(<<"bondy_rpc_gateway_http_pool_", ServiceName/binary>>).

%% For every service(procs) we return => [{realm, service(realm_procs)}]
callee_params(State) ->
    lists:foldl(
        fun(Service0, Acc) ->
            case maps:take(procedures, Service0) of
                {Procedures, Service1} ->
                    %{Realm => [{ProceName, ProcMap}]}
                    ProceduresByRealm =
                        maps:groups_from_list(
                            fun
                                ({_Name, #{uri := RealmUri}}) -> RealmUri;
                                (_) -> undefined
                            end,
                            maps:to_list(Procedures)
                        ),
                    maps:fold(
                        fun
                            (undefined, _, IAcc) ->
                                IAcc;

                            (RealmUri, List, IAcc) ->
                                Service = Service1#{
                                    procedures => maps:from_list(List)
                                },
                                PoolName = poolname(
                                    State, maps:get(name, Service)
                                ),
                                [{RealmUri, Service, PoolName} | IAcc]
                        end,
                        Acc,
                        ProceduresByRealm
                    );

                error ->
                    Acc
            end
        end,
        [],
        State#state.services
    ).


poolname(#state{service_poolnames = Map}, Name) ->
    maps:get(Name, Map).

