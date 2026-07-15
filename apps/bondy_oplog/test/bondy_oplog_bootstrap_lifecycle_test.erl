%% Unit tests for bondy_oplog_bootstrap_lifecycle (PR-1 / catalogue
%% expansion plan §2).
%%
%% The lifecycle module is exercised here in isolation. Integration
%% with the applier (the gate) and the sync-session (the transition)
%% is exercised in bondy_oplog_bootstrap_lifecycle_e2e_test.

-module(bondy_oplog_bootstrap_lifecycle_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_oplog.hrl").

-define(MODL, bondy_oplog_bootstrap_lifecycle).

%% =============================================================================
%% Ephemeral instance defaults
%% =============================================================================

ephemeral_defaults_live_test() ->
    H = ?MODL:open(<<"eph1">>, #{}),
    ?assertEqual(live, ?MODL:state(H)),
    ?assert(?MODL:is_live(H)),
    ?assertEqual(undefined, ?MODL:flag_path(H)).

ephemeral_seed_false_starts_pre_bootstrap_test() ->
    H = ?MODL:open(<<"eph2">>, #{seed => false}),
    ?assertEqual(pre_bootstrap, ?MODL:state(H)),
    ?assertNot(?MODL:is_live(H)).

ephemeral_mark_live_works_test() ->
    H = ?MODL:open(<<"eph3">>, #{seed => false}),
    ?assertEqual(pre_bootstrap, ?MODL:state(H)),
    ok = ?MODL:mark_live(H),
    ?assertEqual(live, ?MODL:state(H)).

%% =============================================================================
%% Persistent instance defaults
%% =============================================================================

persistent_no_flag_no_seed_starts_pre_bootstrap_test() ->
    Tmp = mk_tmp_dir(),
    try
        H = ?MODL:open(<<"p1">>, #{
            storage_path => Tmp,
            path_layout => flat
        }),
        ?assertEqual(pre_bootstrap, ?MODL:state(H)),
        Path = ?MODL:flag_path(H),
        ?assert(is_binary(Path) orelse is_list(Path)),
        ?assertNot(filelib:is_regular(Path))
    after
        rm_rf(Tmp)
    end.

persistent_seed_true_starts_live_and_persists_flag_test() ->
    Tmp = mk_tmp_dir(),
    try
        H = ?MODL:open(<<"p2">>, #{
            storage_path => Tmp,
            path_layout => flat,
            seed => true
        }),
        ?assertEqual(live, ?MODL:state(H)),
        Path = ?MODL:flag_path(H),
        ?assert(
            filelib:is_regular(Path),
            "seed:true must persist lifecycle.live"
        )
    after
        rm_rf(Tmp)
    end.

persistent_existing_flag_overrides_seed_false_test() ->
    Tmp = mk_tmp_dir(),
    try
        Id = <<"p3">>,
        %% Plant a flag file as if a previous bootstrap had completed.
        ok = filelib:ensure_dir(filename:join([Tmp, Id, "x"])),
        Flag = filename:join([Tmp, Id, "lifecycle.live"]),
        ok = file:write_file(Flag, <<>>),
        H = ?MODL:open(Id, #{
            storage_path => Tmp,
            path_layout => flat,
            seed => false
        }),
        ?assertEqual(live, ?MODL:state(H))
    after
        rm_rf(Tmp)
    end.

%% =============================================================================
%% Transition durability
%% =============================================================================

mark_live_persists_flag_test() ->
    Tmp = mk_tmp_dir(),
    try
        H = ?MODL:open(<<"p4">>, #{
            storage_path => Tmp,
            path_layout => flat
        }),
        ?assertEqual(pre_bootstrap, ?MODL:state(H)),
        ok = ?MODL:mark_live(H),
        ?assertEqual(live, ?MODL:state(H)),
        ?assert(filelib:is_regular(?MODL:flag_path(H)))
    after
        rm_rf(Tmp)
    end.

mark_live_idempotent_test() ->
    Tmp = mk_tmp_dir(),
    try
        H = ?MODL:open(<<"p5">>, #{
            storage_path => Tmp,
            path_layout => flat
        }),
        ok = ?MODL:mark_live(H),
        %% Calling again must not error.
        ok = ?MODL:mark_live(H),
        ?assertEqual(live, ?MODL:state(H))
    after
        rm_rf(Tmp)
    end.

restart_after_mark_live_sees_live_test() ->
    Tmp = mk_tmp_dir(),
    Id = <<"p6">>,
    try
        Opts = #{
            storage_path => Tmp,
            path_layout => flat
        },
        H1 = ?MODL:open(Id, Opts),
        ?assertEqual(pre_bootstrap, ?MODL:state(H1)),
        ok = ?MODL:mark_live(H1),
        %% Simulate a fresh process start: open a brand-new handle
        %% from the same on-disk directory. seed defaults to false.
        H2 = ?MODL:open(Id, Opts),
        ?assertEqual(live, ?MODL:state(H2))
    after
        rm_rf(Tmp)
    end.

restart_without_mark_live_sees_pre_bootstrap_test() ->
    %% Crash before mark_live: the flag file was never created, so
    %% restart goes back to pre_bootstrap and a re-run of bootstrap is
    %% required. This is the §2.4 ordering invariant in action.
    Tmp = mk_tmp_dir(),
    Id = <<"p7">>,
    try
        Opts = #{
            storage_path => Tmp,
            path_layout => flat
        },
        _H1 = ?MODL:open(Id, Opts),
        %% Drop the handle without calling mark_live, then "restart".
        H2 = ?MODL:open(Id, Opts),
        ?assertEqual(pre_bootstrap, ?MODL:state(H2))
    after
        rm_rf(Tmp)
    end.

%% =============================================================================
%% Path strategy honoured
%% =============================================================================

uses_configured_path_layout_test() ->
    Tmp = mk_tmp_dir(),
    Id = <<"p8">>,
    try
        H = ?MODL:open(Id, #{
            storage_path => Tmp,
            path_layout => flat
        }),
        ExpectedDir = bondy_oplog_path:storage_path(Id, Tmp, flat),
        ExpectedPath = filename:join(
            unicode:characters_to_binary(ExpectedDir),
            "lifecycle.live"
        ),
        ?assertEqual(ExpectedPath, ?MODL:flag_path(H))
    after
        rm_rf(Tmp)
    end.

defaults_to_sharded_path_layout_test() ->
    Tmp = mk_tmp_dir(),
    Id = <<"p9">>,
    try
        H = ?MODL:open(Id, #{storage_path => Tmp}),
        ExpectedDir = bondy_oplog_path:storage_path(Id, Tmp, sharded),
        ExpectedPath = filename:join(
            unicode:characters_to_binary(ExpectedDir),
            "lifecycle.live"
        ),
        ?assertEqual(ExpectedPath, ?MODL:flag_path(H))
    after
        rm_rf(Tmp)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

mk_tmp_dir() ->
    Base = filename:join(
        ["/tmp", "bondy_mst_lifecycle_test", os:getpid()]
    ),
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    Dir = filename:join(Base, Suffix),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    unicode:characters_to_binary(Dir).

rm_rf(Dir0) ->
    Dir = unicode:characters_to_list(Dir0),
    case filelib:is_dir(Dir) of
        true ->
            {ok, Entries} = file:list_dir(Dir),
            lists:foreach(
                fun(E) ->
                    P = filename:join(Dir, E),
                    case filelib:is_dir(P) of
                        true -> rm_rf(P);
                        false -> file:delete(P)
                    end
                end,
                Entries
            ),
            file:del_dir(Dir);
        false ->
            ok
    end.
