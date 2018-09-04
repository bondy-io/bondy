#!/usr/bin/env escript
%%! -noshell -noinput
%% -*- mode: erlang;erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ft=erlang ts=4 sw=4 et

main([Partition]) ->
    io:format("Repairing ~s.~n", [application:set_env(eleveldb, data_root, undefeind)]),
    application:set_env(eleveldb, data_root, ""),
    Options = [],
    DataRoot = "data/db",
    Path = lists:flatten(DataRoot ++ "/" ++ Partition),
    filelib:is_dir(Path) orelse exit("Invalid partition"),
    io:format("Repairing ~s.~n", [Path]),
    eleveldb:repair(Path, Options),
    halt(1).