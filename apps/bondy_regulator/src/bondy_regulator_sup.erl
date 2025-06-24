%%%-------------------------------------------------------------------
%% @doc bondy_regulator top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(bondy_regulator_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% sup_flags() = #{strategy => strategy(),         % optional
%%                 intensity => non_neg_integer(), % optional
%%                 period => pos_integer()}        % optional
%% child_spec() = #{id => child_id(),       % mandatory
%%                  start => mfargs(),      % mandatory
%%                  restart => restart(),   % optional
%%                  shutdown => shutdown(), % optional
%%                  type => worker(),       % optional
%%                  modules => modules()}   % optional
init([]) ->
    SupFlags = #{
        strategy => one_for_all,
        intensity => 5,
        period => 10
    },
    ChildSpecs = [
        #{
            id => bondy_regulator_rate_limit,
            start => {bondy_regulator_rate_limit, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [bondy_regulator_rate_limit]
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
