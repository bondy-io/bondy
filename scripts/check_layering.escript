#!/usr/bin/env escript
%% -*- erlang -*-
%%! -hidden
%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%%
%% Architecture boundary checks (xref), over the compiled apps.
%%
%% STORAGE LAYERING. Enforces the dependency-direction contract: calls flow
%% strictly
%%
%%     bondy_db  ->  bondy_oplog  ->  bondy_mst
%%
%% with NO cycles and NO layer-skips. A lower layer must never STATICALLY call a
%% higher one. Run by `just xref-layering` (which compiles first) and
%% `just check`. Exit 0 = intact, exit 1 = violation (offending edges printed).
%%
%% Why scoped (not project-wide `rebar3 xref`): the umbrella's full xref run is
%% dominated by unrelated `undefined_functions` noise (and pulls in sibling
%% build artefacts), so it is a poor gate. The apps are taken from AppsDir, not
%% from LibDir, and each query names the apps it judges: the layering queries
%% read only the three storage apps' application call graph `AE`.
%%
%% STATIC-ONLY by design: the cross-layer storage wiring is dependency-injected
%% (e.g. `projection_adapter => Mod` opts), so bondy_oplog drives bondy_db's
%% leveled projection at runtime with NO static edge — which is exactly what
%% keeps the graph acyclic. This guards the static call graph; it neither can
%% nor should resolve dynamic dispatch.
%%
%% CLUSTER BOUNDARY. Only `bondy_cluster` may call the Partisan service modules
%% in ?CLUSTER_SERVICES, and `bondy_cluster` calls no other project app, so
%% every app may depend on it without closing a cycle. The check sees direct
%% calls only: a `partisan` function that reaches one of those processes, such
%% as `partisan:cast_message/4` or `partisan:broadcast/2`, is outside it (see
%% the `bondy_cluster` moduledoc).
%% Usage: check_layering.escript [LibDir [AppsDir]].
%% =============================================================================

-mode(compile).

%% Highest layer first. Each app may statically call only apps BELOW it.
-define(LAYERS, [bondy_db, bondy_oplog, bondy_mst]).

-define(CLUSTER_FACADE, bondy_cluster).

%% The facade's canary: each must be called from it, or the boundary check
%% below could pass on a graph that never saw the facade.
-define(FACADE_WRAPS, [
    partisan_inet, partisan_membership, partisan_peer_service, partisan_rpc
]).

-define(CLUSTER_SERVICES, [
    partisan_erpc,
    partisan_inet,
    partisan_membership,
    partisan_peer_discovery_agent,
    partisan_peer_service,
    partisan_peer_service_manager,
    partisan_plumtree_broadcast,
    partisan_pluggable_peer_service_manager,
    partisan_rpc
]).

%% The client SDK ships without Bondy, so it cannot depend on the facade; it
%% probes for `partisan_inet` and degrades when Partisan is absent.
-define(CLUSTER_EXEMPT, [bondy_connect_connection]).

main(Args) ->
    {LibDir, AppsDir} =
        case Args of
            [L, A | _] -> {L, A};
            [L] -> {L, "apps"};
            [] -> {"_build/default/lib", "apps"}
        end,
    Project = project_apps(AppsDir),
    {ok, _} = xref:start(layering),
    try
        ok = add_apps(LibDir, [partisan | Project]),
        ok = check_canaries(?LAYERS),
        ok = check_forbidden(?LAYERS),
        io:format("OK  layering intact: ~s~n", [chain_str(?LAYERS)]),
        ok = check_cluster_boundary(Project),
        io:format("OK  cluster services reached only through ~p~n", [
            ?CLUSTER_FACADE
        ]),
        halt(0)
    catch
        throw:{fail, Fmt, FArgs} ->
            io:format(standard_error, "FAIL  " ++ Fmt ++ "~n", FArgs),
            halt(1)
    after
        %% Unlike most cleanup calls, `xref:stop/1` EXITS rather than returning
        %% an error when the server is already gone -- measured:
        %% `{'EXIT', {noproc, {gen_server, call, [_, stop, infinity]}}}`. That
        %% is precisely the state an abnormal exit through this `after` can
        %% leave behind, so it is tolerated and nothing else is.
        try
            xref:stop(layering)
        catch
            exit:{noproc, _} ->
                ok
        end
    end.

%% Add each app's ebin dir to the xref server; a missing one is a hard failure
%% (the check would otherwise pass vacuously).
add_apps(LibDir, Apps) ->
    lists:foreach(
        fun(App) ->
            Dir = filename:join(LibDir, atom_to_list(App)),
            case xref:add_application(layering, Dir, [{warnings, false}]) of
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

%% Every app under AppsDir; a project without any is a hard failure.
project_apps(AppsDir) ->
    case filelib:wildcard(filename:join([AppsDir, "*", "src", "*.app.src"])) of
        [] ->
            throw({fail, "no applications under ~s", [AppsDir]});
        Files ->
            [list_to_atom(filename:basename(F, ".app.src")) || F <- Files]
    end.

check_cluster_boundary(Project) ->
    Edges = q(lists:flatten(io_lib:format(
        "(Mod) ((XC | ~s : App) || ~s : Mod)",
        [atoms(Project), atoms(?CLUSTER_SERVICES)]
    ))),
    Missing = [
        S || S <- ?FACADE_WRAPS, not lists:member({?CLUSTER_FACADE, S}, Edges)
    ],
    Missing == [] orelse
        throw({fail, "canary: ~p does not call ~p (graph not populated?)",
            [?CLUSTER_FACADE, Missing]}),
    Allowed = [?CLUSTER_FACADE | ?CLUSTER_EXEMPT],
    case [E || {From, _} = E <- Edges, not lists:member(From, Allowed)] of
        [] -> ok;
        Bad ->
            throw({fail, "only ~p may call the Partisan cluster services; "
                "offending edges: ~p", [?CLUSTER_FACADE, Bad]})
    end,
    case q(edge_query(?CLUSTER_FACADE, Project -- [?CLUSTER_FACADE])) of
        [] -> ok;
        Up ->
            throw({fail, "~p must call no other project app; offending "
                "edges: ~p", [?CLUSTER_FACADE, Up]})
    end.

atoms(L) ->
    "[" ++ string:join([atom_to_list(A) || A <- L], ", ") ++ "]".

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
