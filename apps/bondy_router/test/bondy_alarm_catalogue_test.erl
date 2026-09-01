%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% The coverage contract for `bondy_alarm_catalogue`.
%%
%% A catalogue that is merely written down rots: the tenth producer invents an
%% id, nobody notices, and the table quietly becomes documentation of the past.
%% So this reads the `debug_info` of every module in every Bondy application,
%% finds every `set_alarm` / `clear_alarm` call, and checks the two directions
%% that matter:
%%
%%   - every id a producer raises is declared, and
%%   - every declared entry has a producer.
%%
%% The scan works on compiled abstract code rather than source text because two
%% producers name their alarm through a macro (`?OVERSIZED_ALARM_ID`,
%% `?PERSIST_ALARM_ID`) — already expanded in the beam, invisible to a grep.
%%
%% WHAT IT DOES NOT COVER. An id built in a variable cannot be resolved from
%% the call site; `unresolvable_sites/0` names those explicitly, with the id
%% each one raises read from its source, so a NEW unresolvable site fails the
%% test rather than disappearing from it. And the scan is scoped to
%% applications whose name begins with `bondy`: no dependency in this build
%% raises an alarm (checked by grepping `_build/default/lib/*/src` on
%% 2026-08-30), and `os_mon` — whose `system_memory_high_watermark` would
%% otherwise be an undeclared OTP alarm — is in no `.app.src` and not in the
%% release's application list, so it never starts.
-module(bondy_alarm_catalogue_test).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% FIXTURE
%% =============================================================================

catalogue_test_() ->
    {setup, fun scan/0, fun(Scan) ->
        [
            {"the scan found the known producers", ?_test(scan_is_sound(Scan))},
            {"every raised id is declared", ?_test(sites_are_declared(Scan))},
            {"the unresolvable sites are exactly the declared ones",
                ?_test(unresolvable_are_declared(Scan))},
            {"every entry has a producer",
                ?_test(entries_have_producers(Scan))},
            {"declared detail keys are delivered",
                ?_test(declared_detail_keys_are_delivered(Scan))},
            {"every task in a runbook is a catalogued task",
                ?_test(runbook_tasks_are_catalogued())},
            {"every realm-class alarm carries realm_uri",
                ?_test(realm_class_alarms_carry_realm_uri(Scan))},
            {"every config_keys entry names a real setting",
                ?_test(config_keys_resolve())},
            {"every readiness_via names a real function",
                ?_test(readiness_via_resolves())},
            {"every observe_with reference resolves",
                ?_test(observe_refs_resolve(Scan))},
            {"no observe_with reference is a task",
                ?_test(no_observe_ref_is_a_task())},
            {"entries are well formed", ?_test(entries_are_well_formed())},
            {"entry heads are distinct", ?_test(entry_heads_are_distinct())},
            {"lookup is arity sensitive", ?_test(lookup_is_arity_sensitive())},
            {"lookup finds a parameterised id",
                ?_test(lookup_finds_a_parameterised_id())}
        ]
    end}.

%% Call sites whose alarm id is bound to a variable, so the walker cannot read
%% it from the call. Each maps to the id it actually raises, read from the
%% source — this is the one claim in this module that a human verified rather
%% than the machine, so it is small and cited on purpose.
unresolvable_sites() ->
    #{
        %% `bondy_mcp_gateway:536-539` builds
        %% `{bondy_mcp_name_collision, RealmUri, maps:get(name, C)}` in a list
        %% comprehension and both raises and clears it through the variable.
        {bondy_mcp_gateway, reconcile_alarms, 3} =>
            {bondy_mcp_name_collision, '_', '_'}
    }.

%% =============================================================================
%% TESTS
%% =============================================================================

