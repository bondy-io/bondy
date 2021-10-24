#!/usr/bin/env escript
%%! -noshell -noinput
%% -*- mode: erlang;erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ft=erlang ts=4 sw=4 et

main([Partition]) ->
    application:set_env(eleveldb, data_root, ""),
    Options = [],
    DataRoot = "data/db",
    Path = lists:flatten(DataRoot ++ "/" ++ Partition),

    case filelib:is_dir(Path) of
        true ->
            io:format("Repairing partition ~s ...~n", [Path]),
            eleveldb:repair(Path, Options),
            io:format("Repairing done.~n");
        false ->
            io:format(
                "Partition ~p does not exist at path ~p.~n",
                [Partition, DataRoot]
            )
    end,
    halt(1).