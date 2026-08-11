-module(bondy_oplog_origin_bans_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    %% Start with a clean ban list — other tests may have populated it.
    [
        bondy_oplog_origin_bans:unban(O)
     || #{origin := O} <- bondy_oplog_origin_bans:list()
    ],
    ok.

cleanup(_) ->
    [
        bondy_oplog:stop_instance(I)
     || I <- bondy_oplog:list_instances()
    ],
    [
        bondy_oplog_origin_bans:unban(O)
     || #{origin := O} <- bondy_oplog_origin_bans:list()
    ],
    ok.

bans_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun ban_and_unban/0,
        fun banned_origin_rejected_at_append_remote/0,
        fun ban_applies_across_instances/0
    ]}.

retirement_test_() ->
    {setup, fun setup_retirement/0, fun cleanup_retirement/1, [
        fun retire_is_a_ban/0,
        fun retire_refuses_unban/0,
        fun retire_survives_restart/0,
        fun merge_retired_is_a_union/0,
        fun retire_without_path_is_refused/0,
        fun a_failed_persist_enforces_nothing/0,
        fun a_successful_write_restores_persistence/0
    ]}.

%% PERSIST BEFORE ENFORCE. `proofs/tla/OriginRetirementSet.tla` with
%% `RetirementDurable = FALSE` — a replica may enforce a retirement it has
%% not persisted — violates `SpuriousGap` in 9 steps: the reap that
%% retirement licensed is already gone from the frontier when the restart
%% forgets the retirement, so the node reads a peer's surviving entry as a
%% deficit it can never fill. A failed write must therefore leave the origin
%% unbanned, unretired, and absent from the replicated set.
a_failed_persist_enforces_nothing() ->
    O = <<"orig-persist-fail">>,
    %% The preceding case leaves the env unset, so re-establish a path of
    %% this case's own rather than depend on ordering.
    Path = set_retirement_path(),
    %% Make the write fail: a directory where the temp file must go, so
    %% `persist/2` cannot open it.
    ok = filelib:ensure_dir(Path),
    ok = file:make_dir(<<Path/binary, ".tmp">>),
    ?assertEqual(
        {error, not_persistent},
        bondy_oplog_origin_bans:retire(O, decommissioned)
    ),
    ?assertNot(bondy_oplog_origin_bans:is_retired(O)),
    ?assertNot(bondy_oplog_origin_bans:is_banned(O)),
    ?assertNot(lists:member(O, bondy_oplog_origin_bans:retired())),
    %% Reaping is disabled while the node cannot persist.
    ?assertNot(bondy_oplog_origin_bans:is_persistent()),
    ok = file:del_dir(<<Path/binary, ".tmp">>).

%% The alarm and the reap gate must agree in BOTH directions: a successful
%% write is the evidence the path works, so it lifts the earlier failure.
%% Otherwise the alarm clears while reaping stays disabled for the life of
%% the node, which reads as recovery that has not happened.
a_successful_write_restores_persistence() ->
    O = <<"orig-persist-recover">>,
    ?assertNot(bondy_oplog_origin_bans:is_persistent()),
    ?assertEqual(ok, bondy_oplog_origin_bans:retire(O, decommissioned)),
    ?assert(bondy_oplog_origin_bans:is_persistent()),
    ?assert(bondy_oplog_origin_bans:is_retired(O)),
    %% And it is genuinely durable.
    ok = restart_bans(),
    ?assert(bondy_oplog_origin_bans:is_retired(O)),
    ?assert(bondy_oplog_origin_bans:is_persistent()).