%% Everything below is vacuous if the scan found nothing — a wrong code path or
%% a beam stripped of `debug_info` would make an empty catalogue pass. So the
%% scan asserts its own reach first: no module failed to yield abstract code,
%% and three producers with three DIFFERENT id spellings (bare atom, macro,
%% `{Head, Discriminator}` pair) are present.
scan_is_sound(#{errors := Errors, sites := Sites}) ->
    ?assertEqual([], Errors),
    Found = [{M, F, A} || {M, F, A, _Kind, _Id, _Keys, _Opts} <- Sites],
    ?assert(lists:member({bondy_namespace_catalog, set_main_failed, 1}, Found)),
    ?assert(
        lists:member({bondy_oplog_responder, set_oversized_alarm, 0}, Found)
    ),
    ?assert(
        lists:member(
            {bondy_http_connector_http_pool, set_service_down_alarm, 1}, Found
        )
    ),
    %% Nine producers today across raise and clear; the count is a floor, not
    %% an assertion about the exact number.
    ?assert(length(Sites) >= 15).

sites_are_declared(#{sites := Sites}) ->
    Undeclared = [
        {M, F, A, Id}
     || {M, F, A, _Kind, {ok, Id}, _Keys, _Opts} <- Sites,
        bondy_alarm_catalogue:lookup(Id) == error
    ],
    ?assertEqual([], Undeclared).

unresolvable_are_declared(#{sites := Sites}) ->
    Found = lists:usort([
        {M, F, A}
     || {M, F, A, _Kind, unresolved, _Keys, _Opts} <- Sites
    ]),
    ?assertEqual(lists:sort(maps:keys(unresolvable_sites())), Found).

%% The other direction: an entry for an alarm nothing raises any more is stale
%% documentation, and the catalogue is meant to be the opposite of that.
entries_have_producers(#{sites := Sites}) ->
    Raised =
        [Id || {_, _, _, _, {ok, Id}, _, _} <- Sites] ++
            maps:values(unresolvable_sites()),
    Orphans = [
        Pattern
     || #{id_pattern := Pattern} = E <- bondy_alarm_catalogue:list(),
        not lists:any(
            fun(Id) -> bondy_alarm_catalogue:lookup(Id) == {ok, E} end, Raised
        )
    ],
    ?assertEqual([], Orphans).

%% `detail_keys` is the catalogue's promise about what an alarm CARRIES, and
%% an agent parsing `bondy.alarm.list` reads it to know which fields to expect
%% under `details`. Nothing checked it until this case: all three entries with
%% a non-empty `detail_keys` had producers passing exactly those keys as the
%% alarm's DESCRIPTION, leaving `details` empty on every raise (measured
%% 2026-08-30 by driving `bondy_mail_relay`'s term through the handler).
%%
%% Checks one direction only: every declared key must be delivered. A producer
%% passing MORE than it declares is not failed here — the agent under-uses the
%% alarm rather than mis-parsing it — so this case would not catch an
%% undeclared detail key.
declared_detail_keys_are_delivered(#{sites := Sites}) ->
    Checked = [
        {M, F, A, Id, Declared, Delivered}
     || {M, F, A, set, {ok, Id}, Delivered, _Opts} <- Sites,
        {ok, #{detail_keys := Declared}} <- [bondy_alarm_catalogue:lookup(Id)],
        Declared =/= []
    ],
    Missing = [
        {M, F, A, Id, Declared, Delivered}
     || {M, F, A, Id, Declared, Delivered} <- Checked,
        not delivers(Delivered, Declared)
    ],
    ?assertEqual([], Missing),
    %% Vacuity guard: the comprehension above passes trivially if the scanner
    %% stops resolving raise sites or the catalogue stops declaring any keys.
    ?assertEqual(
        5,
        length(Checked),
        "the entries with non-empty detail_keys are no longer being checked"
    ).

%% @private
delivers({ok, Delivered}, Declared) -> Declared -- Delivered == [];
delivers(_, _) -> false.

%% The runbook join (design §9): what an agent may look at, and what it may do.
%% A dangling reference is worse than an absent one — an agent sent at a
%% procedure that is not there has to improvise, which is the behaviour the
%% catalogue exists to remove.
runbook_tasks_are_catalogued() ->
    Dangling = [
        {Pattern, T}
     || #{id_pattern := Pattern, tasks := Ts} <- bondy_alarm_catalogue:list(),
        T <- Ts,
        bondy_task_catalogue:lookup(T) == error
    ],
    ?assertEqual([], Dangling),
    %% Vacuity guard: this checks nothing while no entry names a task.
    ?assert(
        length([
            x
         || #{tasks := [_ | _]} <- bondy_alarm_catalogue:list()
        ]) >= 2
    ).

%% `bondy_docs`' alarm reference states that `realm_uri` is "present on
%% `class = realm` alarms; names the affected tenant". Nothing checked it, and
%% one of the three realm-class entries did not deliver it: the MCP name
%% collision raised through the bare OTP 2-tuple, so a consumer following that
%% rule got nothing and had to parse the id instead (found 2026-09-01).
%%
%% Checks the RAISE sites only. A `clear` carries no options and needs none.
realm_class_alarms_carry_realm_uri(#{sites := Sites}) ->
    Realm = [
        Pattern
     || #{id_pattern := Pattern, class := realm} <- bondy_alarm_catalogue:list()
    ],
    %% Vacuity guard: this checks nothing if no entry is realm-class.
    ?assert(length(Realm) >= 3),
    %% An id built from variables reads as `unresolved`, so the site is
    %% resolved through `unresolvable_sites/0` instead. This is not a corner:
    %% the MCP name collision is the alarm this check was written for, and it
    %% is the one site whose id cannot be read statically — checking only the
    %% resolvable ones would have passed while the defect stood.
    Sets = [
        {M, F, A, resolve_id({M, F, A}, Id), Opts}
     || {M, F, A, set, Id, _Keys, Opts} <- Sites
    ],
    Checked = [
        S
     || {_, _, _, Id, _} = S <- Sets,
        Id =/= unresolved,
        lists:any(fun(P) -> bondy_alarm_catalogue:matches(P, Id) end, Realm)
    ],
    Missing = [S || {_, _, _, _, Opts} = S <- Checked, not delivers(Opts)],
    ?assertEqual([], Missing),
    %% The other half: the check is worthless if the scan stopped resolving
    %% the realm-class raise sites at all. One per realm-class entry.
    ?assertEqual(3, length(Checked)).

%% @private
resolve_id(MFA, unresolved) -> maps:get(MFA, unresolvable_sites(), unresolved);
resolve_id(_, {ok, Id}) -> Id.

%% @private
delivers({ok, Keys}) -> lists:member(realm_uri, Keys);
delivers(_) -> false.

%% Every `config_keys` entry must name a setting the schema actually declares.
%% `observe_with` and `tasks` were resolved from the start and this was not, so
%% a renamed or removed key would have sent an operator to a knob that no
%% longer exists — at the one moment they are least able to absorb it. Key rot
%% is not hypothetical in this tree.
%%
%% A `$name` / `$service` segment is cuttlefish's variable, matched as a
%% wildcard against the mapping's own declaration, which carries the same
%% spelling.
config_keys_resolve() ->
    Declared = schema_mappings(),
    ?assert(length(Declared) >= 200),
    Keys = lists:usort(
        lists:append([
            K
         || #{config_keys := K} <- bondy_alarm_catalogue:list()
        ])
    ),
    ?assert(length(Keys) >= 8),
    Dangling = [K || K <- Keys, not lists:member(K, Declared)],
    ?assertEqual([], Dangling).

%% The same discipline for `readiness_via`, which names the mechanism that
%% reports readiness when the alarm does not. A dangling one tells an operator
%% to look at a function that is not there.
readiness_via_resolves() ->
    Refs = [
        R
     || #{readiness_via := R} <- bondy_alarm_catalogue:list()
    ],
    ?assert(length(Refs) >= 1),
    Bad = [R || R <- Refs, not is_exported_mfa(R)],
    ?assertEqual([], Bad).

%% @private
%% `<<"mod:fun/arity">>` resolved against the module's own export list.
is_exported_mfa(Ref) ->
    case binary:split(Ref, [~":", ~"/"], [global]) of
        [M, F, A] ->
            try
                Mod = binary_to_existing_atom(M, utf8),
                Fun = binary_to_existing_atom(F, utf8),
                _ = code:ensure_loaded(Mod),
                erlang:function_exported(
                    Mod, Fun, binary_to_integer(A)
                )
            catch
                _:_ -> false
            end;
        _ ->
            false
    end.

%% @private
%% Every `{mapping, Key, _, _}` in the schema files, read as text rather than
%% through cuttlefish: the schemas are not compiled into this VM and parsing
%% them here would be a second implementation of something only this check
%% needs.
schema_mappings() ->
    Files = schema_files(),
    %% A missing schema directory must FAIL rather than report every key
    %% dangling or, worse, none — `code:lib_dir/1` answers a RELATIVE path
    %% under `rebar3 eunit`, which is what made the first version of this
    %% resolve to nothing.
    ?assert(Files =/= []),
    lists:usort(lists:append([mappings_of(F) || F <- Files])).

%% @private
%% Walks UP from the application's own ebin rather than trusting the working
%% directory eunit happens to run in — the same reason `bondy_apps/0` derives
%% its paths from `code:get_path/0`.
schema_files() ->
    walk_up(filename:absname(code:lib_dir(bondy_router)), 8).

%% @private
walk_up(_, 0) ->
    [];
walk_up(Dir, N) ->
    case filelib:wildcard(filename:join([Dir, "schema", "*.schema"])) of
        [] ->
            Parent = filename:dirname(Dir),
            case Parent == Dir of
                true -> [];
                false -> walk_up(Parent, N - 1)
            end;
        Files ->
            Files
    end.

%% @private
mappings_of(File) ->
    case file:read_file(File) of
        {ok, Bin} ->
            case
                re:run(
                    Bin,
                    "\\{mapping,\\s*\"([^\"]+)\"",
                    [global, {capture, all_but_first, binary}]
                )
            of
                {match, Groups} -> lists:append(Groups);
                nomatch -> []
            end;
        _ ->
            []
    end.

%% A `procedure` reference must be a live procedure, not one of the seven that
%% reply `no_such_procedure`; a `metric` reference must be a name something
%% actually declares through `bondy_metrics:declare/1`.
observe_refs_resolve(#{procedures := Procs, metrics := Metrics}) ->
    Bad = [
        {Pattern, Sig}
     || #{id_pattern := Pattern, observe_with := Sigs} <-
            bondy_alarm_catalogue:list(),
        Sig <- Sigs,
        not resolves(Sig, Procs, Metrics)
    ],
    ?assertEqual([], Bad),
    %% Vacuity guards, one per reference kind: a scan that stopped finding either
    %% would make the check above pass by finding nothing to check.
    ?assert(map_size(Procs) >= 100),
    ?assert(length(Metrics) >= 50),
    ?assert(length([x || #{kind := metric} <- all_observe_refs()]) >= 2),
    ?assert(length([x || #{kind := procedure} <- all_observe_refs()]) >= 2).

%% The safety half of the join. `observe_with` is what an agent may look at
%% WITHOUT
%% sanction, so a mutating procedure must never appear as one: the task
%% catalogue is the only place an action may be named, and it carries the
%% `impact` an agent's policy is written against. A procedure that is both
%% would let an agent act while believing it was only looking.
no_observe_ref_is_a_task() ->
    Acting = [
        Ref
     || #{kind := procedure, ref := Ref} <- all_observe_refs(),
        bondy_task_catalogue:lookup(Ref) =/= error
    ],
    ?assertEqual([], Acting).

entries_are_well_formed() ->
    lists:foreach(
        fun(E) ->
            ?assert(maps:is_key(id_pattern, E)),
            ?assert(is_list(maps:get(observe_with, E))),
            ?assert(is_list(maps:get(tasks, E))),
            ?assert(
                lists:all(
                    fun(#{kind := K, ref := R}) ->
                        (K == procedure andalso is_binary(R)) orelse
                            (K == metric andalso is_atom(R))
                    end,
                    maps:get(observe_with, E)
                )
            ),
            ?assert(
                lists:member(maps:get(severity, E), [warning, major, critical])
            ),
            ?assert(
                lists:member(
                    maps:get(class, E), [node, cluster, realm, integration]
                )
            ),
            ?assert(is_boolean(maps:get(affects_ready, E))),
            ?assert(is_binary(maps:get(summary, E))),
            ?assert(lists:all(fun is_atom/1, maps:get(detail_keys, E))),
            ?assert(lists:all(fun is_binary/1, maps:get(config_keys, E)))
        end,
        bondy_alarm_catalogue:list()
    ).

%% A duplicated entry would be shadowed by `lookup/1` returning the first
%% match, so the second copy could drift unnoticed.
entry_heads_are_distinct() ->
    Heads = [head(P) || #{id_pattern := P} <- bondy_alarm_catalogue:list()],
    ?assertEqual(lists:usort(Heads), lists:sort(Heads)).

%% Arity is part of the pattern. Without this, the three-element MCP collision
%% entry would answer for any two-element id sharing its head.
lookup_is_arity_sensitive() ->
    ?assertMatch(
        {ok, _},
        bondy_alarm_catalogue:lookup(
            {bondy_mcp_name_collision, <<"realm">>, <<"name">>}
        )
    ),
    ?assertEqual(
        error, bondy_alarm_catalogue:lookup({bondy_mcp_name_collision, <<"r">>})
    ),
    ?assertEqual(error, bondy_alarm_catalogue:lookup(bondy_mcp_name_collision)).

%% The point of the `'_'` wildcard: every service collapses onto one entry.
lookup_finds_a_parameterised_id() ->
    {ok, A} = bondy_alarm_catalogue:lookup(
        {http_connector_service_down, <<"billing">>}
    ),
    {ok, B} = bondy_alarm_catalogue:lookup(
        {http_connector_service_down, <<"shipping">>}
    ),
    ?assertEqual(A, B),
    ?assertEqual(integration, maps:get(class, A)),
    ?assertEqual(
        error, bondy_alarm_catalogue:lookup({no_such_alarm, <<"billing">>})
    ).

%% =============================================================================
%% PRIVATE — the scan
%% =============================================================================

%% @private
scan() ->
    Acc = lists:foldl(
        fun scan_app/2, #{sites => [], errors => []}, bondy_apps()
    ),
    %% The procedure scan is BORROWED from `bondy_task_catalogue_test` rather
    %% than written twice. Two scanners over the same abstract code would drift,
    %% and the one that drifted would go quiet rather than fail — the whole
    %% failure mode these tests exist to prevent.
    #{procs := Procs} = bondy_task_catalogue_test:scan(),
    Acc#{procedures => Procs, metrics => declared_metrics()}.

%% @private
%% Derived from the live code path rather than from a directory listing, so it
%% does not depend on the working directory eunit happens to run in. The ebin
%% directory is carried along because `code:which/1` answers `cover_compiled`
%% under `rebar3 eunit` — the beam ON DISK still holds the `debug_info`, and
%% that is the file this reads.
bondy_apps() ->
    lists:usort([
        {F, D}
     || D <- code:get_path(),
        F <- filelib:wildcard(filename:join(D, "*.app")),
        lists:prefix("bondy", filename:basename(F, ".app"))
    ]).

%% @private
%% The `.app` file is read directly rather than through `application:load/1` +
%% `application:get_key/2`. Loading an application publishes its whole `env`
%% into the VM, and eunit shares ONE VM across every test module in a run, so
%% loading sixteen applications here would silently change what
%% `application:get_env/2` answers for every other module in the suite. A file
%% read has no such reach.
scan_app({AppFile, Ebin}, #{errors := Errors} = Acc) ->
    case file:consult(AppFile) of
        {ok, [{application, _, Props}]} ->
            Mods = proplists:get_value(modules, Props, []),
            lists:foldl(fun(M, A) -> scan_module(M, Ebin, A) end, Acc, Mods);
        Other ->
            Acc#{errors := [{AppFile, Other} | Errors]}
    end.

%% @private
%% A module whose abstract code cannot be read is recorded, never skipped: a
%% silent skip is how a producer would vanish from this check.
scan_module(Mod, Ebin, #{sites := Sites, errors := Errors} = Acc) ->
    Beam = filename:join(Ebin, atom_to_list(Mod) ++ ".beam"),
    case beam_lib:chunks(Beam, [abstract_code]) of
        {ok, {Mod, [{abstract_code, {raw_abstract_v1, Forms}}]}} ->
            New = lists:flatmap(fun(F) -> sites(Mod, F) end, Forms),
            Acc#{sites := Sites ++ New};
        Other ->
            Acc#{errors := [{Mod, Other} | Errors]}
    end.

%% @private
%% Keyed by function rather than by line, so editing anything above a call
%% site does not move it out of `unresolvable_sites/0`.
sites(Mod, {function, _, Name, Arity, Clauses}) ->
    Env = map_bindings(Clauses, #{}),
    [
        {Mod, Name, Arity, Kind, Id, detail_keys(Opts, Env), opt_keys(Opts)}
     || {Kind, Id, Opts} <- calls(Clauses, [])
    ];
sites(_, _) ->
    [].

%% @private
calls({call, _, {remote, _, {atom, _, M}, {atom, _, F}}, Args} = T, Acc) ->
    Acc1 =
        case site(M, F, Args) of
            {ok, Site} -> [Site | Acc];
            none -> Acc
        end,
    children(T, Acc1);
calls(T, Acc) when is_tuple(T) ->
    children(T, Acc);
calls([H | T], Acc) ->
    calls(T, calls(H, Acc));
calls(_, Acc) ->
    Acc.

%% @private
children(T, Acc) ->
    lists:foldl(fun calls/2, Acc, tuple_to_list(T)).

%% @private
site(M, set_alarm, [Arg]) when M == alarm_handler; M == bondy_alarm_handler ->
    {ok, {set, id_of_alarm(Arg), opts_of_alarm(Arg)}};
site(bondy_alarm_handler, set_alarm, [Arg, Opts]) ->
    {ok, {set, id_of_alarm(Arg), Opts}};
site(M, clear_alarm, [Arg]) when M == alarm_handler; M == bondy_alarm_handler ->
    {ok, {clear, pattern(Arg), none}};
site(_, _, _) ->
    none.

%% @private
%% `set_alarm/1` takes either the OTP `{Id, Description}` pair or Bondy's
%% `{Id, Description, Opts}` triple — `alarm_handler:set_alarm/1` is
%% `gen_event:notify(alarm_handler, {set_alarm, Alarm})` for any term
%% (sasl-4.4 `alarm_handler.erl:103`), so the triple reaches
%% `bondy_alarm_handler:handle_event/2` unchanged. `clear_alarm/1` takes the
%% id itself.
id_of_alarm({tuple, _, [IdExpr, _Desc]}) -> pattern(IdExpr);
id_of_alarm({tuple, _, [IdExpr, _Desc, _Opts]}) -> pattern(IdExpr);
id_of_alarm(_) -> unresolved.

%% @private
opts_of_alarm({tuple, _, [_Id, _Desc, Opts]}) -> Opts;
opts_of_alarm(_) -> none.

%% @private
%% The literal TOP-LEVEL keys of the options map a raise site passes, or
%% `none` when it passes no options map at all. Unlike `detail_keys/2` this
%% does not follow a variable binding: every producer that passes options
%% writes the map inline at the call, and a site that stopped doing so should
%% fail the check below rather than be resolved through a guess.
opt_keys(none) -> none;
opt_keys({map, _, Fields}) -> {ok, literal_keys(Fields)};
opt_keys(_) -> unknown.

%% @private
%% The literal keys of the `details` map a raise site passes, or `unknown` when
%% they cannot be read statically. The producers bind the map to a variable
%% first, so the value is resolved through `Env`; Erlang is single-assignment,
%% so a name bound exactly once in the function has exactly one map behind it,
%% and `map_bindings/2` drops any name bound more than once rather than
%% guessing.
detail_keys(none, _Env) ->
    none;
detail_keys({map, _, Fields}, Env) ->
    case assoc(details, Fields) of
        {ok, {map, _, DFields}} -> {ok, literal_keys(DFields)};
        {ok, {var, _, V}} -> maps:get(V, Env, unknown);
        _ -> unknown
    end;
detail_keys(_, _Env) ->
    unknown.

%% @private
assoc(Key, Fields) ->
    case
        [
            V
         || {F, _, {atom, _, K}, V} <- Fields,
            F == map_field_assoc orelse F == map_field_exact,
            K == Key
        ]
    of
        [V] -> {ok, V};
        _ -> error
    end.

%% @private
literal_keys(Fields) ->
    lists:usort([
        K
     || {F, _, {atom, _, K}, _} <- Fields,
        F == map_field_assoc orelse F == map_field_exact
    ]).

%% @private
%% `Var = #{...}` bindings in a function body. A map UPDATE (`V#{k => x}`) is a
%% 4-element `{map, Anno, Expr, Assocs}` form and does not match the 3-element
%% literal here, which is what keeps `?LOG_WARNING(Info#{description => D})`
%% from being read as a rebinding of `Info`.
map_bindings({match, _, {var, _, V}, {map, _, Fields}}, Env) ->
    case maps:is_key(V, Env) of
        true -> Env#{V := unknown};
        false -> Env#{V => {ok, literal_keys(Fields)}}
    end;
map_bindings(T, Env) when is_tuple(T) ->
    lists:foldl(fun map_bindings/2, Env, tuple_to_list(T));
map_bindings([H | T], Env) ->
    map_bindings(T, map_bindings(H, Env));
map_bindings(_, Env) ->
    Env.

%% @private
%% A literal element is kept and a computed one becomes `'_'`, which is exactly
%% the shape `bondy_alarm_catalogue:lookup/1` matches against — so a producer
%% whose id is more general than its entry (a variable where the entry names a
%% constant) fails rather than passing.
pattern({atom, _, A}) ->
    {ok, A};
pattern({tuple, _, Elems}) ->
    {ok, list_to_tuple([element_pattern(E) || E <- Elems])};
pattern(_) ->
    unresolved.

%% @private
element_pattern({atom, _, A}) -> A;
element_pattern({integer, _, I}) -> I;
element_pattern(_) -> '_'.

%% @private
head(P) when is_tuple(P) -> element(1, P);
head(P) -> P.

%% @private
all_observe_refs() ->
    lists:append([
        S
     || #{observe_with := S} <- bondy_alarm_catalogue:list()
    ]).

%% @private
resolves(#{kind := procedure, ref := Ref}, Procs, _) ->
    maps:get(Ref, Procs, missing) == implemented;
resolves(#{kind := metric, ref := Ref}, _, Metrics) ->
    lists:member(Ref, Metrics);
resolves(_, _, _) ->
    false.

%% @private
%% Every name passed to `bondy_metrics:declare/1` anywhere in the tree, read
%% from abstract code rather than from the runtime registry: eunit does not
%% start the applications that declare them, so an ETS read here would answer
%% empty and make every metric reference look invalid.
%%
%% Metrics exported directly by a Prometheus collector (`bondy_alarm_active`,
%% `bondy_alarms`, `bondy_node_ready` in `bondy_prometheus_db`) do NOT go
%% through `declare/1` and are therefore not nameable here. That is a
%% stated limit, not an oversight.
declared_metrics() ->
    lists:usort(
        lists:append([
            metrics_of(Beam)
         || {_, Ebin} <- bondy_apps(),
            Beam <- filelib:wildcard(filename:join(Ebin, "*.beam"))
        ])
    ).

%% @private
metrics_of(Beam) ->
    case beam_lib:chunks(Beam, [abstract_code]) of
        {ok, {_, [{abstract_code, {raw_abstract_v1, Forms}}]}} ->
            declares(Forms, []);
        _ ->
            []
    end.

%% @private
declares(
    {call, _, {remote, _, {atom, _, bondy_metrics}, {atom, _, declare}}, [Arg]} =
        T,
    Acc
) ->
    declares_children(T, metric_name(Arg) ++ Acc);
declares(T, Acc) when is_tuple(T) ->
    declares_children(T, Acc);
declares(L, Acc) when is_list(L) ->
    lists:foldl(fun declares/2, Acc, L);
declares(_, Acc) ->
    Acc.

%% @private
declares_children(T, Acc) ->
    lists:foldl(fun declares/2, Acc, tuple_to_list(T)).

%% @private
metric_name({map, _, Fields}) ->
    [
        N
     || {F, _, {atom, _, name}, {atom, _, N}} <- Fields,
        F == map_field_assoc orelse F == map_field_exact
    ];
metric_name(_) ->
    [].
