#!/usr/bin/env escript
%% -*- erlang -*-
%%! -hidden
%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Storage-stack LAYERING check (xref).
%%
%% Enforces the dependency-direction contract: calls flow strictly
%%
%%     bondy_db  ->  bondy_oplog  ->  bondy_mst
%%
%% with NO cycles and NO layer-skips. A lower layer must never STATICALLY call a
%% higher one. Wired as a CI gate via `just xref-layering` (which compiles
%% first). Exit 0 = intact, exit 1 = violation (offending edges printed).
%%
%% Why scoped (not project-wide `rebar3 xref`): the umbrella's full xref run is
%% dominated by unrelated `undefined_functions` noise (and pulls in sibling
%% build artefacts), so it is a poor gate. This checks the layering invariant
%% specifically, over only the three storage apps, on the application call
%% graph `AE`.
%%
%% STATIC-ONLY by design: the cross-layer storage wiring is dependency-injected
%% (e.g. `projection_adapter => Mod` opts), so bondy_oplog drives bondy_db's
%% leveled projection at runtime with NO static edge — which is exactly what
%% keeps the graph acyclic. This guards the static call graph; it neither can
%% nor should resolve dynamic dispatch.
%% =============================================================================

-mode(compile).

%% Highest layer first. Each app may statically call only apps BELOW it.
-define(LAYERS, [bondy_db, bondy_oplog, bondy_mst]).

main(Args) ->
    LibDir =
        case Args of
            [D | _] -> D;
            _ -> "_build/default/lib"
        end,
    {ok, _} = xref:start(layering),
    try
        ok = add_apps(LibDir, ?LAYERS),
        ok = check_canaries(?LAYERS),
        ok = check_forbidden(?LAYERS),
        io:format("OK  layering intact: ~s~n", [chain_str(?LAYERS)]),
        halt(0)
    catch
        throw:{fail, Fmt, FArgs} ->
            io:format(standard_error, "FAIL  " ++ Fmt ++ "~n", FArgs),
            halt(1)
    after
        catch xref:stop(layering)
    end.

%% Add each app's ebin dir to the xref server; a missing one is a hard failure
%% (the check would otherwise pass vacuously).
add_apps(LibDir, Apps) ->
    lists:foreach(
        fun(App) ->
            Dir = filename:join(LibDir, atom_to_list(App)),
            case xref:add_application(layering, Dir) of
                {ok, App} -> ok;
                {ok, Other} -> throw({fail, "~s holds app ~p, expected ~p", [Dir, Other, App]});
                {error, _, R} -> throw({fail, "cannot add ~p from ~s: ~p", [App, Dir, R]})
            end
        end,
        Apps
    ).

%% CANARY: every adjacent downward edge MUST exist, so the forbidden-edge
%% checks below cannot pass vacuously on an empty/unpopulated graph.
check_canaries([Hi, Lo | Rest]) ->
    Q = edge_query(Hi, [Lo]),
    case q(Q) of
        [{Hi, Lo}] ->
            check_canaries([Lo | Rest]);
        Other ->
            throw({fail, "canary: expected the edge ~p -> ~p to exist, got ~p "
                "(graph not populated? dependency removed?)", [Hi, Lo, Other]})
    end;
check_canaries(_) ->
    ok.

%% For each app, the set of higher apps it must NOT call is everything to its
%% left in ?LAYERS. Assert no such edge exists.
check_forbidden(Layers) ->
    check_forbidden(Layers, []).

check_forbidden([], _Higher) ->
    ok;
check_forbidden([App | Lower], Higher) ->
    case Higher of
        [] ->
            ok;
        _ ->
            case q(edge_query(App, Higher)) of
                [] -> ok;
                Edges ->
                    throw({fail, "~p must not call a higher layer; offending edges: ~p",
                        [App, Edges]})
            end
    end,
    check_forbidden(Lower, Higher ++ [App]).

%% `AE` edges whose source is From and target is in Tos.
edge_query(From, Tos) ->
    TosCsv = string:join([atom_to_list(A) || A <- Tos], ", "),
    lists:flatten(io_lib:format(
        "(AE | ([~s] : App)) || ([~s] : App)", [atom_to_list(From), TosCsv]
    )).

q(Query) ->
    case xref:q(layering, Query) of
        {ok, Result} -> Result;
        {error, _, R} -> throw({fail, "xref query ~s failed: ~p", [Query, R]})
    end.

chain_str(Apps) ->
    string:join([atom_to_list(A) || A <- Apps], " -> ").
