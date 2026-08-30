%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_alarm_cluster_SUITE).
-moduledoc """
The `bondy.alarm.list` / `.get` cluster fan-out, on a real 2-node cluster.

This suite exists because nothing smaller can falsify the mechanism. On one
node the reply is `answered: [me], silent: []` whether the fan-out works
perfectly or is not wired at all, so `bondy_alarm_api_SUITE` — which is the
single-node suite — cannot tell those apart. Only a second node can.

Three properties, in the order they matter:

  * REACH — an alarm raised on node 2 appears in node 1's reply, carrying
    node 2's name. Without this the "cluster view" is a local list with extra
    fields.
  * PARTITION — `answered` and `silent` partition the membership: every member
    is in exactly one, always. This is the property §6 of the design is about,
    and it is what stops "node X has no alarms" being read as "node X is
    silent".
  * DEGRADATION — with node 2 stopped, node 1 still answers for itself and
    reports node 2 SILENT rather than absent. A node dropping out of the reply
    entirely is the failure this design was built to prevent: the missing node
    is usually the interesting one.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").

-compile([nowarn_export_all, export_all]).

-define(NODE_NAMES, [alarmfan1, alarmfan2]).

%% Catalogued, so the reply carries `integration` — a class the handler's
%% constant default (`node`) would not produce. Evidence the record crossed the
%% wire whole rather than being rebuilt locally.
-define(ALARM_ID, {mail_relay_down, <<"cluster_fanout">>}).

%% =============================================================================
%% CT CALLBACKS
%% =============================================================================

all() ->
    [
        an_alarm_on_a_peer_reaches_the_local_reply,
        get_finds_a_peer_alarm,
        answered_and_silent_partition_the_membership,
        a_stopped_peer_is_silent_not_absent
    ].

suite() ->
    [{timetrap, {minutes, 10}}].

init_per_suite(Config) ->
    Nodes = bondy_ct:start_cluster(?NODE_NAMES, Config),
    _ = [push_module(Node, ?MODULE) || {_, Node, _} <- Nodes],
    [{cluster, Nodes} | Config].

end_per_suite(Config) ->
    %% `a_stopped_peer_is_silent_not_absent` stops node 2, so this must tolerate
    %% a cluster that is already partly down.
    try
        bondy_ct:stop_cluster(?config(cluster, Config))
    catch
        _:_ -> ok
    end,
    Config.

%% =============================================================================
%% TESTS
%% =============================================================================

%% The load-bearing case: the alarm is raised ONLY on node 2 and read ONLY on
%% node 1.
an_alarm_on_a_peer_reaches_the_local_reply(Config) ->
    [N1, N2] = nodes_of(Config),
    ok = erpc:call(N2, ?MODULE, do_raise, [<<"peer relay down">>]),

    #{<<"alarms">> := Alarms, <<"nodes">> := Nodes} = list_on(N1),
    N2Str = nodestring_of(N2),

    [A] = [X || X <- Alarms, maps:get(<<"node">>, X) == N2Str],
    ?assertEqual(wire_id(), maps:get(<<"id">>, A)),
    ?assertEqual(<<"peer relay down">>, maps:get(<<"description">>, A)),
    %% The catalogue join happened on node 2 and survived the hop.
    ?assertEqual(<<"integration">>, maps:get(<<"class">>, A)),

    ?assert(lists:member(N2Str, maps:get(<<"answered">>, Nodes))),
    ?assertEqual([], maps:get(<<"silent">>, Nodes)),

    ok = erpc:call(N2, ?MODULE, do_clear, []).

%% `get` is the same envelope filtered, so it must reach as far as `list` does.
%% A `get` that only searched locally would answer "not here" for an alarm the
%% operator can see in the list they just read.
get_finds_a_peer_alarm(Config) ->
    [N1, N2] = nodes_of(Config),
    ok = erpc:call(N2, ?MODULE, do_raise, [<<"peer relay down">>]),

    #{<<"alarms">> := [A], <<"nodes">> := Nodes} = get_on(N1, wire_id()),
    ?assertEqual(nodestring_of(N2), maps:get(<<"node">>, A)),
    %% The node sets are the envelope's, untouched by the filter — an empty
    %% `alarms` is only definitive when `silent` is empty, so the filter must
    %% not drop them.
    ?assertEqual([], maps:get(<<"silent">>, Nodes)),
    ?assertEqual(2, length(maps:get(<<"answered">>, Nodes))),

    ok = erpc:call(N2, ?MODULE, do_clear, []).

%% Every member in exactly one set, and the union is the membership. Checked
%% from BOTH nodes, because a fan-out that forgets to include the caller reads
%% correctly from whichever node happens to be asked first.
answered_and_silent_partition_the_membership(Config) ->
    [N1, N2] = nodes_of(Config),
    Members = lists:sort([nodestring_of(N) || N <- [N1, N2]]),

    lists:foreach(
        fun(Node) ->
            #{<<"nodes">> := Ns} = list_on(Node),
            Answered = maps:get(<<"answered">>, Ns),
            Silent = maps:get(<<"silent">>, Ns),
            ?assertEqual(
                Members, lists:sort(Answered ++ Silent), {union, Node}
            ),
            ?assertEqual(
                [], intersection(Answered, Silent), {disjoint, Node}
            ),
            %% Whoever was asked always answers for itself: the local alarms
            %% are read directly and never travel.
            ?assert(lists:member(nodestring_of(Node), Answered))
        end,
        [N1, N2]
    ).

%% Runs last: it stops node 2 for the rest of the suite.
a_stopped_peer_is_silent_not_absent(Config) ->
    [N1, N2] = nodes_of(Config),
    N2Str = nodestring_of(N2),
    ok = erpc:call(N1, ?MODULE, do_raise, [<<"local relay down">>]),

    ok = stop_peer(Config, N2),

    #{<<"alarms">> := Alarms, <<"nodes">> := Nodes} = list_on(N1),
    Answered = maps:get(<<"answered">>, Nodes),
    Silent = maps:get(<<"silent">>, Nodes),

    %% Not absent. A node that vanished from both sets would let an operator
    %% read a partial answer as a clean cluster.
    ?assert(lists:member(N2Str, Silent), {not_silent, Silent}),
    ?assertNot(lists:member(N2Str, Answered)),

    %% And node 1 still answers for itself while its peer is gone.
    ?assert(lists:member(nodestring_of(N1), Answered)),
    ?assertMatch(
        [_ | _], [X || X <- Alarms, maps:get(<<"id">>, X) == wire_id()]
    ).

%% =============================================================================
%% CODE RUN ON THE PEERS
%% =============================================================================

%% @private
%% Raised through the raw OTP call, the spelling every producer in the tree
%% uses.
do_raise(Desc) ->
    alarm_handler:set_alarm({?ALARM_ID, Desc}).

%% @private
do_clear() ->
    alarm_handler:clear_alarm(?ALARM_ID).

%% @private
%% Through `bondy_wamp_api:handle_call/2`, so the dispatch clause is exercised
%% on the node under test rather than bypassed.
do_call(Proc, Args) ->
    Ctxt = bondy_context:local_context(?MASTER_REALM_URI),
    M = bondy_wamp_message:call(1, #{}, Proc, Args),
    case bondy_wamp_api:handle_call(M, Ctxt) of
        {reply, #result{args = [Reply]}} -> Reply;
        Other -> {unexpected, Other}
    end.

%% @private
do_nodestring() ->
    partisan:nodestring().

%% =============================================================================
%% HELPERS (controller side)
%% =============================================================================

%% @private
nodes_of(Config) ->
    [Node || {_, Node, _} <- ?config(cluster, Config)].

%% @private
push_module(Node, Mod) ->
    {Mod, Bin, File} = code:get_object_code(Mod),
    {module, Mod} = erpc:call(Node, code, load_binary, [Mod, File, Bin]),
    ok.

%% @private
%% A peer's Partisan name is NOT its Erlang node name, so it is asked rather
%% than derived.
nodestring_of(Node) ->
    erpc:call(Node, ?MODULE, do_nodestring, []).

%% @private
list_on(Node) ->
    erpc:call(Node, ?MODULE, do_call, [<<"bondy.alarm.list">>, []]).

%% @private
get_on(Node, WireId) ->
    erpc:call(Node, ?MODULE, do_call, [<<"bondy.alarm.get">>, [WireId]]).

%% @private
wire_id() ->
    bondy_alarm_api:wire_id(?ALARM_ID).

%% @private
stop_peer(Config, Node) ->
    [Entry] = [E || {_, N, _} = E <- ?config(cluster, Config), N == Node],
    ok = bondy_ct:stop_node(Entry),
    wait_until_gone(Node, erlang:monotonic_time(millisecond) + 30000).

%% @private
%% The stop is not instant, so this waits for the peer to become unreachable
%% rather than assuming it. Without the wait the case could read a reply taken
%% before the node went down and pass for the wrong reason.
wait_until_gone(Node, Deadline) ->
    try erpc:call(Node, erlang, node, [], 1000) of
        _ ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    error({peer_still_up, Node});
                false ->
                    timer:sleep(200),
                    wait_until_gone(Node, Deadline)
            end
    catch
        _:_ -> ok
    end.

%% @private
intersection(A, B) ->
    [X || X <- A, lists:member(X, B)].
