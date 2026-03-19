-module(bondy_rpc_gateway_http_pool_sup).

-moduledoc """
`simple_one_for_one` supervisor for `bondy_rpc_gateway_http_pool` workers.

The manager calls `start_pool/3` for each configured service.
""".

-behaviour(supervisor).

%% API
-export([start_link/0]).
-export([start_pool/3]).
-export([stop_pool/1]).
-export([which_pools/0]).

%% supervisor callback
-export([init/1]).



%% =============================================================================
%% API
%% =============================================================================


-doc "Start the supervisor, registered locally.".
-spec start_link() -> {ok, pid()} | {error, term()}.

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


-doc "Start a pool child for the given endpoint.".
-spec start_pool(atom(), binary(), bondy_rpc_gateway_http_pool:start_opts()) ->
    {ok, pid()} | {error, term()}.

start_pool(Name, Endpoint, Opts) ->
    supervisor:start_child(?MODULE, [Name, Endpoint, Opts]).


-doc "Stop a pool child by its registered name.".
-spec stop_pool(atom()) -> ok | {error, not_found}.

stop_pool(Name) ->
    case whereis(Name) of
        undefined ->
            {error, not_found};
        Pid ->
            supervisor:terminate_child(?MODULE, Pid)
    end.


-doc "Return the pids of all running pool children.".
-spec which_pools() -> [pid()].

which_pools() ->
    [
        Pid
        || {_, Pid, _, _} <- supervisor:which_children(?MODULE), is_pid(Pid)
    ].


%% =============================================================================
%% supervisor callback
%% =============================================================================


-doc false.
init([]) ->
    ChildSpec = #{
        id => bondy_rpc_gateway_http_pool,
        start => {bondy_rpc_gateway_http_pool, start_link, []},
        restart => permanent,
        shutdown => 5_000,
        type => worker,
        modules => [bondy_rpc_gateway_http_pool]
    },
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 10,
        period => 60
    },
    {ok, {SupFlags, [ChildSpec]}}.
