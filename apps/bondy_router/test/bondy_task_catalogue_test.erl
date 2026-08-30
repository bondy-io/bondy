%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_task_catalogue_test).

-moduledoc """
Makes `bondy_task_catalogue` a checked contract rather than prose.

A task catalogue an agent reads is only as good as its weakest claim, and the
claim most likely to rot is the simplest one: that the procedure named still
exists and still does something. So this module does not read the source — it
reads the COMPILED ABSTRACT CODE of every `*api` module and extracts the
procedure URI each `handle_call/3` clause matches, the same technique
`bondy_alarm_catalogue_test` uses on raise sites and for the same reason: the
URIs are macros, invisible to grep and already expanded in the beam.

**A clause matching a URI is not enough.** Seven procedures in this build reply
`no_such_procedure` — they are advertised and unimplemented — and cataloguing
one as a task would tell an agent it may do something that always fails. A
clause whose body reaches `no_such_procedure_error/1` is detected as a stub and
may not be a task.

## What this does NOT check

Whether a task's `impact` is *right*. Nothing can: it is a judgement about
consequence, which is the reason the catalogue exists. It checks the shape, the
vocabulary and every cross-reference; the grades are reviewed by people.

It also does not require every procedure of a covered family to be a task — a
read-only procedure is a signal, not a task — only that every FAMILY is either
represented or declared out of scope.
""".

-include_lib("eunit/include/eunit.hrl").

%% Exported: `bondy_alarm_catalogue_test` borrows this for the runbook join
%% rather than writing a second scanner over the same abstract code. Two would
%% drift, and the one that drifted would go quiet rather than fail.
-export([scan/0]).

%% =============================================================================
%% FIXTURE
%% =============================================================================

catalogue_test_() ->
    {setup, fun scan/0, fun(Scan) ->
        [
            {"the scan found the dispatch table", ?_test(scan_is_sound(Scan))},
            {"every task names a real procedure",
                ?_test(tasks_name_real_procedures(Scan))},
            {"no task names an unimplemented stub",
                ?_test(no_task_is_a_stub(Scan))},
            {"every cross-reference resolves",
                ?_test(cross_references_resolve(Scan))},
            {"reversal is symmetric", ?_test(reversal_is_symmetric())},
            {"every family is covered or declared out of scope",
                ?_test(families_are_accounted_for(Scan))},
            {"out-of-scope families exist", ?_test(exclusions_are_live(Scan))},
            {"entries are well formed", ?_test(entries_are_well_formed())},
            {"ids are distinct", ?_test(ids_are_distinct())},
            {"argument counts match the handlers",
                ?_test(argument_counts_match_the_handlers(Scan))}
        ]
    end}.

%% =============================================================================
%% TESTS
%% =============================================================================