ban_and_unban() ->
    O = <<"orig-test-1">>,
    ?assertEqual(false, bondy_oplog_origin_bans:is_banned(O)),
    ok = bondy_oplog_origin_bans:ban(O, malicious),
    ?assert(bondy_oplog_origin_bans:is_banned(O)),
    [#{origin := O, reason := malicious}] =
        bondy_oplog_origin_bans:list(),
    ok = bondy_oplog_origin_bans:unban(O),
    ?assertEqual(false, bondy_oplog_origin_bans:is_banned(O)).

banned_origin_rejected_at_append_remote() ->
    Id = mk_id(),
    {ok, _} = bondy_oplog:start_instance(Id),
    Origin = <<"orig-banned-aaaa">>,
    Event = bondy_oplog_event:new(
        bondy_oplog_event:key(1, Origin, 1), op, undefined
    ),
    ok = bondy_oplog_origin_bans:ban(Origin, manual),
    ?assertEqual(
        {error, banned_origin},
        bondy_oplog:append_remote(Id, Event)
    ),
    ?assertEqual(0, bondy_oplog:size(Id)),
    %% Lifting the ban allows the event through.
    ok = bondy_oplog_origin_bans:unban(Origin),
    ?assertEqual(
        ok,
        bondy_oplog:append_remote(Id, Event)
    ),
    ?assertEqual(1, bondy_oplog:size(Id)),
    ok = bondy_oplog:stop_instance(Id).

ban_applies_across_instances() ->
    %% A single ban affects every running instance — that's the whole
    %% point of the node-shared list.
    IdA = mk_id(),
    IdB = mk_id(),
    {ok, _} = bondy_oplog:start_instance(IdA),
    {ok, _} = bondy_oplog:start_instance(IdB),
    Origin = <<"orig-everywhere-bb">>,
    EventA = bondy_oplog_event:new(
        bondy_oplog_event:key(1, Origin, 1), opA, undefined
    ),
    EventB = bondy_oplog_event:new(
        bondy_oplog_event:key(1, Origin, 2), opB, undefined
    ),
    ok = bondy_oplog_origin_bans:ban(Origin, manual),
    ?assertEqual(
        {error, banned_origin},
        bondy_oplog:append_remote(IdA, EventA)
    ),
    ?assertEqual(
        {error, banned_origin},
        bondy_oplog:append_remote(IdB, EventB)
    ),
    ok = bondy_oplog:stop_instance(IdA),
    ok = bondy_oplog:stop_instance(IdB).

%% The retirement set is only writable with a `retirement_path`, so these
%% cases configure one and restart the gen_server to pick it up. The path
%% carries the OS pid: parallel test runs share /tmp and would otherwise
%% load each other's set.
setup_retirement() ->
    {ok, _} = application:ensure_all_started(bondy_db),
    Dir = filename:join([
        "/tmp",
        "bondy_oplog_retirement_test_" ++ os:getpid()
    ]),
    Path = filename:join(Dir, "retired"),
    _ = file:del_dir_r(Dir),
    ok = application:set_env(bondy_oplog, retirement_path, Path),
    ok = restart_bans(),
    #{dir => Dir, path => Path}.

cleanup_retirement(#{dir := Dir}) ->
    ok = application:unset_env(bondy_oplog, retirement_path),
    _ = file:del_dir_r(Dir),
    ok = restart_bans(),
    ok.

%% Bounce the gen_server so `init/1` re-reads the env and reloads the set
%% from disk. The ETS table dies with the process, which is exactly the
%% restart the persistence requirement exists for.
restart_bans() ->
    _ = supervisor:terminate_child(bondy_oplog_sup, bondy_oplog_origin_bans),
    {ok, _} = supervisor:restart_child(
        bondy_oplog_sup, bondy_oplog_origin_bans
    ),
    ok.

retire_is_a_ban() ->
    O = <<"orig-retired-1">>,
    ?assertEqual(false, bondy_oplog_origin_bans:is_retired(O)),
    ok = bondy_oplog_origin_bans:retire(O, decommissioned),
    ?assert(bondy_oplog_origin_bans:is_retired(O)),
    %% A retirement is a ban, so the existing append_remote gate covers it
    %% with no second lookup on the hot path.
    ?assert(bondy_oplog_origin_bans:is_banned(O)),
    ?assertEqual([O], bondy_oplog_origin_bans:retired()),
    %% An ordinary ban is NOT a retirement: reaping must not act on it.
    B = <<"orig-merely-banned">>,
    ok = bondy_oplog_origin_bans:ban(B, malicious),
    ?assert(bondy_oplog_origin_bans:is_banned(B)),
    ?assertEqual(false, bondy_oplog_origin_bans:is_retired(B)).

retire_refuses_unban() ->
    O = <<"orig-retired-2">>,
    ok = bondy_oplog_origin_bans:retire(O, decommissioned),
    ?assertEqual({error, retired}, bondy_oplog_origin_bans:unban(O)),
    ?assert(bondy_oplog_origin_bans:is_retired(O)).

retire_survives_restart() ->
    O = <<"orig-retired-3">>,
    ok = bondy_oplog_origin_bans:retire(O, decommissioned),
    ?assert(bondy_oplog_origin_bans:is_persistent()),
    ok = restart_bans(),
    ?assert(bondy_oplog_origin_bans:is_retired(O)),
    ?assert(bondy_oplog_origin_bans:is_banned(O)).

merge_retired_is_a_union() ->
    A = <<"orig-union-a">>,
    B = <<"orig-union-b">>,
    ok = bondy_oplog_origin_bans:retire(A, decommissioned),
    ok = bondy_oplog_origin_bans:merge_retired([A, B]),
    ?assert(bondy_oplog_origin_bans:is_retired(A)),
    ?assert(bondy_oplog_origin_bans:is_retired(B)),
    %% Monotone and idempotent: re-applying any subset changes nothing.
    Before = bondy_oplog_origin_bans:retired(),
    ok = bondy_oplog_origin_bans:merge_retired([B]),
    ok = bondy_oplog_origin_bans:merge_retired([]),
    ?assertEqual(Before, bondy_oplog_origin_bans:retired()).

retire_without_path_is_refused() ->
    ok = application:unset_env(bondy_oplog, retirement_path),
    ok = restart_bans(),
    ?assertEqual(false, bondy_oplog_origin_bans:is_persistent()),
    ?assertEqual(
        {error, not_persistent},
        bondy_oplog_origin_bans:retire(<<"orig-nopath">>, decommissioned)
    ),
    ?assertEqual(
        {error, not_persistent},
        bondy_oplog_origin_bans:merge_retired([<<"orig-nopath">>])
    ),
    ?assertEqual(false, bondy_oplog_origin_bans:is_retired(<<"orig-nopath">>)).

%% Points `retirement_path` at this run's own directory and reloads, so a
%% case is independent of what the previous one left in the env.
set_retirement_path() ->
    Dir = filename:join([
        "/tmp",
        "bondy_oplog_retirement_test_" ++ os:getpid()
    ]),
    Path = unicode:characters_to_binary(filename:join(Dir, "retired")),
    ok = application:set_env(bondy_oplog, retirement_path, Path),
    ok = restart_bans(),
    Path.

mk_id() ->
    list_to_binary(
        "obt_" ++
            integer_to_list(
                erlang:unique_integer([positive, monotonic])
            )
    ).
