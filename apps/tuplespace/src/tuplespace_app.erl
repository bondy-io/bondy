-module(tuplespace_app).
-behaviour(application).
-include ("tuplespace.hrl").

-export([start/2]).
-export([stop/1]).
-export([priv_dir/0]).


start(_Type, _Args) ->
    case tuplespace_sup:start_link() of
        {ok, Pid} ->
            %% More init here
            {ok, Pid};
        Other ->
            Other
    end.


stop(_State) ->
    ok.


priv_dir() ->
    case code:priv_dir(betflow) of
        {error, bad_name} ->
            filename:join([filename:dirname(code:which(?MODULE)), "..", "priv"]);
        A ->
            A
    end.
