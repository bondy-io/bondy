-module(tuplespace_worker_sup).
-behaviour(supervisor).
-include ("tuplespace.hrl").


-export([start_link/0]).
-export([init/1]).


start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


init([]) ->
    Procs = child_specs(),
    {ok, {{one_for_one, 10, 60}, Procs}}.



%% =============================================================================
%%  PRIVATE
%% =============================================================================


%% @private
child_specs() ->
    %% We reuse the existing ring so that there is a worker per table
    {_N, L} = tuplespace:get_ring(?REGISTRY_TABLE_NAME),
    [child_spec({PIdx, PName}) || {PIdx, PName} <- L].


%% @private
child_spec({PIdx, PName} = Id) ->
    {
        Id,
        {tuplespace_worker, start_link, [PIdx, PName]},
        permanent,
        5000,
        worker,
        [tuplespace_worker]
    }.
