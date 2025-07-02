%%%-------------------------------------------------------------------
%% @doc bondy_regulator public API
%% @end
%%%-------------------------------------------------------------------

-module(bondy_regulator_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    bondy_regulator_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
