%%%-------------------------------------------------------------------
%% @doc bondy_migrations public API
%% @end
%%%-------------------------------------------------------------------

-module(bondy_migrations_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    bondy_migrations_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
