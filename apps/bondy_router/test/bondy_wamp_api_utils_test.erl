%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% The `CALL.Options._deadline` contract on the static `bondy.*` path, in two
%% halves.
%%
%% FIRST, the two pure helpers that turn a caller's option into something a
%% handler can wait on. They are tested here rather than through a procedure
%% because every interesting case is an EDGE — no deadline, a deadline already
%% spent, a deadline longer than the handler's own bound — and a procedure can
%% only reach the first of those reliably. What a procedure DOES with the
%% answer is pinned where that procedure lives.
%%
%% SECOND, a RATCHET over every `bondy_wamp_api` implementation in the tree.
%% "Honoured by all APIs" is a property of a SET, and a set is exactly what
%% goes quietly wrong: the next fan-out somebody adds would wait on its own
%% fixed timeout and nothing would say so. So the places a handler waits are
%% DECLARED below and checked against the compiled abstract code.
-module(bondy_wamp_api_utils_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").

%% =============================================================================
%% deadline/1
%% =============================================================================

%% Absent means UNBOUNDED, not zero. Reading a missing option as "no time left"
%% would make every call that never set one fail immediately.
no_deadline_option_is_infinity_test() ->
    ?assertEqual(infinity, bondy_wamp_api_utils:deadline(#{})).

%% `_deadline` is a DURATION on the wire and an INSTANT here — the only form a
%% multi-step handler can keep comparing against as it proceeds.
a_deadline_becomes_an_instant_test() ->
    Before = erlang:system_time(millisecond),
    D = bondy_wamp_api_utils:deadline(#{'_deadline' => 1000}),
    After = erlang:system_time(millisecond),
    ?assert(D >= Before + 1000),
    ?assert(D =< After + 1000).

%% Extension options pass WAMP validation UNTYPED, so anything unusable means
%% NO deadline rather than an error: a malformed option must not turn a working
%% call into a failing one.
an_unusable_deadline_is_infinity_test() ->
    _ = [
        ?assertEqual(
            infinity, bondy_wamp_api_utils:deadline(#{'_deadline' => V})
        )
     || V <- [0, -1, <<"1000">>, "1000", 1.5, undefined, null]
    ].

%% =============================================================================
%% budget/2
%% =============================================================================

%% Without a deadline a handler waits exactly what it would have waited.
no_deadline_leaves_the_ceiling_test() ->
    ?assertEqual(5000, bondy_wamp_api_utils:budget(infinity, 5000)).

%% A caller can only ever SHORTEN a wait. `_deadline` says when to give up; it
%% is not a grant of patience, and a handler's ceiling is its own judgement
%% about how long the thing it is waiting for is worth waiting for.
a_deadline_beyond_the_ceiling_does_not_extend_it_test() ->
    Far = erlang:system_time(millisecond) + 3600000,
    ?assertEqual(5000, bondy_wamp_api_utils:budget(Far, 5000)).

a_deadline_inside_the_ceiling_shortens_it_test() ->
    Near = erlang:system_time(millisecond) + 200,
    B = bondy_wamp_api_utils:budget(Near, 5000),
    ?assert(B =< 200),
    ?assert(B > 0).

%% Zero is a real answer meaning DO NOT WAIT, and it is what every caller of
%% this function branches on. A negative would be passed to a `receive` or an
%% RPC as a timeout and raise there instead.
a_spent_deadline_is_zero_never_negative_test() ->
    Past = erlang:system_time(millisecond) - 60000,
    ?assertEqual(0, bondy_wamp_api_utils:budget(Past, 5000)).

%% The two compose: this is the whole path from a caller's option to a timeout.
the_wire_option_reaches_a_timeout_test() ->
    D = bondy_wamp_api_utils:deadline(#{'_deadline' => 100}),
    B = bondy_wamp_api_utils:budget(D, 5000),
    ?assert(B =< 100),
    ?assert(B > 0).

%% =============================================================================
%% THE RATCHET
%% =============================================================================

%% Functions that WAIT — where a `bondy.*` handler can spend real time.
%%
%% Declared rather than discovered: the whole point is to notice a call that
%% was not here before, and a scanner that inferred "blocking" from the shape
%% of a call would have to be right about every future one. Several of these
%% have no caller in the tree today and are listed BECAUSE of that: the two
%% `partisan_peer_service` reads were removed from `bondy_cluster_api` on
%% 2026-09-01 for being `gen_server:call(..., infinity)`, and re-introducing
%% one must fail here rather than quietly restore an unbounded wait.
blocking_callees() ->
    [
        {partisan_rpc, call, 4},
        {partisan_rpc, call, 5},
        {partisan_rpc, multicall, 4},
        {partisan_rpc, multicall, 5},
        {partisan_peer_service, members, 0},
        {partisan_peer_service, members_for_orchestration, 0},
        {erpc, call, 4},
        {erpc, call, 5},
        {erpc, multicall, 4},
        {erpc, multicall, 5},
        {rpc, call, 4},
        {rpc, call, 5},
        {rpc, multicall, 4},
        {rpc, multicall, 5},
        {gen_server, call, 2},
        {gen_server, call, 3},
        {gen_statem, call, 2},
        {gen_statem, call, 3}
    ].

%% Every function in a `bondy_wamp_api` implementation that calls one of the
%% above, and what bounds each. All three take their timeout from
%% `bondy_wamp_api_utils:budget/2`, so the caller's `_deadline` can only
%% shorten them.
%%
%% Adding a row is a DECISION, not bookkeeping: a new waiting site that is not
%% wired to the budget makes `_deadline` mean less than it says, and this list
%% is where someone has to notice.
waiting_sites() ->
    [
        %% One node of the cluster-wide history walk. Bounded by what is left
        %% of the page's budget, not by a fresh timeout per node.
        {bondy_alarm_api, node_history, 4},
        %% The `bondy.alarm.list` / `.get` fan-out.
        {bondy_alarm_api, peer_answers, 2},
        %% The `bondy.cluster.leave` safety survey. Fail-closed when spent.
        {bondy_cluster_api, survey, 2}
    ].

%% Both directions. A NEW waiting site fails because it is not declared; a
%% declared site that has gone fails because the list would otherwise rot into
%% a description of a tree that no longer exists.
the_declared_waiting_sites_are_the_ones_in_the_tree_test() ->
    {Sites, Modules, Errors} = scan(),

    %% The scan asserts its own REACH first. A beam stripped of `debug_info`,
    %% or an app file that did not parse, would otherwise make an empty tree
    %% pass this test perfectly.
    ?assertEqual([], Errors),
    ?assert(length(Modules) >= 10, {too_few_api_modules, Modules}),
    _ = [
        ?assert(lists:member(M, Modules), {not_scanned, M})
     || M <- [bondy_alarm_api, bondy_cluster_api, bondy_registry_api]
    ],

    ?assertEqual(lists:sort(waiting_sites()), lists:sort(Sites)).

%% =============================================================================
%% THE SCAN
%% =============================================================================

%% @private
%% `{Sites, ApiModules, Errors}` over every `bondy_wamp_api` implementation in
%% every bondy application on the code path.
scan() ->
    lists:foldl(fun scan_app/2, {[], [], []}, bondy_apps()).

%% @private
%% The `.app` file is read directly rather than through `application:load/1`:
%% loading publishes an application's whole `env` into the VM, and eunit shares
%% ONE VM across every test module in a run.
scan_app({AppFile, Ebin}, {Sites, Mods, Errors} = Acc) ->
    case file:consult(AppFile) of
        {ok, [{application, _, Props}]} ->
            lists:foldl(
                fun(M, A) -> scan_module(M, Ebin, A) end,
                Acc,
                proplists:get_value(modules, Props, [])
            );
        Other ->
            {Sites, Mods, [{AppFile, Other} | Errors]}
    end.

%% @private
%% A module whose abstract code cannot be read is RECORDED, never skipped: a
%% silent skip is how a handler would vanish from this check.
scan_module(Mod, Ebin, {Sites, Mods, Errors} = Acc) ->
    Beam = filename:join(Ebin, atom_to_list(Mod) ++ ".beam"),
    case beam_lib:chunks(Beam, [abstract_code]) of
        {ok, {Mod, [{abstract_code, {raw_abstract_v1, Forms}}]}} ->
            case is_api_module(Forms) of
                true -> {sites(Mod, Forms) ++ Sites, [Mod | Mods], Errors};
                false -> Acc
            end;
        {error, beam_lib, {file_error, _, enoent}} ->
            %% Listed in the `.app` but not built into this profile.
            Acc;
        Other ->
            {Sites, Mods, [{Mod, Other} | Errors]}
    end.

%% @private
is_api_module(Forms) ->
    [] =/=
        [
            B
         || {attribute, _, A, B} <- Forms,
            A == behaviour orelse A == behavior,
            B == bondy_wamp_api
        ].

%% @private
%% Keyed by FUNCTION rather than by line, so editing anything above a call site
%% does not move it out of the declared set.
sites(Mod, Forms) ->
    Blocking = blocking_callees(),
    lists:usort([
        {Mod, Name, Arity}
     || {function, _, Name, Arity, Clauses} <- Forms,
        [] =/= [C || C <- calls(Clauses), lists:member(C, Blocking)]
    ]).

%% @private
calls({call, _, {remote, _, {atom, _, M}, {atom, _, F}}, Args} = T) ->
    [{M, F, length(Args)} | calls(tuple_to_list(T))];
calls(T) when is_tuple(T) ->
    calls(tuple_to_list(T));
calls([H | T]) ->
    calls(H) ++ calls(T);
calls(_) ->
    [].

%% @private
%% Derived from the live code path rather than a directory listing, so it does
%% not depend on where eunit was run from. The ebin directory is carried along
%% because `code:which/1` answers `cover_compiled` under `rebar3 eunit` — the
%% beam ON DISK is the one holding `debug_info`.
bondy_apps() ->
    lists:usort([
        {F, D}
     || D <- code:get_path(),
        F <- filelib:wildcard(filename:join(D, "*.app")),
        lists:prefix("bondy", filename:basename(F, ".app"))
    ]).
