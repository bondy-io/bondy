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

mk_id() ->
    list_to_binary(
        "obt_" ++
            integer_to_list(
                erlang:unique_integer([positive, monotonic])
            )
    ).
