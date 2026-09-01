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

`bondy.alarm.history` is here for the same reason, and more sharply: it walks
the cluster ONE NODE AT A TIME, and three of its properties are invisible on a
single node because that node is read directly and can neither fail nor be
skipped.

  * SPAN — one page crosses from this node's ring into a peer's once the first
    is exhausted. Without it "cluster-wide history" is a local ring.
  * NAMING — a peer that was ASKED and did not answer is named in
    `not_reached`, and STAYS named on every later page of the walk. A short
    page and a complete one must not read alike.
  * DEFERRAL — a peer the time budget did not get to is NOT named: it is left
    in the cursor and asked next page. The budget is shared by the whole page,
    which is the only reason a walk over n unreachable peers costs one timeout
    rather than n.

The last two are the ones `bondy_alarm_api_SUITE` cannot hold: mutants that
name a deferred node, or spend a fresh budget per node, pass every case there
(mutation-checked 2026-09-01).
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
        a_history_page_spans_both_rings,
        an_exhausted_budget_defers_without_naming,
        a_stopped_peer_is_silent_not_absent,
        a_stopped_peer_is_named_in_not_reached,
        not_reached_accumulates_across_pages
    ].

suite() ->
    [{timetrap, {minutes, 10}}].

init_per_suite(Config) ->
    Cluster = bondy_ct:start_cluster(?NODE_NAMES, Config),
    _ = [push_module(Node, ?MODULE) || {_, Node, _} <- Cluster],
    %% Both names are recorded while both nodes are UP: the later cases stop
    %% node 2 and a stopped node cannot be asked what it is called.
    Names = lists:append([
        [
            {{nodestring, N}, nodestring_of(N)},
            {{partisan_node, N}, partisan_node_of(N)}
        ]
     || {_, N, _} <- Cluster
    ]),
    [{cluster, Cluster} | Names] ++ Config.

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

%% One page crosses from this node's ring into the peer's once the first is
%% exhausted. The ring is capped at 100 per node, so a limit above that drains
%% node 1 and reaches node 2 in the SAME page — which is what makes it a
%% cluster walk rather than a local read with a peer bolted on.
a_history_page_spans_both_rings(Config) ->
    [N1, N2] = nodes_of(Config),
    ok = erpc:call(N1, ?MODULE, do_raise, [<<"local relay down">>]),
    ok = erpc:call(N2, ?MODULE, do_raise, [<<"peer relay down">>]),

    Page = history_on(N1, #{~"limit" => 1000}),

    ?assertEqual([], maps:get(<<"not_reached">>, Page)),
    ?assertEqual(false, maps:get(<<"has_more">>, Page)),
    Nodes = nodes_in(Page),
    ?assert(lists:member(nodestring_of(N1), Nodes), {missing_n1, Nodes}),
    ?assert(lists:member(nodestring_of(N2), Nodes), {missing_n2, Nodes}),

    ok = erpc:call(N1, ?MODULE, do_clear, []),
    ok = erpc:call(N2, ?MODULE, do_clear, []).

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

%% From here on node 2 is STOPPED but still a member.

%% A peer that was ASKED and did not answer is NAMED. The walk always starts
%% with the node being asked, so the cursor is re-minted to put the stopped
%% peer first — the state a walk is in the moment it reaches a dead member.
a_stopped_peer_is_named_in_not_reached(Config) ->
    [N1, N2] = nodes_of(Config),
    ok = erpc:call(N1, ?MODULE, do_raise, [<<"local relay down">>]),
    Page = history_on(N1, #{~"cursor" => peer_first(Config)}),

    ?assertEqual(
        [nodestring_of_stopped(Config, N2)],
        maps:get(<<"not_reached">>, Page)
    ),
    %% And node 1 still answered for itself with its peer dead.
    ?assert(length(maps:get(<<"values">>, Page)) > 0).

%% `not_reached` rides in the CURSOR, so a peer that went unheard on page 1 is
%% still named on page 2 — the last page of a walk states the whole truth about
%% it. A caller reading only the final page, which is what a progressive caller
%% effectively does, would otherwise conclude the walk had been complete.
not_reached_accumulates_across_pages(Config) ->
    [N1, N2] = nodes_of(Config),
    _ = [
        erpc:call(N1, ?MODULE, do_raise, [
            <<"local relay down ", (integer_to_binary(I))/binary>>
        ])
     || I <- lists:seq(1, 3)
    ],
    Expected = [nodestring_of_stopped(Config, N2)],

    Page1 = history_on(N1, #{
        ~"limit" => 1, ~"cursor" => peer_first(Config)
    }),
    ?assertEqual(Expected, maps:get(<<"not_reached">>, Page1)),
    ?assertEqual(true, maps:get(<<"has_more">>, Page1)),

    %% Page 2 never asks the dead peer — the walk has moved past it — so the
    %% only way it can still name it is the cursor.
    Page2 = history_on(N1, #{
        ~"limit" => 1, ~"cursor" => maps:get(<<"cursor">>, Page1)
    }),
    ?assertEqual(Expected, maps:get(<<"not_reached">>, Page2)).

