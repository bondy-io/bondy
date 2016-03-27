-module(tuplespace_sup).
-behaviour(supervisor).
-include ("tuplespace.hrl").


-export([start_link/0]).
-export([init/1]).


start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).




%% =============================================================================
%%  PRIVATE
%% =============================================================================


init(_Args) ->
    %% We need to init tuplespace_static_table_manager
    %% before tuplespace_sup

    TabMan = {tuplespace_static_table_manager,
       {tuplespace_static_table_manager, start_link, []},
       permanent, 2000, worker, [tuplespace_static_table_manager]},

    TS = {tuplespace_worker_sup,
           {tuplespace_worker_sup,start_link,[]},
           permanent, 5000, supervisor, [tuplespace_worker_sup]},

    Procs = [TabMan, TS],
    MaxRestarts = 1,
    InSecs = 5,
    {ok, {{one_for_one, MaxRestarts, InSecs}, Procs}}.