%% Everything below is vacuous if the scan found nothing. Assert its reach
%% first: no module failed to yield abstract code, the count is in the right
%% order of magnitude, and three procedures with three different shapes are
%% present — one catalogued, one read-only, one known stub.
scan_is_sound(#{errors := Errors, procs := Procs, arities := Arities}) ->
    ?assertEqual([], Errors),
    ?assert(map_size(Procs) >= 100),
    ?assert(maps:is_key(~"bondy.router.bridge.stop", Procs)),
    ?assert(maps:is_key(~"bondy.registration.list", Procs)),
    ?assert(maps:is_key(~"bondy.cluster.leave", Procs)),
    %% The arity pass, pinned on the two shapes it has to handle: an arity
    %% read from the dispatch clause itself, and one read through a local
    %% helper the clause delegates to. Without the second, the listener pair
    %% would silently drop out of the check below.
    ?assertEqual({ok, 1}, maps:find(~"bondy.router.bridge.stop", Arities)),
    ?assertEqual({ok, 0}, maps:find(~"bondy.router.bridge.list", Arities)),
    ?assertEqual({ok, 1}, maps:find(~"bondy.listener.suspend", Arities)).

tasks_name_real_procedures(#{procs := Procs}) ->
    Missing = [
        Id
     || #{id := Id} <- bondy_task_catalogue:list(),
        not maps:is_key(Id, Procs)
    ],
    ?assertEqual([], Missing).

%% The check that a clause alone would not give: `bondy.cluster.leave` IS
%% matched by a clause and always refuses. A task must be something an agent
%% can actually be told to do.
no_task_is_a_stub(#{procs := Procs}) ->
    Stubs = [
        Id
     || #{id := Id} <- bondy_task_catalogue:list(),
        maps:get(Id, Procs, false) == stub
    ],
    ?assertEqual([], Stubs),
    %% Vacuity guard: this is only meaningful while stubs exist to be caught.
    ?assert(length([x || {_, stub} <- maps:to_list(Procs)]) >= 1).

%% `reverses` and `observe_with` are what an agent follows next. A dangling one
%% sends it at a procedure that is not there.
cross_references_resolve(#{procs := Procs}) ->
    Dangling = [
        {Id, Ref}
     || #{id := Id} = E <- bondy_task_catalogue:list(),
        Ref <- refs(E),
        not maps:is_key(Ref, Procs)
    ],
    ?assertEqual([], Dangling),
    UncataloguedReversal = [
        {Id, Rev}
     || #{id := Id, reverses := Rev} <- bondy_task_catalogue:list(),
        bondy_task_catalogue:lookup(Rev) == error
    ],
    ?assertEqual([], UncataloguedReversal).

%% If A reverses B then B reverses A. An asymmetric pair means an agent can
%% undo an action but not find its way back, or — worse — believes it undid
%% something that names a different inverse.
reversal_is_symmetric() ->
    Asymmetric = [
        {Id, Rev}
     || #{id := Id, reverses := Rev} <- bondy_task_catalogue:list(),
        {ok, #{reverses := Back}} <- [bondy_task_catalogue:lookup(Rev)],
        Back =/= Id
    ],
    ?assertEqual([], Asymmetric).

%% The ratchet. Coverage is partial ON PURPOSE, so completeness cannot be the
%% check; what CAN be checked is that no family is uncatalogued by accident. A
%% new `bondy.<family>.*` fails here until someone decides whether its
%% procedures are tasks.
families_are_accounted_for(#{procs := Procs}) ->
    Excluded = maps:keys(bondy_task_catalogue:out_of_scope()),
    Covered = lists:usort([
        family(Id)
     || #{id := Id} <- bondy_task_catalogue:list()
    ]),
    Unaccounted = [
        F
     || F <- lists:usort([family(P) || P <- maps:keys(Procs)]),
        not lists:member(F, Covered),
        not lists:member(F, Excluded)
    ],
    ?assertEqual([], Unaccounted).

%% The other direction: an exclusion for a family that no longer exists is
%% stale documentation, and this table is meant to be the opposite of that.
exclusions_are_live(#{procs := Procs}) ->
    Live = lists:usort([family(P) || P <- maps:keys(Procs)]),
    Stale = [
        F
     || F <- maps:keys(bondy_task_catalogue:out_of_scope()),
        not lists:member(F, Live)
    ],
    ?assertEqual([], Stale).

entries_are_well_formed() ->
    Impacts = bondy_task_catalogue:impacts(),
    Radii = bondy_task_catalogue:blast_radii(),
    lists:foreach(
        fun(E) ->
            ?assert(is_binary(maps:get(id, E))),
            ?assert(is_binary(maps:get(title, E))),
            ?assert(is_binary(maps:get(summary, E))),
            ?assert(lists:member(maps:get(impact, E), Impacts)),
            ?assert(lists:member(maps:get(blast_radius, E), Radii)),
            ?assert(is_boolean(maps:get(idempotent, E))),
            %% `dry_run` is read by `bondy_wamp_api` BEFORE dispatch, so a
            %% non-boolean here would decide whether a call is refused. That
            %% a declared `true` is actually implemented is checked where it
            %% can be — `bondy_dry_run_SUITE`, by calling it.
            ?assert(is_boolean(maps:get(dry_run, E))),
            Args = maps:get(args, E),
            ?assert(is_list(Args)),
            ?assert(lists:all(fun is_map/1, Args)),
            ?assert(is_list(maps:get(observe_with, E)))
        end,
        bondy_task_catalogue:list()
    ),
    ?assert(length(bondy_task_catalogue:list()) >= 8).

ids_are_distinct() ->
    Ids = [Id || #{id := Id} <- bondy_task_catalogue:list()],
    ?assertEqual(lists:usort(Ids), lists:sort(Ids)).

%% An agent builds its CALL from `args`, and `bondy_mcp_sre_overlay` turns the
%% list into the MCP tool's `inputSchema`, so a list of the wrong length tells
%% the agent to make a call the router refuses before the handler ever runs.
%% The expected count is NOT restated here — it is read out of the compiled
%% abstract code of the clause that decodes the call, so adding an argument to
%% a procedure fails this rather than reaching an agent as a wrong shape. A
%% procedure whose arity could not be read fails too (`unknown`): an
%% unreadable clause is a gap in the check, not a pass.
argument_counts_match_the_handlers(#{arities := Arities}) ->
    Wrong = [
        {Id, declared, length(Args), validates, maps:get(Id, Arities, unknown)}
     || #{id := Id, args := Args} <- bondy_task_catalogue:list(),
        maps:get(Id, Arities, unknown) =/= length(Args)
    ],
    ?assertEqual([], Wrong).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
%% `observe_with` carries the same `#{kind, ref}` shape `bondy_alarm_catalogue`
%% uses. Only `procedure` refs are URIs this scan can resolve; a `metric` ref is
%% checked by `bondy_alarm_catalogue_test` against `bondy_metrics:declare/1`.
refs(#{observe_with := Obs} = E) ->
    [Ref || #{kind := procedure, ref := Ref} <- Obs] ++
        [R || R <- [maps:get(reverses, E, undefined)], R =/= undefined].

%% @private
%% `bondy.<family>.<rest>`; `bondy.ping` has no rest and its family is `ping`.
family(<<"bondy.", Rest/binary>>) ->
    case binary:split(Rest, ~".") of
        [F, _] -> F;
        [F] -> F
    end.

%% @private
%% `#{Uri => implemented | stub}` for every procedure any `*api` module
%% dispatches. `do_handle_call/3` is read as well as `handle_call/3` because
%% `bondy_wamp_api` serves `bondy.ping` from its own dispatch clause rather
%% than delegating it to a family module. Read from the app ebin dirs on disk, NOT `code:which/1`, which
%% answers `cover_compiled` under `rebar3 eunit`.
scan() ->
    Beams = lists:usort(
        lists:append([
            filelib:wildcard(filename:join(Ebin, "*api.beam"))
         || Ebin <- ebin_dirs()
        ])
    ),
    lists:foldl(
        fun scan_beam/2,
        #{procs => #{}, arities => #{}, validators => #{}, errors => []},
        Beams
    ).

%% @private
ebin_dirs() ->
    Root = filename:dirname(code:lib_dir(bondy_router)),
    filelib:wildcard(filename:join([Root, "*", "ebin"])).

%% @private
%% A beam whose abstract code cannot be read is recorded, never skipped: a
%% silent skip is how a whole family would vanish from the ratchet.
scan_beam(
    Beam,
    #{
        procs := Procs,
        arities := Arities,
        validators := Validators,
        errors := Errors
    } = Acc
) ->
    case beam_lib:chunks(Beam, [abstract_code]) of
        {ok, {_Mod, [{abstract_code, {raw_abstract_v1, Forms}}]}} ->
            New = lists:append([clauses(F) || F <- Forms]),
            Fns = functions(Forms),
            Found = lists:append([arity_clauses(F, Fns) || F <- Forms]),
            Acc#{
                procs := maps:merge(Procs, maps:from_list(New)),
                arities := maps:merge(
                    Arities, maps:from_list([{U, N} || {U, {_, N}} <- Found])
                ),
                validators := maps:merge(
                    Validators, maps:from_list([{U, F} || {U, {F, _}} <- Found])
                )
            };
        {ok, {_Mod, [{abstract_code, no_abstract_code}]}} ->
            Acc;
        Other ->
            Acc#{errors := [{Beam, Other} | Errors]}
    end.

%% @private
clauses({function, _, Name, N, Cs}) when
    (Name == handle_call orelse Name == do_handle_call) andalso
        (N == 2 orelse N == 3)
->
    [
        {Uri, kind(Body)}
     || {clause, _, [Head | _], _, Body} <- Cs, {ok, Uri} <- [literal(Head)]
    ];
clauses(_) ->
    [].

%% @private
%% `{Name, Arity} => Clauses` for every function of one module, so an arity
%% search can follow a dispatch clause into the local helper it delegates to.
functions(Forms) ->
    maps:from_list([{{Name, N}, Cs} || {function, _, Name, N, Cs} <- Forms]).

%% @private
%% `#{Uri => N}`: the number of POSITIONAL arguments each dispatch clause
%% accepts, read from the `bondy_wamp_api_utils:validate_call_args/3` or
%% `validate_admin_call_args/3` literal that clause reaches. Two of the
%% catalogued procedures (`bondy.listener.{suspend,resume}`) decode their
%% arguments in a shared local helper rather than in the clause body, so one
%% level of local call is followed; deeper is not chased, and a clause whose
%% arity cannot be read yields NOTHING rather than a guess — the caller then
%% reports it as a mismatch instead of passing over it.
arity_clauses({function, _, Name, N, Cs}, Fns) when
    (Name == handle_call orelse Name == do_handle_call) andalso
        (N == 2 orelse N == 3)
->
    [
        {Uri, A}
     || {clause, _, [Head | _], _, Body} <- Cs,
        {ok, Uri} <- [literal(Head)],
        {ok, A} <- [arity(Body, Fns, 2)]
    ];
arity_clauses(_, _) ->
    [].

%% @private
arity(_, _, 0) ->
    error;
arity(Body, Fns, Depth) ->
    case validated_arity(Body) of
        {ok, _} = Ok ->
            Ok;
        error ->
            first_ok(
                fun({F, A}) ->
                    case maps:find({F, A}, Fns) of
                        {ok, Cs} ->
                            arity(
                                [B || {clause, _, _, _, B} <- Cs],
                                Fns,
                                Depth - 1
                            );
                        error ->
                            error
                    end
                end,
                local_calls(Body)
            )
    end.

%% @private
validated_arity({call, _, {remote, _, _, {atom, _, F}}, Args}) when
    F == validate_call_args;
    F == validate_admin_call_args;
    F == call_args;
    F == admin_call_args
->
    case lists:last(Args) of
        {integer, _, N} -> {ok, {validator_family(F), N}};
        _ -> error
    end;
validated_arity(T) when is_tuple(T) ->
    validated_arity(tuple_to_list(T));
validated_arity(L) when is_list(L) ->
    first_ok(fun validated_arity/1, L);
validated_arity(_) ->
    error.

%% @private
%% Which of the two `bondy_wamp_api_utils` VALIDATOR families the clause
%% reached — not to be confused with a procedure family (`bondy.<family>.*`),
%% which is what `families_are_accounted_for/1` above is about. `realm` reads the first positional argument as a realm URI and
%% COMPLETES a call that is one argument short with the caller's own realm;
%% `no_realm` checks the arity exactly. Which one a procedure wants is a
%% property of the procedure, and `bondy_wamp_api_arity_test` is what checks
%% the `no_realm` ones actually refuse the short call.
validator_family(validate_call_args) -> realm;
validator_family(validate_admin_call_args) -> realm;
validator_family(call_args) -> no_realm;
validator_family(admin_call_args) -> no_realm.

%% @private
local_calls({call, _, {atom, _, F}, Args}) ->
    [{F, length(Args)} | local_calls(Args)];
local_calls(T) when is_tuple(T) ->
    local_calls(tuple_to_list(T));
local_calls(L) when is_list(L) ->
    lists:append([local_calls(E) || E <- L]);
local_calls(_) ->
    [].

%% @private
first_ok(Fun, L) ->
    lists:foldl(
        fun
            (_, {ok, _} = Ok) -> Ok;
            (E, error) -> Fun(E)
        end,
        error,
        L
    ).

%% @private
%% A clause that reaches `no_such_procedure_error/1` (or the local
%% `no_such_procedure/1` wrapper some modules use) does nothing but refuse.
kind(Body) ->
    case refuses(Body) of
        true -> stub;
        false -> implemented
    end.

%% @private
refuses({call, _, {remote, _, {atom, _, _}, {atom, _, F}}, _}) when
    F == no_such_procedure_error; F == no_such_procedure
->
    true;
refuses({call, _, {atom, _, F}, _}) when
    F == no_such_procedure_error; F == no_such_procedure
->
    true;
refuses(T) when is_tuple(T) ->
    lists:any(fun refuses/1, tuple_to_list(T));
refuses(L) when is_list(L) ->
    lists:any(fun refuses/1, L);
refuses(_) ->
    false.

%% @private
%% Only a WHOLLY literal binary pattern is a procedure name. A prefix pattern
%% (`<<"bondy.alarm.", _/binary>>`) has a variable segment and is rejected
%% rather than silently truncated to its literal prefix.
literal({bin, _, Elems}) ->
    Literal = fun
        ({bin_element, _, {string, _, _}, default, _}) -> true;
        (_) -> false
    end,
    case lists:all(Literal, Elems) of
        true ->
            {ok,
                iolist_to_binary([
                    S
                 || {bin_element, _, {string, _, S}, _, _} <- Elems
                ])};
        false ->
            none
    end;
literal(_) ->
    none.