%% The budget is shared by the whole page, and a node the budget did not get to
%% is DEFERRED, not named: it is left in the cursor and asked next page.
%%
%% Forced by SUSPENDING node 2's alarm manager, so the RPC to it blocks until
%% the deadline instead of failing. That is the whole point: a peer that is
%% DOWN fails immediately and consumes no budget, so only a peer that is up and
%% not answering — the case the timeout exists for — can exhaust one. It is
%% walked first, and the 200ms `_deadline` is provably gone by the time the
%% walk reaches node 1.
%%
%% With a fresh budget per node — the shape this replaced — node 1 would be
%% read and the page would carry its events.
an_exhausted_budget_defers_without_naming(Config) ->
    [N1, N2] = nodes_of(Config),
    ok = erpc:call(N1, ?MODULE, do_raise, [<<"local relay down">>]),
    Cursor = peer_first(Config),

    ok = erpc:call(N2, ?MODULE, do_suspend, []),
    Page =
        try
            history_on(
                N1,
                #{~"limit" => 1000, ~"cursor" => Cursor},
                #{'_deadline' => 200}
            )
        after
            ok = erpc:call(N2, ?MODULE, do_resume, [])
        end,

    %% Node 2 was asked and did not answer, so it is named.
    ?assertEqual(
        [nodestring_of_stopped(Config, N2)], maps:get(<<"not_reached">>, Page)
    ),
    %% Node 1 was never reached, and is NOT named — it is in the cursor.
    ?assertEqual([], maps:get(<<"values">>, Page)),
    ?assertEqual(true, maps:get(<<"has_more">>, Page)),

    %% And the deferral costs nothing: resuming reaches node 1.
    Next = history_on(N1, #{~"cursor" => maps:get(<<"cursor">>, Page)}),
    ?assert(length(maps:get(<<"values">>, Next)) > 0),
    ?assertEqual(
        [nodestring_of_stopped(Config, N2)], maps:get(<<"not_reached">>, Next)
    ),

    ok = erpc:call(N1, ?MODULE, do_clear, []).

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
    do_call(Proc, Args, #{}, #{}).

%% @private
do_call(Proc, Args, KWArgs, Options) ->
    Ctxt = bondy_context:local_context(?MASTER_REALM_URI),
    M = bondy_wamp_message:call(1, Options, Proc, Args, KWArgs),
    case bondy_wamp_api:handle_call(M, Ctxt) of
        {reply, #result{args = [Reply]}} -> Reply;
        Other -> {unexpected, Other}
    end.

%% @private
do_node() ->
    partisan:node().

%% @private
%% `local_history/2` reads the ring with `gen_event:call(alarm_handler, ...)`,
%% so a suspended manager makes the RPC block rather than fail — the only way
%% to spend a time budget on purpose.
do_suspend() ->
    sys:suspend(alarm_handler).

%% @private
do_resume() ->
    sys:resume(alarm_handler).

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
history_on(Node, KWArgs) ->
    history_on(Node, KWArgs, #{}).

%% @private
history_on(Node, KWArgs, Options) ->
    erpc:call(
        Node, ?MODULE, do_call, [<<"bondy.alarm.history">>, [], KWArgs, Options]
    ).

%% @private
%% A peer's PARTISAN node name, which is what the walk's node list holds.
partisan_node_of(Node) ->
    erpc:call(Node, ?MODULE, do_node, []).

%% @private
%% `Page`'s cursor, re-minted to walk `Nodes` instead — the only way to put a
%% chosen node FIRST, since the walk always starts with the node being asked.
%% Fingerprint and payload come from a real cursor rather than being restated.
reroute(Page, Nodes) ->
    C = binary_to_term(base64:decode(maps:get(<<"cursor">>, Page)), [safe]),
    bondy_pagination:encode_cursor(
        bondy_pagination:new_cursor(
            bondy_pagination:fingerprint(C),
            (bondy_pagination:payload(C))#{nodes => Nodes}
        )
    ).

%% @private
%% A cursor over `[peer, this node]`, which is the only way to put the peer
%% FIRST — the walk always starts with the node being asked.
%%
%% Both are MEMBERS, up or not: a stopped node does not leave the membership,
%% which is exactly why `bondy.alarm.list` can report it silent, and it is why
%% this node list survives the cursor's membership intersection intact.
peer_first(Config) ->
    [N1, N2] = nodes_of(Config),
    Seed = history_on(N1, #{~"limit" => 1}),
    reroute(Seed, [
        ?config({partisan_node, N2}, Config),
        ?config({partisan_node, N1}, Config)
    ]).

%% @private
%% Names are read in `init_per_suite` while both nodes are up, because a
%% stopped node cannot be asked what it is called.
nodestring_of_stopped(Config, Node) ->
    ?config({nodestring, Node}, Config).

%% @private
nodes_in(Page) ->
    lists:usort([maps:get(<<"node">>, E) || E <- maps:get(<<"values">>, Page)]).

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
